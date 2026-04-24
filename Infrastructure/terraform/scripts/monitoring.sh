#!/usr/bin/env bash
# Monitoring node — Prometheus + Grafana
# Scrapes MistServer metrics and TSduck exporter from the streaming server.
# Idempotent — safe to re-run.
set -euo pipefail

STREAMING_PRIVATE_IP="${STREAMING_PRIVATE_IP:?STREAMING_PRIVATE_IP must be set}"
PROMETHEUS_PASSPHRASE="${PROMETHEUS_PASSPHRASE:?PROMETHEUS_PASSPHRASE must be set}"
MIST_API_PORT="${MIST_API_PORT:-4242}"
EXPORTER_PORT="${EXPORTER_PORT:-9101}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD must be set}"

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing Prometheus"
apt-get update -qq
apt-get install -y -qq prometheus curl jq wget

echo "==> Installing Grafana"
wget -q -O /usr/share/keyrings/grafana.key https://apt.grafana.com/gpg.key
echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list
apt-get update -qq
apt-get install -y -qq grafana

# ---------------------------------------------------------------------------
# Prometheus config
# ---------------------------------------------------------------------------
echo "==> Configuring Prometheus"
cat > /etc/prometheus/prometheus.yml << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "mistserver"
    scrape_interval: 10s
    scrape_timeout: 10s
    metrics_path: "/${PROMETHEUS_PASSPHRASE}"
    static_configs:
      - targets: ["${STREAMING_PRIVATE_IP}:${MIST_API_PORT}"]
        labels:
          instance: "mist-streaming"

  - job_name: "mist-exporter"
    scrape_interval: 10s
    static_configs:
      - targets: ["${STREAMING_PRIVATE_IP}:${EXPORTER_PORT}"]
        labels:
          instance: "mist-streaming"
EOF

systemctl enable prometheus
systemctl restart prometheus
echo "==> Prometheus running"

# ---------------------------------------------------------------------------
# Grafana
# ---------------------------------------------------------------------------
systemctl enable grafana-server
systemctl start grafana-server

echo "==> Waiting for Grafana to start..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:3000/api/health > /dev/null 2>&1; then
    echo "==> Grafana is up"
    break
  fi
  sleep 2
done

# Set admin password
curl -sf -X PUT http://admin:admin@localhost:3000/api/user/password \
  -H "Content-Type: application/json" \
  -d "{\"oldPassword\":\"admin\",\"newPassword\":\"${GRAFANA_ADMIN_PASSWORD}\",\"confirmNew\":\"${GRAFANA_ADMIN_PASSWORD}\"}" \
  && echo "==> Grafana admin password set" || echo "==> Password already changed"

GRAFANA_AUTH="admin:${GRAFANA_ADMIN_PASSWORD}"

# Add Prometheus datasource
curl -sf -X POST "http://${GRAFANA_AUTH}@localhost:3000/api/datasources" \
  -H "Content-Type: application/json" \
  -d '{"name":"Prometheus","type":"prometheus","url":"http://localhost:9090","access":"proxy","isDefault":true}' \
  && echo "==> Prometheus datasource added" || echo "==> Datasource already exists"

# Import MistServer dashboards from Grafana Labs
for DASH_ID in 1096 4526 4529; do
  echo "==> Importing dashboard ${DASH_ID}..."
  DASH_JSON=$(curl -sf "https://grafana.com/api/dashboards/${DASH_ID}/revisions/latest/download")
  curl -sf -X POST "http://${GRAFANA_AUTH}@localhost:3000/api/dashboards/import" \
    -H "Content-Type: application/json" \
    -d "{\"dashboard\":${DASH_JSON},\"overwrite\":true,\"inputs\":[{\"name\":\"DS_PROMETHEUS\",\"type\":\"datasource\",\"pluginId\":\"prometheus\",\"value\":\"Prometheus\"}],\"folderId\":0}" \
    | jq -r '"Dashboard \(.title): \(.importedUrl)"' || echo "==> Dashboard ${DASH_ID} import failed"
done

# Import broadcast quality dashboard
curl -sf -X POST "http://${GRAFANA_AUTH}@localhost:3000/api/dashboards/import" \
  -H "Content-Type: application/json" \
  -d '{
    "dashboard": {
      "title": "MistServer Broadcast Quality",
      "uid": "mist-bq",
      "tags": ["mistserver","broadcast"],
      "timezone": "browser",
      "refresh": "10s",
      "schemaVersion": 36,
      "panels": [
        {"id":1,"type":"timeseries","title":"Stream Up/Down",
         "gridPos":{"x":0,"y":0,"w":12,"h":6},
         "targets":[{"expr":"mist_stream_up","legendFormat":"{{stream}}"}],
         "fieldConfig":{"defaults":{"min":0,"max":1,"thresholds":{"steps":[{"color":"red","value":0},{"color":"green","value":1}]}}}},
        {"id":2,"type":"timeseries","title":"Bitrate (kbits/s)",
         "gridPos":{"x":12,"y":0,"w":12,"h":6},
         "targets":[{"expr":"mist_stream_bitrate_kbits","legendFormat":"{{stream}} {{track}}"}]},
        {"id":3,"type":"timeseries","title":"Stream FPS",
         "gridPos":{"x":0,"y":6,"w":12,"h":8},
         "targets":[{"expr":"mist_stream_fps","legendFormat":"{{stream}}"}]},
        {"id":4,"type":"timeseries","title":"Stream Jitter (ms)",
         "gridPos":{"x":12,"y":6,"w":12,"h":8},
         "targets":[{"expr":"mist_stream_jitter_ms","legendFormat":"{{stream}}"}],
         "fieldConfig":{"defaults":{"thresholds":{"steps":[{"color":"green","value":0},{"color":"yellow","value":50},{"color":"red","value":200}]}}}},
        {"id":5,"type":"stat","title":"Active Operator Sessions",
         "gridPos":{"x":0,"y":14,"w":6,"h":4},
         "targets":[{"expr":"sum by (stream) (mist_operator_sessions_total{direction=\"output\"})","legendFormat":"{{stream}}"}],
         "fieldConfig":{"defaults":{"thresholds":{"steps":[{"color":"green","value":0}]}}}},
        {"id":6,"type":"stat","title":"SRT Packet Loss %",
         "gridPos":{"x":6,"y":14,"w":6,"h":4},
         "targets":[{"expr":"rate(mist_packets{pkttype=\"lost\"}[5m])/rate(mist_packets{pkttype=\"sent\"}[5m])*100","legendFormat":"{{stream}} loss%"}],
         "fieldConfig":{"defaults":{"unit":"percent","thresholds":{"steps":[{"color":"green","value":0},{"color":"yellow","value":0.5},{"color":"red","value":2}]}}}},
        {"id":7,"type":"stat","title":"Active Viewer Sessions",
         "gridPos":{"x":12,"y":14,"w":6,"h":4},
         "targets":[{"expr":"mist_sessions_total{sessType=\"outgoing\"}","legendFormat":"outgoing"}]},
        {"id":8,"type":"stat","title":"Active Ingest Sessions",
         "gridPos":{"x":18,"y":14,"w":6,"h":4},
         "targets":[{"expr":"mist_sessions_total{sessType=\"incoming\"}","legendFormat":"incoming"}]}
      ]
    },
    "overwrite": true,
    "folderId": 0
  }' | jq -r '"Broadcast Quality dashboard: \(.importedUrl)"' \
  || echo "==> Broadcast quality dashboard import failed"

echo "==> Monitoring server setup complete"
echo "==> Grafana: http://$(curl -sf https://ipinfo.io/ip):3000"
