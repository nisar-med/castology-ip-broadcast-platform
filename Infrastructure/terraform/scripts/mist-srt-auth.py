#!/usr/bin/env python3
"""
MistServer SRT auth — executable trigger handler.

MistServer calls this script with the trigger name as argv[1] and pipes the
payload to stdin. The script writes its response to stdout.

Handled triggers:
  PLAY_REWRITE   — fires for every new viewer session; payload:
                     stream name / connection address / connector / request URL
                   response: stream name to connect to (pass-through or rewrite)

  DEFAULT_STREAM — fires when requested stream doesn't exist; payload:
                     defaultStream setting / requested name / viewer host / connector
                   response: real stream name (allow) or empty (deny)

SRT streamid format expected from operators: geo+news/TOKEN
"""

import sys
import os
import json
import logging
import urllib.request
import urllib.parse
import ipaddress

PB_URL    = os.environ.get("PB_URL",   "http://127.0.0.1:8090")
PB_EMAIL  = os.environ.get("PB_EMAIL", "admin@castology.tv")
PB_PASS   = os.environ.get("PB_PASS",  "")
CACHE_DIR = "/tmp/mist-auth-cache"
CACHE_TTL = 300  # seconds

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[logging.StreamHandler(sys.stderr)],
)
log = logging.getLogger(__name__)

os.makedirs(CACHE_DIR, exist_ok=True)


def _cache_key(token, sname):
    import hashlib
    return os.path.join(CACHE_DIR, hashlib.sha256(f"{token}:{sname}".encode()).hexdigest())


def cache_put(token, sname, real_stream):
    try:
        with open(_cache_key(token, sname), "w") as f:
            f.write(f"{real_stream}\n{int(__import__('time').time())}\n")
    except Exception:
        pass


def cache_get(token, sname):
    try:
        path = _cache_key(token, sname)
        with open(path) as f:
            parts = f.read().strip().splitlines()
        if len(parts) < 2:
            return None
        real_stream, ts = parts[0], int(parts[1])
        if __import__('time').time() - ts > CACHE_TTL:
            os.unlink(path)
            return None
        return real_stream
    except Exception:
        return None


def pb_auth_token():
    payload = json.dumps({"identity": PB_EMAIL, "password": PB_PASS}).encode()
    req = urllib.request.Request(
        f"{PB_URL}/api/collections/_superusers/auth-with-password",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())["token"]


def pb_get(path, token):
    req = urllib.request.Request(
        f"{PB_URL}{path}",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())


def validate(token, requested_stream, source_ip):
    """
    Look up channel_group by token_key. Returns real stream name on success, None on failure.
    """
    auth = pb_auth_token()

    filt = urllib.parse.quote(f'token_key="{token}" && active=true')
    data = pb_get(f"/api/collections/channel_groups/records?filter={filt}&perPage=1", auth)
    items = data.get("items", [])
    if not items:
        log.warning(f"DENY: no active channel_group for token='{token}'")
        return None

    group = items[0]

    channels = group.get("channels") or []
    if isinstance(channels, str):
        try:
            channels = json.loads(channels)
        except (ValueError, TypeError):
            channels = []
    stream_names = [ch.get("stream", "") for ch in channels if isinstance(ch, dict)]

    if requested_stream and requested_stream not in stream_names:
        log.warning(f"DENY: stream '{requested_stream}' not in group '{group['name']}' {stream_names}")
        return None

    filt2 = urllib.parse.quote(f'group_id="{group["id"]}" && active=true')
    ops = pb_get(f"/api/collections/cable_operators/records?filter={filt2}&perPage=1", auth)
    if not ops.get("items"):
        log.warning(f"DENY: no active cable_operator in group '{group['name']}'")
        return None

    allowed_ips_raw = (group.get("allowed_ips") or "").strip()
    if allowed_ips_raw and source_ip:
        allowed = [x.strip() for x in allowed_ips_raw.split(",") if x.strip()]
        try:
            src = ipaddress.ip_address(source_ip)
            if not any(src in ipaddress.ip_network(c, strict=False) for c in allowed):
                log.warning(f"DENY: IP {source_ip} not in allowed_ips for group '{group['name']}'")
                return None
        except ValueError:
            log.warning(f"DENY: could not parse source IP '{source_ip}'")
            return None

    target = requested_stream if requested_stream else (stream_names[0] if stream_names else None)
    log.info(f"ALLOW: stream='{target}' group='{group['name']}' ip={source_ip}")
    return target


