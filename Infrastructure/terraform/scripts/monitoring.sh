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
PROMETHEUS_SCRAPE_HOST="${PROMETHEUS_SCRAPE_HOST:-localhost}"

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
      - targets: ["${PROMETHEUS_SCRAPE_HOST}:${MIST_API_PORT}"]
        labels:
          instance: "mist-streaming"

  - job_name: "mist-exporter"
    scrape_interval: 10s
    static_configs:
      - targets: ["${PROMETHEUS_SCRAPE_HOST}:${EXPORTER_PORT}"]
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

# Narrow the imported MistServer Vitals server filter to actual Mist targets.
VITALS_FILE=$(mktemp)
if curl -sf "http://${GRAFANA_AUTH}@localhost:3000/api/dashboards/uid/000000009" > "${VITALS_FILE}"; then
  python3 - "${VITALS_FILE}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text())
dashboard = payload["dashboard"]
for var in dashboard.get("templating", {}).get("list", []):
    if var.get("name") == "srv":
        var["query"] = "label_values(mist_cpu{job=\"mistserver\"}, instance)"
        var["definition"] = var["query"]
        var["current"] = {"selected": False, "text": "mist-streaming", "value": "mist-streaming"}
        break
path.write_text(json.dumps({"dashboard": dashboard, "overwrite": True, "folderId": 0}))
PY

  curl -sf -X POST "http://${GRAFANA_AUTH}@localhost:3000/api/dashboards/db" \
    -H "Content-Type: application/json" \
    -d @"${VITALS_FILE}" \
    | jq -r '"Vitals dashboard: \(.url)"' \
    || echo "==> MistServer Vitals patch failed"
else
  echo "==> MistServer Vitals dashboard fetch failed"
fi
rm -f "${VITALS_FILE}"

# Import broadcast quality dashboard
# Look up the actual datasource UID assigned by Grafana at install time
DS_UID=$(curl -sf "http://${GRAFANA_AUTH}@localhost:3000/api/datasources/name/Prometheus" | python3 -c 'import sys,json; print(json.load(sys.stdin)["uid"])')
echo "==> Prometheus datasource UID: ${DS_UID}"

