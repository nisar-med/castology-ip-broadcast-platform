#!/usr/bin/env bash
# VPS kernel tuning for high-density SRT — 750 concurrent streams on a single UDP port.
# Idempotent — safe to re-run. Survives reboots.
set -euo pipefail

# ---------------------------------------------------------------------------
# Network buffer tuning
#
# 750 SRT streams × ~1 Mbps each = 750 Mbps aggregate. SRT holds up to
# latency_ms × bitrate bytes in each socket's receive buffer. At 1000 ms
# latency and 1 Mbps: 1000ms × 125000 B/s = 125 KB per stream.
# Ceiling: 750 × 125 KB = ~93 MB just for receive buffers.
#
# rmem_max / wmem_max cap what any single socket can allocate. MistServer
# uses large SRT latency buffers so we need at least 16 MB per socket.
# udp_mem (in pages) sets the system-wide UDP memory ceiling: 750 × 16 MB
# = 11.7 GB — but we let the kernel manage within available RAM so we set
# the ceiling to 75% of expected RAM (32 GB target VPS = 6 M pages ≈ 24 GB).
# On smaller VPS the kernel will apply memory pressure before hitting this.
# ---------------------------------------------------------------------------

cat > /etc/sysctl.d/99-cast-srt.conf << 'EOF'
# --- UDP / SRT socket buffers ---
# Max per-socket receive/send buffer (16 MB).
# SRT will request up to this for its latency buffer.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# Default per-socket receive/send buffer (2 MB).
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152

# UDP memory ceiling in pages (4 KB/page).
# min / pressure / max — let kernel manage; set max to ~24 GB equivalent.
net.ipv4.udp_mem = 524288 786432 6291456

# --- NIC ring buffer / packet backlog ---
# How many packets the kernel queues when a CPU is busy.
# Default 1000 is too low for 750 streams bursting simultaneously.
net.core.netdev_max_backlog = 16384

# --- TCP (for PocketBase auth, Prometheus, nginx) ---
# Larger TCP buffers improve throughput on auth calls under load.
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Recycle TIME_WAIT sockets faster — reduces socket exhaustion on reconnects.
net.ipv4.tcp_tw_reuse = 1

# Allow more simultaneous connections.
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192

# --- File descriptors / inotify (system-wide) ---
fs.file-max = 2097152
EOF

sysctl --system -q
echo "==> sysctl applied"

# ---------------------------------------------------------------------------
# Per-process file descriptor limits
#
# Each MistOutTSSRT process opens ~3 FDs (socket + pipe + log).
# 750 sessions × 3 = 2250 minimum. Pad to 65536.
# Set both soft and hard limit for root (MistServer runs as root).
# ---------------------------------------------------------------------------

cat > /etc/security/limits.d/99-cast-srt.conf << 'EOF'
# File descriptor limits for high-density SRT (750 streams)
root    soft    nofile    65536
root    hard    nofile    65536
*       soft    nofile    65536
*       hard    nofile    65536
EOF
echo "==> limits.d applied"

# ---------------------------------------------------------------------------
# systemd service overrides — ensures MistServer itself inherits high FD limit
# (pam_limits is not applied to systemd services by default)
# ---------------------------------------------------------------------------

mkdir -p /etc/systemd/system/mistserver.service.d
cat > /etc/systemd/system/mistserver.service.d/99-cast-srt-limits.conf << 'EOF'
[Service]
LimitNOFILE=65536
LimitNPROC=8192
EOF

systemctl daemon-reload
echo "==> systemd MistServer limits applied"
echo "==> VPS kernel tuning complete — effective immediately and on reboot"
