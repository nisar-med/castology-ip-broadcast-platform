#!/usr/bin/env bash
# MistServer CONN_PLAY trigger — fires after PLAY_REWRITE succeeds.
# Writes to PocketBase active_sessions and session_audit (async, non-blocking).
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

# Only track SRT and HLS output sessions — skip loopback and unknown connectors
if [[ "$client_ip" == "127.0.0.1" || "$client_ip" == "::1" ]]; then
    exit 0
fi
if [[ "$connector" != "TSSRT" && "$connector" != "HLS" ]]; then
    exit 0
fi

# Extract token from request_url (same logic as cast-mist-stream-auth.sh)
if [[ "$connector" == "TSSRT" ]]; then
    sname="${stream%%/*}"
    token="${stream#*/}"
    [[ "$token" == "$stream" ]] && token=""
elif [[ "$connector" == "HLS" ]]; then
    sname="$stream"
    token=$(echo "$request_url" | grep -o 'token=[^&]*' | cut -d= -f2)
fi

# Authenticate with PocketBase
pb_token=$(curl -sf -X POST "$PB_URL/api/collections/_superusers/auth-with-password" \
    -H "Content-Type: application/json" \
    -d "{\"identity\":\"$PB_EMAIL\",\"password\":\"$PB_PASS\"}" \
    | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

[[ -z "$pb_token" ]] && exit 0

# Resolve affiliate + client_name from token
if [[ -n "$token" ]]; then
    filter=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
        "token_key=\"$token\" && active=true")
    affiliate_json=$(curl -sf "$PB_URL/api/collections/affiliates/records?filter=$filter&perPage=1" \
        -H "Authorization: Bearer $pb_token")
    affiliate=$(echo "$affiliate_json" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -n "$affiliate" ]]; then
        client_filter=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
            "affiliate_name=\"$affiliate\" && stream=\"$sname\" && active=true")
        client_json=$(curl -sf "$PB_URL/api/collections/affiliate_clients/records?filter=$client_filter&perPage=1" \
            -H "Authorization: Bearer $pb_token")
        client_name=$(echo "$client_json" | grep -o '"client_name":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi
fi

affiliate="${affiliate:-unknown}"
client_name="${client_name:-unknown}"
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Upsert active_sessions — delete existing record for this stream+ip+vps then insert fresh
existing_id=$(curl -sf "$PB_URL/api/collections/active_sessions/records?filter=$(python3 -c \
    "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
    "stream=\"$sname\" && ip=\"$client_ip\" && vps=\"$VPS_ID\"")&perPage=1" \
    -H "Authorization: Bearer $pb_token" \
    | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

[[ -n "$existing_id" ]] && curl -sf -X DELETE \
    "$PB_URL/api/collections/active_sessions/records/$existing_id" \
    -H "Authorization: Bearer $pb_token" > /dev/null

curl -sf -X POST "$PB_URL/api/collections/active_sessions/records" \
    -H "Authorization: Bearer $pb_token" \
    -H "Content-Type: application/json" \
    -d "{\"stream\":\"$sname\",\"ip\":\"$client_ip\",\"connector\":\"$connector\",\
\"affiliate\":\"$affiliate\",\"client_name\":\"$client_name\",\
\"token\":\"$token\",\"vps\":\"$VPS_ID\",\"connected_at\":\"$now\"}" > /dev/null

# Append session_audit connected event
curl -sf -X POST "$PB_URL/api/collections/session_audit/records" \
    -H "Authorization: Bearer $pb_token" \
    -H "Content-Type: application/json" \
    -d "{\"stream\":\"$sname\",\"ip\":\"$client_ip\",\"connector\":\"$connector\",\
\"affiliate\":\"$affiliate\",\"client_name\":\"$client_name\",\
\"token\":\"$token\",\"event\":\"connected\",\"vps\":\"$VPS_ID\",\"event_at\":\"$now\"}" > /dev/null

exit 0
