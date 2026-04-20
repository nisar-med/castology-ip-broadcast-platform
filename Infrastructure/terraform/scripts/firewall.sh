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

# TCP open to all
if [ -n "$ALLOW_TCP" ]; then
  IFS=',' read -ra PORTS <<< "$ALLOW_TCP"
  for port in "${PORTS[@]}"; do
    [ "$port" = "22" ] && continue   # already added
    echo "==> Allow TCP $port"
    case "$port" in
      80)   comment="HTTP (nginx — Cloudflare proxy)" ;;
      443)  comment="HTTPS" ;;
      *)    comment="TCP $port" ;;
    esac
    ufw allow "${port}/tcp" comment "$comment"
  done
fi

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
