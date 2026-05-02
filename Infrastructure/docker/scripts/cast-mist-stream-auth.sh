#!/usr/bin/env python3
"""MistServer PLAY_REWRITE trigger — SRT/HLS auth via PocketBase."""

from __future__ import annotations

import ipaddress
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone


LOG_TAG = "cast-mist-stream-auth"
PB_URL = os.environ.get("PB_URL", "http://127.0.0.1:8090")
PB_EMAIL = os.environ.get("PB_EMAIL", "admin@castology.tv")
PB_PASS = os.environ.get("PB_PASS", "")
VPS_ID = os.environ.get("VPS_ID", os.uname().nodename)
ENV_FILE = "/etc/cast-mist-stream-auth.env"


def load_env_file(path: str) -> None:
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key, value)


load_env_file(ENV_FILE)
PB_URL = os.environ.get("PB_URL", PB_URL)
PB_EMAIL = os.environ.get("PB_EMAIL", PB_EMAIL)
PB_PASS = os.environ.get("PB_PASS", PB_PASS)
VPS_ID = os.environ.get("VPS_ID", VPS_ID)


def log(message: str) -> None:
    subprocess.run(
        ["logger", "-t", LOG_TAG, message],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def output_stream(value: str) -> int:
    sys.stdout.write(value)
    sys.stdout.flush()
    return 0


def normalize_client_ip(value: str) -> str:
    ip = value.strip().replace("[", "").replace("]", "")
    if ip.startswith("::ffff:"):
        ip = ip[7:]
    if ip.count(":") == 1:
        host, maybe_port = ip.rsplit(":", 1)
        if maybe_port.isdigit():
            ip = host
    return ip


def is_loopback_ip(value: str) -> bool:
    return value in {"127.0.0.1", "::1"}


def pb_request(path: str, *, method: str = "GET", token: str | None = None, payload: dict | None = None) -> dict:
    data = None
    headers: dict[str, str] = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(f"{PB_URL}{path}", data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=5) as response:
        raw = response.read()
    return json.loads(raw) if raw else {}


def pb_auth() -> str:
    response = pb_request(
        "/api/collections/_superusers/auth-with-password",
        method="POST",
        payload={"identity": PB_EMAIL, "password": PB_PASS},
    )
    return response.get("token", "")


def quote_filter(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def pb_fetch_records(collection: str, token: str, *, filter_expr: str | None = None, per_page: int = 200) -> list[dict]:
    params = [("perPage", str(per_page))]
    if filter_expr:
        params.append(("filter", filter_expr))
    query = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
    try:
        response = pb_request(f"/api/collections/{collection}/records?{query}", token=token)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return []
        raise
    return response.get("items", [])


def pb_create_record(collection: str, payload: dict, token: str) -> None:
    pb_request(f"/api/collections/{collection}/records", method="POST", token=token, payload=payload)


def ip_matches(candidate_ip: str, allowed_value: str) -> bool:
    entry = allowed_value.strip()
    if not entry:
        return False
    try:
        return ipaddress.ip_address(candidate_ip) in ipaddress.ip_network(entry, strict=False)
    except ValueError:
        return candidate_ip == entry


def resolve_client_match(items: list[dict], client_ip: str) -> dict | None:
    for item in items:
        values = [value.strip() for value in (item.get("allowed_ips", "") or "").split(",") if value.strip()]
        if not values and item.get("client_name"):
            values = [item["client_name"]]
        if any(ip_matches(client_ip, value) for value in values):
            return item
    return None


def count_matching_sessions(stream_name: str, client_ip: str) -> int:
    result = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True, check=False)
    count = 0
    for line in result.stdout.splitlines():
        if "MistSession" not in line:
            continue
        if f"--streamname {stream_name}" not in line:
            continue
        if f"--ip {client_ip}" not in line:
            continue
        count += 1
    return count


def parse_trigger_input() -> tuple[str, str, str, str]:
    values = [sys.stdin.readline().rstrip("\n") for _ in range(4)]
    while len(values) < 4:
        values.append("")
    return values[0], values[1], values[2], values[3]


def main() -> int:
    stream, client_ip, connector, request_url = parse_trigger_input()

    stream = stream.replace(" ", "+")
    client_ip = normalize_client_ip(client_ip)

    if connector not in {"TSSRT", "HLS"}:
        return output_stream(stream)

    if is_loopback_ip(client_ip):
        return output_stream(stream)

    if connector == "HLS":
        sname = stream
        query = urllib.parse.parse_qs(urllib.parse.urlparse(request_url).query)
        if "tkn" in query:
            return output_stream(sname)
        token = (query.get("token") or [""])[0]
        if not token:
            log(f"DENY: no token in HLS request '{request_url}'")
            return 1
    else:
        sname, sep, token = stream.partition("/")
        if not sname:
            return output_stream(stream)
        if sep != "/" or not token:
            # No token — check if this is a known broadcaster ingest IP for this stream
            try:
                pb_token = pb_auth()
                feed_records = pb_fetch_records(
                    "broadcaster_feeds",
                    pb_token,
                    filter_expr=f'stream="{quote_filter(sname)}" && active=true',
                )
                matched_feed = resolve_client_match(feed_records, client_ip)
                if matched_feed:
                    log(f"ALLOW: broadcaster ingest stream={sname} broadcaster={matched_feed.get('broadcaster_name','')} ip={client_ip}")
                    return output_stream(sname)
            except Exception as exc:  # noqa: BLE001
                log(f"ERROR: broadcaster ingest check failed for stream={sname} ip={client_ip}: {exc}")
            log(f"DENY: no token in SRT stream '{stream}' from ip={client_ip} (expected format: streamname/token)")
            return 1

    try:
        pb_token = pb_auth()
    except Exception as exc:  # noqa: BLE001
        log(f"ERROR: PocketBase auth failed: {exc}")
        return 1

    if not pb_token:
        log("ERROR: PocketBase auth failed")
        return 1

    affiliate_records = pb_fetch_records(
        "affiliates",
        pb_token,
        filter_expr=f'token_key="{quote_filter(token)}" && active=true',
        per_page=1,
    )
    if not affiliate_records:
        log(f"DENY: no active affiliate for token={token}")
        return 1

    affiliate = affiliate_records[0]
    affiliate_name = (affiliate.get("name") or "").strip()
    client_records = pb_fetch_records(
        "affiliate_clients",
        pb_token,
        filter_expr=(
            f'affiliate_name="{quote_filter(affiliate_name)}" && '
            f'stream="{quote_filter(sname)}" && active=true'
        ),
        per_page=200,
    )
    client_match = resolve_client_match(client_records, client_ip)
    if not client_match:
        log(
            "DENY: no active affiliate_client match "
            f"for ip={client_ip} affiliate='{affiliate_name}' stream='{sname}' "
            "(check allowed_ips and active flag)"
        )
        return 1

    client_name = (client_match.get("client_name") or "").strip() or "unknown"
    endpoint_role = (client_match.get("endpoint_role") or "").strip()

    session_count = count_matching_sessions(sname, client_ip)
    if session_count >= 1:
        log(
            "DENY: duplicate session "
            f"stream={sname} affiliate={affiliate_name} client={client_name} "
            f"ip={client_ip} connector={connector} existing={session_count}"
        )
        return 1

    log(f"ALLOW: stream={sname} affiliate={affiliate_name} client={client_name} role={endpoint_role} ip={client_ip}")
    return output_stream(sname)


if __name__ == "__main__":
    sys.exit(main())