# Build dashboard JSON in a temp file to avoid shell escaping issues with HERE-doc
DASH_FILE=$(mktemp)
cat > "${DASH_FILE}" << DASHEOF
{
  "dashboard": {
    "title": "MistServer Session Status",
    "uid": "mist-bq",
    "tags": ["mistserver", "broadcast"],
    "timezone": "browser",
    "refresh": "10s",
    "schemaVersion": 36,
    "templating": {"list": [
      {"name": "stream", "label": "Stream", "type": "query",
       "datasource": {"type": "prometheus", "uid": "${DS_UID}"},
       "query": {"query": "label_values(mist_ingest_status{job=\"mist-exporter\"}, stream)", "refId": "A"},
       "includeAll": true, "multi": true,
       "current": {"text": "All", "value": "\$__all"}, "refresh": 2, "sort": 1}
    ]},
    "panels": [
      {
        "id": 1, "type": "table", "title": "Broadcaster Feeds (Primary / Backup)",
        "gridPos": {"x": 0, "y": 0, "w": 24, "h": 8},
        "options": {"sortBy": [{"displayName": "Name", "desc": false}]},
        "targets": [
          {
            "refId": "A",
            "expr": "mist_broadcaster_feed_status{job=\"mist-exporter\", stream=~\"\$stream\"}",
            "instant": true, "format": "table", "legendFormat": "",
            "datasource": {"type": "prometheus", "uid": "${DS_UID}"}
          },
          {
            "refId": "B",
            "expr": "mist_broadcaster_feed_jitter_ms{job=\"mist-exporter\", stream=~\"\$stream\"}",
            "instant": true, "format": "table", "legendFormat": "",
            "datasource": {"type": "prometheus", "uid": "${DS_UID}"}
          },
          {
            "refId": "C",
            "expr": "mist_broadcaster_feed_loss{job=\"mist-exporter\", stream=~\"\$stream\"}",
            "instant": true, "format": "table", "legendFormat": "",
            "datasource": {"type": "prometheus", "uid": "${DS_UID}"}
          }
        ],
        "transformations": [
          {"id": "filterFieldsByName", "options": {"include": {"pattern": "^(name|stream|feed_role|ip|Value.*)$"}}},
          {"id": "merge", "options": {}},
          {"id": "organize", "options": {
            "includeByName": {"name": true, "stream": true, "feed_role": true, "ip": true, "Value #A": true, "Value #B": true, "Value #C": true},
            "indexByName": {"name": 0, "stream": 1, "feed_role": 2, "ip": 3, "Value #A": 4, "Value #B": 5, "Value #C": 6},
            "renameByName": {"name": "Name", "stream": "Stream", "feed_role": "Feed Role", "ip": "IP", "Value #A": "Status", "Value #B": "Jitter (ms)", "Value #C": "Loss"}
          }}
        ],
        "fieldConfig": {"defaults": {"custom": {"filterable": true}}, "overrides": [
          {"matcher": {"id": "byName", "options": "Status"}, "properties": [
            {"id": "custom.displayMode", "value": "color-background"},
            {"id": "mappings", "value": [{"type": "value", "options": {"0": {"text": "OFFLINE", "color": "red"}, "1": {"text": "ONLINE", "color": "green"}}}]},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "red", "value": 0}, {"color": "green", "value": 1}]}}
          ]},
          {"matcher": {"id": "byName", "options": "Loss"}, "properties": [
            {"id": "unit", "value": "percentunit"},
            {"id": "custom.displayMode", "value": "color-background"},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "green", "value": 0}, {"color": "yellow", "value": 0.005}, {"color": "red", "value": 0.02}]}}
          ]},
          {"matcher": {"id": "byName", "options": "Jitter (ms)"}, "properties": [
            {"id": "unit", "value": "ms"},
            {"id": "custom.displayMode", "value": "color-background"},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "green", "value": 0}, {"color": "yellow", "value": 50}, {"color": "red", "value": 200}]}}
          ]}
        ]}
      },
      {
        "id": 2, "type": "table", "title": "Affiliate Clients",
        "gridPos": {"x": 0, "y": 8, "w": 24, "h": 8},
        "options": {"sortBy": [{"displayName": "Affiliate", "desc": false}]},
        "targets": [
          {
            "refId": "A",
            "expr": "mist_affiliate_client_status{job=\"mist-exporter\", stream=~\"\$stream\"}",
            "instant": true, "format": "table", "legendFormat": "",
            "datasource": {"type": "prometheus", "uid": "${DS_UID}"}
          },
          {
            "refId": "B",
            "expr": "mist_affiliate_client_loss{job=\"mist-exporter\", stream=~\"\$stream\"}",
            "instant": true, "format": "table", "legendFormat": "",
            "datasource": {"type": "prometheus", "uid": "${DS_UID}"}
          },
          {
            "refId": "C",
            "expr": "mist_affiliate_client_uptime_seconds{job=\"mist-exporter\", stream=~\"\$stream\"}",
            "instant": true, "format": "table", "legendFormat": "",
            "datasource": {"type": "prometheus", "uid": "${DS_UID}"}
          },
          {
            "refId": "D",
            "expr": "mist_affiliate_client_bytes{job=\"mist-exporter\", stream=~\"\$stream\"}",
            "instant": true, "format": "table", "legendFormat": "",
            "datasource": {"type": "prometheus", "uid": "${DS_UID}"}
          }
        ],
        "transformations": [
          {"id": "filterFieldsByName", "options": {"include": {"pattern": "^(name|client_name|endpoint_role|stream|ip|Value.*)$"}}},
          {"id": "merge", "options": {}},
          {"id": "organize", "options": {
            "includeByName": {"name": true, "client_name": true, "endpoint_role": true, "stream": true, "ip": true, "Value #A": true, "Value #B": true, "Value #C": true, "Value #D": true},
            "indexByName": {"name": 0, "client_name": 1, "endpoint_role": 2, "stream": 3, "ip": 4, "Value #A": 5, "Value #B": 6, "Value #C": 7, "Value #D": 8},
            "renameByName": {"name": "Affiliate", "client_name": "Client", "endpoint_role": "Role", "stream": "Stream", "ip": "IP", "Value #A": "Status", "Value #B": "Loss", "Value #C": "Uptime", "Value #D": "Bytes"}
          }}
        ],
        "fieldConfig": {"defaults": {"custom": {"filterable": true}}, "overrides": [
          {"matcher": {"id": "byName", "options": "Status"}, "properties": [
            {"id": "custom.displayMode", "value": "color-background"},
            {"id": "mappings", "value": [{"type": "value", "options": {"0": {"text": "OFFLINE", "color": "red"}, "1": {"text": "ONLINE", "color": "green"}}}]},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "red", "value": 0}, {"color": "green", "value": 1}]}}
          ]},
          {"matcher": {"id": "byName", "options": "Loss"}, "properties": [
            {"id": "unit", "value": "percentunit"},
            {"id": "custom.displayMode", "value": "color-background"},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "green", "value": 0}, {"color": "yellow", "value": 0.005}, {"color": "red", "value": 0.02}]}}
          ]},
          {"matcher": {"id": "byName", "options": "Uptime"}, "properties": [{"id": "unit", "value": "s"}]},
          {"matcher": {"id": "byName", "options": "Bytes"}, "properties": [{"id": "unit", "value": "bytes"}]}
        ]}
      }
    ]
  },
  "overwrite": true,
  "folderId": 0
}
DASHEOF

curl -sf -X POST "http://${GRAFANA_AUTH}@localhost:3000/api/dashboards/import" \
  -H "Content-Type: application/json" \
  -d @"${DASH_FILE}" \
  | jq -r '"Session status dashboard: \(.importedUrl)"' \
  || echo "==> Session status dashboard import failed"
rm -f "${DASH_FILE}"

echo "==> Monitoring server setup complete"
echo "==> Grafana: http://$(curl -sf https://ipinfo.io/ip):3000"
