#!/usr/bin/env bash
# Incremental deploy: syncs files and restarts only changed services.
# Usage: bash deploy-incremental.sh <vps-ip>
set -euo pipefail

VPS_IP="${1:?Usage: deploy-incremental.sh <vps-ip>}"
REPO_DIR="/opt/castology"
DOCKER_DIR="${REPO_DIR}/Infrastructure/docker"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ssh_run() { ssh -o StrictHostKeyChecking=no root@"${VPS_IP}" "$@"; }

# ---------------------------------------------------------------------------
echo "==> [1/3] Syncing repo to VPS"
# ---------------------------------------------------------------------------
rsync -az --delete \
  --exclude='.git' \
  --exclude='.claude' \
  --exclude='Infrastructure/docker/.env' \
  --exclude='Infrastructure/terraform/' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  -e "ssh -o StrictHostKeyChecking=no" \
  "${REPO_ROOT}/" \
  root@"${VPS_IP}":"${REPO_DIR}/"
echo "    Repo synced"

# ---------------------------------------------------------------------------
echo "==> [2/3] Copying .env"
# ---------------------------------------------------------------------------
if [ ! -f "${SCRIPT_DIR}/.env" ]; then
  echo "ERROR: ${SCRIPT_DIR}/.env not found."
  exit 1
fi
scp "${SCRIPT_DIR}/.env" root@"${VPS_IP}":"${DOCKER_DIR}/.env"
echo "    .env copied"

# ---------------------------------------------------------------------------
echo "==> [3/3] Rebuilding and restarting services"
# ---------------------------------------------------------------------------
ssh_run bash -s -- "${DOCKER_DIR}" << 'REMOTE'
set -euo pipefail
cd "$1"
docker compose pull --quiet 2>/dev/null || true
docker compose up -d --build --remove-orphans
REMOTE

echo ""
echo "==> Incremental deploy complete"
