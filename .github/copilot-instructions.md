# Castology IP Broadcast Platform — Copilot Context

## What This Project Does

Live video broadcast platform: encoders push SRT streams into MistServer, which packages them as HLS and delivers to cable operators via SRT pull or HLS. Segments are also pushed to Cloudflare R2 for CDN HLS delivery.

## Infrastructure

- **VPS:** `83.147.18.124` (Ubuntu 22.04) — MistServer, nginx, PocketBase, Prometheus, Grafana
- **Cloudflare:** R2 bucket `castology-hls`, Worker at `play.castology.tv`, KV namespace `OPERATOR_TOKENS`
- **Terraform:** all infrastructure is code in `Infrastructure/terraform/`

## Stream Naming

Streams use `+` as separator: `geo+news`, `geo+ent`. The `+` is significant — do not replace with `-` in stream names. Systemd unit names use `-` as safe name (e.g. `geo-news`).

## Cable Operator Auth

**MistServer PLAY_REWRITE trigger:** `Infrastructure/terraform/scripts/mist-srt-auth.sh`

- Deployed to `/opt/mist-scripts/mist-srt-auth.sh` on the VPS
- Validates every new session (SRT and HLS) against PocketBase
- Two factors: `token_key` (unique per operator) + `allowed_ips` (static IPs/CIDRs)
- Credentials loaded from `/etc/mist-auth.env` (never hardcode in script)
- Logs via `logger -t mist-srt-auth` → `journalctl -t mist-srt-auth -f`

**SRT streamid format:** `geo+news/TOKEN` (MistServer decodes `+` as space — script restores it)

**HLS token:** `?token=TOKEN` in request URL. Sub-requests use `?tkn=` (MistServer session) — pass through without re-validation.

## PocketBase Collections

- `channel_groups`: `token_key`, `channels` (JSON array `[{name, stream}]`), `allowed_ips` (comma-separated), `active`
- `cable_operators`: `company_name`, `group_id`, `active`, `email`, `contact_name`

PocketBase runs at `http://127.0.0.1:8090`. Auth: superusers collection, `auth-with-password` endpoint.

## HLS Delivery Routes

| Path | Handler | Auth |
|---|---|---|
| `play.castology.tv/live/*` | Cloudflare Worker → R2 | KV token lookup |
| `play.castology.tv/hls/*` | bypass Worker → nginx → MistServer:8080 | PLAY_REWRITE trigger |
| `play.castology.tv/playlist` | Cloudflare Worker | KV token lookup |
| `stream.castology.tv/hls/*` | nginx → MistServer:8080 (grey-cloud, no CF proxy) | PLAY_REWRITE trigger |

## Cloudflare Worker

File: `Infrastructure/terraform/modules/worker/src/index.js`

- KV format: `token → {"broadcaster":"geo","channels":[{"name":"...","stream":"..."}]}`
- `broadcaster` is the stream prefix (e.g. `geo` for `geo+news`)
- `/hls/*` route has no Worker assigned — bypasses to origin

## Terraform Conventions

- All VPS provisioning uses `null_resource` with SSH `remote-exec` — no cloud-init
- Re-provision triggers are `filemd5()` on scripts + key config values
- `terraform apply -target=module.worker` to deploy Worker only
- Secrets never in scripts — use env files or Terraform `sensitive` variables
- `terraform.tfvars` is gitignored (contains credentials)

## nginx Sites

Managed by `Infrastructure/terraform/scripts/nginx.sh` via `NGINX_SITES` env var.
Valid sites: `play`, `mist`, `monitoring`, `onboard`, `stream`

- `play` → MistServer:8080
- `stream` → MistServer:8080, `/hls/` only (Worker bypass origin)
- `onboard` → PocketBase:8090 + `/var/www/onboard` static portal

## Operator Onboarding Checklist

1. Create `channel_group` in PocketBase (`token_key`, `channels`, `allowed_ips`, `active=true`)
2. Create `cable_operators` record (`group_id`, `active=true`, `email`, `contact_name`)
3. Write token to Cloudflare KV for `/live/` delivery
4. Give operator: SRT URL `srt://stream.castology.tv:1234?streamid=STREAM/TOKEN&latency=1000`
5. Give operator: HLS URL `https://play.castology.tv/hls/STREAM/index.m3u8?token=TOKEN`

## Common Debugging

```bash
# Auth decisions (SRT + HLS)
journalctl -t mist-srt-auth -f

# MistServer events
journalctl -u mistserver -f | grep -E "FAIL|ACCS|REWRITE"

# HLS pipeline
journalctl -u mist-hls-writer-geo-news -f
journalctl -u mist-seg-push-geo-news -f

# Prometheus metrics
curl -s localhost:9101/metrics | grep r2_
```

## Key File Locations on VPS

| Path | Purpose |
|---|---|
| `/opt/mist-scripts/mist-srt-auth.sh` | PLAY_REWRITE trigger |
| `/etc/mist-auth.env` | PocketBase credentials (chmod 600) |
| `/etc/mistserver.conf` | MistServer config |
| `/var/lib/mist-hls/{stream}/` | HLS segment working dir |
| `/etc/nginx/sites-enabled/` | nginx site configs |
