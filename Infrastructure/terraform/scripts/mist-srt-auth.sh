#!/usr/bin/env bash
# MistServer PLAY_REWRITE trigger — SRT token auth via PocketBase

log() { logger -t mist-srt-auth "$*"; }
PB_URL="${PB_URL:-http://127.0.0.1:8090}"
PB_EMAIL="${PB_EMAIL:-admin@castology.tv}"
[[ -f /etc/mist-auth.env ]] && source /etc/mist-auth.env
PB_PASS="${PB_PASS:-}"

IFS= read -r stream
IFS= read -r client_ip
IFS= read -r connector
IFS= read -r request_url

stream=$(echo "$stream" | sed 's/ /+/g')
client_ip=$(echo "$client_ip" | sed 's/\[//g; s/\]//g; s/::ffff://g; s/:[0-9]*$//')

log "connector=$connector ip=$client_ip stream=$stream"

# Pass unknown connectors through
if [[ "$connector" != "TSSRT" && "$connector" != "HLS" ]]; then
    printf '%s' "$stream"
    exit 0
fi

# Pass loopback through — ffmpeg writer and internal MistServer sub-requests
if [[ "$client_ip" == "127.0.0.1" || "$client_ip" == "::1" ]]; then
    printf '%s' "$stream"
    exit 0
fi

if [[ "$connector" == "HLS" ]]; then
    sname="$stream"
    if echo "$request_url" | grep -q 'tkn='; then
        printf '%s' "$sname"
        exit 0
    fi
    token=$(echo "$request_url" | grep -o 'token=[^&]*' | cut -d= -f2)
    if [[ -z "$token" ]]; then
        log "DENY: no token in HLS request '$request_url'"
        exit 1
    fi
elif [[ "$connector" == "TSSRT" ]]; then
    sname="${stream%%/*}"
    token="${stream#*/}"
    if [[ -z "$sname" || "$token" == "$stream" ]]; then
        log "DENY: no token in '$stream'"
        exit 1
    fi
fi

# Authenticate with PocketBase
pb_token=$(curl -sf -X POST "$PB_URL/api/collections/_superusers/auth-with-password" \
    -H "Content-Type: application/json" \
    -d "{\"identity\":\"$PB_EMAIL\",\"password\":\"$PB_PASS\"}" \
    | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [[ -z "$pb_token" ]]; then
    log "ERROR: PocketBase auth failed"
    exit 1
fi

# Look up affiliate by token_key
filter=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "token_key=\"$token\" && active=true")
affiliate_json=$(curl -sf "$PB_URL/api/collections/affiliates/records?filter=$filter&perPage=1" \
    -H "Authorization: Bearer $pb_token")

affiliate_id=$(echo "$affiliate_json" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
affiliate_name=$(echo "$affiliate_json" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)

if [[ -z "$affiliate_id" ]]; then
    log "DENY: no active affiliate for token=$token"
    exit 1
fi

# Check source IP against affiliate_clients for this affiliate and stream.
client_filter=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "affiliate_name=\"$affiliate_name\" && stream=\"$sname\" && active=true")
affiliate_clients_json=$(curl -sf "$PB_URL/api/collections/affiliate_clients/records?filter=$client_filter&perPage=200" \
    -H "Authorization: Bearer $pb_token")

client_match=$(AFFILIATE_CLIENTS_JSON="$affiliate_clients_json" python3 - "$client_ip" <<'PY'
import ipaddress
import json
import os
import sys

client_ip = sys.argv[1]
payload = json.loads(os.environ.get("AFFILIATE_CLIENTS_JSON", "{}"))
items = payload.get("items", [])

try:
    client_addr = ipaddress.ip_address(client_ip)
except ValueError:
    sys.exit(1)

def matches(ip_value: str) -> bool:
    candidate = ip_value.strip()
    if not candidate:
        return False
    try:
        return client_addr in ipaddress.ip_network(candidate, strict=False)
    except ValueError:
        return client_ip == candidate

for item in items:
    allowed_ips = item.get("allowed_ips", "")
    values = [value.strip() for value in allowed_ips.split(",") if value.strip()]
    if not values and item.get("client_name"):
        values = [item["client_name"]]
    if any(matches(value) for value in values):
        print(json.dumps({
            "client_name": item.get("client_name", ""),
            "endpoint_role": item.get("endpoint_role", ""),
            "is_test_client": bool(item.get("is_test_client", False)),
        }))
        sys.exit(0)

sys.exit(1)
PY
)

if [[ -z "$client_match" ]]; then
    log "DENY: IP $client_ip not authorized via affiliate_clients for affiliate '$affiliate_name' stream '$sname'"
    exit 1
fi

client_name=$(echo "$client_match" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_name',''))")
endpoint_role=$(echo "$client_match" | python3 -c "import sys,json; print(json.load(sys.stdin).get('endpoint_role',''))")
is_test_client=$(echo "$client_match" | python3 -c "import sys,json; print('true' if json.load(sys.stdin).get('is_test_client') else 'false')")

log "ALLOW: stream=$sname affiliate=$affiliate_name client=$client_name role=$endpoint_role test_client=$is_test_client ip=$client_ip"
printf '%s' "$sname"
exit 0
