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

# /etc/tsduck-exporter.env is written by the Terraform file provisioner before this script runs

# ---------------------------------------------------------------------------
# Deploy tsduck-exporter.py (uploaded by Terraform file provisioner)
# ---------------------------------------------------------------------------
cp /tmp/tsduck-exporter.py /usr/local/bin/tsduck-exporter.py
chmod +x /usr/local/bin/tsduck-exporter.py

cat > /etc/systemd/system/tsduck-exporter.service << 'UNIT'
[Unit]
Description=MistServer API Prometheus Exporter
After=network.target mistserver.service

[Service]
Type=simple
EnvironmentFile=/etc/tsduck-exporter.env
ExecStart=/usr/bin/python3 /usr/local/bin/tsduck-exporter.py
Restart=always
RestartSec=5
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable tsduck-exporter
systemctl restart tsduck-exporter
echo "==> tsduck-exporter running on port ${EXPORTER_PORT}"