def handle_play_rewrite(lines):
    """
    PLAY_REWRITE: fires for every viewer session.
    Payload: stream_name / conn_addr / connector / request_url
    Response: stream name to actually connect to.

    For TSSRT: MistServer passes the raw SRT streamid (e.g. "geo+news/TOKEN" → "geo news/TOKEN").
    Returning a different stream name on an acceptable-mode TSSRT socket breaks the handshake.
    So for TSSRT we validate the token here but return the ORIGINAL stream name unchanged —
    this causes MistServer to fire DEFAULT_STREAM (stream not found), which we handle to return
    the real stream name. Deny is still enforced by returning "" here.
    """
    stream_name = lines[0].strip() if len(lines) >= 1 else ""
    conn_addr   = lines[1].strip() if len(lines) >= 2 else ""
    connector   = lines[2].strip() if len(lines) >= 3 else ""
    request_url = lines[3].strip() if len(lines) >= 4 else ""

    log.info(f"PLAY_REWRITE stream='{stream_name}' addr={conn_addr} connector={connector} url='{request_url}'")

    # Non-SRT connections pass straight through
    if connector != "TSSRT":
        return stream_name

    # Strip IPv6-mapped prefix from source IP
    source_ip = conn_addr.rsplit(":", 1)[0].strip("[]").removeprefix("::ffff:")

    # MistServer decodes + as space in SRT streamids — restore it
    stream_name = stream_name.replace(" ", "+")

    # Parse streamid: "stream_name/token" or bare "token"
    parts = stream_name.split("/", 1)
    if len(parts) == 2 and parts[1]:
        sname, token = parts[0], parts[1]
    elif len(parts) == 1 and parts[0] and "/" not in parts[0]:
        # No token present — deny (all TSSRT output requires a token)
        log.warning(f"DENY: no token in TSSRT streamid '{stream_name}' from {source_ip}")
        return ""
    else:
        log.warning(f"DENY: unparseable TSSRT streamid '{stream_name}'")
        return ""

    try:
        real_stream = validate(token, sname, source_ip)
        if real_stream:
            cache_put(token, sname, real_stream)
            log.info(f"PLAY_REWRITE token valid, cached '{stream_name}' → '{real_stream}'")
            return stream_name  # pass through unchanged; DEFAULT_STREAM resolves via cache
        return ""
    except Exception as e:
        log.error(f"PocketBase error: {e}")
        return ""


def handle_default_stream(lines):
    """
    DEFAULT_STREAM: fires when requested stream doesn't exist in MistServer.
    Payload: defaultStream / requested_name / viewer_host / connector
    Response: real stream name (allow) or empty (deny).

    For TSSRT: PLAY_REWRITE passes the streamid unchanged (e.g. "geo+news/TOKEN"),
    MistServer can't find it, fires DEFAULT_STREAM. We parse the token from the
    requested name and return the real stream name. Token already validated in
    PLAY_REWRITE, so this is a fast lookup to get the stream name.
    """
    raw_requested = lines[0].strip() if len(lines) >= 1 else ""
    source_ip_raw = lines[1].strip() if len(lines) >= 2 else ""
    source_ip = source_ip_raw.rsplit(":", 1)[0].strip("[]").removeprefix("::ffff:")

    # MistServer decodes + as space
    raw_requested = raw_requested.replace(" ", "+")

    log.info(f"DEFAULT_STREAM raw='{raw_requested}' ip={source_ip}")

    # Skip internal aliases that mean the streamid was lost
    if raw_requested in ("", "true", "false", "stream_1234"):
        log.warning(f"DENY: DEFAULT_STREAM got internal alias '{raw_requested}'")
        return ""

    parts = raw_requested.split("/", 1)
    if len(parts) == 2 and parts[1]:
        sname, token = parts[0], parts[1]
    elif len(parts) == 1 and parts[0]:
        sname, token = "", parts[0]
    else:
        log.warning("DENY: empty streamid in DEFAULT_STREAM")
        return ""

    # Fast path: PLAY_REWRITE already validated and cached the result
    cached = cache_get(token, sname)
    if cached is not None:
        log.info(f"DEFAULT_STREAM cache hit: '{raw_requested}' → '{cached}'")
        return cached

    try:
        real_stream = validate(token, sname, source_ip)
        if real_stream:
            cache_put(token, sname, real_stream)
            log.info(f"DEFAULT_STREAM resolved '{raw_requested}' → '{real_stream}'")
        return real_stream if real_stream else ""
    except Exception as e:
        log.error(f"PocketBase error: {e}")
        return ""


def main():
    trigger = sys.argv[1] if len(sys.argv) > 1 else ""
    body = sys.stdin.read()
    lines = body.strip().splitlines()

    log.info(f"Trigger={trigger} lines={lines}")

    if trigger == "PLAY_REWRITE":
        result = handle_play_rewrite(lines)
    elif trigger == "DEFAULT_STREAM":
        result = handle_default_stream(lines)
    elif trigger in ("USER_NEW", "CONN_OPEN", "CONN_PLAY"):
        result = "1"
    else:
        log.warning(f"Unknown trigger '{trigger}', defaulting allow")
        result = "1"

    sys.stdout.write(result)
    sys.stdout.flush()


if __name__ == "__main__":
    main()
