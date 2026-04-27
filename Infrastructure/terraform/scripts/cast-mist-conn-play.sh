#!/usr/bin/env bash
# MistServer CONN_PLAY trigger — fires after PLAY_REWRITE succeeds (output)
# or when an ingest push connects (input).
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

# Skip loopback and unknown connectors
if [[ "$client_ip" == "127.0.0.1" || "$client_ip" == "::1" ]]; then
    exit 0
fi
if [[ "$connector" != "TSSRT" && "$connector" != "HLS" ]]; then
    exit 0
fi

# Extract stream name and token
if [[ "$connector" == "TSSRT" ]]; then
    sname="${stream%%/*}"
    token="${stream#*/}"
    [[ "$token" == "$stream" ]] && token=""
elif [[ "$connector" == "HLS" ]]; then
    sname="$stream"
    token=$(echo "$request_url" | grep -o 'token=[^&]*' | cut -d= -f2)
fi

# Skip if no token — anonymous or unrecognised session
[[ -z "$token" ]] && exit 0

# Authenticate with PocketBase
pb_token=$(curl -sf -X POST "$PB_URL/api/collections/_superusers/auth-with-password" \
    -H "Content-Type: application/json" \
    -d "{\"identity\":\"$PB_EMAIL\",\"password\":\"$PB_PASS\"}" \
    | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
[[ -z "$pb_token" ]] && exit 0

# ── Resolve identity from token ───────────────────────────────────────────────
# Try affiliates first (output sessions)
af_filter=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
    "token_key=\"$token\" && active=true")
af_json=$(curl -sf "$PB_URL/api/collections/affiliates/records?filter=$af_filter&perPage=1" \
    -H "Authorization: Bearer $pb_token")
affiliate=$(echo "$af_json" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)

if [[ -n "$affiliate" ]]; then
    direction="output"
    # No active=true — client may be inactive but identity must resolve from token
    cl_filter=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
        "affiliate_name=\"$affiliate\" && stream=\"$sname\"")
    cl_json=$(curl -sf "$PB_URL/api/collections/affiliate_clients/records?filter=$cl_filter&perPage=1" \
        -H "Authorization: Bearer $pb_token")
    client_name=$(echo "$cl_json" | grep -o '"client_name":"[^"]*"' | head -1 | cut -d'"' -f4)
else
    # Try broadcasters (input/ingest sessions)
    br_filter=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
        "token_key=\"$token\" && active=true")
    br_json=$(curl -sf "$PB_URL/api/collections/broadcasters/records?filter=$br_filter&perPage=1" \
        -H "Authorization: Bearer $pb_token")
    affiliate=$(echo "$br_json" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -n "$affiliate" ]]; then
        direction="input"
        # Use feed_role as client_name for consistency with exporter IP-matching fallback
        feed_filter=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
            "broadcaster_name=\"$affiliate\" && stream=\"$sname\"")
        feed_json=$(curl -sf "$PB_URL/api/collections/broadcaster_feeds/records?filter=$feed_filter&perPage=1" \
            -H "Authorization: Bearer $pb_token")
        client_name=$(echo "$feed_json" | grep -o '"feed_role":"[^"]*"' | head -1 | cut -d'"' -f4)
        client_name="${client_name:-primary}"
    fi
fi

# Skip if token doesn't match any known broadcaster or affiliate
[[ -z "$affiliate" ]] && exit 0

affiliate="${affiliate}"
client_name="${client_name:-unknown}"
direction="${direction:-output}"
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Upsert active_sessions
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
\"direction\":\"$direction\",\"affiliate\":\"$affiliate\",\"client_name\":\"$client_name\",\
\"token\":\"$token\",\"vps\":\"$VPS_ID\",\"connected_at\":\"$now\"}" > /dev/null

# Append session_audit
curl -sf -X POST "$PB_URL/api/collections/session_audit/records" \
    -H "Authorization: Bearer $pb_token" \
    -H "Content-Type: application/json" \
    -d "{\"stream\":\"$sname\",\"ip\":\"$client_ip\",\"connector\":\"$connector\",\
\"direction\":\"$direction\",\"affiliate\":\"$affiliate\",\"client_name\":\"$client_name\",\
\"token\":\"$token\",\"event\":\"connected\",\"vps\":\"$VPS_ID\",\"event_at\":\"$now\"}" > /dev/null

exit 0
