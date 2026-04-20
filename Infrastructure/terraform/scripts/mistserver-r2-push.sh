#!/usr/bin/env bash
# MistServer → HLS → R2 pipeline.
#
# Uses ffmpeg to pull HLS from MistServer's local HTTP port and write
# segments to disk. A wrapper script refreshes the MistServer token on
# each ffmpeg restart so token rotation never breaks the stream.
# rclone copy uploads new segments to R2 on a 2s loop.
# Idempotent — safe to re-run.
set -euo pipefail

: "${R2_ENDPOINT:?R2_ENDPOINT must be set}"
: "${R2_ACCESS_KEY:?R2_ACCESS_KEY must be set}"
: "${R2_SECRET_KEY:?R2_SECRET_KEY must be set}"
: "${R2_BUCKET:?R2_BUCKET must be set}"
: "${STREAM_NAME:?STREAM_NAME must be set}"
: "${MIST_HLS_PORT:=8080}"

HLS_DIR="/var/lib/mist-hls/${STREAM_NAME}"
WRAPPER="/usr/local/bin/mist-hls-writer-${STREAM_NAME//[^a-zA-Z0-9]/-}.sh"

# ---------------------------------------------------------------------------
# Install dependencies
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
if ! command -v ffmpeg &>/dev/null; then
  apt-get update -qq && apt-get install -y -qq ffmpeg
fi
if ! command -v rclone &>/dev/null; then
  curl -fsSL https://rclone.org/install.sh | bash
fi

mkdir -p "${HLS_DIR}"

# ---------------------------------------------------------------------------
# rclone config
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

# ---------------------------------------------------------------------------
# Wrapper script — fetches fresh MistServer token before each ffmpeg run
# ---------------------------------------------------------------------------
cat > "${WRAPPER}" << 'WRAPPER_EOF'
#!/usr/bin/env bash
set -euo pipefail

STREAM_NAME="${1:?stream name required}"
HLS_PORT="${2:-8080}"
HLS_DIR="/var/lib/mist-hls/${STREAM_NAME}"

# Fetch fresh playlist to get current token from MistServer
PLAYLIST_URL="http://127.0.0.1:${HLS_PORT}/hls/${STREAM_NAME}/index.m3u8"
PLAYLIST=$(curl -sf "${PLAYLIST_URL}" 2>/dev/null || true)

# Extract the sub-playlist URL (contains the token) from the master playlist
SUB_URL=$(echo "${PLAYLIST}" | grep -v '^#' | grep '\.m3u8' | head -1)

if [ -z "${SUB_URL}" ]; then
  # Not a master playlist — use the URL directly
  STREAM_URL="${PLAYLIST_URL}"
else
  # Build full sub-playlist URL
  BASE="http://127.0.0.1:${HLS_PORT}/hls/${STREAM_NAME}/"
  STREAM_URL="${BASE}${SUB_URL}"
fi

echo "==> Starting ffmpeg for ${STREAM_NAME}: ${STREAM_URL}"
exec /usr/bin/ffmpeg \
  -loglevel error \
  -i "${STREAM_URL}" \
  -c copy \
  -f hls \
  -hls_time 2 \
  -hls_list_size 10 \
  -hls_flags append_list+split_by_time \
  -hls_segment_filename "${HLS_DIR}/seg_%05d.ts" \
  "${HLS_DIR}/index.m3u8"
WRAPPER_EOF
chmod +x "${WRAPPER}"

# ---------------------------------------------------------------------------
# ffmpeg HLS writer service — restarts automatically on token rotation
# ---------------------------------------------------------------------------
FFMPEG_UNIT="mist-hls-writer-${STREAM_NAME//[^a-zA-Z0-9]/-}"

cat > "/etc/systemd/system/${FFMPEG_UNIT}.service" << EOF
[Unit]
Description=MistServer HLS writer for stream ${STREAM_NAME}
After=network.target mistserver.service

[Service]
Type=simple
ExecStart=${WRAPPER} ${STREAM_NAME} ${MIST_HLS_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# rclone copy loop — uploads new segments to R2 every 2s
# ---------------------------------------------------------------------------
RCLONE_UNIT="mist-r2-sync-${STREAM_NAME//[^a-zA-Z0-9]/-}"

cat > "/etc/systemd/system/${RCLONE_UNIT}.service" << EOF
[Unit]
Description=MistServer HLS to R2 sync for stream ${STREAM_NAME}
After=network.target ${FFMPEG_UNIT}.service

[Service]
Type=simple
ExecStart=/usr/bin/rclone copy ${HLS_DIR} r2:${R2_BUCKET}/live/${STREAM_NAME} --s3-chunk-size=5M --transfers=8 --s3-no-check-bucket --ignore-checksum --log-level=ERROR
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# Cleanup timer — deletes R2 segments older than 2 hours
# ---------------------------------------------------------------------------
CLEANUP_UNIT="mist-r2-cleanup-${STREAM_NAME//[^a-zA-Z0-9]/-}"

cat > "/etc/systemd/system/${CLEANUP_UNIT}.service" << EOF
[Unit]
Description=R2 segment cleanup for stream ${STREAM_NAME}

[Service]
Type=oneshot
ExecStart=/usr/bin/rclone delete r2:${R2_BUCKET}/live/${STREAM_NAME} --min-age=2h --include="*.ts" --log-level=ERROR
EOF

cat > "/etc/systemd/system/${CLEANUP_UNIT}.timer" << EOF
[Unit]
Description=Periodic R2 cleanup for ${STREAM_NAME}

[Timer]
OnBootSec=10min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

systemctl enable "${FFMPEG_UNIT}" && systemctl restart "${FFMPEG_UNIT}"
systemctl enable "${RCLONE_UNIT}" && systemctl restart "${RCLONE_UNIT}"
systemctl enable "${CLEANUP_UNIT}.timer" && systemctl start "${CLEANUP_UNIT}.timer"

echo "==> Pipeline active for '${STREAM_NAME}':"
echo "    ffmpeg (token-aware) → ${HLS_DIR} → rclone → r2:${R2_BUCKET}/live/${STREAM_NAME}"
echo "    R2 cleanup: segments older than 2h deleted every 30min"
