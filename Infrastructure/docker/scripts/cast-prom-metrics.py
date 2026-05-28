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

METRICS_PORT      = int(os.environ.get("EXPORTER_PORT", "9101"))
MIST_API_PORT     = os.environ.get("MIST_API_PORT", "4242")
MIST_API_HOST     = os.environ.get("MIST_API_HOST", "127.0.0.1")
MIST_API_URL      = f"http://{MIST_API_HOST}:{MIST_API_PORT}/api"
MIST_USERNAME     = os.environ.get("MIST_USERNAME", "admin")
MIST_PASSWORD     = os.environ.get("MIST_PASSWORD", "")
PB_URL            = os.environ.get("PB_URL", "http://127.0.0.1:8090")
PB_EMAIL          = os.environ.get("PB_EMAIL", "admin@castology.tv")
PB_PASS           = os.environ.get("PB_PASS", "")

SESSION_POLL_SECS = 10
HEALTH_POLL_SECS  = 60
R2_POLL_SECS      = 5
HLS_BASE_DIR      = "/var/lib/mist-hls"
CLIENTS_LOOKBACK_SECS = int(os.environ.get("CLIENTS_LOOKBACK_SECS", "3"))

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
    ["stream", "ip", "direction", "connector", "affiliate", "client_name"],
    registry=registry,
)
session_uptime = Gauge(
    "mist_operator_session_uptime_seconds",
    "Uptime in seconds of active operator session",
    ["stream", "ip", "connector", "affiliate", "client_name"],
    registry=registry,
)
session_pkt_loss = Gauge(
    "mist_session_packet_loss_ratio",
    "Packet loss ratio (lost/sent) for active SRT session",
    ["stream", "ip", "direction", "affiliate", "client_name"],
    registry=registry,
)
session_bitrate_kbps = Gauge(
    "mist_operator_session_bitrate_kbps",
    "Current throughput in kbps for active operator session",
    ["stream", "ip", "direction", "connector", "affiliate", "client_name"],
    registry=registry,
)
session_retransmit_rate = Gauge(
    "mist_operator_session_retransmit_rate",
    "Retransmit ratio (retransmitted/sent) for active operator session",
    ["stream", "ip", "direction", "connector", "affiliate", "client_name"],
    registry=registry,
)

# Stream health
stream_up = Gauge(
    "mist_stream_up",
    "1 if stream is online in MistServer",
    ["stream"],
    registry=registry,
)
stream_jitter_ms = Gauge(
    "mist_stream_jitter_ms",
    "Stream-level ingest jitter in milliseconds (from /json_{stream}.js meta.jitter)",
    ["stream"],
    registry=registry,
)
track_jitter_ms = Gauge(
    "mist_track_jitter_ms",
    "Per-track ingest jitter in milliseconds (from /json_{stream}.js per-track jitter)",
    ["stream", "track_type", "codec"],
    registry=registry,
)

