#!/usr/bin/env bash
# Host VPS setup — run once before docker compose up.
# Applies kernel tuning for 750 concurrent SRT streams.
# Idempotent — safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

read_env_var() {
  local key="$1"
  if [ ! -f "${ENV_FILE}" ]; then
    return 0
  fi
  grep -E "^${key}=" "${ENV_FILE}" | cut -d= -f2- | tr -d '[:space:]' || true
}

configure_tailscale() {
  local enabled auth_key hostname ssh_enabled advertise_tags distro

  enabled="$(read_env_var TAILSCALE_ENABLED)"
  enabled="${enabled,,}"
  if [ "${enabled}" != "true" ]; then
    return 0
  fi

  auth_key="$(read_env_var TAILSCALE_AUTH_KEY)"
  hostname="$(read_env_var TAILSCALE_HOSTNAME)"
  ssh_enabled="$(read_env_var TAILSCALE_SSH)"
  advertise_tags="$(read_env_var TAILSCALE_ADVERTISE_TAGS)"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl

  distro="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  install -m 0755 -d /usr/share/keyrings
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${distro}.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${distro}.tailscale-keyring.list" \
    -o /etc/apt/sources.list.d/tailscale.list

  apt-get update -qq
  apt-get install -y -qq tailscale
  systemctl enable --now tailscaled

  up_args=()
  if [ -n "${hostname}" ]; then
    up_args+=("--hostname=${hostname}")
  fi
  if [ "${ssh_enabled,,}" = "true" ]; then
    up_args+=("--ssh")
  fi
  if [ -n "${advertise_tags}" ]; then
    up_args+=("--advertise-tags=${advertise_tags}")
  fi

  if tailscale ip -4 >/dev/null 2>&1; then
    tailscale up "${up_args[@]}"
  else
    if [ -z "${auth_key}" ]; then
      echo "ERROR: TAILSCALE_ENABLED=true but TAILSCALE_AUTH_KEY is empty and the node is not enrolled yet." >&2
      exit 1
    fi
    tailscale up --auth-key="${auth_key}" "${up_args[@]}"
  fi

  echo "==> Tailscale ready: $(tailscale ip -4 | head -n1)"
}

# ---------------------------------------------------------------------------
# Kernel / sysctl tuning
#
# 750 SRT streams × ~1 Mbps = 750 Mbps aggregate. SRT holds up to
# latency_ms × bitrate bytes per socket. At 1000 ms latency, 1 Mbps:
# 125 KB per stream → 750 × 125 KB = ~93 MB just for receive buffers.
# rmem_max / wmem_max: 16 MB per socket (SRT latency buffer ceiling).
# udp_mem max: ~24 GB equivalent (kernel manages pressure below this).
# ---------------------------------------------------------------------------
cat > /etc/sysctl.d/99-cast-srt.conf << 'EOF'
# UDP / SRT socket buffers
net.core.rmem_max        = 16777216
net.core.wmem_max        = 16777216
net.core.rmem_default    = 4194304
net.core.wmem_default    = 4194304
net.ipv4.udp_mem         = 524288 786432 6291456

# NIC packet backlog — default 1000 is too low for 750 simultaneous streams
net.core.netdev_max_backlog = 16384

# TCP (PocketBase auth, Prometheus, nginx)
net.core.optmem_max           = 65536
net.ipv4.tcp_rmem             = 4096 87380 16777216
net.ipv4.tcp_wmem             = 4096 65536 16777216
net.ipv4.tcp_tw_reuse         = 1
net.core.somaxconn            = 8192
net.ipv4.tcp_max_syn_backlog  = 8192

# File descriptors
fs.file-max = 2097152
EOF

sysctl --system -q
echo "==> sysctl applied"

# ---------------------------------------------------------------------------
# File descriptor limits
# Docker container ulimits handle MistServer itself (set in compose.yml).
# These limits cover the Docker daemon and any host processes.
# ---------------------------------------------------------------------------
cat > /etc/security/limits.d/99-cast-srt.conf << 'EOF'
root  soft  nofile  65536
root  hard  nofile  65536
*     soft  nofile  65536
*     hard  nofile  65536
EOF
echo "==> limits.d applied"

# ---------------------------------------------------------------------------
# Docker daemon — raise default ulimits so all containers inherit them
# ---------------------------------------------------------------------------
mkdir -p /etc/docker
if [ -f /etc/docker/daemon.json ]; then
  python3 -c "
import json
with open('/etc/docker/daemon.json') as f:
    d = json.load(f)
d['default-ulimits'] = {'nofile': {'Name': 'nofile', 'Hard': 65536, 'Soft': 65536}}
with open('/etc/docker/daemon.json', 'w') as f:
    json.dump(d, f, indent=2)
print('Updated daemon.json')
"
else
  cat > /etc/docker/daemon.json << 'EOF'
{
  "default-ulimits": {
    "nofile": {"Name": "nofile", "Hard": 65536, "Soft": 65536}
  }
}
EOF
  echo "==> Created daemon.json"
fi

# ---------------------------------------------------------------------------
# /dev/shm — resize to 11092 MB for MistServer shared memory (~95% of 11.7GB RAM)
# ---------------------------------------------------------------------------
if ! grep -q 'tmpfs /dev/shm' /etc/fstab; then
  echo "tmpfs /dev/shm tmpfs defaults,size=11092M 0 0" >> /etc/fstab
  echo "==> /etc/fstab updated"
fi
mount -o remount,size=11092M /dev/shm 2>/dev/null && echo "==> /dev/shm remounted at 11092M" || true

configure_tailscale

echo "==> Host setup complete — reboot recommended for all limits to take full effect"
echo "    Then: docker compose up -d"
