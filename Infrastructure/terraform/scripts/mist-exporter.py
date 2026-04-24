#!/usr/bin/env python3
"""
MistServer API Prometheus Exporter.

Polls MistServer /api2 for active operator sessions and stream health.
Also polls local filesystem + systemctl for R2 HLS pipeline health.
Exposes metrics on port 9101 for Prometheus to scrape.
"""

import json
import os
import subprocess
import threading
import time
import logging
import sys
import urllib.request
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler
from prometheus_client import (
    Counter, Gauge, CollectorRegistry, generate_latest, CONTENT_TYPE_LATEST
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

# ── Config ────────────────────────────────────────────────────────────────────

_raw_streams = os.environ.get("STREAMS_JSON", "")
STREAMS = json.loads(_raw_streams) if _raw_streams else [
    {"name": "geo+ent",  "port": 1238},
    {"name": "geo+news", "port": 1236},
]
STREAM_NAMES = [s["name"] for s in STREAMS]

METRICS_PORT     = int(os.environ.get("EXPORTER_PORT", "9101"))
MIST_API_PORT    = os.environ.get("MIST_API_PORT", "4242")
MIST_API_URL     = f"http://127.0.0.1:{MIST_API_PORT}/api2"
SESSION_POLL_SECS = 10
R2_POLL_SECS      = 5
HLS_BASE_DIR      = "/var/lib/mist-hls"

# ── Prometheus metrics ────────────────────────────────────────────────────────

registry = CollectorRegistry()

# Operator sessions (from /api2?clients)
operator_sessions = Gauge(
    "mist_operator_sessions_total",
    "Active operator sessions per stream, direction and connector",
    ["stream", "direction", "connector"],
    registry=registry,
)
session_bytes = Gauge(
    "mist_operator_session_bytes",
    "Bytes transferred per active operator session",
    ["stream", "ip", "direction", "connector"],
    registry=registry,
)
session_uptime = Gauge(
    "mist_operator_session_uptime_seconds",
    "Uptime in seconds of active operator session",
    ["stream", "ip", "connector"],
    registry=registry,
)

# Stream health (from /api2?active_streams)
stream_up = Gauge(
    "mist_stream_up",
    "1 if stream is online in MistServer",
    ["stream"],
    registry=registry,
)
stream_bitrate = Gauge(
    "mist_stream_bitrate_kbits",
    "Per-track bitrate in kbits/s",
    ["stream", "track"],
    registry=registry,
)
stream_fps = Gauge(
    "mist_stream_fps",
    "Video frames per second",
    ["stream"],
    registry=registry,
)
stream_jitter = Gauge(
    "mist_stream_jitter_ms",
    "Stream jitter in milliseconds",
    ["stream"],
    registry=registry,
)
stream_buffer = Gauge(
    "mist_stream_buffer_ms",
    "Stream buffer size in milliseconds",
    ["stream"],
    registry=registry,
)

# R2 HLS pipeline (filesystem + systemctl)
r2_ffmpeg_up = Gauge(
    "r2_ffmpeg_up",
    "1 if ffmpeg HLS writer service is active",
    ["stream"],
    registry=registry,
)
r2_segment_lag = Gauge(
    "r2_segment_lag_count",
    "HLS segments written locally but not yet in R2",
    ["stream"],
    registry=registry,
)
r2_segment_age = Gauge(
    "r2_latest_segment_age_seconds",
    "Age in seconds of the most recently written local HLS segment",
    ["stream"],
    registry=registry,
)
r2_upload_errors = Counter(
    "r2_upload_errors_total",
    "Upload errors from the seg-push service",
    ["stream"],
    registry=registry,
)

# Initialise labels so metrics appear even before first poll
for _s in STREAM_NAMES:
    stream_up.labels(stream=_s).set(0)
    stream_fps.labels(stream=_s).set(0)
    stream_jitter.labels(stream=_s).set(0)
    stream_buffer.labels(stream=_s).set(0)
    r2_ffmpeg_up.labels(stream=_s).set(0)
    r2_segment_lag.labels(stream=_s).set(0)
    r2_segment_age.labels(stream=_s).set(0)
    r2_upload_errors.labels(stream=_s)
    for _d in ("input", "output", "unknown"):
        for _c in ("TSSRT", "HLS", "HTTP", "unknown"):
            operator_sessions.labels(stream=_s, direction=_d, connector=_c).set(0)

# ── MistServer API helpers ────────────────────────────────────────────────────

def mist_get(query_param: str) -> dict:
    url = f"{MIST_API_URL}?{query_param}"
    with urllib.request.urlopen(url, timeout=5) as resp:
        return json.loads(resp.read())


# ── Session + stream health poller ───────────────────────────────────────────

def poll_sessions_and_streams():
    while True:
        try:
            _poll_clients()
        except Exception as e:
            log.warning("clients poll error: %s", e)
        try:
            _poll_active_streams()
        except Exception as e:
            log.warning("active_streams poll error: %s", e)
        time.sleep(SESSION_POLL_SECS)


def _poll_clients():
    data = mist_get("clients")
    # Response: {"streams": {"geo+news": {"clients": [...]}}}
    streams_data = data.get("streams", {})

    # Clear old per-session gauges before repopulating
    session_bytes.clear()
    session_uptime.clear()

    counts: dict[tuple[str, str, str], int] = {}

    for stream_name, stream_info in streams_data.items():
        if stream_name not in STREAM_NAMES:
            continue
        clients = stream_info.get("clients", [])
        for client in clients:
            if not isinstance(client, dict):
                continue
            direction  = client.get("direction", "unknown")
            connector  = client.get("connector", "unknown")
            ip = client.get("ip", "unknown")
            # Strip IPv6-mapped prefix
            ip = ip.replace("::ffff:", "").strip("[]").split(":")[0] if "::ffff:" in ip or ip.startswith("[") else ip
            bytes_val  = client.get("bytes", 0)
            uptime_ms  = client.get("ms", 0)

            key = (stream_name, direction, connector)
            counts[key] = counts.get(key, 0) + 1
            session_bytes.labels(stream=stream_name, ip=ip, direction=direction, connector=connector).set(bytes_val)
            session_uptime.labels(stream=stream_name, ip=ip, connector=connector).set(uptime_ms / 1000.0)

    # Reset all known combos to 0, then set actuals
    for name in STREAM_NAMES:
        for direction in ("input", "output", "unknown"):
            for connector in ("TSSRT", "HLS", "HTTP", "unknown"):
                operator_sessions.labels(stream=name, direction=direction, connector=connector).set(
                    counts.get((name, direction, connector), 0)
                )


def _poll_active_streams():
    data = mist_get("active_streams")
    active = data.get("active_streams", {})

    for name in STREAM_NAMES:
        if name not in active:
            stream_up.labels(stream=name).set(0)
            stream_fps.labels(stream=name).set(0)
            stream_jitter.labels(stream=name).set(0)
            stream_buffer.labels(stream=name).set(0)
            continue

        stream_up.labels(stream=name).set(1)
        info = active[name]

        # Per-track bitrate
        tracks = info.get("tracks", {})
        for track_id, track in tracks.items():
            codec = track.get("codec", track_id)
            bps = track.get("bps", 0)
            stream_bitrate.labels(stream=name, track=codec).set(bps / 1000.0)
            if track.get("type") == "video":
                fps = track.get("fpks", 0) / 1000.0
                stream_fps.labels(stream=name).set(fps)

        stream_jitter.labels(stream=name).set(info.get("jitter", 0))
        stream_buffer.labels(stream=name).set(info.get("buffer", 0))


# ── R2 pipeline poller ───────────────────────────────────────────────────────

def _seg_number(filename: str) -> int:
    try:
        return int(filename.replace("seg_", "").replace(".ts", ""))
    except ValueError:
        return -1


def poll_r2_pipeline():
    _prev_error_counts: dict[str, int] = {}

    while True:
        for s in STREAMS:
            name = s["name"]
            safe = name.replace("+", "-").replace(" ", "-")
            hls_dir = os.path.join(HLS_BASE_DIR, name)
            label = {"stream": name}

            try:
                result = subprocess.run(
                    ["systemctl", "is-active", f"mist-hls-writer-{safe}"],
                    capture_output=True, text=True
                )
                r2_ffmpeg_up.labels(**label).set(1 if result.stdout.strip() == "active" else 0)
            except Exception:
                r2_ffmpeg_up.labels(**label).set(0)

            try:
                segs = [f for f in os.listdir(hls_dir) if f.startswith("seg_") and f.endswith(".ts")]
                if segs:
                    segs.sort(key=_seg_number)
                    latest_local = _seg_number(segs[-1])
                    mtime = os.path.getmtime(os.path.join(hls_dir, segs[-1]))
                    r2_segment_age.labels(**label).set(time.time() - mtime)

                    playlist_path = os.path.join(hls_dir, "index.m3u8")
                    if os.path.exists(playlist_path):
                        with open(playlist_path) as f:
                            playlist_segs = [l.strip() for l in f if l.strip() and not l.startswith("#")]
                        if playlist_segs:
                            latest_playlist = _seg_number(playlist_segs[-1])
                            r2_segment_lag.labels(**label).set(max(0, latest_local - latest_playlist))
            except Exception as e:
                log.debug("[r2-poll] %s segment check: %s", name, e)

            try:
                result = subprocess.run(
                    ["journalctl", "-u", f"mist-seg-push-{safe}",
                     "--since", f"{R2_POLL_SECS + 2}s ago",
                     "--no-pager", "-o", "cat"],
                    capture_output=True, text=True
                )
                error_count = result.stdout.lower().count("[seg-push]")
                prev = _prev_error_counts.get(name, 0)
                delta = max(0, error_count - prev)
                if delta:
                    r2_upload_errors.labels(**label).inc(delta)
                _prev_error_counts[name] = error_count
            except Exception:
                pass

        time.sleep(R2_POLL_SECS)


# ── HTTP server ───────────────────────────────────────────────────────────────

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            output = generate_latest(registry)
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.end_headers()
            self.wfile.write(output)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    threading.Thread(target=poll_sessions_and_streams, daemon=True, name="mist-api-poller").start()
    log.info("Started MistServer API poller (interval %ds)", SESSION_POLL_SECS)

    threading.Thread(target=poll_r2_pipeline, daemon=True, name="r2-pipeline-poller").start()
    log.info("Started R2 pipeline poller (interval %ds)", R2_POLL_SECS)

    server = HTTPServer(("0.0.0.0", METRICS_PORT), MetricsHandler)
    log.info("Prometheus metrics available at http://localhost:%d/metrics", METRICS_PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down")
        sys.exit(0)
