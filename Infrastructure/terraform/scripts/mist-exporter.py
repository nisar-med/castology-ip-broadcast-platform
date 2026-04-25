#!/usr/bin/env python3
"""
MistServer API Prometheus Exporter.

Polls MistServer /api for active sessions and stream health.
Polls PocketBase for broadcaster/operator config and checks expected
sessions are connected. Flags unregistered sessions.
Exposes metrics on port 9101 for Prometheus to scrape.
"""

import json
import ipaddress
import os
import re
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
    {"name": "geo+ent"},
    {"name": "geo+news"},
]
STREAM_NAMES = [s["name"] for s in STREAMS]

METRICS_PORT      = int(os.environ.get("EXPORTER_PORT", "9101"))
MIST_API_PORT     = os.environ.get("MIST_API_PORT", "4242")
MIST_API_URL      = f"http://127.0.0.1:{MIST_API_PORT}/api"
PB_URL            = os.environ.get("PB_URL", "http://127.0.0.1:8090")
PB_EMAIL          = os.environ.get("PB_EMAIL", "admin@castology.tv")
PB_PASS           = os.environ.get("PB_PASS", "")

SESSION_POLL_SECS = 10
HEALTH_POLL_SECS  = 60
R2_POLL_SECS      = 5
HLS_BASE_DIR      = "/var/lib/mist-hls"
CLIENTS_LOOKBACK_SECS = int(os.environ.get("CLIENTS_LOOKBACK_SECS", "3"))
AUTH_LOG_LOOKBACK_SECS = int(os.environ.get("AUTH_LOG_LOOKBACK_SECS", "86400"))
AUTH_LOG_MAX_LINES = int(os.environ.get("AUTH_LOG_MAX_LINES", "500"))

# Packet loss alert threshold — alert if lost/sent > this over the scrape window
PACKET_LOSS_THRESHOLD = 0.02  # 2%

# ── Prometheus metrics ────────────────────────────────────────────────────────

registry = CollectorRegistry()

# Active sessions (from POST /api {"clients": null})
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
session_pkt_loss = Gauge(
    "mist_session_packet_loss_ratio",
    "Packet loss ratio (lost/sent) for active SRT session",
    ["stream", "ip", "direction"],
    registry=registry,
)

# Stream health
stream_up = Gauge(
    "mist_stream_up",
    "1 if stream is online in MistServer",
    ["stream"],
    registry=registry,
)

# Health checks against PocketBase config
# One series per configured entity×stream. ip=connected IP or "none" when offline.
connection_status = Gauge(
    "mist_connection_status",
    "1 if connected, 0 if offline. name=broadcaster or group, role=broadcaster|operator, ip=connected IP or none",
    ["name", "stream", "role", "ip"],
    registry=registry,
)

