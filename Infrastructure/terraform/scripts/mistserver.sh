#!/usr/bin/env bash
# MistServer — installs and configures MistServer.
# Idempotent — safe to re-run.
set -euo pipefail

SRT_INGEST_PORT="${SRT_INGEST_PORT:-1235}"
SRT_OUTPUT_PORTS="${SRT_OUTPUT_PORTS:-1236,1238}"   # comma-separated
MIST_API_PORT="${MIST_API_PORT:-4242}"
PROMETHEUS_PASSPHRASE="${PROMETHEUS_PASSPHRASE:?PROMETHEUS_PASSPHRASE must be set}"

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing dependencies"
apt-get update -qq
apt-get install -y -qq curl wget jq ufw

# ---------------------------------------------------------------------------
# MistServer
# ---------------------------------------------------------------------------
if ! command -v MistController &>/dev/null; then
  echo "==> Installing MistServer"
  curl -fsSL https://d.mistserver.org/mistserver_unsigned.sh | bash
else
  echo "==> MistServer already installed — skipping"
fi

# Set Prometheus passphrase in config
if [ -f /etc/mistserver.conf ]; then
  python3 - <<PYEOF
import json
with open('/etc/mistserver.conf') as f:
    cfg = json.load(f)
cfg.setdefault('config', {})['prometheus'] = '${PROMETHEUS_PASSPHRASE}'
with open('/etc/mistserver.conf', 'w') as f:
    json.dump(cfg, f, indent=2)
print('MistServer Prometheus passphrase configured')
PYEOF
fi

systemctl enable mistserver
systemctl restart mistserver
echo "==> MistServer running"

echo "==> Streaming server setup complete"
