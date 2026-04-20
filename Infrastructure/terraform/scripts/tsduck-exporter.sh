#!/usr/bin/env bash
# TSduck + tsduck-exporter — runs on the STREAMING VM alongside MistServer.
# Idempotent — safe to re-run.
set -euo pipefail

SRT_OUTPUT_PORTS="${SRT_OUTPUT_PORTS:-1236,1238}"
MIST_API_PORT="${MIST_API_PORT:-4242}"
EXPORTER_PORT="${EXPORTER_PORT:-9101}"

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing TSduck dependencies"
apt-get update -qq
apt-get install -y -qq \
  build-essential cmake git \
  libpcsclite-dev libcurl4-openssl-dev libssl-dev \
  libsrt-openssl-dev libedit-dev zlib1g-dev \
  libsqlite3-dev libusb-1.0-0-dev \
  python3 python3-pip
pip3 install -q prometheus-client

# ---------------------------------------------------------------------------
# TSduck — build from source (Ubuntu 22 has no prebuilt package)
# ---------------------------------------------------------------------------
if ! command -v tsp &>/dev/null; then
  echo "==> Building TSduck from source (this takes ~10 minutes)"
  cd /tmp
  rm -rf tsduck
  git clone --depth 1 https://github.com/tsduck/tsduck.git
  cd tsduck
  make -j"$(nproc)" NORIST=1 NOTELETEXT=1 CXXFLAGS_EXTRA="-Wno-error=attributes" \
    2>&1 | grep -E "^\s+\[(LD|CXX|GEN)\]|error:|Error" || true
  make install NOTELEXT=1 NODOC=1 2>&1 | grep -v "^make" || true
  cd /
  rm -rf /tmp/tsduck
  echo "==> TSduck installed: $(tsp --version 2>&1)"
else
  echo "==> TSduck already installed — skipping"
fi

# ---------------------------------------------------------------------------
# Build STREAMS_JSON from SRT_OUTPUT_PORTS
# ---------------------------------------------------------------------------
PORTS_JSON="["
IFS=',' read -ra PORTS <<< "${SRT_OUTPUT_PORTS}"
for i in "${!PORTS[@]}"; do
  port="${PORTS[$i]}"
  case "$port" in
    1236) name="geo+news" ;;
    1238) name="geo+ent"  ;;
    *)    name="stream_${port}" ;;
  esac
  PORTS_JSON+="{\"name\":\"${name}\",\"port\":${port}}"
  [ $i -lt $((${#PORTS[@]}-1)) ] && PORTS_JSON+=","
done
PORTS_JSON+="]"

# Env file — Python exporter reads config from here at runtime
cat > /etc/tsduck-exporter.env <<EOF
STREAMS_JSON=${PORTS_JSON}
EXPORTER_PORT=${EXPORTER_PORT}
MIST_API_PORT=${MIST_API_PORT}
EOF

# ---------------------------------------------------------------------------
# Deploy tsduck-exporter.py (uploaded by Terraform file provisioner)
# ---------------------------------------------------------------------------
cp /tmp/tsduck-exporter.py /usr/local/bin/tsduck-exporter.py
chmod +x /usr/local/bin/tsduck-exporter.py

cat > /etc/systemd/system/tsduck-exporter.service << 'UNIT'
[Unit]
Description=TSduck Prometheus Exporter for MistServer streams
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