# Health checks against PocketBase config
# One series per configured entity×stream. ip=connected IP or "none" when offline.
broadcaster_feed_status = Gauge(
    "mist_broadcaster_feed_status",
    "Broadcaster feed connection: 1=online 0=offline",
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
    ["name", "stream", "client_name", "endpoint_role", "ip", "monitor"],
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
session_unregistered = Gauge(
    "mist_session_unregistered",
    "1 if an active session has no matching token in PocketBase",
    ["stream", "ip", "direction", "connector"],
    registry=registry,
)

# Auth events from cast-mist-stream-auth trigger (ALLOW/DENY per affiliate)
mist_auth_events = Counter(
    "mist_auth_events_total",
    "Cumulative auth events from cast-mist-stream-auth by stream, affiliate and result",
    ["stream", "affiliate", "result"],
    registry=registry,
)
# Output process warnings from MistOutTSSRT (packet loss etc.) per stream
mist_output_warnings = Counter(
    "mist_output_warnings_total",
    "Cumulative WARN/FAIL log events from MistOutTSSRT by stream",
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

_init_streams: set[str] = set()

def _ensure_stream_labels(stream_names: list[str]):
    """Initialise gauge label sets for any stream not yet seen."""
    for _s in stream_names:
        if _s in _init_streams:
            continue
        _init_streams.add(_s)
        stream_up.labels(stream=_s).set(0)
        r2_ffmpeg_up.labels(stream=_s).set(0)
        r2_segment_lag.labels(stream=_s).set(0)
        r2_segment_age.labels(stream=_s).set(0)
        r2_upload_errors.labels(stream=_s)
        for _d in ("input", "output", "unknown"):
            for _c in ("TSSRT", "HLS", "HTTP", "unknown"):
                operator_sessions.labels(stream=_s, direction=_d, connector=_c).set(0)

# Per-session previous poll state for delta-based rate metrics
_prev_poll: dict[tuple, dict] = {}  # (stream, ip, direction, connector) → {bytes, retrans, sent, ts}

# Last written IP labels for health gauges — used to zero out stale series when IP changes
_last_feed_ip:     dict[tuple[str, str, str], str] = {}  # (name, stream, feed_role) → ip
_last_client_ip:   dict[tuple[str, str, str, str], tuple[str, str]] = {}  # (name, stream, client_name, endpoint_role) → (ip, monitor)

# Highest log entry timestamp seen — prevents double-counting on each poll
_last_log_ts: int = 0

# ── PocketBase config cache (refreshed every HEALTH_POLL_SECS) ───────────────

_pb_lock = threading.Lock()
_pb_config = {
    "broadcasters": [],      # [{"name", "streams": [...], "token_key", "allowed_ips"}]
    "broadcaster_feeds": [], # [{"broadcaster_name", "stream", "feed_role", "allowed_ips"}]
    "affiliate_clients": [], # [{"affiliate_name", "stream", "client_name", "endpoint_role", "allowed_ips"}]
    "tokens": set(),         # all valid token_keys
    "stream_names": [],      # unique stream names derived from active broadcaster_feeds
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

            active_group_names = set()
            for g in affiliates:
                if not g.get("active", True):
                    continue
                tk = g.get("token_key", "")
                active_group_names.add(g.get("name", "unknown"))
                if tk:
                    tokens.add(tk)
            for client in affiliate_clients:
                if not client.get("active", True):
                    continue
                affiliate_name = (client.get("affiliate_name") or "").strip()
                stream = (client.get("stream") or "").strip()
                client_name = (client.get("client_name") or "").strip()
                if not affiliate_name or not stream or not client_name or affiliate_name not in active_group_names:
                    continue
                parsed_affiliate_clients.append({
                    "affiliate_name": affiliate_name,
                    "stream": stream,
                    "client_name": client_name,
                    "endpoint_role": (client.get("endpoint_role") or "primary").strip().lower() or "primary",
                    "allowed_ips": client.get("allowed_ips", ""),
                    "is_test_client": bool(client.get("is_test_client", False)),
                    "monitor": bool(client.get("monitor", False)),
                    "notes": client.get("notes", ""),
                })

            for b in parsed_broadcasters:
                if b["token_key"]:
                    tokens.add(b["token_key"])

            stream_names = sorted({f["stream"] for f in parsed_broadcaster_feeds})

            with _pb_lock:
                _pb_config["broadcasters"] = parsed_broadcasters
                _pb_config["broadcaster_feeds"] = parsed_broadcaster_feeds
                _pb_config["affiliate_clients"] = parsed_affiliate_clients
                _pb_config["tokens"] = tokens
                _pb_config["stream_names"] = stream_names

            _ensure_stream_labels(stream_names)

            log.info("PocketBase config refreshed: %d broadcasters, %d broadcaster feeds, %d affiliate clients, %d tokens, streams=%s",
                     len(parsed_broadcasters), len(parsed_broadcaster_feeds), len(parsed_affiliate_clients), len(tokens), stream_names)
        except Exception as e:
            log.warning("PocketBase config poll error: %s", e)

        time.sleep(HEALTH_POLL_SECS)


def _stream_names() -> list[str]:
    with _pb_lock:
        return list(_pb_config["stream_names"])


# ── MistServer API helpers ────────────────────────────────────────────────────

def _mist_request(payload: dict) -> dict:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(MIST_API_URL, data=data,
                                  headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())

def mist_post(payload: dict) -> dict:
    if not MIST_PASSWORD:
        return _mist_request(payload)
    # Step 1: get challenge
    resp = _mist_request({})
    challenge = resp.get("authorize", {}).get("challenge", "")
    if not challenge:
        return resp
    # Step 2: MD5(MD5(password) + challenge)
    import hashlib
    pass_md5 = hashlib.md5(MIST_PASSWORD.encode()).hexdigest()
    h = hashlib.md5((pass_md5 + challenge).encode()).hexdigest()
    # Step 3: send auth + payload together
    return _mist_request({"authorize": {"username": MIST_USERNAME, "password": h}, **payload})


# ── Session + stream health poller ───────────────────────────────────────────

def poll_sessions_and_streams():
    while True:
        try:
            _check_health()
        except Exception as e:
            log.warning("health check error: %s", e)
        time.sleep(SESSION_POLL_SECS)


def _allowed_ips(raw: str) -> list[str]:
    return [x.strip() for x in raw.split(",") if x.strip()]


_INTERNAL_NETWORKS = [
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),  # Docker bridge ranges
    ipaddress.ip_network("10.0.0.0/8"),
]

def _is_loopback_ip(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
        return any(addr in net for net in _INTERNAL_NETWORKS)
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


def _assign_connected_ips(entities, connected_ips: set[str]):
    remaining = set(connected_ips)
    assignments = []
    explicit = []
    wildcard = []

    for index, entity in enumerate(entities):
        allowed = _allowed_ips(entity["allowed_ips"])
        is_wildcard_entry = not allowed or any(e in ("0.0.0.0/0", "::/0") for e in allowed)
        if is_wildcard_entry:
            wildcard.append(entity)
        else:
            explicit.append((entity, allowed))

    for entity, allowed in explicit:
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

    for entity in wildcard:
        match = sorted(remaining)[0] if remaining else None
        assignments.append((entity, match))
        if match is not None:
            remaining.remove(match)

    return assignments


def _build_broadcaster_feeds(broadcasters: list[dict], broadcaster_feeds: list[dict], stream_names: list[str]) -> dict[str, list[dict]]:
    feeds_by_key: dict[tuple[str, str], list[dict]] = {}
    for feed in broadcaster_feeds:
        feeds_by_key.setdefault((feed["broadcaster_name"], feed["stream"]), []).append(feed)

    stream_feeds: dict[str, list[dict]] = {stream: [] for stream in stream_names}
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


def _build_affiliate_clients(affiliate_clients: list[dict], stream_names: list[str]) -> dict[str, list[dict]]:
    stream_clients: dict[str, list[dict]] = {stream: [] for stream in stream_names}
    for client in affiliate_clients:
        if client.get("is_test_client"):
            continue
        stream_clients.setdefault(client["stream"], []).append({
            "name": client["affiliate_name"],
            "stream": client["stream"],
            "client_name": client["client_name"],
            "endpoint_role": client["endpoint_role"],
            "allowed_ips": client["allowed_ips"],
            "monitor": client["monitor"],
        })
    return stream_clients



def _is_test_client_session(ip: str, stream: str) -> bool:
    """Return True only if the IP matches a test record but NO non-test record for this stream.
    This allows an IP that is a test client for one affiliate to still appear as a real
    client for a different affiliate on the same stream."""
    with _pb_lock:
        affiliate_clients = list(_pb_config["affiliate_clients"])

    matched_test = False
    for client in affiliate_clients:
        if client["stream"] != stream:
            continue
        allowed = _allowed_ips(client["allowed_ips"])
        if not allowed and client["client_name"]:
            allowed = [client["client_name"]]
        if not _ip_allowed(ip, allowed):
            continue
        if not client.get("is_test_client"):
            return False  # has a real (non-test) record — not a test-only session
        matched_test = True
    return matched_test


def _is_registered(ip: str, stream: str, direction: str) -> bool:
    with _pb_lock:
        broadcasters = _pb_config["broadcasters"]
        broadcaster_feeds = _pb_config["broadcaster_feeds"]
        affiliate_clients = _pb_config["affiliate_clients"]

    # Input sessions — check broadcaster_feeds allowed_ips (feed-level), falling back to broadcaster-level
    if direction == "input":
        for feed in broadcaster_feeds:
            if feed["stream"] != stream:
                continue
            allowed = _allowed_ips(feed["allowed_ips"])
            if not allowed:
                # Fall back to broadcaster-level allowed_ips
                for b in broadcasters:
                    if b["name"] == feed["broadcaster_name"]:
                        allowed = _allowed_ips(b["allowed_ips"])
                        break
            if _ip_allowed(ip, allowed):
                return True
        return False

    # Output sessions — check operator affiliate_clients IPs
    for client in affiliate_clients:
        if client["stream"] != stream:
            continue
        if client.get("is_test_client"):
            continue
        allowed = _allowed_ips(client["allowed_ips"])
        if not allowed and client["client_name"]:
            allowed = [client["client_name"]]
        if _ip_allowed(ip, allowed):
            return True

    return False


def _resolve_session_identity(ip: str, stream: str, direction: str) -> tuple[str, str]:
    """Return (affiliate_name, client_name) for an IP+stream+direction, or ("", "") if unknown.
    """
    with _pb_lock:
        broadcaster_feeds = _pb_config["broadcaster_feeds"]
        broadcasters = _pb_config["broadcasters"]
        affiliate_clients = _pb_config["affiliate_clients"]

    if direction == "input":
        for feed in broadcaster_feeds:
            if feed["stream"] != stream:
                continue
            allowed = _allowed_ips(feed["allowed_ips"])
            if not allowed:
                for b in broadcasters:
                    if b["name"] == feed["broadcaster_name"]:
                        allowed = _allowed_ips(b["allowed_ips"])
                        break
            if _ip_allowed(ip, allowed):
                return feed["broadcaster_name"], feed["feed_role"]
        return "", ""

    wildcard_match: tuple[str, str] | None = None
    for client in affiliate_clients:
        if client["stream"] != stream:
            continue
        if client.get("is_test_client"):
            continue
        allowed = _allowed_ips(client["allowed_ips"])
        if not allowed and client["client_name"]:
            allowed = [client["client_name"]]
        if not _ip_allowed(ip, allowed):
            continue
        is_wildcard_entry = not allowed or any(e in ("0.0.0.0/0", "::/0") for e in allowed)
        if is_wildcard_entry:
            if wildcard_match is None:
                wildcard_match = (client["affiliate_name"], client["client_name"])
            continue
        return client["affiliate_name"], client["client_name"]
    return wildcard_match if wildcard_match else ("", "")


def _check_health():
    """Cross-reference live sessions against PocketBase config."""
    data = mist_post({"clients": {"time": -CLIENTS_LOOKBACK_SECS}, "active_streams": {}, "log": True})
    clients_block = data.get("clients") or {}
    fields = clients_block.get("fields") or []
    rows   = clients_block.get("data") or []

    fi = {f: i for i, f in enumerate(fields)} if fields else {}

    # Per-session metrics
    session_bytes.clear()
    session_uptime.clear()
    session_pkt_loss.clear()
    session_unregistered.clear()
    session_bitrate_kbps.clear()
    session_retransmit_rate.clear()

    counts: dict[tuple[str, str, str], int] = {}
    active_inputs: dict[str, set] = {}
    active_outputs: dict[str, set] = {}
    input_loss:    dict[tuple[str, str], float] = {}
    output_loss:   dict[tuple[str, str], float] = {}
    output_bytes:  dict[tuple[str, str], float] = {}
    output_uptime: dict[tuple[str, str], float] = {}

    now = time.time()
    for row in rows:
        if not isinstance(row, list) or not fi or len(row) < len(fields):
            continue

        stream    = row[fi["stream"]]
        protocol  = row[fi["protocol"]]
        if not protocol:
            continue
        direction, connector = _parse_protocol(protocol)
        ip = row[fi["host"]]
        ip = ip.replace("::ffff:", "").strip("[]").split(":")[0] if "::ffff:" in ip or ip.startswith("[") else ip
        if direction == "output" and not _is_loopback_ip(ip) and _is_test_client_session(ip, stream):
            continue

        conntime       = row[fi["conntime"]]
        down_bytes     = row[fi["down"]]
        up_bytes       = row[fi["up"]]
        pkt_count      = row[fi["pktcount"]]
        pkt_lost       = row[fi["pktlost"]]
        pkt_retransmit = row[fi["pktretransmit"]] if "pktretransmit" in fi else 0
        total_bytes    = down_bytes + up_bytes
        loss           = pkt_lost / pkt_count if pkt_count > 0 else 0.0
        session_key    = (stream, ip)

        counts[(stream, direction, connector)] = counts.get((stream, direction, connector), 0) + 1

        if direction == "input":
            active_inputs.setdefault(stream, set()).add(ip)
            input_loss[session_key] = loss
        elif not _is_loopback_ip(ip):
            active_outputs.setdefault(stream, set()).add(ip)
            output_loss[session_key]   = loss
            output_bytes[session_key]  = total_bytes
            output_uptime[session_key] = conntime

        affiliate, client_name = ("", "") if _is_loopback_ip(ip) else _resolve_session_identity(ip, stream, direction)

        session_bytes.labels(stream=stream, ip=ip, direction=direction, connector=connector, affiliate=affiliate, client_name=client_name).set(total_bytes)
        session_uptime.labels(stream=stream, ip=ip, connector=connector, affiliate=affiliate, client_name=client_name).set(conntime)

        if pkt_count > 0:
            session_pkt_loss.labels(stream=stream, ip=ip, direction=direction, affiliate=affiliate, client_name=client_name).set(loss)
            if loss > PACKET_LOSS_THRESHOLD:
                log.warning("HIGH PACKET LOSS: stream=%s ip=%s direction=%s loss=%.1f%%",
                            stream, ip, direction, loss * 100)

        rate_key = (stream, ip, direction, connector)
        prev = _prev_poll.get(rate_key)
        if prev and (now - prev["ts"]) > 0:
            dt = now - prev["ts"]
            bitrate = max(0, total_bytes - prev["bytes"]) * 8 / (dt * 1000)
            session_bitrate_kbps.labels(stream=stream, ip=ip, direction=direction, connector=connector, affiliate=affiliate, client_name=client_name).set(bitrate)
            sent_delta    = max(0, pkt_count - prev["sent"])
            retrans_delta = max(0, pkt_retransmit - prev["retrans"])
            session_retransmit_rate.labels(stream=stream, ip=ip, direction=direction, connector=connector, affiliate=affiliate, client_name=client_name).set(
                retrans_delta / sent_delta if sent_delta > 0 else 0
            )
        _prev_poll[rate_key] = {"bytes": total_bytes, "retrans": pkt_retransmit, "sent": pkt_count, "ts": now}

        if not _is_loopback_ip(ip):
            is_registered = affiliate != "" or _is_registered(ip, stream, direction)
            session_unregistered.labels(stream=stream, ip=ip, direction=direction, connector=connector).set(
                0 if is_registered else 1
            )
            if not is_registered:
                log.warning("UNREGISTERED SESSION: stream=%s ip=%s direction=%s connector=%s",
                            stream, ip, direction, connector)

    with _pb_lock:
        broadcasters = list(_pb_config["broadcasters"])
        broadcaster_feeds = list(_pb_config["broadcaster_feeds"])
        affiliate_clients = list(_pb_config["affiliate_clients"])
        stream_names = list(_pb_config["stream_names"])

    for name in stream_names:
        stream_up.labels(stream=name).set(1 if name in active_inputs else 0)
        for d in ("input", "output", "unknown"):
            for c in ("TSSRT", "HLS", "HTTP", "unknown"):
                operator_sessions.labels(stream=name, direction=d, connector=c).set(
                    counts.get((name, d, c), 0)
                )

    # Do NOT .clear() health gauges — that causes Grafana to show stale values when
    # the ip= label changes (old series lingers until Prometheus staleness window).
    # Instead we zero out the previous label set explicitly when the IP changes.

    broadcaster_feed_defs = _build_broadcaster_feeds(broadcasters, broadcaster_feeds, stream_names)
    broadcaster_summary: dict[tuple[str, str], dict] = {}

    # Check each broadcaster feed
    for stream in stream_names:
        stream_broadcasters = broadcaster_feed_defs.get(stream, [])
        for b, ip in _assign_connected_ips(stream_broadcasters, active_inputs.get(stream, set())):
            summary_key = (b["name"], stream)
            existing = broadcaster_summary.get(summary_key)
            candidate = {
                "ip": ip or "none",
                "status": 1 if ip is not None else 0,
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

            new_ip = ip if ip is not None else "none"
            feed_key = (b["name"], stream, b["feed_role"])
            old_ip = _last_feed_ip.get(feed_key)
            if old_ip and old_ip != new_ip:
                try:
                    broadcaster_feed_status.remove(b["name"], stream, b["feed_role"], old_ip)
                    broadcaster_feed_loss.remove(b["name"], stream, b["feed_role"], old_ip)
                except Exception:
                    pass
            _last_feed_ip[feed_key] = new_ip
            broadcaster_feed_status.labels(name=b["name"], stream=stream, feed_role=b["feed_role"], ip=new_ip).set(1 if ip is not None else 0)
            broadcaster_feed_loss.labels(name=b["name"], stream=stream, feed_role=b["feed_role"], ip=new_ip).set(input_loss.get((stream, ip), 0) if ip is not None else 0)
            if ip is None:
                log.warning("BROADCASTER FEED OFFLINE: broadcaster=%s stream=%s feed_role=%s", b["name"], stream, b["feed_role"])

    affiliate_client_defs = _build_affiliate_clients(affiliate_clients, stream_names)

    for stream in stream_names:
        monitored_outputs = active_outputs.get(stream, set())
        stream_groups = affiliate_client_defs.get(stream, [])
        for g, ip in _assign_connected_ips(stream_groups, monitored_outputs):
            new_ip = ip if ip is not None else "none"
            client_key = (g["name"], stream, g["client_name"], g["endpoint_role"])
            monitor = "1" if g["monitor"] else "0"
            prev = _last_client_ip.get(client_key)
            if prev and prev != (new_ip, monitor):
                old_ip, old_monitor = prev
                try:
                    affiliate_client_status.remove(g["name"], stream, g["client_name"], g["endpoint_role"], old_ip, old_monitor)
                except KeyError:
                    pass
                if old_ip != new_ip:
                    for metric in (affiliate_client_loss, affiliate_client_bytes, affiliate_client_uptime):
                        try:
                            metric.remove(g["name"], stream, g["client_name"], g["endpoint_role"], old_ip)
                        except KeyError:
                            pass
            _last_client_ip[client_key] = (new_ip, monitor)
            affiliate_client_status.labels(name=g["name"], stream=stream, client_name=g["client_name"], endpoint_role=g["endpoint_role"], ip=new_ip, monitor=monitor).set(1 if ip is not None else 0)
            affiliate_client_loss.labels(name=g["name"], stream=stream, client_name=g["client_name"], endpoint_role=g["endpoint_role"], ip=new_ip).set(output_loss.get((stream, ip), 0) if ip is not None else 0)
            affiliate_client_bytes.labels(name=g["name"], stream=stream, client_name=g["client_name"], endpoint_role=g["endpoint_role"], ip=new_ip).set(output_bytes.get((stream, ip), 0) if ip is not None else 0)
            affiliate_client_uptime.labels(name=g["name"], stream=stream, client_name=g["client_name"], endpoint_role=g["endpoint_role"], ip=new_ip).set(output_uptime.get((stream, ip), 0) if ip is not None else 0)

    # Parse jitter from active_streams response
    active_streams_block = data.get("active_streams") or {}
    streams_data = active_streams_block.get("data") or {}
    fields = active_streams_block.get("fields") or []
    health_idx = fields.index("health") if "health" in fields else None
    if health_idx is not None:
        for stream, row in streams_data.items():
            if not isinstance(row, list) or len(row) <= health_idx:
                continue
            health = row[health_idx]
            if not isinstance(health, dict):
                continue
            jitter = health.get("jitter")
            if jitter is not None:
                stream_jitter_ms.labels(stream=stream).set(jitter)
            for key, val in health.items():
                if not isinstance(val, dict):
                    continue
                track_jitter = val.get("jitter")
                if track_jitter is None:
                    continue
                track_jitter_ms.labels(
                    stream=stream,
                    track_type=val.get("type", val.get("codec", "unknown")),
                    codec=val.get("codec", "unknown"),
                ).set(track_jitter)

    # Parse log entries for auth events and output warnings
    global _last_log_ts
    _RE_AUTH_STREAM    = re.compile(r"stream=(\S+)")
    _RE_AUTH_AFFILIATE = re.compile(r"affiliate[=']([^'\s]+(?:\s+[^'\s]+)*?)(?:\s+client=|\s*$)")
    new_max_ts = _last_log_ts
    for entry in data.get("log") or []:
        if not isinstance(entry, list) or len(entry) < 6:
            continue
        ts, level, msg, _stream, _pid, binary = entry[0], entry[1], entry[2], entry[3], entry[4], entry[5]
        if ts <= _last_log_ts:
            continue
        if ts > new_max_ts:
            new_max_ts = ts

        if binary == "cast-mist-stream-auth" and level in ("INFO", "WARN", "FAIL"):
            m_stream = _RE_AUTH_STREAM.search(msg)
            stream_label = m_stream.group(1) if m_stream else "unknown"
            if "ALLOW:" in msg:
                m_aff = _RE_AUTH_AFFILIATE.search(msg)
                affiliate_label = m_aff.group(1).strip() if m_aff else "unknown"
                mist_auth_events.labels(stream=stream_label, affiliate=affiliate_label, result="allow").inc()
            elif "DENY:" in msg:
                m_aff = _RE_AUTH_AFFILIATE.search(msg)
                affiliate_label = m_aff.group(1).strip() if m_aff else "unknown"
                mist_auth_events.labels(stream=stream_label, affiliate=affiliate_label, result="deny").inc()
            elif "ERROR:" in msg:
                mist_auth_events.labels(stream=stream_label, affiliate="unknown", result="error").inc()

        elif binary == "MistOutTSSRT" and level in ("WARN", "FAIL", "CRIT"):
            stream_label = _stream or "unknown"
            mist_output_warnings.labels(stream=stream_label).inc()

    _last_log_ts = new_max_ts


# ── R2 pipeline poller ───────────────────────────────────────────────────────

def _seg_number(filename: str) -> int:
    try:
        return int(filename.replace("seg_", "").replace(".ts", ""))
    except ValueError:
        return -1


def poll_r2_pipeline():
    _prev_error_counts: dict[str, int] = {}

    while True:
        for name in _stream_names():
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