# Pre-joined table metrics — all share {name, stream, ip} so Grafana merge works cleanly
ingest_status   = Gauge("mist_ingest_status",    "Ingest connection: 1=online 0=offline", ["name", "stream", "ip"], registry=registry)
ingest_jitter   = Gauge("mist_ingest_jitter_ms", "Ingest stream jitter in ms",            ["name", "stream", "ip"], registry=registry)
ingest_loss     = Gauge("mist_ingest_loss",      "Ingest packet loss ratio",              ["name", "stream", "ip"], registry=registry)
broadcaster_feed_status = Gauge(
    "mist_broadcaster_feed_status",
    "Broadcaster feed connection: 1=online 0=offline",
    ["name", "stream", "feed_role", "ip"],
    registry=registry,
)
broadcaster_feed_jitter = Gauge(
    "mist_broadcaster_feed_jitter_ms",
    "Broadcaster feed stream jitter in ms",
    ["name", "stream", "feed_role", "ip"],
    registry=registry,
)
broadcaster_feed_loss = Gauge(
    "mist_broadcaster_feed_loss",
    "Broadcaster feed packet loss ratio",
    ["name", "stream", "feed_role", "ip"],
    registry=registry,
)
affiliate_client_status = Gauge(
    "mist_affiliate_client_status",
    "Affiliate client connection: 1=online 0=offline",
    ["name", "stream", "client_name", "endpoint_role", "ip"],
    registry=registry,
)
affiliate_client_loss = Gauge(
    "mist_affiliate_client_loss",
    "Affiliate client packet loss ratio",
    ["name", "stream", "client_name", "endpoint_role", "ip"],
    registry=registry,
)
affiliate_client_bytes = Gauge(
    "mist_affiliate_client_bytes",
    "Affiliate client bytes transferred",
    ["name", "stream", "client_name", "endpoint_role", "ip"],
    registry=registry,
)
affiliate_client_uptime = Gauge(
    "mist_affiliate_client_uptime_seconds",
    "Affiliate client session uptime seconds",
    ["name", "stream", "client_name", "endpoint_role", "ip"],
    registry=registry,
)
playout_status  = Gauge("mist_playout_status",   "Playout connection: 1=online 0=offline",["name", "stream", "ip"], registry=registry)
playout_loss    = Gauge("mist_playout_loss",     "Playout packet loss ratio",             ["name", "stream", "ip"], registry=registry)
playout_bytes   = Gauge("mist_playout_bytes",    "Playout bytes transferred",             ["name", "stream", "ip"], registry=registry)
playout_uptime  = Gauge("mist_playout_uptime_seconds", "Playout session uptime seconds",  ["name", "stream", "ip"], registry=registry)
session_unregistered = Gauge(
    "mist_session_unregistered",
    "1 if an active session has no matching token in PocketBase",
    ["stream", "ip", "direction", "connector"],
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

# ── PocketBase config cache (refreshed every HEALTH_POLL_SECS) ───────────────

_pb_lock = threading.Lock()
_pb_config = {
    "broadcasters": [],   # [{"name", "streams": [...], "token_key", "allowed_ips"}]
    "broadcaster_feeds": [],  # [{"broadcaster_name", "stream", "feed_role", "allowed_ips"}]
    "groups": [],         # [{"name", "token_key", "channels": [...], "allowed_ips"}]
    "affiliate_clients": [],  # [{"affiliate_name", "stream", "client_name", "endpoint_role", "allowed_ips"}]
    "tokens": set(),      # all valid token_keys
}

def _pb_auth() -> str:
    data = json.dumps({"identity": PB_EMAIL, "password": PB_PASS}).encode()
    req = urllib.request.Request(
        f"{PB_URL}/api/collections/_superusers/auth-with-password",
        data=data, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())["token"]

def _pb_fetch(token: str, collection: str) -> list:
    req = urllib.request.Request(
        f"{PB_URL}/api/collections/{collection}/records?perPage=200",
        headers={"Authorization": token}
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read()).get("items", [])
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return []
        raise

def poll_pb_config():
    while True:
        try:
            token = _pb_auth()
            broadcasters = _pb_fetch(token, "broadcasters")
            broadcaster_feeds = _pb_fetch(token, "broadcaster_feeds")
            affiliates = _pb_fetch(token, "affiliates")
            affiliate_clients = _pb_fetch(token, "affiliate_clients")

            parsed_broadcasters = []
            for b in broadcasters:
                if not b.get("active", True):
                    continue
                streams = b.get("streams", [])
                if isinstance(streams, str):
                    streams = json.loads(streams)
                parsed_broadcasters.append({
                    "name":       b.get("name", "unknown"),
                    "token_key":  b.get("token_key", ""),
                    "streams":    streams,
                    "allowed_ips": b.get("allowed_ips", ""),
                })

            parsed_groups = []
            tokens = set()
            parsed_broadcaster_feeds = []
            parsed_affiliate_clients = []

            for feed in broadcaster_feeds:
                if not feed.get("active", True):
                    continue
                broadcaster_name = (feed.get("broadcaster_name") or "").strip()
                stream = (feed.get("stream") or "").strip()
                if not broadcaster_name or not stream:
                    continue
                parsed_broadcaster_feeds.append({
                    "broadcaster_name": broadcaster_name,
                    "stream": stream,
                    "feed_role": (feed.get("feed_role") or "primary").strip().lower() or "primary",
                    "allowed_ips": feed.get("allowed_ips", ""),
                    "origin_host": feed.get("origin_host", ""),
                    "notes": feed.get("notes", ""),
                })

            for g in affiliates:
                if not g.get("active", True):
                    continue
                streams = g.get("streams", [])
                if isinstance(streams, str):
                    streams = json.loads(streams)
                tk = g.get("token_key", "")
                parsed_groups.append({
                    "name":       g.get("name", "unknown"),
                    "token_key":  tk,
                    "streams":    streams,
                    "allowed_ips": g.get("allowed_ips", ""),
                })
                if tk:
                    tokens.add(tk)

            for client in affiliate_clients:
                if not client.get("active", True):
                    continue
                affiliate_name = (client.get("affiliate_name") or "").strip()
                stream = (client.get("stream") or "").strip()
                client_name = (client.get("client_name") or "").strip()
                if not affiliate_name or not stream or not client_name:
                    continue
                parsed_affiliate_clients.append({
                    "affiliate_name": affiliate_name,
                    "stream": stream,
                    "client_name": client_name,
                    "endpoint_role": (client.get("endpoint_role") or "primary").strip().lower() or "primary",
                    "allowed_ips": client.get("allowed_ips", ""),
                    "notes": client.get("notes", ""),
                })

            for b in parsed_broadcasters:
                if b["token_key"]:
                    tokens.add(b["token_key"])

            with _pb_lock:
                _pb_config["broadcasters"] = parsed_broadcasters
                _pb_config["broadcaster_feeds"] = parsed_broadcaster_feeds
                _pb_config["groups"] = parsed_groups
                _pb_config["affiliate_clients"] = parsed_affiliate_clients
                _pb_config["tokens"] = tokens

            log.info("PocketBase config refreshed: %d broadcasters, %d broadcaster feeds, %d groups, %d affiliate clients, %d tokens",
                     len(parsed_broadcasters), len(parsed_broadcaster_feeds), len(parsed_groups), len(parsed_affiliate_clients), len(tokens))
        except Exception as e:
            log.warning("PocketBase config poll error: %s", e)

        time.sleep(HEALTH_POLL_SECS)


# ── MistServer API helpers ────────────────────────────────────────────────────

def mist_post(payload: dict) -> dict:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(MIST_API_URL, data=data,
                                  headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())


def _clients_request() -> dict:
    return {"clients": {"time": -CLIENTS_LOOKBACK_SECS}}


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
        try:
            _check_health()
        except Exception as e:
            log.warning("health check error: %s", e)
        time.sleep(SESSION_POLL_SECS)


def _poll_clients():
    # POST /api {"clients": null} →
    # {"clients": {"fields": ["host","stream","protocol","conntime","position",
    #                         "down","up","downbps","upbps","sessid",
    #                         "pktcount","pktlost","pktretransmit"], "data": [...]}}
    data = mist_post(_clients_request())
    clients_block = data.get("clients", {})
    fields = clients_block.get("fields", [])
    rows   = clients_block.get("data", [])

    if not fields:
        session_bytes.clear()
        session_uptime.clear()
        session_pkt_loss.clear()
        session_unregistered.clear()
        return

    fi = {f: i for i, f in enumerate(fields)}

    session_bytes.clear()
    session_uptime.clear()
    session_pkt_loss.clear()
    session_unregistered.clear()

    counts: dict[tuple[str, str, str], int] = {}

    with _pb_lock:
        known_tokens = set(_pb_config["tokens"])

    for row in rows:
        if not isinstance(row, list) or len(row) < len(fields):
            continue

        stream    = row[fi["stream"]]
        protocol  = row[fi["protocol"]]              # e.g. "OUTPUT:TSSRT"
        direction, connector = _parse_protocol(protocol)

        ip = row[fi["host"]]
        ip = ip.replace("::ffff:", "").strip("[]").split(":")[0] if "::ffff:" in ip or ip.startswith("[") else ip

        conntime   = row[fi["conntime"]]
        down_bytes = row[fi["down"]]
        up_bytes   = row[fi["up"]]
        pkt_count  = row[fi["pktcount"]]
        pkt_lost   = row[fi["pktlost"]]

        # Session metrics (all streams, not just configured ones)
        key = (stream, direction, connector)
        counts[key] = counts.get(key, 0) + 1
        session_bytes.labels(stream=stream, ip=ip, direction=direction, connector=connector).set(down_bytes + up_bytes)
        session_uptime.labels(stream=stream, ip=ip, connector=connector).set(conntime)

        if pkt_count > 0:
            loss_ratio = pkt_lost / pkt_count
            session_pkt_loss.labels(stream=stream, ip=ip, direction=direction).set(loss_ratio)
            if loss_ratio > PACKET_LOSS_THRESHOLD:
                log.warning("HIGH PACKET LOSS: stream=%s ip=%s direction=%s loss=%.1f%%",
                            stream, ip, direction, loss_ratio * 100)

        # Unregistered session detection — sessid starts with I/O + token
        sessid = row[fi["sessid"]] if "sessid" in fi else ""
        # sessid format: "O<token_hash>..." — we can't reverse the token from hash,
        # so flag any output session on a known stream where IP isn't in any group
        is_registered = _is_registered(ip, stream, direction, known_tokens, sessid)
        session_unregistered.labels(stream=stream, ip=ip, direction=direction, connector=connector).set(
            0 if is_registered else 1
        )
        if not is_registered:
            log.warning("UNREGISTERED SESSION: stream=%s ip=%s direction=%s connector=%s",
                        stream, ip, direction, connector)

    # Update aggregate counts for configured streams
    for name in STREAM_NAMES:
        for d in ("input", "output", "unknown"):
            for c in ("TSSRT", "HLS", "HTTP", "unknown"):
                operator_sessions.labels(stream=name, direction=d, connector=c).set(
                    counts.get((name, d, c), 0)
                )


def _allowed_ips(raw: str) -> list[str]:
    return [x.strip() for x in raw.split(",") if x.strip()]


def _is_loopback_ip(ip: str) -> bool:
    try:
        return ipaddress.ip_address(ip).is_loopback
    except ValueError:
        return False


def _parse_protocol(protocol: str) -> tuple[str, str]:
    direction, _, connector = protocol.partition(":")
    direction = direction.lower() or "unknown"
    connector = connector or "unknown"
    return direction, connector


def _ip_allowed(ip: str, allowed: list[str]) -> bool:
    if not allowed:
        return True

    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False

    for entry in allowed:
        try:
            if addr in ipaddress.ip_network(entry, strict=False):
                return True
        except ValueError:
            if ip == entry:
                return True

    return False


def _assign_connected_ips(entities, connected_ips: set[str], preferred_names: dict[str, str] | None = None):
    remaining = set(connected_ips)
    assignments = []
    explicit = []
    wildcard = []
    assigned_indexes = set()

    if preferred_names:
        for ip in sorted(list(remaining)):
            preferred_name = preferred_names.get(ip)
            if not preferred_name:
                continue
            for index, entity in enumerate(entities):
                if index in assigned_indexes:
                    continue
                if entity["name"] != preferred_name:
                    continue
                if _ip_allowed(ip, _allowed_ips(entity["allowed_ips"])):
                    assignments.append((entity, ip))
                    assigned_indexes.add(index)
                    remaining.remove(ip)
                    break

    for index, entity in enumerate(entities):
        if index in assigned_indexes:
            continue
        allowed = _allowed_ips(entity["allowed_ips"])
        if allowed:
            explicit.append((index, entity, allowed))
        else:
            wildcard.append((index, entity))

    for index, entity, allowed in explicit:
        match = None
        for entry in allowed:
            candidates = sorted(ip for ip in remaining if _ip_allowed(ip, [entry]))
            if candidates:
                match = candidates[0]
                break
        if match is None:
            match = next((ip for ip in sorted(remaining) if _ip_allowed(ip, allowed)), None)
        assignments.append((entity, match))
        if match is not None:
            remaining.remove(match)
        assigned_indexes.add(index)

    for index, entity in wildcard:
        match = sorted(remaining)[0] if remaining else None
        assignments.append((entity, match))
        if match is not None:
            remaining.remove(match)
        assigned_indexes.add(index)

    return assignments


def _build_broadcaster_feeds(broadcasters: list[dict], broadcaster_feeds: list[dict]) -> dict[str, list[dict]]:
    feeds_by_key: dict[tuple[str, str], list[dict]] = {}
    for feed in broadcaster_feeds:
        feeds_by_key.setdefault((feed["broadcaster_name"], feed["stream"]), []).append(feed)

    stream_feeds: dict[str, list[dict]] = {stream: [] for stream in STREAM_NAMES}
    for broadcaster in broadcasters:
        for stream in broadcaster["streams"]:
            feed_defs = feeds_by_key.get((broadcaster["name"], stream))
            if feed_defs:
                for feed in feed_defs:
                    stream_feeds.setdefault(stream, []).append({
                        "name": broadcaster["name"],
                        "stream": stream,
                        "feed_role": feed["feed_role"],
                        "allowed_ips": feed["allowed_ips"] or broadcaster["allowed_ips"],
                    })
            else:
                stream_feeds.setdefault(stream, []).append({
                    "name": broadcaster["name"],
                    "stream": stream,
                    "feed_role": "primary",
                    "allowed_ips": broadcaster["allowed_ips"],
                })
    return stream_feeds


def _build_affiliate_clients(groups: list[dict], affiliate_clients: list[dict]) -> dict[str, list[dict]]:
    clients_by_key: dict[tuple[str, str], list[dict]] = {}
    for client in affiliate_clients:
        clients_by_key.setdefault((client["affiliate_name"], client["stream"]), []).append(client)

    stream_clients: dict[str, list[dict]] = {stream: [] for stream in STREAM_NAMES}
    for group in groups:
        for stream in group["streams"]:
            client_defs = clients_by_key.get((group["name"], stream))
            if client_defs:
                for client in client_defs:
                    stream_clients.setdefault(stream, []).append({
                        "name": group["name"],
                        "stream": stream,
                        "client_name": client["client_name"],
                        "endpoint_role": client["endpoint_role"],
                        "allowed_ips": client["allowed_ips"] or group["allowed_ips"],
                    })
            else:
                stream_clients.setdefault(stream, []).append({
                    "name": group["name"],
                    "stream": stream,
                    "client_name": group["name"],
                    "endpoint_role": "primary",
                    "allowed_ips": group["allowed_ips"],
                })
    return stream_clients


def _recent_affiliate_auth() -> dict[tuple[str, str], str]:
    cutoff = f"{AUTH_LOG_LOOKBACK_SECS} seconds ago"
    try:
        result = subprocess.run(
            [
                "journalctl",
                "-t", "mist-srt-auth",
                "--since", cutoff,
                "-n", str(AUTH_LOG_MAX_LINES),
                "--no-pager",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except Exception as e:
        log.warning("auth log read error: %s", e)
        return {}

    assignments: dict[tuple[str, str], str] = {}
    for line in result.stdout.splitlines():
        match = re.search(r"ALLOW: stream=(?P<stream>\S+) affiliate=(?P<affiliate>.+?) ip=(?P<ip>\S+)$", line)
        if not match:
            continue
        stream = match.group("stream").strip()
        affiliate = match.group("affiliate").strip()
        ip = match.group("ip").strip()
        if stream and affiliate and ip:
            assignments[(stream, ip)] = affiliate

    return assignments


def _is_registered(ip: str, stream: str, direction: str, known_tokens: set, sessid: str) -> bool:
    with _pb_lock:
        broadcasters = _pb_config["broadcasters"]
        groups = _pb_config["groups"]

    # Input sessions — check broadcaster allowed_ips
    if direction == "input":
        for b in broadcasters:
            if stream in b["streams"]:
                if _ip_allowed(ip, _allowed_ips(b["allowed_ips"])):
                    return True
        return False

    # Output sessions — check operator group allowed_ips
    for g in groups:
        if stream in g["streams"]:
            if _ip_allowed(ip, _allowed_ips(g["allowed_ips"])):
                return True

    return False


def _poll_active_streams():
    data = mist_post({"active_streams": None})
    active = data.get("active_streams", [])
    if isinstance(active, dict):
        active = list(active.keys())

    for name in STREAM_NAMES:
        stream_up.labels(stream=name).set(1 if name in active else 0)


def _check_health():
    """Cross-reference live sessions against PocketBase config."""
    data = mist_post({"clients": {"time": -CLIENTS_LOOKBACK_SECS}, "active_streams": None})
    clients_block = data.get("clients", {})
    fields = clients_block.get("fields", [])
    rows   = clients_block.get("data", [])
    active_streams = data.get("active_streams", [])
    if isinstance(active_streams, dict):
        active_streams = list(active_streams.keys())

    fi = {f: i for i, f in enumerate(fields)} if fields else {}

    # Build sets of what's actually connected
    active_inputs: dict[str, set] = {}   # stream → set of IPs pushing in
    active_outputs: dict[str, set] = {}  # stream → set of IPs pulling out

    for row in rows:
        if not isinstance(row, list) or not fi:
            continue
        stream   = row[fi["stream"]]
        protocol = row[fi["protocol"]]
        direction, connector = _parse_protocol(protocol)
        ip = row[fi["host"]]
        ip = ip.replace("::ffff:", "").strip("[]").split(":")[0] if "::ffff:" in ip or ip.startswith("[") else ip
        if direction == "input":
            active_inputs.setdefault(stream, set()).add(ip)
        elif not _is_loopback_ip(ip):
            active_outputs.setdefault(stream, set()).add(ip)
        elif connector in ("HTTP", "HLS", "unknown"):
            log.info("Ignoring loopback playout session: stream=%s ip=%s connector=%s", stream, ip, connector)

    with _pb_lock:
        broadcasters = list(_pb_config["broadcasters"])
        broadcaster_feeds = list(_pb_config["broadcaster_feeds"])
        groups = list(_pb_config["groups"])
        affiliate_clients = list(_pb_config["affiliate_clients"])

    connection_status.clear()
    ingest_status.clear()
    ingest_jitter.clear()
    ingest_loss.clear()
    broadcaster_feed_status.clear()
    broadcaster_feed_jitter.clear()
    broadcaster_feed_loss.clear()
    affiliate_client_status.clear()
    affiliate_client_loss.clear()
    affiliate_client_bytes.clear()
    affiliate_client_uptime.clear()
    playout_status.clear()
    playout_loss.clear()
    playout_bytes.clear()
    playout_uptime.clear()

    # Build per-IP session data maps for joining
    # stream → jitter (from active_streams data — polled separately, use cached value)
    # ip → {pkt_loss, bytes, uptime} from active sessions
    input_loss:   dict[tuple[str, str], float] = {}   # (stream, ip) → loss ratio
    output_loss:  dict[tuple[str, str], float] = {}   # (stream, ip) → loss ratio
    output_bytes: dict[tuple[str, str], float] = {}   # (stream, ip) → bytes
    output_uptime: dict[tuple[str, str], float] = {}  # (stream, ip) → uptime seconds
    stream_jitter: dict[str, float] = {}  # stream → jitter ms

    for row in rows:
        if not isinstance(row, list) or not fi:
            continue
        stream   = row[fi["stream"]]
        protocol = row[fi["protocol"]]
        direction, _ = _parse_protocol(protocol)
        ip = row[fi["host"]]
        ip = ip.replace("::ffff:", "").strip("[]").split(":")[0] if "::ffff:" in ip or ip.startswith("[") else ip
        pkt_count = row[fi["pktcount"]]
        pkt_lost  = row[fi["pktlost"]]
        loss = pkt_lost / pkt_count if pkt_count > 0 else 0.0
        session_key = (stream, ip)
        if direction == "input":
            input_loss[session_key] = loss
        elif not _is_loopback_ip(ip):
            output_loss[session_key] = loss
            output_bytes[session_key] = row[fi["down"]] + row[fi["up"]]
            output_uptime[session_key] = row[fi["conntime"]]

    # Fetch jitter from active_streams info (already polled in active_streams response)
    try:
        streams_data = mist_post({"active_streams": None})
        raw = streams_data.get("active_streams", {})
        if isinstance(raw, dict):
            for sname, sinfo in raw.items():
                if isinstance(sinfo, dict):
                    stream_jitter[sname] = sinfo.get("jitter", 0)
    except Exception:
        pass

    broadcaster_feed_defs = _build_broadcaster_feeds(broadcasters, broadcaster_feeds)
    broadcaster_summary: dict[tuple[str, str], dict] = {}
    affiliate_auth = _recent_affiliate_auth()

    # Check each broadcaster feed
    for stream in STREAM_NAMES:
        stream_broadcasters = broadcaster_feed_defs.get(stream, [])
        for b, ip in _assign_connected_ips(stream_broadcasters, active_inputs.get(stream, set())):
            summary_key = (b["name"], stream)
            existing = broadcaster_summary.get(summary_key)
            candidate = {
                "ip": ip or "none",
                "status": 1 if ip is not None else 0,
                "jitter": stream_jitter.get(stream, 0) if ip is not None else 0,
                "loss": input_loss.get((stream, ip), 0) if ip is not None else 0,
                "feed_role": b["feed_role"],
            }
            if existing is None:
                broadcaster_summary[summary_key] = candidate
            elif existing["status"] == 0 and candidate["status"] == 1:
                broadcaster_summary[summary_key] = candidate
            elif existing["status"] == candidate["status"] == 1:
                existing_primary = existing["feed_role"] == "primary"
                candidate_primary = candidate["feed_role"] == "primary"
                if candidate_primary and not existing_primary:
                    broadcaster_summary[summary_key] = candidate

            if ip is not None:
                broadcaster_feed_status.labels(name=b["name"], stream=stream, feed_role=b["feed_role"], ip=ip).set(1)
                broadcaster_feed_jitter.labels(name=b["name"], stream=stream, feed_role=b["feed_role"], ip=ip).set(stream_jitter.get(stream, 0))
                broadcaster_feed_loss.labels(name=b["name"], stream=stream, feed_role=b["feed_role"], ip=ip).set(input_loss.get((stream, ip), 0))
            else:
                broadcaster_feed_status.labels(name=b["name"], stream=stream, feed_role=b["feed_role"], ip="none").set(0)
                broadcaster_feed_jitter.labels(name=b["name"], stream=stream, feed_role=b["feed_role"], ip="none").set(0)
                broadcaster_feed_loss.labels(name=b["name"], stream=stream, feed_role=b["feed_role"], ip="none").set(0)
                log.warning("BROADCASTER FEED OFFLINE: broadcaster=%s stream=%s feed_role=%s", b["name"], stream, b["feed_role"])

    for broadcaster in broadcasters:
        for stream in broadcaster["streams"]:
            summary = broadcaster_summary.get((broadcaster["name"], stream), {
                "ip": "none",
                "status": 0,
                "jitter": 0,
                "loss": 0,
            })
            connection_status.labels(
                name=broadcaster["name"],
                stream=stream,
                role="broadcaster",
                ip=summary["ip"],
            ).set(summary["status"])
            ingest_status.labels(name=broadcaster["name"], stream=stream, ip=summary["ip"]).set(summary["status"])
            ingest_jitter.labels(name=broadcaster["name"], stream=stream, ip=summary["ip"]).set(summary["jitter"])
            ingest_loss.labels(name=broadcaster["name"], stream=stream, ip=summary["ip"]).set(summary["loss"])

    affiliate_client_defs = _build_affiliate_clients(groups, affiliate_clients)
    affiliate_summary: dict[tuple[str, str], dict] = {}

    # Check each affiliate client
    for stream in STREAM_NAMES:
        stream_groups = affiliate_client_defs.get(stream, [])
        preferred_names = {
            ip: affiliate_name
            for (auth_stream, ip), affiliate_name in affiliate_auth.items()
            if auth_stream == stream
        }
        for g, ip in _assign_connected_ips(stream_groups, active_outputs.get(stream, set()), preferred_names=preferred_names):
            summary_key = (g["name"], stream)
            existing = affiliate_summary.get(summary_key)
            candidate = {
                "ip": ip or "none",
                "status": 1 if ip is not None else 0,
                "loss": output_loss.get((stream, ip), 0) if ip is not None else 0,
                "bytes": output_bytes.get((stream, ip), 0) if ip is not None else 0,
                "uptime": output_uptime.get((stream, ip), 0) if ip is not None else 0,
                "endpoint_role": g["endpoint_role"],
            }
            if existing is None:
                affiliate_summary[summary_key] = candidate
            elif existing["status"] == 0 and candidate["status"] == 1:
                affiliate_summary[summary_key] = candidate
            elif existing["status"] == candidate["status"] == 1:
                existing_primary = existing["endpoint_role"] == "primary"
                candidate_primary = candidate["endpoint_role"] == "primary"
                if candidate_primary and not existing_primary:
                    affiliate_summary[summary_key] = candidate

            if ip is not None:
                affiliate_client_status.labels(name=g["name"], stream=stream, client_name=g["client_name"], endpoint_role=g["endpoint_role"], ip=ip).set(1)
                affiliate_client_loss.labels(name=g["name"], stream=stream, client_name=g["client_name"], endpoint_role=g["endpoint_role"], ip=ip).set(output_loss.get((stream, ip), 0))
                affiliate_client_bytes.labels(name=g["name"], stream=stream, client_name=g["client_name"], endpoint_role=g["endpoint_role"], ip=ip).set(output_bytes.get((stream, ip), 0))
                affiliate_client_uptime.labels(name=g["name"], stream=stream, client_name=g["client_name"], endpoint_role=g["endpoint_role"], ip=ip).set(output_uptime.get((stream, ip), 0))
            else:
                affiliate_client_status.labels(name=g["name"], stream=stream, client_name=g["client_name"], endpoint_role=g["endpoint_role"], ip="none").set(0)
                affiliate_client_loss.labels(name=g["name"], stream=stream, client_name=g["client_name"], endpoint_role=g["endpoint_role"], ip="none").set(0)
                affiliate_client_bytes.labels(name=g["name"], stream=stream, client_name=g["client_name"], endpoint_role=g["endpoint_role"], ip="none").set(0)
                affiliate_client_uptime.labels(name=g["name"], stream=stream, client_name=g["client_name"], endpoint_role=g["endpoint_role"], ip="none").set(0)

    for group in groups:
        for stream in group["streams"]:
            summary = affiliate_summary.get((group["name"], stream), {
                "ip": "none",
                "status": 0,
                "loss": 0,
                "bytes": 0,
                "uptime": 0,
            })
            connection_status.labels(name=group["name"], stream=stream, role="operator", ip=summary["ip"]).set(summary["status"])
            playout_status.labels(name=group["name"], stream=stream, ip=summary["ip"]).set(summary["status"])
            playout_loss.labels(name=group["name"], stream=stream, ip=summary["ip"]).set(summary["loss"])
            playout_bytes.labels(name=group["name"], stream=stream, ip=summary["ip"]).set(summary["bytes"])
            playout_uptime.labels(name=group["name"], stream=stream, ip=summary["ip"]).set(summary["uptime"])


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
    if not PB_PASS:
        log.warning("PB_PASS not set — health checks against PocketBase will fail")

    threading.Thread(target=poll_pb_config, daemon=True, name="pb-config-poller").start()
    log.info("Started PocketBase config poller (interval %ds)", HEALTH_POLL_SECS)

    # Give PocketBase a moment to load before first session poll
    time.sleep(2)

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
