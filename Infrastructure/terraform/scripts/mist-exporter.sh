#!/usr/bin/env bash
# MistServer API Prometheus Exporter — runs on the STREAMING VM alongside MistServer.
# Idempotent — safe to re-run.
set -euo pipefail

MIST_API_PORT="${MIST_API_PORT:-4242}"
EXPORTER_PORT="${EXPORTER_PORT:-9101}"

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing Python dependencies"
apt-get update -qq
apt-get install -y -qq python3 python3-pip
pip3 install -q prometheus-client

# /etc/mist-exporter.env is written by the Terraform file provisioner before this script runs

# ---------------------------------------------------------------------------
# Migrate from old tsduck-exporter service if present
# ---------------------------------------------------------------------------
if systemctl is-active --quiet tsduck-exporter 2>/dev/null; then
  systemctl stop tsduck-exporter || true
  systemctl disable tsduck-exporter || true
fi
rm -f /etc/systemd/system/tsduck-exporter.service \
      /usr/local/bin/tsduck-exporter.py \
      /etc/tsduck-exporter.env

# ---------------------------------------------------------------------------
# Deploy mist-exporter.py (uploaded by Terraform file provisioner)
# ---------------------------------------------------------------------------
cp /tmp/mist-exporter.py /usr/local/bin/mist-exporter.py
chmod +x /usr/local/bin/mist-exporter.py

cat > /etc/systemd/system/mist-exporter.service << 'UNIT'
[Unit]
Description=MistServer API Prometheus Exporter
After=network.target mistserver.service

[Service]
Type=simple
EnvironmentFile=/etc/mist-exporter.env
ExecStart=/usr/bin/python3 /usr/local/bin/mist-exporter.py
Restart=always
RestartSec=5
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable mist-exporter
systemctl restart mist-exporter
echo "==> mist-exporter running on port ${EXPORTER_PORT}"
