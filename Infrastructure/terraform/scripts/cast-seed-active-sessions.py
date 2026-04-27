#!/usr/bin/env python3
"""Seed active_sessions from auth log ALLOW entries for currently connected output sessions.
Broadcaster ingest sessions (inputs) are intentionally skipped — identity resolved via IP matching."""
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

# Most recent ALLOW per (stream, ip)
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

# Find currently connected output sessions from MistSession processes
proc = subprocess.run(["ps", "aux"], capture_output=True, text=True)
active_outputs: set[tuple] = set()
for line in proc.stdout.splitlines():
    if "MistSession" not in line:
        continue
    parts = line.split()
    idx = next((i for i, p in enumerate(parts) if "MistSession" in p), None)
    if idx is None:
        continue
    sess_id = parts[idx + 1] if idx + 1 < len(parts) else ""
    if sess_id.startswith("I"):
        continue  # broadcaster input — skip
    args = parts[idx + 1:]
    stream = ip = ""
    for i, a in enumerate(args):
        if a == "--streamname" and i + 1 < len(args): stream = args[i + 1]
        elif a == "--ip" and i + 1 < len(args): ip = args[i + 1]
    ip = ip.replace("::ffff:", "").strip("[]").split(":")[0]
    if stream and ip and ip not in ("127.0.0.1", "::1"):
        active_outputs.add((stream, ip))

print(f"Active output sessions: {active_outputs}")
print(f"Auth log entries: {list(best.keys())}")

now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

for key in active_outputs:
    stream, ip = key
    entry = best.get(key)
    if not entry:
        print(f"  SKIP {stream} {ip} — no auth log entry found")
        continue

    affiliate = entry["affiliate"]
    client_name = entry["client_name"]

    # Delete existing
    filter_q = urllib.request.quote(f'stream="{stream}" && ip="{ip}" && vps="{VPS_ID}"')
    existing = pb("GET", f"/api/collections/active_sessions/records?filter={filter_q}&perPage=1", token=token)
    for rec in existing.get("items", []):
        pb("DELETE", f"/api/collections/active_sessions/records/{rec['id']}", token=token)

    # Insert
    result2 = pb("POST", "/api/collections/active_sessions/records", {
        "stream": stream, "ip": ip, "connector": "TSSRT",
        "affiliate": affiliate, "client_name": client_name,
        "token": "", "vps": VPS_ID, "connected_at": now,
    }, token=token)
    if "error" in result2:
        print(f"  ERROR {stream} {ip}: {result2['error']}")
    else:
        print(f"  Seeded: {stream} {ip} → affiliate={affiliate!r} client={client_name!r}")

print("Done.")
