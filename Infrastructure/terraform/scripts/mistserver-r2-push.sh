#!/usr/bin/env bash
# Configures MistServer to push HLS segments to Cloudflare R2.
# Runs on the streaming VPS after MistServer is already installed.
# Idempotent — safe to re-run.
set -euo pipefail

: "${MIST_API_PORT:=4242}"
: "${R2_ENDPOINT:?R2_ENDPOINT must be set}"
: "${R2_ACCESS_KEY:?R2_ACCESS_KEY must be set}"
: "${R2_SECRET_KEY:?R2_SECRET_KEY must be set}"
: "${R2_BUCKET:?R2_BUCKET must be set}"
: "${STREAM_NAME:=geo-news}"

MIST_API="http://127.0.0.1:${MIST_API_PORT}"

wait_for_mist() {
  echo "==> Waiting for MistServer API..."
  for i in $(seq 1 30); do
    if curl -sf "${MIST_API}/api" > /dev/null 2>&1; then
      echo "==> MistServer ready"
      return
    fi
    sleep 2
  done
  echo "ERROR: MistServer API did not respond after 60s" >&2
  exit 1
}

wait_for_mist

echo "==> Configuring S3/R2 push for stream: ${STREAM_NAME}"

# MistServer S3 push config — sets the push target on the named stream.
# The push URL format: s3://<access-key>:<secret-key>@<endpoint>/<bucket>/live/<stream>/
PUSH_TARGET="s3://${R2_ACCESS_KEY}:${R2_SECRET_KEY}@${R2_ENDPOINT#https://}/${R2_BUCKET}/live/${STREAM_NAME}/"

# Use MistServer API to add the automatic push
curl -sf -X POST "${MIST_API}/api" \
  -H "Content-Type: application/json" \
  -d "{
    \"config\": {
      \"autopush\": {
        \"${STREAM_NAME}\": [\"${PUSH_TARGET}\"]
      }
    }
  }" | jq -r '.result // "configured"'

echo "==> R2 push configured: s3://...@${R2_ENDPOINT#https://}/${R2_BUCKET}/live/${STREAM_NAME}/"
