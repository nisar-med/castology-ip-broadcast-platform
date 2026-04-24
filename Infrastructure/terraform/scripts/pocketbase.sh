#!/usr/bin/env bash
# PocketBase — installs latest release, sets up collections and systemd service.
# Idempotent — safe to re-run.
set -euo pipefail

PB_ADMIN_EMAIL="${PB_ADMIN_EMAIL:?PB_ADMIN_EMAIL must be set}"
PB_ADMIN_PASSWORD="${PB_ADMIN_PASSWORD:?PB_ADMIN_PASSWORD must be set}"
STREAMING_PUBLIC_IP="${STREAMING_PUBLIC_IP:?STREAMING_PUBLIC_IP must be set}"
SRT_INGEST_PORT="${SRT_INGEST_PORT:-1235}"
SRT_OUTPUT_PORTS="${SRT_OUTPUT_PORTS:-1236,1238}"

PB_DIR="/opt/pocketbase"
PB_BIN="${PB_DIR}/pocketbase"
PB_DATA="${PB_DIR}/pb_data"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl jq unzip

# ---------------------------------------------------------------------------
# Install PocketBase
# ---------------------------------------------------------------------------
if [ ! -f "${PB_BIN}" ]; then
  echo "==> Installing PocketBase"
  mkdir -p "${PB_DIR}"

  LATEST=$(curl -sf https://api.github.com/repos/pocketbase/pocketbase/releases/latest \
    | jq -r '.tag_name' | tr -d 'v')
  ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
  URL="https://github.com/pocketbase/pocketbase/releases/download/v${LATEST}/pocketbase_${LATEST}_linux_${ARCH}.zip"

  curl -fsSL "${URL}" -o /tmp/pocketbase.zip
  unzip -q /tmp/pocketbase.zip -d "${PB_DIR}"
  chmod +x "${PB_BIN}"
  rm /tmp/pocketbase.zip
  echo "==> PocketBase ${LATEST} installed"
else
  echo "==> PocketBase already installed — skipping download"
fi

# ---------------------------------------------------------------------------
# Systemd service
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/pocketbase.service << EOF
[Unit]
Description=PocketBase
After=network.target

[Service]
Type=simple
WorkingDirectory=${PB_DIR}
ExecStart=${PB_BIN} serve --http=127.0.0.1:8090 --dir=${PB_DATA}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pocketbase
systemctl restart pocketbase

echo "==> Waiting for PocketBase to start..."
for i in $(seq 1 20); do
  if curl -sf http://127.0.0.1:8090/api/health > /dev/null 2>&1; then
    echo "==> PocketBase is up"
    break
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
# Bootstrap superadmin — PocketBase v0.23+ uses CLI (not API) for superusers
# ---------------------------------------------------------------------------
${PB_BIN} superuser upsert "${PB_ADMIN_EMAIL}" "${PB_ADMIN_PASSWORD}" --dir="${PB_DATA}"
echo "==> Superadmin upserted"

# Get auth token for schema setup — v0.23+ endpoint
TOKEN=$(curl -sf -X POST http://127.0.0.1:8090/api/collections/_superusers/auth-with-password \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"${PB_ADMIN_EMAIL}\",\"password\":\"${PB_ADMIN_PASSWORD}\"}" \
  | jq -r '.token')

if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "null" ]; then
  echo "ERROR: Could not authenticate to PocketBase" >&2
  exit 1
fi

AUTH="Authorization: Bearer ${TOKEN}"

# ---------------------------------------------------------------------------
# Collections
# ---------------------------------------------------------------------------

# broadcasters — ingest side (companies pushing SRT streams into MistServer)
echo "==> Creating broadcasters collection..."
curl -sf -X POST http://127.0.0.1:8090/api/collections \
  -H "Content-Type: application/json" \
  -H "${AUTH}" \
  -d '{
    "name": "broadcasters",
    "type": "base",
    "fields": [
      {"name":"name",        "type":"text",  "required":true},
      {"name":"token_key",   "type":"text",  "required":true},
      {"name":"streams",     "type":"json",  "required":false},
      {"name":"allowed_ips", "type":"text",  "required":false},
      {"name":"active",      "type":"bool",  "required":false}
    ]
  }' | jq -r '"broadcasters collection: \(.id // .message)"' || echo "==> broadcasters may already exist"

# affiliates — playout side (cable operators, streaming services pulling SRT streams)
echo "==> Creating affiliates collection..."
curl -sf -X POST http://127.0.0.1:8090/api/collections \
  -H "Content-Type: application/json" \
  -H "${AUTH}" \
  -d '{
    "name": "affiliates",
    "type": "base",
    "fields": [
      {"name":"name",         "type":"text",  "required":true},
      {"name":"token_key",    "type":"text",  "required":true},
      {"name":"streams",      "type":"json",  "required":false},
      {"name":"allowed_ips",  "type":"text",  "required":false},
      {"name":"contact_name", "type":"text",  "required":false},
      {"name":"email",        "type":"email", "required":false},
      {"name":"phone",        "type":"text",  "required":false},
      {"name":"notes",        "type":"text",  "required":false},
      {"name":"active",       "type":"bool",  "required":false}
    ]
  }' | jq -r '"affiliates collection: \(.id // .message)"' || echo "==> affiliates may already exist"

echo "==> PocketBase schema configured"

# ---------------------------------------------------------------------------
# Placeholder — operator portal not yet implemented
# ---------------------------------------------------------------------------
mkdir -p /var/www/onboard

cat > /var/www/onboard/index.html << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Castology</title>
  <style>
    body { font-family: -apple-system, sans-serif; background: #0f1117; color: #e2e8f0; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
    .card { text-align: center; padding: 2rem; }
    h1 { font-size: 1.5rem; color: #fff; margin-bottom: 0.5rem; }
    p { color: #64748b; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Castology</h1>
    <p>Coming soon. Contact <a href="mailto:support@castology.tv" style="color:#6366f1;">support@castology.tv</a> for access.</p>
  </div>
</body>
</html>
HTMLEOF

echo "==> Operator portal deployed to /var/www/onboard"
echo "==> PocketBase admin UI: http://localhost:8090/_/"
echo "==> PocketBase setup complete"
