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

# Stream health
stream_up = Gauge(
    "mist_stream_up",
    "1 if stream is online in MistServer",
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

def mist_post(payload: dict) -> dict:
    MIST_API_V1 = f"http://127.0.0.1:{MIST_API_PORT}/api"
    data = json.dumps(payload).encode()
    req = urllib.request.Request(MIST_API_V1, data=data,
                                  headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as resp:
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
    # POST /api {"clients": null} returns:
    # {"clients": {"fields": ["host","stream","protocol","conntime","position",
    #                         "down","up","downbps","upbps","sessid",
    #                         "pktcount","pktlost","pktretransmit"],
    #              "data": [[...], ...]}}
    data = mist_post({"clients": None})
    clients_block = data.get("clients", {})
    fields = clients_block.get("fields", [])
    rows   = clients_block.get("data", [])

    if not fields:
        return

    fi = {f: i for i, f in enumerate(fields)}

    # Clear old per-session gauges before repopulating
    session_bytes.clear()
    session_uptime.clear()

    counts: dict[tuple[str, str, str], int] = {}

    for row in rows:
        if not isinstance(row, list) or len(row) < len(fields):
            continue

        stream    = row[fi["stream"]]
        if stream not in STREAM_NAMES:
            continue

        protocol  = row[fi["protocol"]]          # e.g. "OUTPUT:TSSRT"
        direction, _, connector = protocol.partition(":")
        direction  = direction.lower()            # "input" / "output"
        connector  = connector or "unknown"       # "TSSRT" / "HLS" / "HTTP"

        ip         = row[fi["host"]]
        ip = ip.replace("::ffff:", "").strip("[]").split(":")[0] if "::ffff:" in ip or ip.startswith("[") else ip

        conntime   = row[fi["conntime"]]          # seconds
        down_bytes = row[fi["down"]]
        up_bytes   = row[fi["up"]]
        bytes_val  = down_bytes + up_bytes

        key = (stream, direction, connector)
        counts[key] = counts.get(key, 0) + 1
        session_bytes.labels(stream=stream, ip=ip, direction=direction, connector=connector).set(bytes_val)
        session_uptime.labels(stream=stream, ip=ip, connector=connector).set(conntime)

    # Reset all known combos to 0, then set actuals
    for name in STREAM_NAMES:
        for direction in ("input", "output", "unknown"):
            for connector in ("TSSRT", "HLS", "HTTP", "unknown"):
                operator_sessions.labels(stream=name, direction=direction, connector=connector).set(
                    counts.get((name, direction, connector), 0)
                )


def _poll_active_streams():
    # POST /api {"active_streams": null} returns a list of online stream names
    data = mist_post({"active_streams": None})
    active = data.get("active_streams", [])
    if isinstance(active, dict):
        active = list(active.keys())

    for name in STREAM_NAMES:
        stream_up.labels(stream=name).set(1 if name in active else 0)


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
