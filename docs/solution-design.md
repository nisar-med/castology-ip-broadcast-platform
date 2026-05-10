# Castology IP Broadcast Platform — Solution Design

**Version:** 1.2  
**Date:** 2026-04-24  
**Status:** Production

---

## 1. Overview

The Castology IP Broadcast Platform ingests live video over SRT, transcodes/packages it as HLS, stores segments in Cloudflare R2, and delivers them to authenticated viewers via a Cloudflare Worker. A Prometheus/Grafana stack monitors stream health end-to-end.

```
Encoder (OBS/vMix)                      Affiliate STB/IRD/Player
       │ SRT push                               │
       ▼                                        │ SRT pull  srt://stream.castology.tv:1234
 ┌─────────────┐      HLS pull (localhost)      │   streamid=geo+news/TOKEN
 │ MistServer  │ ──────────────────────────────▶│──────────────────────────────────────┐
 │  :1235 SRT  │                  ┌──────────────┘                                      │
 │  :1234 SRT  │◀─────────────────┘  ┌──────────────┐                                  │
 │  :8080 HTTP │                     │    ffmpeg    │                                   │
 │  :4242 API  │────────────────────▶│ writes .ts + │                                  │
 └─────┬───────┘                     │  index.m3u8  │                                   │
       │                             └──────┬───────┘                                   │
       │ PLAY_REWRITE trigger               │ local disk                                │
       │ /usr/local/bin/                 ▼                                           │
       │ cast-mist-stream-auth.sh       /var/lib/mist-hls/{stream}/                            ▼
       │ validates token+IP              seg_NNNNN.ts                        HLS player
       │ via PocketBase                  index.m3u8                  https://play.castology.tv
       ▼                                     │ boto3 parallel upload         /hls/{stream}/
  TSduck / tsp                               ▼                              index.m3u8?token=
  (CC/bitrate                   ┌──────────────────────┐
   analysis)                    │  Cloudflare R2       │
       │                        │  castology-hls       │
       ▼                        │  live/{stream}/      │
  Prometheus                    │    seg_NNNNN.ts      │
  Exporter :9101                │    index.m3u8        │
       │                        └──────────┬───────────┘
       ▼                                   │
  Prometheus + Grafana                     ▼
  (monitoring VPS)             Cloudflare Worker
                               play.castology.tv/live/*
                                    │ token auth (KV) + playlist rewrite
                                    ▼
                               VLC / browser player
```

---

## 2. Infrastructure

### 2.1 VPS

| Role | IP | Services |
|---|---|---|
| Streaming | 83.147.18.124 | MistServer, cast-prom-metrics, ffmpeg, boto3 seg-push, nginx |
| Monitoring | 83.147.18.124 (same VPS) | Prometheus, Grafana, PocketBase, nginx |

Both roles currently share one VPS. The Terraform `vps` map supports different IPs; split is straightforward if load grows.

In the current repo layout, Cloudflare resources are managed by the live Terraform root, while VPS bootstrap, firewall rules, and optional Tailscale admin access are managed by `Infrastructure/docker/`. Admin services stay bound to localhost and are reached with SSH tunnels over either the public SSH path or the Tailscale tailnet.

### 2.2 Cloudflare Services

