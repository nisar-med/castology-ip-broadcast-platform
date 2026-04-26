#!/usr/bin/env bash
# MistServer — installs and configures MistServer.
# Idempotent — safe to re-run.
set -euo pipefail

SRT_INGEST_PORT="${SRT_INGEST_PORT:-1235}"
SRT_OUTPUT_PORTS="${SRT_OUTPUT_PORTS:-1236,1238}"   # comma-separated
MIST_API_PORT="${MIST_API_PORT:-4242}"
PROMETHEUS_PASSPHRASE="${PROMETHEUS_PASSPHRASE:?PROMETHEUS_PASSPHRASE must be set}"
MIST_SHM_SIZE="${MIST_SHM_SIZE:-1536M}"

export DEBIAN_FRONTEND=noninteractive

ensure_castology_governance() {
  mkdir -p /etc/systemd/system

  cat > /etc/systemd/system/castology-platform.target <<'EOF'
[Unit]
Description=Castology platform services
Wants=castology-streaming.target castology-origin.target castology-monitoring.target
After=castology-streaming.target castology-origin.target castology-monitoring.target

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/castology-streaming.target <<'EOF'
[Unit]
Description=Castology streaming services
PartOf=castology-platform.target
EOF

  cat > /etc/systemd/system/castology-origin.target <<'EOF'
[Unit]
Description=Castology origin services
PartOf=castology-platform.target
EOF

  cat > /etc/systemd/system/castology-monitoring.target <<'EOF'
[Unit]
Description=Castology monitoring services
PartOf=castology-platform.target
EOF

  cat > /etc/systemd/system/castology.slice <<'EOF'
[Unit]
Description=Castology platform slice
Before=slices.target

[Slice]
CPUAccounting=true
MemoryAccounting=true
TasksAccounting=true
EOF
}

register_castology_service() {
  local unit="$1"
  local target="$2"
  mkdir -p "/etc/systemd/system/${unit}.d"
  cat > "/etc/systemd/system/${unit}.d/castology.conf" <<EOF
[Unit]
PartOf=${target}.target

[Service]
Slice=castology.slice
EOF
}

echo "==> Installing dependencies"
apt-get update -qq
apt-get install -y -qq curl wget jq ufw
ensure_castology_governance

# ---------------------------------------------------------------------------
# MistServer
# ---------------------------------------------------------------------------
if ! command -v MistController &>/dev/null; then
  echo "==> Installing MistServer"
  curl -fsSL https://d.mistserver.org/mistserver_unsigned.sh | bash
else
  echo "==> MistServer already installed — skipping"
fi

echo "==> Configuring shared memory"
python3 - <<PYEOF
from pathlib import Path

fstab = Path("/etc/fstab")
entry = "tmpfs /dev/shm tmpfs defaults,size=${MIST_SHM_SIZE} 0 0"
lines = fstab.read_text().splitlines() if fstab.exists() else []
out = []
replaced = False

for line in lines:
    stripped = line.strip()
    if stripped and not stripped.startswith("#"):
        parts = stripped.split()
        if len(parts) >= 3 and parts[1] == "/dev/shm" and parts[2] == "tmpfs":
            out.append(entry)
            replaced = True
            continue
    out.append(line)

if not replaced:
    out.append(entry)

fstab.write_text("\n".join(out) + "\n")
PYEOF
mount -o remount,size="${MIST_SHM_SIZE}" /dev/shm
df -h /dev/shm

# Configure MistServer — must be done with service stopped to prevent overwrites
systemctl stop mistserver 2>/dev/null || true
sleep 2

if [ -f /etc/mistserver.conf ]; then
  python3 - <<PYEOF
import json

with open('/etc/mistserver.conf') as f:
    cfg = json.load(f)

cfg.setdefault('config', {})['prometheus'] = '${PROMETHEUS_PASSPHRASE}'

# Trust nginx loopback so PLAY_REWRITE sees real client IP via X-Real-IP header
cfg['config']['trustedproxy'] = ['127.0.0.1']

# Protocols: HTTP on 8080, HLS output, SRT ingest on configured port
cfg['config']['protocols'] = [
    {"connector": "HTTP",  "online": 1, "port": 8080},
    {"connector": "HLS",   "online": 1},
    {"connector": "TSSRT", "online": 1, "port": ${SRT_INGEST_PORT}},
]

# Wildcard stream — accepts any push with geo+ prefix
cfg.setdefault('streams', {})['geo'] = {
    "name": "geo",
    "source": "push://",
    "processes": [],
    "stop_sessions": False,
    "tags": []
}

with open('/etc/mistserver.conf', 'w') as f:
    json.dump(cfg, f, indent=2)
print('MistServer config written')
PYEOF
fi

register_castology_service "mistserver.service" "castology-streaming"
systemctl daemon-reload
systemctl enable castology-platform.target
systemctl add-wants castology-streaming.target mistserver.service
systemctl enable mistserver
systemctl start mistserver
echo "==> MistServer running"

echo "==> Streaming server setup complete"
