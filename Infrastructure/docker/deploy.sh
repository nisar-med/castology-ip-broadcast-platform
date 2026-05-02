#!/usr/bin/env bash
# Deploys the Castology stack to a fresh VPS.
# Run from your local machine — requires SSH access to root@VPS_IP.
#
# Usage:
#   bash deploy.sh <vps-ip>
#   bash deploy.sh 51.254.136.32
set -euo pipefail

VPS_IP="${1:?Usage: deploy.sh <vps-ip>}"
REPO_DIR="/opt/castology"
DOCKER_DIR="${REPO_DIR}/Infrastructure/docker"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ssh_run() { ssh -o StrictHostKeyChecking=no root@"${VPS_IP}" "$@"; }

# ---------------------------------------------------------------------------
echo "==> [1/6] Installing Docker on VPS"
# ---------------------------------------------------------------------------
ssh_run bash << 'REMOTE'
set -euo pipefail
if command -v docker &>/dev/null; then
  echo "Docker already installed: $(docker --version)"
  exit 0
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin git
systemctl enable docker
echo "Docker installed: $(docker --version)"
REMOTE

# ---------------------------------------------------------------------------
echo "==> [2/6] Syncing repo to VPS"
# ---------------------------------------------------------------------------
ssh_run mkdir -p "${REPO_DIR}"
rsync -az --delete \
  --exclude='.git' \
  --exclude='Infrastructure/docker/.env' \
  --exclude='Infrastructure/terraform/.terraform' \
  --exclude='Infrastructure/terraform/terraform.tfstate*' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  -e "ssh -o StrictHostKeyChecking=no" \
  "${REPO_ROOT}/" \
  root@"${VPS_IP}":"${REPO_DIR}/"
echo "    Repo synced"

# ---------------------------------------------------------------------------
echo "==> [3/6] Copying .env"
# ---------------------------------------------------------------------------
if [ ! -f "${SCRIPT_DIR}/.env" ]; then
  echo "ERROR: ${SCRIPT_DIR}/.env not found. Copy .env.example and fill in values."
  exit 1
fi
scp "${SCRIPT_DIR}/.env" root@"${VPS_IP}":"${DOCKER_DIR}/.env"
echo "    .env copied"

# ---------------------------------------------------------------------------
echo "==> [4/7] Running host setup (kernel tuning, Docker daemon limits)"
# ---------------------------------------------------------------------------
ssh_run bash "${DOCKER_DIR}/setup-host.sh"

# ---------------------------------------------------------------------------
echo "==> [5/7] Configuring firewall (ufw)"
# ---------------------------------------------------------------------------
# Read SRT ports from local .env if available
if [ -f "${SCRIPT_DIR}/.env" ]; then
  SRT_INGEST=$(grep -E '^SRT_INGEST_PORT=' "${SCRIPT_DIR}/.env" | cut -d= -f2 | tr -d '[:space:]')
  SRT_OUTPUT=$(grep -E '^SRT_OUTPUT_PORT=' "${SCRIPT_DIR}/.env" | cut -d= -f2 | tr -d '[:space:]')
fi
SRT_INGEST="${SRT_INGEST:-1235}"
SRT_OUTPUT="${SRT_OUTPUT:-1234}"
ssh_run bash -s -- "${DOCKER_DIR}/scripts/firewall.sh" "${SRT_INGEST}" "${SRT_OUTPUT}" << 'REMOTE'
set -euo pipefail
SCRIPT="$1"
SRT_INGEST="$2"
SRT_OUTPUT="$3"
ALLOW_TCP=22 \
ALLOW_UDP="${SRT_INGEST},${SRT_OUTPUT}" \
bash "${SCRIPT}"
REMOTE

# ---------------------------------------------------------------------------
echo "==> [6/7] Building and starting stack"
# ---------------------------------------------------------------------------
ssh_run bash -s -- "${DOCKER_DIR}" << 'REMOTE'
set -euo pipefail
cd "$1"
docker compose build --pull
docker compose up -d
REMOTE

# ---------------------------------------------------------------------------
echo "==> [7/7] Health check"
# ---------------------------------------------------------------------------
sleep 15
ssh_run bash -s -- "${VPS_IP}" << 'REMOTE'
set -euo pipefail
VPS_IP="$1"
fail=0

check() {
  local name="$1" url="$2" expected="$3"
  result=$(curl -sf --max-time 5 "${url}" 2>/dev/null || echo "FAIL")
  if echo "${result}" | grep -q "${expected}"; then
    echo "  ✓ ${name}"
  else
    echo "  ✗ ${name} — got: ${result:0:80}"
    fail=1
  fi
}

check "MistServer API"     "http://localhost:4242/api"          '"challenge"'
check "PocketBase"         "http://localhost:8090/api/health"   "healthy"
check "Prometheus"         "http://localhost:9090/-/healthy"    "Healthy"
check "Grafana"            "http://localhost:3000/api/health"   "ok"
check "nginx"              "http://localhost:${NGINX_PORT:-8888}/" ""

exit $fail
REMOTE

echo ""
echo "==> Deploy complete"
echo "    MistServer API : ssh -L 4242:localhost:4242 root@${VPS_IP}"
echo "    PocketBase     : ssh -L 8090:localhost:8090 root@${VPS_IP}"
echo "    Grafana        : ssh -L 3000:localhost:3000 root@${VPS_IP}"
echo "    HLS play       : https://play.castology.tv/live/{stream}/index.m3u8"
echo "    SRT ingest     : srt://${VPS_IP}:1235"