| Service | Purpose |
|---|---|
| R2 bucket `castology-hls` | HLS segment and playlist storage |
| Workers (play.castology.tv/live/*) | Authenticated HLS delivery from R2 |
| KV namespace `OPERATOR_TOKENS` | Bearer token → operator metadata mapping |
| R2 Local Uploads | Routes uploads through nearest CF edge PoP |
| Worker route `play.castology.tv/hls/*` | No Worker — bypasses to origin (MistServer handles auth) |

### 2.3 Terraform Modules

| Module | Manages |
|---|---|
| `mistserver` | MistServer install + config; TSduck exporter; SRT auth script + env file |
| `monitoring` | Prometheus, Grafana, node-exporter |
| `pocketbase` | PocketBase + collections setup |
| `nginx` | Reverse proxy; per-unique-IP deduplication; stream.castology.tv HLS bypass origin |
| `firewall` | UFW rules; ports merged across VPS roles |
| `dns` | Cloudflare DNS A records + SRT SRV records |
| `r2` | R2 bucket creation |
| `worker` | Cloudflare Worker deploy + KV binding; /hls/* bypass route |
| `null_resource.mistserver_r2_push` | Per-stream ffmpeg + boto3 push pipeline |

---

## 3. Ingest

**Protocol:** SRT (Secure Reliable Transport) over UDP port 1235.

Encoders push to `srt://83.147.18.124:1235?streamid={name}`. MistServer accepts any push matching the `geo` wildcard stream (`source: push://`). No password is configured; firewall restricts UDP 1235 to `0.0.0.0/0` (encoders are at variable IPs).

**Stream naming convention:** `geo+{channel}` (e.g. `geo+ent`, `geo+news`). The `+` separates geo prefix from channel name.

---

## 4. HLS Pipeline

### 4.1 MistServer → ffmpeg

MistServer serves HLS internally on port 8080. It wraps tracks in a master playlist at `/hls/{stream}/index.m3u8`. The master playlist references a track sub-playlist (e.g. `1_0/index.m3u8`).

MistServer adds a `?tkn=` token to sub-playlist URLs in the master playlist. This token rotates periodically. **Localhost connections bypass token validation entirely**, so the ffmpeg wrapper script:

1. Fetches the master playlist from `http://127.0.0.1:8080/hls/{stream}/index.m3u8`
2. Extracts the sub-playlist path and strips any `?tkn=` parameter with `cut -d'?' -f1`
3. Passes the token-free URL to ffmpeg: `http://127.0.0.1:8080/hls/{stream}/1_0/index.m3u8`

This prevents ffmpeg from disconnecting when the token rotates.

### 4.2 ffmpeg HLS Writer

```
ffmpeg -i {stream_url} -c copy -f hls \
  -hls_time 2 \
  -hls_list_size 10 \
  -hls_flags append_list+split_by_time \
  -hls_segment_filename /var/lib/mist-hls/{stream}/seg_%05d.ts \
  /var/lib/mist-hls/{stream}/index.m3u8
```

- Segment duration: 2 seconds
- Playlist window: 10 segments (20s)
- `append_list`: playlist is append-only; old entries roll off the window but segment files remain on disk until the cleanup timer runs
- Segments are immutable once written; only `index.m3u8` changes

Managed by systemd unit `cast-hls-write-{safe-name}` with `Restart=always`.

### 4.3 R2 Upload — boto3 Parallel Push

A Python script (`cast-hls-push-{safe-name}.py`) runs as a systemd service, polling every 1 second:

1. Reads `index.m3u8` to get the current segment list
2. Finds segments not yet in its `uploaded` set
3. Submits new segments to a `ThreadPoolExecutor(max_workers=4)` for parallel S3 uploads
4. Copies `index.m3u8` to a temp file (`.index.upload`) then uploads the copy

**Why parallel uploads:** Each segment upload to R2 takes ~2–4s over a VPS uplink. With 2s segment cadence, serial upload falls perpetually behind. Eight parallel workers (reduced to 4 with R2 Local Uploads enabled) keep the lag at zero.

**Why boto3 instead of rclone:**
- rclone computes `Content-MD5` when it opens a file. ffmpeg rewrites `index.m3u8` while rclone holds it open. R2 then rejects the upload with `400 BadDigest`. There is no rclone flag to suppress `Content-MD5` for S3-compatible providers.
- rclone lists all R2 objects before deciding what to upload. With 2,000+ segments, this list operation takes ~80 seconds — far too slow for a live 2s segment cadence.
- boto3's `upload_file` sends no `Content-MD5` header by default. R2 accepts the playlist unconditionally.

**Memory management:** The `uploaded` set is trimmed to the last 200 entries when it exceeds 500, preventing unbounded growth across long streams.

### 4.4 R2 Local Uploads

Enabled on the `castology-hls` bucket. Routes all PUT requests from the VPS through the nearest Cloudflare edge PoP rather than directly to R2's primary region. The edge accepts the upload immediately and replicates asynchronously. This reduced observed segment upload time from ~4s to ~2.2s, allowing `max_workers` to be reduced from 8 to 4.

No code change required — Local Uploads is transparent at the S3 API layer.

### 4.5 R2 Cleanup

A systemd timer (`cast-hls-clean-{safe-name}.timer`) runs every 30 minutes and executes:

```bash
rclone delete r2:castology-hls/live/{stream} --min-age=2h --include="*.ts" --log-level=ERROR
```

This prevents unbounded segment accumulation in R2. `index.m3u8` is excluded from deletion.

---

## 5. Affiliate Auth

### 5.1 Authentication Model

Affiliates (cable operators, streaming services) are authenticated on every new session via the MistServer `PLAY_REWRITE` trigger. Two factors are required:

1. **Token** — a unique `token_key` assigned to each affiliate in PocketBase
2. **Client endpoint** — source IP must match an active `affiliate_clients` record for that affiliate and stream

Both SRT and HLS connections use the same trigger script and the same PocketBase data.

### 5.2 PLAY_REWRITE Trigger — cast-mist-stream-auth.sh

MistServer calls `/usr/local/bin/cast-mist-stream-auth.sh` for every new session. The script:

1. Reads 4 lines from stdin: `stream`, `client_ip`, `connector`, `request_url`
2. For **TSSRT**: parses token from streamid (`geo+news/TOKEN`)
3. For **HLS**: parses token from `?token=` in request URL; `?tkn=` sub-requests pass through (MistServer session token, already authenticated)
4. Authenticates with PocketBase superadmin API
5. Looks up `affiliate` by `token_key`
6. Looks up active `affiliate_clients` rows for `affiliate_name + stream`
7. Checks source IP against the matched client row's `allowed_ips` (or `client_name` when used as a single-IP value)
8. Returns the real stream name on success (e.g. `geo+news`), exits 1 on denial

Logs to systemd journal as `cast-mist-stream-auth`. Monitor with:
```bash
journalctl -t cast-mist-stream-auth -f
```

Credentials are stored in `/etc/cast-mist-stream-auth.env` (chmod 600), not in the script.

### 5.3 SRT Output — Affiliate Pull

Port 1234 is configured as TSSRT `acceptable:1` (accepts inbound caller connections). Affiliates connect with:

```
srt://stream.castology.tv:1234?streamid=geo+news/TOKEN&latency=1000
```

MistServer fires PLAY_REWRITE, the script validates token+IP, returns `geo+news` if valid. MistServer delivers the stream from its internal `geo+news` source.

### 5.4 HLS Output — Affiliate Pull

Affiliates can also pull HLS directly from MistServer:

```
https://play.castology.tv/hls/geo+news/index.m3u8?token=TOKEN
```

The Cloudflare Worker route `play.castology.tv/hls/*` has **no Worker assigned** — requests bypass the Worker and go directly to nginx → MistServer port 8080. MistServer fires PLAY_REWRITE for each new session; the script validates token+IP as above.

`stream.castology.tv` is a grey-clouded (DNS-only) hostname exposing MistServer's HLS on port 80 via nginx, used internally as the bypass origin.

### 5.5 PocketBase Data Model

| Collection | Key fields | Purpose |
|---|---|---|
| `broadcasters` | `name`, `token_key`, `streams` (JSON array), `allowed_ips`, `active` | One per broadcaster; ingest side — companies pushing SRT into MistServer |
| `broadcaster_feeds` | `broadcaster_name`, `stream`, `feed_role`, `allowed_ips`, `active` | One per primary/backup broadcaster ingest path |
| `affiliates` | `name`, `token_key`, `contact_name`, `email`, `active` | One per affiliate; parent identity and token metadata only |
| `affiliate_clients` | `affiliate_name`, `stream`, `client_name`, `endpoint_role`, `allowed_ips`, `is_test_client`, `active` | One per affiliate endpoint/IP on a stream; source of truth for auth and monitoring |

`affiliate_clients` is now the source of truth for affiliate stream entitlement. If an affiliate has no active client rows for a stream, auth denies new sessions for that stream.

### 5.6 Affiliate Onboarding

1. Create an `affiliates` record in PocketBase:
   - `name`: affiliate name (e.g. `Storm Fiber`)
   - `token_key`: unique token string (e.g. `storm-fiber-001`)
   - `active`: true

2. Create one or more `affiliate_clients` records:
   - `affiliate_name`: parent affiliate name (e.g. `Storm Fiber`)
   - `stream`: Mist stream name (e.g. `geo+news`)
   - `client_name`: endpoint label or IP (e.g. `61.5.131.218`)
   - `endpoint_role`: endpoint purpose (`primary`, `backup`, `test`, etc.)
   - `allowed_ips`: single IP, CIDR, or comma-separated list for that client endpoint
   - `is_test_client`: true only for auth-test endpoints that must be excluded from monitoring
   - `active`: true

3. Add the token to Cloudflare KV (for `/live/` R2 delivery):
   ```bash
   curl -X PUT "https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/storage/kv/namespaces/{KV_ID}/values/{token}" \
     -H "Authorization: Bearer {CF_TOKEN}" \
     -d '{"affiliate":"Storm Fiber","streams":["geo+news","geo+ent"]}'
   ```

4. Give the affiliate their connection details:
   - **SRT:** `srt://stream.castology.tv:1234?streamid=geo+news/TOKEN&latency=1000`
   - **HLS:** `https://play.castology.tv/hls/geo+news/index.m3u8?token=TOKEN`
   - **R2/CDN HLS:** `https://play.castology.tv/live/geo+news/index.m3u8?token=TOKEN`
   - **M3U playlist:** `https://play.castology.tv/playlist?token=TOKEN`

No MistServer config changes are needed for new affiliates on existing streams.

---

## 6. Delivery

### 6.1 Cloudflare Worker — play.castology.tv/live/*

R2-backed HLS delivery for `/live/` paths is gated through a Cloudflare Worker.

**Routes:**
- `GET /live/{stream}/index.m3u8` — returns playlist with segment URLs rewritten to include `?token=`
- `GET /live/{stream}/*.ts` — returns segment with long cache TTL (1 hour)
- `GET /playlist?token=` — returns M3U channel list for all operator channels
- `GET /health` — public, returns `ok`
- `GET /hls/*` — **no Worker** (bypass route to origin, MistServer handles auth)

**Authentication:** Bearer token in `Authorization: Bearer {token}` header or `?token=` query parameter. Token is looked up in KV namespace `OPERATOR_TOKENS` (token → `{affiliate, streams}`). Invalid/missing tokens return 401.

**Playlist rewrite:** Segment filenames in `index.m3u8` are rewritten to append `?token={token}`. This allows players like VLC that follow playlist URLs without forwarding auth headers to still authenticate segment fetches.

**Cache behaviour:**
- Playlists: `no-store` (live content, must not be cached)
- Segments: `public, max-age=3600` (immutable once written)

---

## 6. Monitoring

### 6.1 Prometheus Scrape Targets

| Target | Metrics |
|---|---|
| `cast-prom-metrics:9101` | Castology session status, broadcaster feed status, affiliate client status, R2 pipeline health |
| `mistserver:4242/prometheus?pass={passphrase}` | MistServer internal metrics |
| `node-exporter:9100` | VPS system metrics (CPU, RAM, disk, network) |

The exporter port 9101 is firewalled to `127.0.0.1` only; Prometheus scrapes via localhost. MistServer API port 4242 is firewalled to `127.0.0.1` only. PocketBase, Grafana, and MistServer admin access are intended to stay on localhost and be reached through SSH tunnels, preferably over Tailscale once the VPS is enrolled.

### 6.2 cast-prom-metrics Metrics

**Broadcaster ingest / feed status:**

| Metric | Type | Description |
|---|---|---|
| `mist_broadcaster_feed_status` | Gauge | 1 = broadcaster feed online, 0 = offline |
| `mist_broadcaster_feed_jitter_ms` | Gauge | Jitter reported for the stream |
| `mist_broadcaster_feed_loss` | Gauge | Packet loss ratio for that feed |

**Affiliate client / playout status:**

| Metric | Type | Description |
|---|---|---|
| `mist_affiliate_client_status` | Gauge | 1 = affiliate endpoint online, 0 = offline |
| `mist_affiliate_client_loss` | Gauge | Packet loss ratio for that endpoint |
| `mist_affiliate_client_uptime_seconds` | Gauge | Endpoint session uptime |
| `mist_affiliate_client_bytes` | Gauge | Bytes transferred for that endpoint |

Test clients (`is_test_client=true`) are excluded from affiliate summary monitoring and dashboard rows, but still exist as auth-capable endpoint records.

**R2 pipeline health (per stream):**

| Metric | Type | Description |
|---|---|---|
| `r2_ffmpeg_up` | Gauge | 1 = `cast-hls-write-*` service active |
| `r2_segment_lag_count` | Gauge | Local segments not yet in R2 |
| `r2_latest_segment_age_seconds` | Gauge | Age of most recent local segment |
| `r2_upload_errors_total` | Counter | Upload errors from seg-push service |

Polled every 5 seconds. Lag > 5 is warning; lag > 10 is critical. Segment age > 30s indicates ffmpeg has stopped writing.

### 6.3 Grafana Dashboard — MistServer Session Status

Dashboard `mist-bq` at `http://83.147.18.124:3000`. Key tables:

1. **Broadcaster Feeds (Primary / Backup)** — `Name / Stream / Feed Role / IP / Status / Jitter / Loss`
2. **Affiliate Clients** — `Affiliate / Client / Role / Stream / IP / Status / Loss / Uptime / Bytes`

The dashboard merges exporter metrics by shared labels so desired-vs-live state is visible as explicit rows rather than inferred from raw Mist sessions.

---

## 7. Linux Services

Every persistent process on the VPS is a systemd unit. All units are installed and enabled by their respective Terraform provisioner — no manual setup is required. The table below is the authoritative list.

### 7.1 Streaming VPS Services

| Unit name | Type | Binary / script | Port(s) | Restart | Provisioned by |
|---|---|---|---|---|---|
| `mistserver` | simple | `/usr/bin/MistController` | 8080 (HTTP), 4242 (API), 1234+1235 (SRT) | always | `module.mistserver` → `mistserver.sh` |
| `cast-hls-write-geo-ent` | simple | `/usr/local/bin/cast-hls-write-geo-ent.sh` → `ffmpeg` | — | always, 3s | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `cast-hls-write-geo-news` | simple | `/usr/local/bin/cast-hls-write-geo-news.sh` → `ffmpeg` | — | always, 3s | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `cast-hls-push-geo-ent` | simple | `/usr/bin/python3 /usr/local/bin/cast-hls-push-geo-ent.py` | — | always, 2s | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `cast-hls-push-geo-news` | simple | `/usr/bin/python3 /usr/local/bin/cast-hls-push-geo-news.py` | — | always, 2s | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `cast-hls-clean-geo-ent.timer` | timer | triggers `.service` below | — | every 2 min | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `cast-hls-clean-geo-ent.service` | oneshot | `/usr/bin/python3 /usr/local/bin/cast-hls-clean-geo-ent.py` | — | — | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `cast-hls-clean-geo-news.timer` | timer | triggers `.service` below | — | every 2 min | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `cast-hls-clean-geo-news.service` | oneshot | `/usr/bin/python3 /usr/local/bin/cast-hls-clean-geo-news.py` | — | — | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `cast-prom-metrics` | simple | `/usr/bin/python3 /usr/local/bin/cast-prom-metrics.py` | 9101 | always, 5s | `module.mistserver` → `null_resource.provision_exporter` → `cast-prom-metrics-install.sh` |
| `nginx` | forking | `/usr/sbin/nginx` | 80 | always | `module.nginx` → `nginx.sh` |

**Stream-per-service naming:** Stream names use `+` (e.g. `geo+ent`). Systemd unit names replace all non-alphanumeric characters with `-` → `geo-ent`, `geo-news`. The safe name is derived once in `mistserver-r2-push.sh` as `SAFE_NAME="${STREAM_NAME//[^a-zA-Z0-9]/-}"`.

**`After=` dependencies:**
- `cast-hls-write-*` → `mistserver.service` (waits for MistServer HTTP port to be ready)
- `cast-hls-push-*` → `cast-hls-write-*.service` (waits for first segments to appear)
- `cast-prom-metrics` → `mistserver.service`

### 7.2 Monitoring VPS Services

| Unit name | Type | Binary / script | Port(s) | Restart | Provisioned by |
|---|---|---|---|---|---|
| `prometheus` | simple | `/usr/bin/prometheus` | 9090 | always | `module.monitoring` → `monitoring.sh` |
| `grafana-server` | simple | `/usr/sbin/grafana-server` | 3000 | always | `module.monitoring` → `monitoring.sh` |
| `prometheus-node-exporter` | simple | `/usr/bin/prometheus-node-exporter` | 9100 | always | distro package / monitoring node |
| `pocketbase` | simple | `/opt/pocketbase/pocketbase serve` | 8090 (localhost only) | always, 5s | `module.pocketbase` → `pocketbase.sh` |
| `nginx` | forking | `/usr/sbin/nginx` | 80 | always | `module.nginx` → `nginx.sh` |

### 7.3 Service Governance

Services are grouped with native systemd targets and a shared slice:

| Unit | Purpose |
|---|---|
| `castology-platform.target` | All Castology-managed services |
| `castology-streaming.target` | Mist, exporter, HLS writers, seg-push services, cleanup timers |
| `castology-origin.target` | nginx and PocketBase |
| `castology-monitoring.target` | Prometheus, Grafana, node-exporter |
| `castology.slice` | Shared accounting slice for the grouped services |

Useful commands:

```bash
systemctl list-dependencies castology-platform.target
systemctl list-dependencies castology-streaming.target
systemctl restart castology-streaming.target
systemctl stop castology-monitoring.target
systemctl status castology-origin.target
```

### 7.4 Terraform Provisioning Map

All services are installed and managed via `null_resource` provisioners using SSH remote-exec. None use cloud-init or configuration management tools. The mapping from Terraform resource to shell script to systemd unit(s):

```
main.tf
├── module.mistserver         (modules/mistserver/main.tf)
│   ├── null_resource.provision
│   │   └── mistserver.sh           → installs MistServer
│   │                                  enables: mistserver.service
│   │                                  groups:  castology-streaming.target
│   └── null_resource.provision_exporter
│       └── cast-prom-metrics-install.sh        → installs Python exporter
│                                      enables: cast-prom-metrics.service
│                                      groups:  castology-streaming.target
│
├── null_resource.mistserver_r2_push  (main.tf — runs per stream_name)
│   └── mistserver-r2-push.sh       → installs ffmpeg, boto3
│                                      enables / groups (per stream):
│                                        cast-hls-write-{safe}.service
│                                        cast-hls-push-{safe}.service
│                                        cast-hls-clean-{safe}.timer
│                                        cast-hls-clean-{safe}.service
│
├── module.monitoring         (modules/monitoring/main.tf)
│   └── monitoring.sh               → installs Prometheus + Grafana
│                                      enables: prometheus.service
│                                               grafana-server.service
│                                      groups:  castology-monitoring.target
│
├── module.pocketbase         (modules/pocketbase/main.tf)
│   └── pocketbase.sh               → installs PocketBase binary
│                                      enables: pocketbase.service
│                                      groups:  castology-origin.target
│                                      bootstraps: superadmin, collections
│                                      deploys:  /var/www/onboard/index.html
│
└── module.nginx              (modules/nginx/main.tf — per unique VPS IP)
    └── nginx.sh                    → installs nginx
                                       enables: nginx.service
                                       groups:  castology-origin.target
                                       configures sites (from var.nginx_sites):
                                         play.castology.tv    → :8080
                                         monitoring.castology.tv → :3000
                                         onboard.castology.tv → :8090 + /var/www/onboard
```

### 7.5 Re-provision Triggers

Each `null_resource` has a `triggers` block. Terraform re-runs the provisioner only when a trigger value changes. This keeps targeted reprovisioning small instead of reinstalling unrelated services on every `terraform apply`.

| Resource | Triggers re-provision when... |
|---|---|
| `module.mistserver / null_resource.provision` | `mistserver.sh` changes, VPS IP changes, Prometheus passphrase changes |
| `module.mistserver / null_resource.provision_exporter` | `cast-prom-metrics-install.sh` changes, `cast-prom-metrics.py` changes, port config changes |
| `module.mistserver / null_resource.provision_stream_auth` | `cast-mist-stream-auth.sh` changes, PocketBase email/password changes |
| `null_resource.mistserver_r2_push` | `mistserver-r2-push.sh` changes, R2 endpoint/bucket/key changes, stream list changes |
| `module.monitoring / null_resource.provision` | `monitoring.sh` changes, scrape IP changes |
| `module.pocketbase / null_resource.provision` | `pocketbase.sh` changes, admin email changes |
| `module.nginx / null_resource.provision` | `nginx.sh` changes (per unique VPS IP) |

### 7.6 Service Configuration Files on Disk

Files written to the VPS outside of systemd unit files:

| Path | Written by | Purpose |
|---|---|---|
| `/etc/mistserver.conf` | `mistserver.sh` (Python inline) | MistServer protocols, stream config, Prometheus passphrase |
| `/etc/cast-mist-stream-auth.env` | `mistserver` module `provision_stream_auth` | PocketBase credentials for `cast-mist-stream-auth.sh` (chmod 600) |
| `/usr/local/bin/cast-mist-stream-auth.sh` | `mistserver` module `provision_stream_auth` | PLAY_REWRITE trigger: validates affiliate token + active affiliate client IP |
| `/etc/cast-prom-metrics.env` | `cast-prom-metrics-install.sh` | `STREAMS_JSON`, `EXPORTER_PORT`, `MIST_API_PORT` — read by `cast-prom-metrics.service` via `EnvironmentFile=` |
| `/etc/prometheus/prometheus.yml` | `monitoring.sh` | Scrape targets (MistServer + cast-prom-metrics) |
| `/root/.config/rclone/rclone.conf` | `mistserver-r2-push.sh` | R2 credentials for cleanup timer only |
| `/usr/local/bin/cast-hls-write-{safe}.sh` | `mistserver-r2-push.sh` | Wrapper: resolves sub-playlist URL, strips token, execs ffmpeg |
| `/usr/local/bin/cast-hls-push-{safe}.py` | `mistserver-r2-push.sh` | boto3 parallel uploader (segments + playlist) |
| `/usr/local/bin/cast-prom-metrics.py` | `cast-prom-metrics-install.sh` | Prometheus exporter (copied from `/tmp/` uploaded by Terraform) |
| `/var/www/onboard/index.html` | `pocketbase.sh` | Placeholder page (affiliate portal not yet implemented) |
| `/opt/pocketbase/` | `pocketbase.sh` | PocketBase binary + data directory |
| `/var/lib/mist-hls/{stream}/` | `mistserver-r2-push.sh` (mkdir) | HLS segment working directory |

---

## 9. cast-prom-metrics Architecture

`cast-prom-metrics.py` runs alongside MistServer and polls:

- Mist `/api {"clients": {"time": -3}}`
- Mist `/api {"active_streams": null}`
- PocketBase collections: `broadcasters`, `broadcaster_feeds`, `affiliates`, `affiliate_clients`
- recent `cast-mist-stream-auth` journal entries for token-aware affiliate attribution

It emits:

- broadcaster feed metrics (`mist_broadcaster_feed_*`)
- affiliate client metrics (`mist_affiliate_client_*`)
- summary ingest/playout metrics (`mist_ingest_*`, `mist_playout_*`, `mist_connection_status`)
- raw session and R2 pipeline metrics

This keeps Grafana state aligned with both live Mist sessions and the configured desired state in PocketBase.

---

## 8. Design Decisions

### 8.1 Why SRT for Ingest

SRT provides ARQ (automatic repeat request) retransmission over UDP. It tolerates the packet loss typical of internet contribution feeds without introducing the latency of TCP. MistServer's TSSRT connector handles SRT natively.

### 8.2 Why ffmpeg Instead of MistServer's Built-in HLS Push

MistServer can push HLS internally, but its external writer S3 upload feature (`/MstExtWriters`) is a Pro-tier feature. The `Free_64` build initialises the shared memory page but never populates it. The `addexternalwriter` API call is ephemeral (lost on restart). The ffmpeg + boto3 approach provides equivalent functionality on the free tier with full operational control.

### 8.3 Why boto3 for R2 Upload

See §4.3. rclone was the original approach but failed due to `Content-MD5` rejection on live-written playlists and per-run listing overhead. boto3 eliminates both issues.

### 8.4 Why Cloudflare Worker for Delivery (Not Direct R2 URL)

- Authentication: R2 public URLs have no auth layer
- Playlist rewriting: segment URLs must include `?token=` for players that don't forward auth headers
- CDN edge caching: Worker responses flow through Cloudflare's cache network
- Future flexibility: rate limiting, geo-restriction, analytics via Analytics Engine all become one-line additions

### 8.5 Why PocketBase for Operator Portal

PocketBase is a single-binary Go server with built-in auth, admin UI, and REST API. It provides operator self-service without requiring a bespoke backend. It does not yet issue tokens automatically; that integration is pending.

---

## 10. Known Limitations and Risks

### 10.1 VPS CPU Steal Time

Observed steal time: 51.4%. The hypervisor is taking approximately half the available CPU cycles from other VMs on the same physical host. Symptoms: occasional stream stalls, high load average (2.2–2.6 on a 2-core VPS).

**Mitigation options:**
- Upgrade to a dedicated CPU VPS (most effective)
- Reduce seg-push `max_workers` from 8 to 4 (done — R2 Local Uploads make this viable)
- Move TSduck exporter to the monitoring VPS if it had a different IP (TSduck connects to `127.0.0.1` SRT ports, so it must co-locate with MistServer)

### 10.2 Single VPS — No Redundancy

Both roles (streaming and monitoring) run on the same VPS. A VPS failure takes down both the stream and observability simultaneously.

**Mitigation:** The Terraform `vps` map already supports separate IPs for `mistserver_vps` and `monitoring_vps`. Moving monitoring to a second VPS requires only a `terraform.tfvars` change and `terraform apply`.

### 10.3 Uploaded Set Memory Growth

The seg-push script's `uploaded` set is trimmed to 200 entries when it exceeds 500. On extremely long streams (many hours), segments not in the trimmed set would be re-uploaded on the next loop iteration. R2's `PUT` is idempotent so this causes redundant uploads, not data corruption. A proper solution would use the playlist window as the only source of truth for "needs uploading."

### 10.4 No Affiliate Token Rotation

Affiliate `token_key` values in PocketBase are static. There is no token expiry or audit log. Revoking an affiliate requires setting `active=false` on the parent `affiliates` record or `active=false` on the relevant `affiliate_clients` rows. The auth script has no caching so revocation takes effect on the next connection attempt.

### 10.5 HLS Auth Tied to MistServer Session Token

For HLS connections, sub-playlist and segment requests use MistServer's internal `?tkn=` session token, not the affiliate token. The `cast-mist-stream-auth.sh` script passes `?tkn=` requests through without re-validating against PocketBase. If an `affiliate_clients` row is disabled or removed, existing HLS playback can continue until the Mist `tkn` session expires. New connections will be denied immediately.

### 10.5 Grafana Not Behind Auth Proxy

Grafana on port 3000 is accessible from `83.147.18.124/32` only (firewall rule). There is no nginx proxy or TLS in front of it. Suitable for internal use; not suitable for external access without adding nginx + Let's Encrypt.

---

## 11. Operational Runbook

### Stream is down (VLC returns 404 or stops playing)

1. Check `r2_ffmpeg_up` in Grafana — if 0, `systemctl restart cast-hls-write-{safe}`
2. Check `r2_segment_lag_count` — if rising, check `journalctl -u cast-hls-push-{safe} -n 50`
3. Check `mist_broadcaster_feed_status` — if 0, upstream encoder is not pushing that broadcaster feed
4. Check `mist_broadcaster_feed_loss` / `mist_broadcaster_feed_jitter_ms` — if elevated, upstream or transport quality is degraded

### Re-provision after config change

```bash
# Full reprovisioning
terraform apply

# Exporter only (avoids 10-min TSduck build if already installed)
terraform apply -target=module.mistserver

# R2 push pipeline only
terraform apply -target=null_resource.mistserver_r2_push
```

### Affiliate denied — auth debugging

```bash
# Watch auth decisions in real time
journalctl -t cast-mist-stream-auth -f

# Common DENY reasons:
# DENY: no token in '...'                     → streamid missing /TOKEN or ?token= param
# DENY: no active affiliate for token=X       → token not in PocketBase or active=false
# DENY: IP x.x.x.x not authorized via affiliate_clients → no active client row for that affiliate+stream+IP
# ERROR: PocketBase auth failed               → check /etc/cast-mist-stream-auth.env credentials
```

### Add an affiliate (SRT + HLS)

1. Create `affiliates` record in PocketBase with `token_key`, `active=true`
2. Create one or more active `affiliate_clients` rows with `stream`, `allowed_ips`, and optional `is_test_client`
   - If IP is unknown at onboarding time, use `allowed_ips: 0.0.0.0/0` as a temporary wildcard and update once confirmed
   - `affiliate_clients` rows are **required** — auth will deny even with a valid token if no matching client row exists
3. Add token to Cloudflare KV for `/live/` R2 delivery:
```bash
curl -X PUT "https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/storage/kv/namespaces/{KV_ID}/values/{token}" \
  -H "Authorization: Bearer {CF_TOKEN}" \
  -d '{"affiliate":"Storm Fiber","streams":["geo+news","geo+ent"]}'
```

### QA: verify affiliate endpoints after onboarding

Run these from an **external machine** (not the VPS) so that IP whitelisting is exercised end-to-end.

```bash
# SRT — expects stream info if auth passes
ffprobe -v quiet -print_format json -show_streams \
  "srt://83.147.18.124:1234?streamid=geo+news/<token_key>"

# HLS — expects a valid #EXTM3U playlist if auth passes
curl -v "http://play.castology.tv/hls/geo+news/index.m3u8?token=<token_key>"
```

> **Note:** HLS must use the domain `play.castology.tv`, not the raw VPS IP. MistServer only serves HLS when the `Host` header matches — raw IP requests return the MistServer web UI instead of the playlist.

### Check upload pipeline manually

```bash
# On streaming VPS
journalctl -u cast-hls-push-geo-ent -f
journalctl -u cast-hls-write-geo-ent -f
ls -lth /var/lib/mist-hls/geo+ent/ | head -5
curl -s localhost:9101/metrics | grep r2_
```

---

## 12. Troubleshooting

### 12.1 SRT Operator Connection Denied

**Symptom:** ffplay/VLC reports `I/O error` immediately on connect.

**Check auth log:**
```bash
journalctl -t cast-mist-stream-auth -f
```

| Log message | Cause | Fix |
|---|---|---|
| `DENY: no token in 'geo+news'` | Streamid missing `/TOKEN` | Use `streamid=geo+news/TOKEN` |
| `DENY: no active affiliate for token=X` | Token not in PocketBase or `active=false` | Check PocketBase `affiliates` collection |
| `DENY: IP x.x.x.x not authorized via affiliate_clients` | No active client row matches that affiliate + stream + IP | Add or enable the matching `affiliate_clients` row |
| `ERROR: PocketBase auth failed` | Wrong credentials in `/etc/cast-mist-stream-auth.env` | Update `/etc/cast-mist-stream-auth.env` on VPS |

**Check MistServer log:**
```bash
journalctl -u mistserver -f | grep -E "FAIL|ACCS|PLAY_REWRITE"
```

- `playback rejected by PLAY_REWRITE trigger` — trigger script returned exit 1 (DENY)
- `ACCS: Session ... ended after Xs` — session was established and ended normally
- `SRT error: transmission timed out` — MistServer tried to create outbound socket (wrong stream name returned by trigger)

### 12.2 HLS Returns 401

**Symptom:** `Server returned 401 Unauthorized` in ffplay or browser.

**For `/live/` path** (Cloudflare Worker):
- Missing `?token=` in URL
- Token not in Cloudflare KV namespace `OPERATOR_TOKENS`
- Token value in KV is malformed JSON — must be `{"affiliate":"Name","streams":["geo+news",...]}`

**For `/hls/` path** (MistServer direct):
- Check auth log: `journalctl -t cast-mist-stream-auth -f`
- Verify token is correct and IP is in `allowed_ips`
- Verify `stream.castology.tv` nginx site is active: `nginx -T | grep stream.castology.tv`

### 12.3 HLS Plays Initially Then Stops

**Symptom:** Stream plays for a few seconds then freezes or reports error on sub-playlist fetch.

This is usually the `?tkn=` rotation issue. MistServer rotates its internal session token periodically. If the player is fetching sub-playlists directly without the `tkn`, it gets denied.

Check if sub-playlist URLs in the master playlist include `?tkn=`:
```bash
curl -s "http://stream.castology.tv/hls/geo+news/index.m3u8?token=TOKEN"
```
The returned URLs should contain `?tkn=`. The trigger script passes `tkn=` requests through without re-validating.

### 12.4 R2 HLS Stream Not Playing

**Symptom:** `/live/` path returns 404 or stale content.

```bash
# Check R2 pipeline services
journalctl -u cast-hls-write-geo-news -f
journalctl -u cast-hls-push-geo-news -f

# Check latest segment age
ls -lth /var/lib/mist-hls/geo+news/ | head -5

# Check Prometheus metrics
curl -s localhost:9101/metrics | grep r2_
```

- `r2_ffmpeg_up 0` → `systemctl restart cast-hls-write-geo-news`
- `r2_segment_lag_count` rising → upload backlog, check seg-push logs
- No segments on disk → MistServer not receiving ingest, check encoder

### 12.5 geo+ent Repeated PLAY_REWRITE Failures in Log

**Symptom:** Hundreds of `playback rejected by PLAY_REWRITE trigger` for `geo+ent` every 5 seconds.

This is MistServer's auto_push trying to push `geo+ent` to SRT output port 1238, which fires PLAY_REWRITE. If no valid operator token is configured for auto_push, the trigger denies it.

This is expected behaviour when no operator is connected — the log noise is benign. To suppress it, remove or disable the auto_push for `geo+ent` in MistServer config if it is not needed.

---

## 13. Future Work

| Item | Priority | Notes |
|---|---|---|
| Dedicated CPU VPS | High | Resolve 51.4% steal time |
| Affiliate self-service portal | Medium | Placeholder at onboard.castology.tv; not yet implemented |
| Grafana alerts → email/Slack | Medium | SMTP config pending |
| Multi-bitrate ladder in MistServer | Low | Requires MistServer transcoding (CPU cost) |
| Segment cleanup on pipeline restart | Low | Old segments persist on disk until 2h rclone cleanup |
| Move monitoring to separate VPS | Low | tfvars change + `terraform apply` only |
