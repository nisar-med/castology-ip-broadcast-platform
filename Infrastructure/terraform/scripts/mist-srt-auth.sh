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
# Strip IPv6-mapped prefix and brackets (e.g. ::ffff:1.2.3.4 → 1.2.3.4)
client_ip=$(echo "$client_ip" | sed 's/\[//g; s/\]//g; s/::ffff://g; s/:[0-9]*$//')

log "connector=$connector ip=$client_ip stream=$stream"

# Pass unknown connectors through
if [[ "$connector" != "TSSRT" && "$connector" != "HLS" ]]; then
    printf '%s' "$stream"
    exit 0
fi

if [[ "$connector" == "HLS" ]]; then
    sname="$stream"
    # Sub-requests use ?tkn= (MistServer session token) — already authenticated, allow through
    if echo "$request_url" | grep -q 'tkn='; then
        printf '%s' "$sname"
        exit 0
    fi
    # Initial request uses ?token= (operator token) — validate against PocketBase
    token=$(echo "$request_url" | grep -o 'token=[^&]*' | cut -d= -f2)
    if [[ -z "$token" ]]; then
        log "DENY: no token in HLS request '$request_url'"
        exit 1
    fi
elif [[ "$connector" == "TSSRT" ]]; then
    # Parse streamid: "stream_name/TOKEN"
    sname="${stream%%/*}"
    token="${stream#*/}"
    # No slash = no token — deny
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

# Look up channel_group by token_key
filter=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "token_key=\"$token\" && active=true")
group_json=$(curl -sf "$PB_URL/api/collections/channel_groups/records?filter=$filter&perPage=1" \
    -H "Authorization: Bearer $pb_token")

group_id=$(echo "$group_json" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
group_name=$(echo "$group_json" | grep -o '"name":"[^"]*"' | head -2 | tail -1 | cut -d'"' -f4)

if [[ -z "$group_id" ]]; then
    log "DENY: no active channel_group for token=$token"
    exit 1
fi

# Check requested stream is in the group's channels
channels=$(echo "$group_json" | grep -o '"channels":\[[^]]*\]' | head -1)
if ! echo "$channels" | grep -q "\"$sname\""; then
    log "DENY: stream '$sname' not in group '$group_name'"
    exit 1
fi

# Check source IP against allowed_ips
allowed_ips=$(echo "$group_json" | grep -o '"allowed_ips":"[^"]*"' | cut -d'"' -f4)
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
        log "DENY: IP $client_ip not in allowed_ips for group '$group_name'"
        exit 1
    fi
fi

# Check active cable_operator exists for this group
filter2=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "group_id=\"$group_id\" && active=true")
ops_json=$(curl -sf "$PB_URL/api/collections/cable_operators/records?filter=$filter2&perPage=1" \
    -H "Authorization: Bearer $pb_token")

op_count=$(echo "$ops_json" | grep -o '"totalItems":[0-9]*' | cut -d: -f2)
if [[ -z "$op_count" || "$op_count" == "0" ]]; then
    log "DENY: no active cable_operator in group '$group_name'"
    exit 1
fi

log "ALLOW: stream=$sname group=$group_name ip=$client_ip"
printf '%s' "$sname"
exit 0
