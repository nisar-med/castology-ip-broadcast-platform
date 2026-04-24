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

# Check requested stream is in the affiliate's streams array
streams=$(echo "$affiliate_json" | python3 -c "import sys,json,re; d=json.load(sys.stdin); items=d.get('items',[]); print(' '.join(items[0].get('streams',[]) if items else []))" 2>/dev/null)
if ! echo " $streams " | grep -q " $sname "; then
    log "DENY: stream '$sname' not licensed for affiliate '$affiliate_name' [$streams]"
    exit 1
fi

# Check source IP against allowed_ips (empty = allow any)
allowed_ips=$(echo "$affiliate_json" | grep -o '"allowed_ips":"[^"]*"' | cut -d'"' -f4)
if [[ -n "$allowed_ips" ]]; then
    ip_allowed=0
    IFS=',' read -ra cidrs <<< "$allowed_ips"
    for cidr in "${cidrs[@]}"; do
        cidr=$(echo "$cidr" | tr -d ' ')
        if python3 -c "import ipaddress,sys; ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) or exit(1)" "$client_ip" "$cidr" 2>/dev/null; then
            ip_allowed=1
            break
        fi
    done
    if [[ "$ip_allowed" == "0" ]]; then
        log "DENY: IP $client_ip not in allowed_ips for affiliate '$affiliate_name'"
        exit 1
    fi
fi

log "ALLOW: stream=$sname affiliate=$affiliate_name ip=$client_ip"
printf '%s' "$sname"
exit 0
