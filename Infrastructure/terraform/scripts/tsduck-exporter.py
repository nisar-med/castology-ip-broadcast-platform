#!/usr/bin/env python3
"""
TSduck Prometheus Exporter for MistServer streams.

Runs one tsp process per stream, tapping MistServer's SRT output port.
Parses continuity counter errors and exposes them as Prometheus metrics
on port 9101, which Prometheus scrapes.

Each stream config:
  name: stream name label (e.g. geo+ent)
  port: SRT listener port on MistServer (e.g. 1238)
"""

import json
import os
import subprocess
import threading
import time
import re
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

# ── Stream config ─────────────────────────────────────────────────────────────

_raw_streams = os.environ.get("STREAMS_JSON", "")
STREAMS = json.loads(_raw_streams) if _raw_streams else [
    {"name": "geo+ent",  "port": 1238},
    {"name": "geo+news", "port": 1236},
]

METRICS_PORT   = int(os.environ.get("EXPORTER_PORT", "9101"))
SRT_HOST       = "127.0.0.1"
MIST_API_URL   = f"http://127.0.0.1:{os.environ.get('MIST_API_PORT', '4242')}"
PUSH_POLL_SECS = 10

# ── Prometheus metrics ────────────────────────────────────────────────────────

registry = CollectorRegistry()

cc_errors = Counter(
    "tsduck_cc_errors_total",
    "Continuity counter errors in MPEG-TS stream (indicates dropped packets/frames)",
    ["stream"],
    registry=registry,
)
pcr_errors = Counter(
    "tsduck_pcr_errors_total",
    "PCR timing errors in MPEG-TS stream (indicates timing/jitter issues)",
    ["stream"],
    registry=registry,
)
stream_up = Gauge(
    "tsduck_stream_up",
    "1 if tsp is connected and receiving the stream, 0 otherwise",
    ["stream"],
    registry=registry,
)
bitrate = Gauge(
    "tsduck_bitrate_bps",
    "Current MPEG-TS stream bitrate in bits per second",
    ["stream"],
    registry=registry,
)

push_active = Gauge(
    "mist_push_active_connections",
    "Number of active outbound SRT push connections for the stream",
    ["stream"],
    registry=registry,
)
push_bytes_sent = Counter(
    "mist_push_bytes_sent_total",
    "Total bytes sent over active push connections for the stream",
    ["stream"],
    registry=registry,
)
push_uptime = Gauge(
    "mist_push_uptime_seconds",
    "Uptime in seconds of the longest-running active push connection",
    ["stream"],
    registry=registry,
)

# Initialise labels so metrics appear even before first event
for s in STREAMS:
    cc_errors.labels(stream=s["name"])
    pcr_errors.labels(stream=s["name"])
    stream_up.labels(stream=s["name"]).set(0)
    bitrate.labels(stream=s["name"]).set(0)
    push_active.labels(stream=s["name"]).set(0)
    push_bytes_sent.labels(stream=s["name"])
    push_uptime.labels(stream=s["name"]).set(0)

# ── TSP runner ────────────────────────────────────────────────────────────────

def run_tsp(stream_name: str, port: int):
    """
    Runs tsp in a loop, connecting to MistServer's SRT listener port.
    Parses JSON log lines for CC errors and PCR errors.
    Reconnects automatically on disconnect.
    """
    label = {"stream": stream_name}

    while True:
        log.info("[%s] Starting tsp on SRT port %d", stream_name, port)
        cmd = [
            "tsp",
            "--realtime",
            # Input: connect to MistServer SRT output as a caller
            "-I", "srt",
            "--caller", f"{SRT_HOST}:{port}",
            "--streamid", stream_name,
            "--latency", "500",
            # Plugin: check continuity counters, report errors as JSON
            "-P", "continuity",
            "--json-line=CC:",
            # Plugin: monitor bitrate every 5s, report as JSON
            "-P", "bitrate_monitor",
            "--periodic-bitrate", "5",
            "--json-line=BR:",
            # Drop output — we only want the analysis
            "-O", "drop",
        ]

        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            stream_up.labels(**label).set(1)

            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue

                # Continuity counter error JSON
                if line.startswith("CC:"):
                    try:
                        data = json.loads(line[3:])
                        errors = data.get("error_count", 0)
                        if errors:
                            cc_errors.labels(**label).inc(errors)
                            log.warning("[%s] CC errors: %d", stream_name, errors)
                    except json.JSONDecodeError:
                        pass

                # Bitrate JSON
                elif line.startswith("BR:"):
                    try:
                        data = json.loads(line[3:])
                        bps = data.get("bitrate", 0)
                        bitrate.labels(**label).set(bps)
                    except json.JSONDecodeError:
                        pass

                # Log any tsp errors
                elif "error" in line.lower() or "warning" in line.lower():
                    log.debug("[%s] tsp: %s", stream_name, line)

            proc.wait()

        except Exception as e:
            log.error("[%s] tsp exception: %s", stream_name, e)
        finally:
            stream_up.labels(**label).set(0)
            bitrate.labels(**label).set(0)

        log.info("[%s] tsp disconnected, reconnecting in 5s...", stream_name)
        time.sleep(5)

