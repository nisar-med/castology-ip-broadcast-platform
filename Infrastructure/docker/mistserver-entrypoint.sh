#!/usr/bin/env bash
# Patches /etc/mistserver.conf with runtime env vars then starts MistController.
set -euo pipefail

CONF=/etc/mistserver.conf

: "${PROMETHEUS_PASSPHRASE:?PROMETHEUS_PASSPHRASE must be set}"
: "${MIST_PASSWORD:?MIST_PASSWORD must be set}"
: "${MIST_USERNAME:=admin}"
: "${SRT_INGEST_PORT:=1235}"
: "${PB_URL:=http://pocketbase:8090}"
: "${PB_EMAIL:?PB_EMAIL must be set}"
: "${PB_PASS:?PB_PASS must be set}"

MIST_PASSWORD_MD5=$(printf '%s' "${MIST_PASSWORD}" | md5sum | cut -d' ' -f1)

# Write PocketBase credentials for cast-mist-stream-auth.sh
cat > /etc/cast-mist-stream-auth.env <<EOF
PB_URL=${PB_URL}
PB_EMAIL=${PB_EMAIL}
PB_PASS=${PB_PASS}
EOF
chmod 600 /etc/cast-mist-stream-auth.env

# Patch MistServer config — update prometheus path and only the first TSSRT
# entry (ingest port); additional TSSRT entries (output ports) are left as-is.
jq \
  --arg prom     "${PROMETHEUS_PASSPHRASE}" \
  --arg user     "${MIST_USERNAME}" \
  --arg pass     "${MIST_PASSWORD_MD5}" \
  --argjson srt_port "${SRT_INGEST_PORT}" \
  '
  .config.prometheus = $prom |
  .account = {($user): {"password": $pass}} |
  (.config.protocols | map(.connector) | indices("TSSRT")[0]) as $ingest_idx |
  .config.protocols[$ingest_idx].port = $srt_port
  ' "${CONF}" > /tmp/mistserver.conf

cat /tmp/mistserver.conf > "${CONF}"

exec MistController -c "${CONF}"
