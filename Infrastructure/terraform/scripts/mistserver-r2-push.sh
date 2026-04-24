#!/usr/bin/env bash
# MistServer → HLS → R2 pipeline.
#
# Uses ffmpeg to pull HLS from MistServer's local HTTP port and write
# segments to disk. A wrapper script refreshes the MistServer token on
# each ffmpeg restart so token rotation never breaks the stream.
#
# Two upload services per stream:
#   - rclone copy: uploads .ts segments (excludes index.m3u8)
#   - playlist-push (Python/boto3): atomically copies index.m3u8 to a temp
#     file then uploads via boto3, which sends no Content-MD5 header —
#     rclone's Content-MD5 causes R2 BadDigest errors on a live-written file.
#
# Idempotent — safe to re-run.
set -euo pipefail

: "${R2_ENDPOINT:?R2_ENDPOINT must be set}"
: "${R2_ACCESS_KEY:?R2_ACCESS_KEY must be set}"
: "${R2_SECRET_KEY:?R2_SECRET_KEY must be set}"
: "${R2_BUCKET:?R2_BUCKET must be set}"
: "${STREAM_NAME:?STREAM_NAME must be set}"
: "${MIST_HLS_PORT:=8080}"

HLS_DIR="/var/lib/mist-hls/${STREAM_NAME}"
SAFE_NAME="${STREAM_NAME//[^a-zA-Z0-9]/-}"
WRAPPER="/usr/local/bin/mist-hls-writer-${SAFE_NAME}.sh"
PLAYLIST_PUSHER="/usr/local/bin/mist-playlist-push-${SAFE_NAME}.sh"

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
pip3 install -q boto3

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
# Wrapper script — resolves sub-playlist path (token-free from localhost)
# ---------------------------------------------------------------------------
cat > "${WRAPPER}" << 'WRAPPER_EOF'
#!/usr/bin/env bash
set -euo pipefail

STREAM_NAME="${1:?stream name required}"
HLS_PORT="${2:-8080}"
HLS_DIR="/var/lib/mist-hls/${STREAM_NAME}"

# Fetch master playlist to find the sub-playlist path (e.g. 1_0/index.m3u8)
PLAYLIST_URL="http://127.0.0.1:${HLS_PORT}/hls/${STREAM_NAME}/index.m3u8"
PLAYLIST=$(curl -sf "${PLAYLIST_URL}" 2>/dev/null || true)

# Extract sub-playlist path and strip any ?tkn= token — localhost doesn't need it
SUB_PATH=$(echo "${PLAYLIST}" | grep -v '^#' | grep '\.m3u8' | head -1 | cut -d'?' -f1)

if [ -z "${SUB_PATH}" ]; then
  STREAM_URL="${PLAYLIST_URL}"
else
  STREAM_URL="http://127.0.0.1:${HLS_PORT}/hls/${STREAM_NAME}/${SUB_PATH}"
fi

echo "==> Starting ffmpeg for ${STREAM_NAME}: ${STREAM_URL}"
exec /usr/bin/ffmpeg \
  -loglevel error \
  -i "${STREAM_URL}" \
  -c copy \
  -f hls \
  -hls_time 6 \
  -hls_list_size 10 \
  -hls_flags append_list+split_by_time \
  -hls_segment_filename "${HLS_DIR}/seg_%05d.ts" \
  "${HLS_DIR}/index.m3u8"
WRAPPER_EOF
chmod +x "${WRAPPER}"

# ---------------------------------------------------------------------------
# ffmpeg HLS writer service — restarts automatically on token rotation
# ---------------------------------------------------------------------------
FFMPEG_UNIT="mist-hls-writer-${SAFE_NAME}"

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
# Segment + playlist push — single boto3 service per stream.
# Reads index.m3u8 every second, uploads any segment not yet uploaded,
# then uploads a snapshot of index.m3u8. boto3 sends no Content-MD5 header
# so R2 never rejects a live-written playlist (rclone's BadDigest problem).
# ---------------------------------------------------------------------------
SEG_PUSH_SCRIPT="/usr/local/bin/mist-seg-push-${SAFE_NAME}.py"
PLAYLIST_UNIT="mist-seg-push-${SAFE_NAME}"

cat > "${SEG_PUSH_SCRIPT}" << PUSH_EOF
#!/usr/bin/env python3
"""Upload HLS segments + playlist to R2 using parallel uploads."""
import boto3, os, time, shutil
from concurrent.futures import ThreadPoolExecutor, as_completed

HLS_DIR     = "${HLS_DIR}"
BUCKET      = "${R2_BUCKET}"
PREFIX      = "live/${STREAM_NAME}"
TMPPLAYLIST = HLS_DIR + "/.index.upload"
ENDPOINT    = "${R2_ENDPOINT}"
ACCESS_KEY  = "${R2_ACCESS_KEY}"
SECRET_KEY  = "${R2_SECRET_KEY}"

def make_client():
    return boto3.client("s3", endpoint_url=ENDPOINT,
                        aws_access_key_id=ACCESS_KEY,
                        aws_secret_access_key=SECRET_KEY,
                        region_name="auto")

def upload_seg(seg):
    local = os.path.join(HLS_DIR, seg)
    if not os.path.exists(local):
        return False
    make_client().upload_file(local, BUCKET, f"{PREFIX}/{seg}",
                              ExtraArgs={"ContentType": "video/mp2t"})
    return True

# Persist uploaded set across loop iterations — never trimmed.
# Memory cost: ~50 bytes per entry × 86400 segs/day (2s cadence) ≈ 4MB/day.
# For streams running >7 days between restarts, cap at last 100k entries
# (~5MB) which covers 55 hours — well beyond the 2h R2 cleanup window.
uploaded = set()
MAX_UPLOADED = 100_000

