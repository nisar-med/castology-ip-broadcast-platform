#!/usr/bin/env python3
"""Seed active_sessions from auth log ALLOW entries for currently connected sessions.
Covers both broadcaster ingest (input) and affiliate output sessions.
Run after a PocketBase restart when CONN_PLAY records have been lost."""
import subprocess, re, urllib.request, json, socket
from datetime import datetime, timezone

PB_URL = "http://127.0.0.1:8090"
PB_EMAIL = "admin@castology.tv"
VPS_ID = socket.gethostname()

env = {}
with open("/etc/cast-prom-metrics.env") as f:
    for line in f:
        k, _, v = line.strip().partition("=")
        if k: env[k] = v
PB_PASS = env.get("PB_PASS", "")

def pb(method, path, data=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token: headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"{PB_URL}{path}",
        data=json.dumps(data).encode() if data else None,
        headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            body = r.read()
            return json.loads(body) if body else {}
    except Exception as e:
        return {"error": str(e)}

token = pb("POST", "/api/collections/_superusers/auth-with-password",
           {"identity": PB_EMAIL, "password": PB_PASS})["token"]

# Parse auth log — get most recent ALLOW per (stream, ip)
result = subprocess.run(
    ["journalctl", "-t", "cast-mist-stream-auth", "--since", "24 hours ago", "--no-pager", "-o", "short-iso"],
    capture_output=True, text=True
)
allow_re = re.compile(
    r"ALLOW: stream=(?P<stream>\S+) affiliate=(?P<affiliate>.+?) client=(?P<client>.+?) role=\S+ ip=(?P<ip>\S+)$"
)
ts_re = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4})")

best: dict[tuple, dict] = {}
for line in result.stdout.splitlines():
    m = allow_re.search(line)
    if not m:
        continue
    ts_m = ts_re.match(line)
    ts = 0
    if ts_m:
        ts_str = ts_m.group(1)
        if len(ts_str) > 19 and ":" not in ts_str[20:]:
            ts_str = ts_str[:22] + ":" + ts_str[22:]
        try:
            ts = datetime.fromisoformat(ts_str).timestamp()
        except Exception:
            pass
    key = (m.group("stream"), m.group("ip"))
    if key not in best or ts > best[key]["ts"]:
        best[key] = {
            "stream": m.group("stream"),
            "ip": m.group("ip"),
            "affiliate": m.group("affiliate"),
            "client_name": m.group("client"),
            "ts": ts,
        }

# Find all currently connected external sessions from MistSession processes
proc = subprocess.run(["ps", "aux"], capture_output=True, text=True)
active_sessions: dict[tuple, str] = {}  # (stream, ip) → direction
for line in proc.stdout.splitlines():
    if "MistSession" not in line:
        continue
    parts = line.split()
    idx = next((i for i, p in enumerate(parts) if "MistSession" in p), None)
    if idx is None:
        continue
    sess_id = parts[idx + 1] if idx + 1 < len(parts) else ""
    args = parts[idx + 1:]
    stream = ip = protocol = ""
    for i, a in enumerate(args):
        if a == "--streamname" and i + 1 < len(args): stream = args[i + 1]
        elif a == "--ip" and i + 1 < len(args): ip = args[i + 1]
        elif a == "--protocol" and i + 1 < len(args): protocol = args[i + 1]
    ip = ip.replace("::ffff:", "").strip("[]").split(":")[0]
    if not stream or not ip or ip in ("127.0.0.1", "::1"):
        continue
    direction = "input" if sess_id.startswith("I") else "output"
    active_sessions[(stream, ip)] = direction

print(f"Active sessions ({len(active_sessions)}): {dict(active_sessions)}")
print(f"Auth log entries ({len(best)}): {list(best.keys())}")

now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# Load broadcaster_feeds for input seed fallback (ingest has no auth log entry)
feeds_raw = pb("GET", "/api/collections/broadcaster_feeds/records?perPage=200&filter=active%3Dtrue", token=token)
broadcasters_raw = pb("GET", "/api/collections/broadcasters/records?perPage=200&filter=active%3Dtrue", token=token)
broadcaster_feeds = feeds_raw.get("items", [])
broadcasters_by_name = {b["name"]: b for b in broadcasters_raw.get("items", [])}

import ipaddress

def resolve_input(ip, stream):
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return "", ""
    for feed in broadcaster_feeds:
        if feed.get("stream") != stream:
            continue
        allowed_str = feed.get("allowed_ips", "") or \
            broadcasters_by_name.get(feed.get("broadcaster_name", ""), {}).get("allowed_ips", "")
        for entry in [x.strip() for x in allowed_str.split(",") if x.strip()]:
            try:
                if addr in ipaddress.ip_network(entry, strict=False):
                    return feed.get("broadcaster_name", ""), feed.get("feed_role", "primary")
            except ValueError:
                if ip == entry:
                    return feed.get("broadcaster_name", ""), feed.get("feed_role", "primary")
    return "", ""

for (stream, ip), direction in active_sessions.items():
    entry = best.get((stream, ip))
    connector = "TSSRT"

    if entry:
        affiliate = entry["affiliate"]
        client_name = entry["client_name"]
    elif direction == "input":
        # Broadcaster ingest — no auth log, resolve via IP matching
        affiliate, client_name = resolve_input(ip, stream)
        if not affiliate:
            print(f"  SKIP input  {stream} {ip} — no broadcaster_feeds match")
            continue
    else:
        print(f"  SKIP {direction:6} {stream} {ip} — no auth log entry")
        continue

    # Delete existing
    filter_q = urllib.request.quote(f'stream="{stream}" && ip="{ip}" && vps="{VPS_ID}"')
    existing = pb("GET", f"/api/collections/active_sessions/records?filter={filter_q}&perPage=1", token=token)
    for rec in existing.get("items", []):
        pb("DELETE", f"/api/collections/active_sessions/records/{rec['id']}", token=token)

    result2 = pb("POST", "/api/collections/active_sessions/records", {
        "stream": stream, "ip": ip, "connector": connector,
        "direction": direction, "affiliate": affiliate, "client_name": client_name,
        "token": "", "vps": VPS_ID, "connected_at": now,
    }, token=token)
    if "error" in result2:
        print(f"  ERROR  {direction:6} {stream} {ip}: {result2['error']}")
    else:
        print(f"  Seeded {direction:6} {stream} {ip} → affiliate={affiliate!r} client={client_name!r}")

print("Done.")
