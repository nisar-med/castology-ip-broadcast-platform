#!/usr/bin/env bash
# Incremental deploy: pulls latest commit on VPS and restarts services.
# Usage: bash deploy-incremental.sh <vps-ip> [git-ref]
#   git-ref defaults to HEAD (latest) — pass a SHA or tag to deploy a specific commit.
set -euo pipefail

VPS_IP="${1:?Usage: deploy-incremental.sh <vps-ip> [git-ref]}"
GIT_REF="${2:-HEAD}"
REPO_DIR="/opt/castology"
DOCKER_DIR="${REPO_DIR}/Infrastructure/docker"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="$(git -C "${SCRIPT_DIR}" remote get-url origin)"

ssh_run() { ssh -o StrictHostKeyChecking=no root@"${VPS_IP}" "$@"; }

# ---------------------------------------------------------------------------
echo "==> [1/3] Updating repo on VPS (ref: ${GIT_REF})"
# ---------------------------------------------------------------------------
ssh_run bash -s -- "${REPO_DIR}" "${REPO_URL}" "${GIT_REF}" << 'REMOTE'
set -euo pipefail
REPO_DIR="$1" REPO_URL="$2" GIT_REF="$3"
if [ ! -d "${REPO_DIR}/.git" ]; then
  git clone "${REPO_URL}" "${REPO_DIR}"
fi
cd "${REPO_DIR}"
git fetch origin
if [ "${GIT_REF}" = "HEAD" ]; then
  git reset --hard origin/main
else
  git reset --hard "${GIT_REF}"
fi
echo "    Now at $(git rev-parse --short HEAD) — $(git log -1 --pretty=%s)"
REMOTE

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
docker compose up -d --build --remove-orphans
REMOTE

echo ""
echo "==> Deploy complete"
