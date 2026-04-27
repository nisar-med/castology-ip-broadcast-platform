#!/usr/bin/env bash
# nginx — unified parameterised installer for all Castology sites.
#
# Control which sites are enabled via NGINX_SITES (comma-separated):
#   play        → play.castology.tv       → MistServer HLS :8080
#   mist        → mist.castology.tv       → MistServer API :4242
#   monitoring  → monitoring.castology.tv → Grafana :3000
#   onboard     → onboard.castology.tv    → PocketBase :8090 + static portal
#
# Example:
#   NGINX_SITES="play,mist,monitoring,onboard" bash nginx.sh   # single VPS
#   NGINX_SITES="play,mist"                    bash nginx.sh   # streaming VPS
#   NGINX_SITES="monitoring,onboard"           bash nginx.sh   # monitoring VPS
#
# Idempotent — safe to re-run.
set -euo pipefail

NGINX_SITES="${NGINX_SITES:?NGINX_SITES must be set (comma-separated: play,mist,monitoring,onboard)}"

export DEBIAN_FRONTEND=noninteractive

ensure_castology_governance() {
  mkdir -p /etc/systemd/system

  cat > /etc/systemd/system/castology-platform.target <<'EOF'
[Unit]
Description=Castology platform services
Wants=castology-streaming.target castology-origin.target castology-monitoring.target
After=castology-streaming.target castology-origin.target castology-monitoring.target

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/castology-streaming.target <<'EOF'
[Unit]
Description=Castology streaming services
PartOf=castology-platform.target
EOF

  cat > /etc/systemd/system/castology-origin.target <<'EOF'
[Unit]
Description=Castology origin services
PartOf=castology-platform.target
EOF

  cat > /etc/systemd/system/castology-monitoring.target <<'EOF'
[Unit]
Description=Castology monitoring services
PartOf=castology-platform.target
EOF

  cat > /etc/systemd/system/castology.slice <<'EOF'
[Unit]
Description=Castology platform slice
Before=slices.target

[Slice]
CPUAccounting=true
MemoryAccounting=true
TasksAccounting=true
EOF
}

register_castology_service() {
  local unit="$1"
  local target="$2"
  mkdir -p "/etc/systemd/system/${unit}.d"
  cat > "/etc/systemd/system/${unit}.d/castology.conf" <<EOF
[Unit]
PartOf=${target}.target

[Service]
Slice=castology.slice
EOF
}

echo "==> Installing nginx"
apt-get update -qq
apt-get install -y -qq nginx

# ---------------------------------------------------------------------------
# Global nginx tuning for 750 concurrent HLS clients
#
# HLS polling pattern: each client requests index.m3u8 every 6 s plus one
# segment fetch per interval → ~250 req/s steady state, spikes to ~1000/s.
# worker_processes auto uses one worker per CPU core.
# worker_connections 4096 per worker gives headroom well above 750 clients.
# multi_accept on: accept all pending connections per event rather than one.
# keepalive_timeout 15s: HLS clients don't benefit from long-lived connections
#   and holding 750 × 75s (default) ties up workers unnecessarily.
# ---------------------------------------------------------------------------
cat > /etc/nginx/nginx.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   15;
    keepalive_requests  100;
    types_hash_max_size 2048;
    server_tokens       off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;

    gzip off;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Helper: check if a site name is in NGINX_SITES
site_enabled() {
  echo "$NGINX_SITES" | tr ',' '\n' | grep -qx "$1"
}

# ---------------------------------------------------------------------------
# Site: play.castology.tv → MistServer HLS/HTTP :8080
# ---------------------------------------------------------------------------
if site_enabled "play"; then
  echo "==> Configuring play.castology.tv"
  cat > /etc/nginx/sites-available/play.castology.tv << 'EOF'
# Upstream pool — keepalive reuses connections to MistServer's HTTP listener.
# 64 idle keepalive connections covers bursts without opening a new TCP
# connection per HLS segment fetch.
upstream mist_hls {
    server 127.0.0.1:8080;
    keepalive 64;
}

