#!/usr/bin/env bash
# ufw firewall — configures ufw rules from environment variables.
# Idempotent — safe to re-run.
set -euo pipefail

# Comma-separated port lists / CIDR-restricted maps passed as env vars:
#   ALLOW_TCP          = "22,80"
#   ALLOW_UDP          = "1236,1238"
#   ALLOW_TCP_FROM     = "4242:1.2.3.4/32,9101:1.2.3.4/32"   (port:cidr pairs)
#   ALLOW_UDP_FROM     = "1235:1.2.3.4/32"

ALLOW_TCP="${ALLOW_TCP:-}"
ALLOW_UDP="${ALLOW_UDP:-}"
ALLOW_TCP_FROM="${ALLOW_TCP_FROM:-}"
ALLOW_UDP_FROM="${ALLOW_UDP_FROM:-}"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq ufw

ufw allow 22/tcp comment "SSH"

# TCP open to all (port 80 is handled separately via Cloudflare IP allowlist)
if [ -n "$ALLOW_TCP" ]; then
  IFS=',' read -ra PORTS <<< "$ALLOW_TCP"
  for port in "${PORTS[@]}"; do
    [ "$port" = "22" ] && continue   # already added
    [ "$port" = "80" ] && continue   # handled below via CF IP allowlist
    echo "==> Allow TCP $port"
    case "$port" in
      443)  comment="HTTPS" ;;
      *)    comment="TCP $port" ;;
    esac
    ufw allow "${port}/tcp" comment "$comment"
  done
fi

# Port 80 restricted to Cloudflare edge IPs only (origin lockdown)
CF_IPS_V4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
CF_IPS_V6="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
for cidr in $CF_IPS_V4 $CF_IPS_V6; do
  ufw allow proto tcp from "$cidr" to any port 80 comment "HTTP Cloudflare"
done

# UDP open to all
if [ -n "$ALLOW_UDP" ]; then
  IFS=',' read -ra PORTS <<< "$ALLOW_UDP"
  for port in "${PORTS[@]}"; do
    echo "==> Allow UDP $port"
    case "$port" in
      1235) comment="SRT ingest" ;;
      *)    comment="UDP $port" ;;
    esac
    ufw allow "${port}/udp" comment "$comment"
  done
fi

# TCP restricted to source CIDRs (format: port:cidr,port:cidr)
if [ -n "$ALLOW_TCP_FROM" ]; then
  IFS=',' read -ra RULES <<< "$ALLOW_TCP_FROM"
  for rule in "${RULES[@]}"; do
    port="${rule%%:*}"
    cidr="${rule#*:}"
    echo "==> Allow TCP $port from $cidr"
    case "$port" in
      4242) comment="MistServer API" ;;
      9101) comment="TSduck Prometheus exporter" ;;
      3000) comment="Grafana" ;;
      9090) comment="Prometheus" ;;
      8090) comment="PocketBase" ;;
      *)    comment="TCP $port restricted" ;;
    esac
    ufw allow from "$cidr" to any port "$port" proto tcp comment "$comment"
  done
fi

# UDP restricted to source CIDRs (format: port:cidr,port:cidr)
if [ -n "$ALLOW_UDP_FROM" ]; then
  IFS=',' read -ra RULES <<< "$ALLOW_UDP_FROM"
  for rule in "${RULES[@]}"; do
    port="${rule%%:*}"
    cidr="${rule#*:}"
    echo "==> Allow UDP $port from $cidr"
    case "$port" in
      1235) comment="SRT ingest" ;;
      *)    comment="UDP $port restricted" ;;
    esac
    ufw allow from "$cidr" to any port "$port" proto udp comment "$comment"
  done
fi

ufw --force enable
ufw status verbose
echo "==> Firewall configured"
