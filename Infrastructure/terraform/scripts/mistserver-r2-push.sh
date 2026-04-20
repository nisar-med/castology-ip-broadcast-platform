#!/usr/bin/env bash
# Pulls HLS from MistServer's local HTTP port and syncs segments to R2 via rclone.
# Uses ffmpeg to pull the live stream and write HLS segments to disk.
# rclone then syncs the local segments directory to R2 continuously.
# Idempotent — safe to re-run.
set -euo pipefail

: "${R2_ENDPOINT:?R2_ENDPOINT must be set}"
: "${R2_ACCESS_KEY:?R2_ACCESS_KEY must be set}"
: "${R2_SECRET_KEY:?R2_SECRET_KEY must be set}"
: "${R2_BUCKET:?R2_BUCKET must be set}"
: "${STREAM_NAME:?STREAM_NAME must be set}"
: "${MIST_API_PORT:=4242}"
: "${MIST_HLS_PORT:=8080}"

HLS_DIR="/var/lib/mist-hls/${STREAM_NAME}"
MIST_HLS_URL="http://127.0.0.1:${MIST_HLS_PORT}/hls/${STREAM_NAME}/index.m3u8"

# ---------------------------------------------------------------------------
# Install dependencies
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
if ! command -v ffmpeg &>/dev/null; then
  echo "==> Installing ffmpeg"
  apt-get update -qq
  apt-get install -y -qq ffmpeg
fi

if ! command -v rclone &>/dev/null; then
  echo "==> Installing rclone"
  curl -fsSL https://rclone.org/install.sh | bash
else
  echo "==> rclone already installed"
fi

mkdir -p "${HLS_DIR}"

# ---------------------------------------------------------------------------
# Configure rclone R2 remote
# ---------------------------------------------------------------------------
mkdir -p /root/.config/rclone
cat > /root/.config/rclone/rclone.conf << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY}
secret_access_key = ${R2_SECRET_KEY}
endpoint = ${R2_ENDPOINT}
acl = private
EOF
echo "==> rclone R2 remote configured"

# ---------------------------------------------------------------------------
# ffmpeg HLS writer — pulls from MistServer, writes segments to disk
# ---------------------------------------------------------------------------
FFMPEG_UNIT="mist-hls-writer-${STREAM_NAME//[^a-zA-Z0-9]/-}"

cat > "/etc/systemd/system/${FFMPEG_UNIT}.service" << EOF
[Unit]
Description=MistServer HLS writer for stream ${STREAM_NAME}
After=network.target mistserver.service

[Service]
Type=simple
ExecStart=/usr/bin/ffmpeg -re -i ${MIST_HLS_URL} -c copy -f hls -hls_time 4 -hls_list_size 5 -hls_flags delete_segments+append_list -hls_segment_filename ${HLS_DIR}/seg_%%05d.ts ${HLS_DIR}/index.m3u8
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# rclone sync — watches local HLS dir and pushes to R2 every 2s
# ---------------------------------------------------------------------------
RCLONE_UNIT="mist-r2-sync-${STREAM_NAME//[^a-zA-Z0-9]/-}"

cat > "/etc/systemd/system/${RCLONE_UNIT}.service" << EOF
[Unit]
Description=MistServer HLS to R2 sync for stream ${STREAM_NAME}
After=network.target ${FFMPEG_UNIT}.service

[Service]
Type=simple
ExecStart=/usr/bin/rclone sync ${HLS_DIR} r2:${R2_BUCKET}/live/${STREAM_NAME} --s3-chunk-size=5M --transfers=8 --fast-list --log-level=ERROR
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

systemctl enable "${FFMPEG_UNIT}"
systemctl restart "${FFMPEG_UNIT}"

systemctl enable "${RCLONE_UNIT}"
systemctl restart "${RCLONE_UNIT}"

echo "==> Pipeline active:"
echo "    MistServer HLS :${MIST_HLS_PORT} → ffmpeg → ${HLS_DIR} → rclone → r2:${R2_BUCKET}/live/${STREAM_NAME}"