server {
    listen 80 backlog=8192;
    server_name play.castology.tv;

    real_ip_header    CF-Connecting-IP;
    set_real_ip_from  0.0.0.0/0;

    proxy_buffering         off;
    proxy_request_buffering off;

    location / {
        proxy_pass         http://mist_hls;
        proxy_http_version 1.1;
        proxy_set_header   Connection        "";
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;

        proxy_read_timeout    30s;
        proxy_send_timeout    30s;
        proxy_connect_timeout 5s;

        add_header Access-Control-Allow-Origin  * always;
        add_header Access-Control-Allow-Methods "GET, OPTIONS" always;
        add_header Access-Control-Allow-Headers "*" always;

        if ($request_method = OPTIONS) {
            return 204;
        }
    }
}
EOF
  ln -sf /etc/nginx/sites-available/play.castology.tv \
         /etc/nginx/sites-enabled/play.castology.tv
fi

# mist.castology.tv intentionally not exposed — access via SSH tunnel:
#   ssh -L 4242:localhost:4242 root@<vps-ip>

# ---------------------------------------------------------------------------
# Site: stream.castology.tv → MistServer HLS :8080 (Worker origin, /hls/ only)
# Grey-clouded DNS — not proxied through Cloudflare.
# Only /hls/ is exposed; all other paths return 404.
# ---------------------------------------------------------------------------
if site_enabled "stream"; then
  echo "==> Configuring stream.castology.tv"
  cat > /etc/nginx/sites-available/stream.castology.tv << 'EOF'
server {
    listen 80;
    server_name stream.castology.tv;

    location /hls/ {
        proxy_pass         http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;

        proxy_read_timeout    30s;
        proxy_connect_timeout 5s;

        add_header Access-Control-Allow-Origin * always;
    }

    location / {
        return 404;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/stream.castology.tv \
         /etc/nginx/sites-enabled/stream.castology.tv
fi

# ---------------------------------------------------------------------------
# Site: monitoring.castology.tv → Grafana :3000
# ---------------------------------------------------------------------------
if site_enabled "monitoring"; then
  echo "==> Configuring monitoring.castology.tv"
  cat > /etc/nginx/sites-available/monitoring.castology.tv << 'EOF'
server {
    listen 80;
    server_name monitoring.castology.tv;

    real_ip_header    CF-Connecting-IP;
    set_real_ip_from  0.0.0.0/0;

    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_set_header   Upgrade           $http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_read_timeout 3600s;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/monitoring.castology.tv \
         /etc/nginx/sites-enabled/monitoring.castology.tv
fi

# ---------------------------------------------------------------------------
# Site: onboard.castology.tv → PocketBase :8090 + static operator portal
# ---------------------------------------------------------------------------
if site_enabled "onboard"; then
  echo "==> Configuring onboard.castology.tv"
  cat > /etc/nginx/sites-available/onboard.castology.tv << 'EOF'
server {
    listen 80;
    server_name onboard.castology.tv;

    real_ip_header    CF-Connecting-IP;
    set_real_ip_from  0.0.0.0/0;

    root  /var/www/onboard;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass         http://127.0.0.1:8090/api/;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_set_header   Upgrade           $http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }

    # PocketBase admin UI intentionally not exposed — access via SSH tunnel:
    #   ssh -L 8090:localhost:8090 root@<vps-ip>
    location /_/ { return 404; }
}
EOF
  ln -sf /etc/nginx/sites-available/onboard.castology.tv \
         /etc/nginx/sites-enabled/onboard.castology.tv
fi

# ---------------------------------------------------------------------------
# Finalise
# ---------------------------------------------------------------------------
rm -f /etc/nginx/sites-enabled/default

nginx -t
ensure_castology_governance
register_castology_service "nginx.service" "castology-origin"
systemctl daemon-reload
systemctl enable castology-platform.target
systemctl add-wants castology-origin.target nginx.service
systemctl enable nginx
systemctl restart nginx
echo "==> nginx configured (sites: ${NGINX_SITES})"