# ── MistServer push_list poller ───────────────────────────────────────────────

def poll_push_list():
    """
    Polls MistServer push_list API every PUSH_POLL_SECS seconds.
    MistServer runs in local mode so no auth is required from localhost.
    push_list entries are arrays; index 5 is a stats dict when the push is active.

    push entry layout (from MistServer docs/observation):
      [0] push_id (int)
      [1] stream_name (str)
      [2] target_uri (str)
      [3] ... (push config)
      [4] ... (push config)
      [5] stats dict OR 0 when not yet connected
            stats keys: bytes, ms (uptime), active_seconds, etc.
    """
    # Track bytes sent per push_id so we can increment the Counter correctly
    _prev_bytes: dict[int, int] = {}

    while True:
        try:
            payload = json.dumps({"push_list": 1}).encode()
            req = urllib.request.Request(
                MIST_API_URL,
                data=payload,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read())

            entries = data.get("push_list", [])

            # Aggregate per stream name
            counts: dict[str, int]   = {}
            uptime: dict[str, float] = {}
            delta_bytes: dict[str, int] = {}

            for entry in entries:
                if not isinstance(entry, list) or len(entry) < 6:
                    continue
                push_id    = entry[0]
                stream     = entry[1]
                stats      = entry[5]
                if not isinstance(stats, dict):
                    continue  # pending / not yet connected

                counts[stream]      = counts.get(stream, 0) + 1
                sent                = stats.get("bytes", 0)
                prev                = _prev_bytes.get(push_id, sent)
                delta_bytes[stream] = delta_bytes.get(stream, 0) + max(0, sent - prev)
                _prev_bytes[push_id] = sent

                ms = stats.get("ms", 0)
                uptime[stream] = max(uptime.get(stream, 0), ms / 1000.0)

            # Remove stale push_ids that disappeared from the list
            active_ids = {e[0] for e in entries if isinstance(e, list) and len(e) >= 1}
            for pid in list(_prev_bytes):
                if pid not in active_ids:
                    del _prev_bytes[pid]

            # Update metrics for all known streams
            for s in STREAMS:
                name = s["name"]
                push_active.labels(stream=name).set(counts.get(name, 0))
                push_uptime.labels(stream=name).set(uptime.get(name, 0))
                if delta_bytes.get(name, 0) > 0:
                    push_bytes_sent.labels(stream=name).inc(delta_bytes[name])

        except urllib.error.URLError as e:
            log.warning("push_list poll failed: %s", e)
        except Exception as e:
            log.error("push_list poll error: %s", e)

        time.sleep(PUSH_POLL_SECS)


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
        pass  # suppress HTTP access log noise

# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # Start one monitoring thread per stream
    for stream in STREAMS:
        t = threading.Thread(
            target=run_tsp,
            args=(stream["name"], stream["port"]),
            daemon=True,
        )
        t.start()
        log.info("Started monitor for stream '%s' on port %d", stream["name"], stream["port"])

    # Start push_list poller
    threading.Thread(target=poll_push_list, daemon=True, name="push-list-poller").start()
    log.info("Started push_list poller (interval %ds)", PUSH_POLL_SECS)

    # Start Prometheus metrics HTTP server
    server = HTTPServer(("0.0.0.0", METRICS_PORT), MetricsHandler)
    log.info("Prometheus metrics available at http://localhost:%d/metrics", METRICS_PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down")
        sys.exit(0)
