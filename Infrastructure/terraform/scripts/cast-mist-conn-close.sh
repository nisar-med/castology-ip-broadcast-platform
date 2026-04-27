#!/usr/bin/env bash
# MistServer CONN_CLOSE trigger — fires when a session ends.
# Deletes from active_sessions, appends disconnected event to session_audit.
# Response is ignored by MistServer (sync: false).

PB_URL="${PB_URL:-http://127.0.0.1:8090}"
PB_EMAIL="${PB_EMAIL:-admin@castology.tv}"
[[ -f /etc/cast-mist-stream-auth.env ]] && source /etc/cast-mist-stream-auth.env
PB_PASS="${PB_PASS:-}"
VPS_ID="${VPS_ID:-$(hostname)}"

IFS= read -r stream
IFS= read -r client_ip
IFS= read -r connector
IFS= read -r request_url

client_ip=$(echo "$client_ip" | sed 's/\[//g; s/\]//g; s/::ffff://g; s/:[0-9]*$//')

if [[ "$client_ip" == "127.0.0.1" || "$client_ip" == "::1" ]]; then
    exit 0
fi
if [[ "$connector" != "TSSRT" && "$connector" != "HLS" ]]; then
    exit 0
fi

sname="${stream%%/*}"

pb_token=$(curl -sf -X POST "$PB_URL/api/collections/_superusers/auth-with-password" \
    -H "Content-Type: application/json" \
    -d "{\"identity\":\"$PB_EMAIL\",\"password\":\"$PB_PASS\"}" \
    | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

[[ -z "$pb_token" ]] && exit 0

now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Look up the active_sessions record to get affiliate+client_name+connected_at
filter=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
    "stream=\"$sname\" && ip=\"$client_ip\" && vps=\"$VPS_ID\"")
session_json=$(curl -sf \
    "$PB_URL/api/collections/active_sessions/records?filter=$filter&perPage=1" \
    -H "Authorization: Bearer $pb_token")

session_id=$(echo "$session_json"   | grep -o '"id":"[^"]*"'           | head -1 | cut -d'"' -f4)
affiliate=$(echo "$session_json"    | grep -o '"affiliate":"[^"]*"'    | head -1 | cut -d'"' -f4)
client_name=$(echo "$session_json"  | grep -o '"client_name":"[^"]*"'  | head -1 | cut -d'"' -f4)
token=$(echo "$session_json"        | grep -o '"token":"[^"]*"'        | head -1 | cut -d'"' -f4)
connected_at=$(echo "$session_json" | grep -o '"connected_at":"[^"]*"' | head -1 | cut -d'"' -f4)

# If no active_sessions record exists this was a denied connection — skip audit
[[ -z "$session_id" ]] && exit 0

# Compute duration
duration_seconds=0
if [[ -n "$connected_at" ]]; then
    connected_ts=$(date -d "$connected_at" +%s 2>/dev/null || echo 0)
    now_ts=$(date -u +%s)
    duration_seconds=$(( now_ts - connected_ts ))
fi

# Delete from active_sessions
curl -sf -X DELETE \
    "$PB_URL/api/collections/active_sessions/records/$session_id" \
    -H "Authorization: Bearer $pb_token" > /dev/null

# Append session_audit disconnected event
curl -sf -X POST "$PB_URL/api/collections/session_audit/records" \
    -H "Authorization: Bearer $pb_token" \
    -H "Content-Type: application/json" \
    -d "{\"stream\":\"$sname\",\"ip\":\"$client_ip\",\"connector\":\"$connector\",\
\"affiliate\":\"${affiliate:-unknown}\",\"client_name\":\"${client_name:-unknown}\",\
\"token\":\"$token\",\"event\":\"disconnected\",\"duration_seconds\":$duration_seconds,\
\"vps\":\"$VPS_ID\",\"event_at\":\"$now\"}" > /dev/null

exit 0
