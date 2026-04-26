#!/usr/bin/env bash
# MistServer API Prometheus Exporter — runs on the STREAMING VM alongside MistServer.
# Idempotent — safe to re-run.
set -euo pipefail

MIST_API_PORT="${MIST_API_PORT:-4242}"
EXPORTER_PORT="${EXPORTER_PORT:-9101}"

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

echo "==> Installing Python dependencies"
apt-get update -qq
apt-get install -y -qq python3 python3-pip
pip3 install -q prometheus-client
ensure_castology_governance

# /etc/cast-prom-metrics.env is written by the Terraform file provisioner before this script runs

# ---------------------------------------------------------------------------
# Migrate from old service names if present
# ---------------------------------------------------------------------------
for old in tsduck-exporter mist-exporter; do
  if systemctl is-active --quiet "$old" 2>/dev/null; then
    systemctl stop "$old" || true
    systemctl disable "$old" || true
  fi
  rm -f /etc/systemd/system/"${old}".service
done
rm -f /usr/local/bin/tsduck-exporter.py /etc/tsduck-exporter.env \
      /usr/local/bin/mist-exporter.py    /etc/mist-exporter.env

# ---------------------------------------------------------------------------
# Deploy cast-prom-metrics.py (uploaded by Terraform file provisioner)
# ---------------------------------------------------------------------------
cp /tmp/cast-prom-metrics.py /usr/local/bin/cast-prom-metrics.py
chmod +x /usr/local/bin/cast-prom-metrics.py

cat > /etc/systemd/system/cast-prom-metrics.service << 'UNIT'
[Unit]
Description=Castology Prometheus metrics exporter
After=network.target mistserver.service

[Service]
Type=simple
EnvironmentFile=/etc/cast-prom-metrics.env
ExecStart=/usr/bin/python3 /usr/local/bin/cast-prom-metrics.py
Restart=always
RestartSec=5
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
UNIT

register_castology_service "cast-prom-metrics.service" "castology-streaming"
systemctl daemon-reload
systemctl enable castology-platform.target
systemctl add-wants castology-streaming.target cast-prom-metrics.service
systemctl enable cast-prom-metrics
systemctl restart cast-prom-metrics
echo "==> cast-prom-metrics running on port ${EXPORTER_PORT}"