with ThreadPoolExecutor(max_workers=4) as pool:
    while True:
        try:
            playlist = os.path.join(HLS_DIR, "index.m3u8")
            if os.path.exists(playlist):
                with open(playlist) as f:
                    segments = [l.strip() for l in f if l.strip() and not l.startswith("#")]
                pending = [s for s in segments if s not in uploaded]
                if pending:
                    futures = {pool.submit(upload_seg, s): s for s in pending}
                    for fut in as_completed(futures):
                        seg = futures[fut]
                        try:
                            if fut.result():
                                uploaded.add(seg)
                        except Exception as e:
                            print(f"[seg-push] {seg}: {e}", flush=True)
                shutil.copy2(playlist, TMPPLAYLIST)
                make_client().upload_file(TMPPLAYLIST, BUCKET, f"{PREFIX}/index.m3u8",
                                          ExtraArgs={"ContentType": "application/vnd.apple.mpegurl"})
            if len(uploaded) > MAX_UPLOADED:
                uploaded = set(list(uploaded)[-MAX_UPLOADED//2:])
        except Exception as e:
            print(f"[seg-push] loop: {e}", flush=True)
        time.sleep(1)
PUSH_EOF
chmod +x "${SEG_PUSH_SCRIPT}"

cat > "/etc/systemd/system/${PLAYLIST_UNIT}.service" << EOF
[Unit]
Description=MistServer segment+playlist push for stream ${STREAM_NAME}
After=network.target ${FFMPEG_UNIT}.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${SEG_PUSH_SCRIPT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# Cleanup script — deletes R2 + local segments older than 2 minutes.
# 2 min is sufficient for a live stream: the HLS playlist window is 10×2s=20s,
# so even a slow player only needs the last ~30s. 2h was wrong for live.
# ---------------------------------------------------------------------------
CLEANUP_UNIT="mist-r2-cleanup-${SAFE_NAME}"
CLEANUP_SCRIPT="/usr/local/bin/mist-r2-cleanup-${SAFE_NAME}.py"

cat > "${CLEANUP_SCRIPT}" << CLEANUP_EOF
#!/usr/bin/env python3
import boto3, os, time
from concurrent.futures import ThreadPoolExecutor, as_completed

BUCKET    = "${R2_BUCKET}"
PREFIX    = "live/${STREAM_NAME}"
ENDPOINT  = "${R2_ENDPOINT}"
ACCESS_KEY= "${R2_ACCESS_KEY}"
SECRET_KEY= "${R2_SECRET_KEY}"
HLS_DIR   = "${HLS_DIR}"
MAX_AGE_S = 120  # 2 minutes — live stream only needs current playlist window

client = boto3.client("s3", endpoint_url=ENDPOINT,
                      aws_access_key_id=ACCESS_KEY,
                      aws_secret_access_key=SECRET_KEY,
                      region_name="auto")

def delete_key(key):
    client.delete_object(Bucket=BUCKET, Key=key)
    return key

now = time.time()
cutoff = now - MAX_AGE_S
to_delete = []

paginator = client.get_paginator("list_objects_v2")
for page in paginator.paginate(Bucket=BUCKET, Prefix=PREFIX + "/"):
    for obj in page.get("Contents", []):
        key = obj["Key"]
        if not key.endswith(".ts"):
            continue
        if obj["LastModified"].timestamp() < cutoff:
            to_delete.append(key)

if not to_delete:
    print("[cleanup] nothing to delete")
else:
    print("[cleanup] deleting %d old segments from R2" % len(to_delete))
    with ThreadPoolExecutor(max_workers=16) as pool:
        futures = {pool.submit(delete_key, k): k for k in to_delete}
        errors = 0
        for fut in as_completed(futures):
            try:
                fut.result()
            except Exception as e:
                errors += 1
                print("[cleanup] error: " + str(e))
        print("[cleanup] done. deleted=%d errors=%d" % (len(to_delete)-errors, errors))

local_deleted = 0
for fname in os.listdir(HLS_DIR):
    if not fname.endswith(".ts"):
        continue
    fpath = os.path.join(HLS_DIR, fname)
    try:
        if os.path.getmtime(fpath) < cutoff:
            os.unlink(fpath)
            local_deleted += 1
    except OSError:
        pass
print("[cleanup] local segments deleted: %d" % local_deleted)
CLEANUP_EOF
chmod +x "${CLEANUP_SCRIPT}"

cat > "/etc/systemd/system/${CLEANUP_UNIT}.service" << EOF
[Unit]
Description=R2 segment cleanup for stream ${STREAM_NAME}

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 ${CLEANUP_SCRIPT}
EOF

cat > "/etc/systemd/system/${CLEANUP_UNIT}.timer" << EOF
[Unit]
Description=Periodic R2 cleanup for ${STREAM_NAME}

[Timer]
OnBootSec=2min
OnCalendar=*:0/2
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

systemctl enable "${FFMPEG_UNIT}"   && systemctl restart "${FFMPEG_UNIT}"
systemctl enable "${PLAYLIST_UNIT}" && systemctl restart "${PLAYLIST_UNIT}"
systemctl enable "${CLEANUP_UNIT}.timer" && systemctl start "${CLEANUP_UNIT}.timer"

echo "==> Pipeline active for '${STREAM_NAME}':"
echo "    ffmpeg (no-token) → ${HLS_DIR}"
echo "    boto3 → r2:${R2_BUCKET}/live/${STREAM_NAME} (segments + playlist)"
echo "    R2 cleanup: segments older than 2 min deleted every 2 min (boto3 parallel)"
