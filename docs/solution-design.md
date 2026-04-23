# Castology IP Broadcast Platform — Solution Design

**Version:** 1.1  
**Date:** 2026-04-23  
**Status:** Production

---

## 1. Overview

The Castology IP Broadcast Platform ingests live video over SRT, transcodes/packages it as HLS, stores segments in Cloudflare R2, and delivers them to authenticated viewers via a Cloudflare Worker. A Prometheus/Grafana stack monitors stream health end-to-end.

```
Encoder (OBS/vMix)                      Cable Operator STB/IRD
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
       │ /opt/mist-scripts/                 ▼                                           │
       │ mist-srt-auth.sh       /var/lib/mist-hls/{stream}/                            ▼
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
| Streaming | 83.147.18.124 | MistServer, ffmpeg, boto3 seg-push, tsduck-exporter, nginx |
| Monitoring | 83.147.18.124 (same VPS) | Prometheus, Grafana, PocketBase, nginx |

Both roles currently share one VPS. The Terraform `vps` map supports different IPs; split is straightforward if load grows.

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
| `pocketbase` | PocketBase operator portal |
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

Managed by systemd unit `mist-hls-writer-{safe-name}` with `Restart=always`.

### 4.3 R2 Upload — boto3 Parallel Push

A Python script (`mist-seg-push-{safe-name}.py`) runs as a systemd service, polling every 1 second:

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

A systemd timer (`mist-r2-cleanup-{safe-name}.timer`) runs every 30 minutes and executes:

```bash
rclone delete r2:castology-hls/live/{stream} --min-age=2h --include="*.ts" --log-level=ERROR
```

This prevents unbounded segment accumulation in R2. `index.m3u8` is excluded from deletion.

---

## 5. Cable Operator Auth

### 5.1 Authentication Model

Cable operators are authenticated on every new session via the MistServer `PLAY_REWRITE` trigger. Two factors are required:

1. **Token** — a unique `token_key` assigned to each operator's `channel_group` in PocketBase
2. **IP** — source IP must match the `allowed_ips` list on the `channel_group` (comma-separated IPs or CIDRs)

Both SRT and HLS connections use the same trigger script and the same PocketBase data.

### 5.2 PLAY_REWRITE Trigger — mist-srt-auth.sh

MistServer calls `/opt/mist-scripts/mist-srt-auth.sh` for every new session. The script:

1. Reads 4 lines from stdin: `stream`, `client_ip`, `connector`, `request_url`
2. For **TSSRT**: parses token from streamid (`geo+news/TOKEN`)
3. For **HLS**: parses token from `?token=` in request URL; `?tkn=` sub-requests pass through (MistServer session token, already authenticated)
4. Authenticates with PocketBase superadmin API
5. Looks up `channel_group` by `token_key`
6. Checks requested stream is in the group's `channels`
7. Checks source IP against group's `allowed_ips`
8. Checks an active `cable_operator` record exists for the group
9. Returns the real stream name on success (e.g. `geo+news`), exits 1 on denial

Logs to systemd journal as `mist-srt-auth`. Monitor with:
```bash
journalctl -t mist-srt-auth -f
```

Credentials are stored in `/etc/mist-auth.env` (chmod 600), not in the script.

### 5.3 SRT Output — Cable Operator Pull

Port 1234 is configured as TSSRT `acceptable:1` (accepts inbound caller connections). Operators connect with:

```
srt://stream.castology.tv:1234?streamid=geo+news/TOKEN&latency=1000
```

MistServer fires PLAY_REWRITE, the script validates token+IP, returns `geo+news` if valid. MistServer delivers the stream from its internal `geo+news` source.

### 5.4 HLS Output — Cable Operator Pull

Operators can also pull HLS directly from MistServer:

```
https://play.castology.tv/hls/geo+news/index.m3u8?token=TOKEN
```

The Cloudflare Worker route `play.castology.tv/hls/*` has **no Worker assigned** — requests bypass the Worker and go directly to nginx → MistServer port 8080. MistServer fires PLAY_REWRITE for each new session; the script validates token+IP as above.

`stream.castology.tv` is a grey-clouded (DNS-only) hostname exposing MistServer's HLS on port 80 via nginx, used internally as the bypass origin.

### 5.5 PocketBase Data Model

| Collection | Key fields | Purpose |
|---|---|---|
| `channel_groups` | `token_key`, `channels` (JSON), `allowed_ips`, `active` | One per operator group; holds token and allowed streams/IPs |
| `cable_operators` | `company_name`, `group_id`, `active`, `email` | One per operator company; linked to a channel_group |

### 5.6 Operator Onboarding

1. Create a `channel_group` record in PocketBase:
   - `name`: operator name
   - `token_key`: unique token string (e.g. `storm-fiber-001`)
   - `channels`: JSON array of `{name, stream}` objects
   - `allowed_ips`: comma-separated static IPs or CIDRs
   - `active`: true

2. Create a `cable_operators` record linked to the group.

3. Add the token to Cloudflare KV (for `/live/` R2 delivery):
   ```bash
   curl -X PUT "https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/storage/kv/namespaces/{KV_ID}/values/{token}" \
     -H "Authorization: Bearer {CF_TOKEN}" \
     -d '{"broadcaster":"geo","channels":[{"name":"Geo News","stream":"geo+news"}]}'
   ```

4. Give the operator their URLs:
   - **SRT:** `srt://stream.castology.tv:1234?streamid=geo+news/TOKEN&latency=1000`
   - **HLS:** `https://play.castology.tv/hls/geo+news/index.m3u8?token=TOKEN`
   - **R2/CDN HLS:** `https://play.castology.tv/live/geo+news/index.m3u8?token=TOKEN`
   - **M3U playlist:** `https://play.castology.tv/playlist?token=TOKEN`

No MistServer config changes are needed for new operators on existing streams.

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

**Authentication:** Bearer token in `Authorization: Bearer {token}` header or `?token=` query parameter. Token is looked up in KV namespace `OPERATOR_TOKENS` (token → `{broadcaster, channels}`). Invalid/missing tokens return 401.

**Playlist rewrite:** Segment filenames in `index.m3u8` are rewritten to append `?token={token}`. This allows players like VLC that follow playlist URLs without forwarding auth headers to still authenticate segment fetches.

**Cache behaviour:**
- Playlists: `no-store` (live content, must not be cached)
- Segments: `public, max-age=3600` (immutable once written)

---

## 6. Monitoring

### 6.1 Prometheus Scrape Targets

| Target | Metrics |
|---|---|
| `tsduck-exporter:9101` | MPEG-TS stream health, R2 pipeline health |
| `mistserver:4242/prometheus?pass={passphrase}` | MistServer internal metrics |
| `node-exporter:9100` | VPS system metrics (CPU, RAM, disk, network) |

The exporter port 9101 is firewalled to `127.0.0.1` only; Prometheus scrapes via localhost. MistServer API port 4242 is firewalled to `127.0.0.1` only.

### 6.2 tsduck-exporter Metrics

**MPEG-TS stream quality (per stream):**

| Metric | Type | Description |
|---|---|---|
| `tsduck_stream_up` | Gauge | 1 = tsp connected and receiving |
| `tsduck_bitrate_bps` | Gauge | Current stream bitrate |
| `tsduck_cc_errors_total` | Counter | Continuity counter errors (dropped packets) |
| `tsduck_pcr_errors_total` | Counter | PCR timing errors (clock jitter) |

CC errors are the primary signal for upstream encoder or SRT transport problems.

**MistServer push connections (per stream):**

| Metric | Type | Description |
|---|---|---|
| `mist_push_active_connections` | Gauge | Active outbound SRT push connections |
| `mist_push_bytes_sent_total` | Counter | Total bytes sent on push connections |
| `mist_push_uptime_seconds` | Gauge | Uptime of longest-running push connection |

Polled from MistServer's `push_list` API every 10 seconds.

**R2 pipeline health (per stream):**

| Metric | Type | Description |
|---|---|---|
| `r2_ffmpeg_up` | Gauge | 1 = `mist-hls-writer-*` service active |
| `r2_segment_lag_count` | Gauge | Local segments not yet in R2 |
| `r2_latest_segment_age_seconds` | Gauge | Age of most recent local segment |
| `r2_upload_errors_total` | Counter | Upload errors from seg-push service |

Polled every 5 seconds. Lag > 5 is warning; lag > 10 is critical. Segment age > 30s indicates ffmpeg has stopped writing.

### 6.3 Grafana Dashboard — MistServer Broadcast Quality

Dashboard `mist-bq` at `http://83.147.18.124:3000`. Panels:

1. Stream Up (stat, per stream)
2. Bitrate (timeseries, per stream)
3. CC Errors/min (timeseries, alert on > 0)
4. Push Active Connections (stat)
5. Push Bytes Sent (timeseries)
6. Push Uptime (stat)
7. R2 ffmpeg Writer Up (stat, green/red)
8. R2 Segment Lag (timeseries, warn >5, crit >10)
9. R2 Latest Segment Age (timeseries, warn >10s, crit >30s)
10. R2 Upload Errors/min (timeseries, alert on any)

---

## 7. Linux Services

Every persistent process on the VPS is a systemd unit. All units are installed and enabled by their respective Terraform provisioner — no manual setup is required. The table below is the authoritative list.

### 7.1 Streaming VPS Services

| Unit name | Type | Binary / script | Port(s) | Restart | Provisioned by |
|---|---|---|---|---|---|
| `mistserver` | simple | `/usr/bin/MistController` | 8080 (HTTP), 4242 (API), 1234+1235 (SRT) | always | `module.mistserver` → `mistserver.sh` |
| `mist-hls-writer-geo-ent` | simple | `/usr/local/bin/mist-hls-writer-geo-ent.sh` → `ffmpeg` | — | always, 3s | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `mist-hls-writer-geo-news` | simple | `/usr/local/bin/mist-hls-writer-geo-news.sh` → `ffmpeg` | — | always, 3s | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `mist-seg-push-geo-ent` | simple | `/usr/bin/python3 /usr/local/bin/mist-seg-push-geo-ent.py` | — | always, 2s | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `mist-seg-push-geo-news` | simple | `/usr/bin/python3 /usr/local/bin/mist-seg-push-geo-news.py` | — | always, 2s | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `mist-r2-cleanup-geo-ent.timer` | timer | triggers `.service` below | — | OnUnitActiveSec=30min | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `mist-r2-cleanup-geo-ent.service` | oneshot | `rclone delete` | — | — | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `mist-r2-cleanup-geo-news.timer` | timer | triggers `.service` below | — | OnUnitActiveSec=30min | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `mist-r2-cleanup-geo-news.service` | oneshot | `rclone delete` | — | — | `null_resource.mistserver_r2_push` → `mistserver-r2-push.sh` |
| `tsduck-exporter` | simple | `/usr/bin/python3 /usr/local/bin/tsduck-exporter.py` | 9101 | always, 5s | `module.mistserver` → `null_resource.provision_exporter` → `tsduck-exporter.sh` |
| `nginx` | forking | `/usr/sbin/nginx` | 80 | always | `module.nginx` → `nginx.sh` |

**Stream-per-service naming:** Stream names use `+` (e.g. `geo+ent`). Systemd unit names replace all non-alphanumeric characters with `-` → `geo-ent`, `geo-news`. The safe name is derived once in `mistserver-r2-push.sh` as `SAFE_NAME="${STREAM_NAME//[^a-zA-Z0-9]/-}"`.

**`After=` dependencies:**
- `mist-hls-writer-*` → `mistserver.service` (waits for MistServer HTTP port to be ready)
- `mist-seg-push-*` → `mist-hls-writer-*.service` (waits for first segments to appear)
- `tsduck-exporter` → `mistserver.service` (connects to SRT output ports)

### 7.2 Monitoring VPS Services

| Unit name | Type | Binary / script | Port(s) | Restart | Provisioned by |
|---|---|---|---|---|---|
| `prometheus` | simple | `/usr/bin/prometheus` | 9090 | always | `module.monitoring` → `monitoring.sh` |
| `grafana-server` | simple | `/usr/sbin/grafana-server` | 3000 | always | `module.monitoring` → `monitoring.sh` |
| `pocketbase` | simple | `/opt/pocketbase/pocketbase serve` | 8090 (localhost only) | always, 5s | `module.pocketbase` → `pocketbase.sh` |
| `nginx` | forking | `/usr/sbin/nginx` | 80 | always | `module.nginx` → `nginx.sh` |

### 7.3 Terraform Provisioning Map

All services are installed and managed via `null_resource` provisioners using SSH remote-exec. None use cloud-init or configuration management tools. The mapping from Terraform resource to shell script to systemd unit(s):

```
main.tf
├── module.mistserver         (modules/mistserver/main.tf)
│   ├── null_resource.provision
│   │   └── mistserver.sh           → installs MistServer
│   │                                  enables: mistserver.service
│   └── null_resource.provision_exporter
│       └── tsduck-exporter.sh      → builds TSduck from source (~10 min, once only)
│                                      enables: tsduck-exporter.service
│
├── null_resource.mistserver_r2_push  (main.tf — runs per stream_name)
│   └── mistserver-r2-push.sh       → installs ffmpeg, boto3
│                                      enables (per stream):
│                                        mist-hls-writer-{safe}.service
│                                        mist-seg-push-{safe}.service
│                                        mist-r2-cleanup-{safe}.timer
│                                        mist-r2-cleanup-{safe}.service
│
├── module.monitoring         (modules/monitoring/main.tf)
│   └── monitoring.sh               → installs Prometheus + Grafana
│                                      enables: prometheus.service
│                                               grafana-server.service
│
├── module.pocketbase         (modules/pocketbase/main.tf)
│   └── pocketbase.sh               → installs PocketBase binary
│                                      enables: pocketbase.service
│                                      bootstraps: superadmin, collections
│                                      deploys:  /var/www/onboard/index.html
│
└── module.nginx              (modules/nginx/main.tf — per unique VPS IP)
    └── nginx.sh                    → installs nginx
                                      enables: nginx.service
                                      configures sites (from var.nginx_sites):
                                        play.castology.tv    → :8080
                                        monitoring.castology.tv → :3000
                                        onboard.castology.tv → :8090 + /var/www/onboard
```

### 7.4 Re-provision Triggers

Each `null_resource` has a `triggers` block. Terraform re-runs the provisioner only when a trigger value changes. This prevents re-running the 10-minute TSduck build on every `terraform apply`.

| Resource | Triggers re-provision when... |
|---|---|
| `module.mistserver / null_resource.provision` | `mistserver.sh` changes, VPS IP changes, Prometheus passphrase changes |
| `module.mistserver / null_resource.provision_exporter` | `tsduck-exporter.sh` changes, `tsduck-exporter.py` changes, port config changes |
| `module.mistserver / null_resource.provision_srt_auth` | `mist-srt-auth.sh` changes, PocketBase email/password changes |
| `null_resource.mistserver_r2_push` | `mistserver-r2-push.sh` changes, R2 endpoint/bucket/key changes, stream list changes |
| `module.monitoring / null_resource.provision` | `monitoring.sh` changes, scrape IP changes |
| `module.pocketbase / null_resource.provision` | `pocketbase.sh` changes, admin email changes |
| `module.nginx / null_resource.provision` | `nginx.sh` changes (per unique VPS IP) |

### 7.5 Service Configuration Files on Disk

Files written to the VPS outside of systemd unit files:

| Path | Written by | Purpose |
|---|---|---|
| `/etc/mistserver.conf` | `mistserver.sh` (Python inline) | MistServer protocols, stream config, Prometheus passphrase |
| `/etc/mist-auth.env` | `mistserver` module `provision_srt_auth` | PocketBase credentials for `mist-srt-auth.sh` (chmod 600) |
| `/opt/mist-scripts/mist-srt-auth.sh` | `mistserver` module `provision_srt_auth` | PLAY_REWRITE trigger: validates operator token + IP |
| `/etc/tsduck-exporter.env` | `tsduck-exporter.sh` | `STREAMS_JSON`, `EXPORTER_PORT`, `MIST_API_PORT` — read by `tsduck-exporter.service` via `EnvironmentFile=` |
| `/etc/prometheus/prometheus.yml` | `monitoring.sh` | Scrape targets (MistServer + tsduck-exporter) |
| `/root/.config/rclone/rclone.conf` | `mistserver-r2-push.sh` | R2 credentials for cleanup timer only |
| `/usr/local/bin/mist-hls-writer-{safe}.sh` | `mistserver-r2-push.sh` | Wrapper: resolves sub-playlist URL, strips token, execs ffmpeg |
| `/usr/local/bin/mist-seg-push-{safe}.py` | `mistserver-r2-push.sh` | boto3 parallel uploader (segments + playlist) |
| `/usr/local/bin/tsduck-exporter.py` | `tsduck-exporter.sh` | Prometheus exporter (copied from `/tmp/` uploaded by Terraform) |
| `/var/www/onboard/index.html` | `pocketbase.sh` | Static operator portal SPA |
| `/opt/pocketbase/` | `pocketbase.sh` | PocketBase binary + data directory |
| `/var/lib/mist-hls/{stream}/` | `mistserver-r2-push.sh` (mkdir) | HLS segment working directory |

---

## 9. TSduck Architecture

TSduck (`tsp`) connects to MistServer's SRT output ports (1236, 1238) as a caller. One `tsp` process per stream, running in a dedicated thread, reconnecting automatically on disconnect.

```
tsp --realtime
  -I srt --caller 127.0.0.1:{port} --streamid {name} --latency 500
  -P continuity --json-line=CC:
  -P bitrate_monitor --periodic-bitrate 5 --json-line=BR:
  -O drop
```

Output is piped to the exporter which parses `CC:{...}` and `BR:{...}` JSON lines. TSduck is built from source (no distro package for the SRT-enabled build); the build runs once and is idempotent — subsequent Terraform applies skip the 10-minute cmake build if `tsp` is already in PATH.

The TSduck exporter is provisioned independently from MistServer (`null_resource.provision_exporter`) so that changes to the Python exporter do not re-trigger the TSduck build.

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

### 10.4 No Operator Token Rotation

Operator `token_key` values in PocketBase are static. There is no token expiry or audit log. Revoking an operator requires setting `active=false` on their `channel_group` and `cable_operators` records. The auth script cache TTL is 0 (no caching) so revocation takes effect on the next connection attempt.

### 10.5 HLS Auth Tied to MistServer Session Token

For HLS connections, sub-playlist and segment requests use MistServer's internal `?tkn=` session token, not the operator token. The `mist-srt-auth.sh` script passes `?tkn=` requests through without re-validating against PocketBase. If an operator's IP is removed from `allowed_ips`, their existing HLS session continues until the `tkn` expires. New connections will be denied immediately.

### 10.5 Grafana Not Behind Auth Proxy

Grafana on port 3000 is accessible from `83.147.18.124/32` only (firewall rule). There is no nginx proxy or TLS in front of it. Suitable for internal use; not suitable for external access without adding nginx + Let's Encrypt.

---

## 11. Operational Runbook

### Stream is down (VLC returns 404 or stops playing)

1. Check `r2_ffmpeg_up` in Grafana — if 0, `systemctl restart mist-hls-writer-{safe}`
2. Check `r2_segment_lag_count` — if rising, check `journalctl -u mist-seg-push-{safe} -n 50`
3. Check `tsduck_stream_up` — if 0, upstream encoder is not pushing SRT
4. Check CC error rate — if spiking, upstream is dropping packets (encoder/network issue)

### Re-provision after config change

```bash
# Full reprovisioning
terraform apply

# Exporter only (avoids 10-min TSduck build if already installed)
terraform apply -target=module.mistserver

# R2 push pipeline only
terraform apply -target=null_resource.mistserver_r2_push
```

### Operator denied — auth debugging

```bash
# Watch auth decisions in real time
journalctl -t mist-srt-auth -f

# Common DENY reasons:
# DENY: no token in '...'          → streamid missing /TOKEN or ?token= param
# DENY: no active channel_group    → token not in PocketBase or active=false
# DENY: stream '...' not in group  → stream not listed in group's channels JSON
# DENY: IP x.x.x.x not in allowed_ips → source IP not registered for this group
# DENY: no active cable_operator   → operator record missing or active=false
# ERROR: PocketBase auth failed    → check /etc/mist-auth.env credentials
```

### Add an operator (SRT + HLS)

1. Create `channel_group` in PocketBase with `token_key`, `channels`, `allowed_ips`, `active=true`
2. Create `cable_operators` record with `group_id` linking to the group
3. Add token to Cloudflare KV for `/live/` R2 delivery:
```bash
curl -X PUT "https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/storage/kv/namespaces/{KV_ID}/values/{token}" \
  -H "Authorization: Bearer {CF_TOKEN}" \
  -d '{"broadcaster":"geo","channels":[{"name":"Geo News","stream":"geo+news"}]}'
```

### Check upload pipeline manually

```bash
# On streaming VPS
journalctl -u mist-seg-push-geo-ent -f
journalctl -u mist-hls-writer-geo-ent -f
ls -lth /var/lib/mist-hls/geo+ent/ | head -5
curl -s localhost:9101/metrics | grep r2_
```

---

## 12. Troubleshooting

### 12.1 SRT Operator Connection Denied

**Symptom:** ffplay/VLC reports `I/O error` immediately on connect.

**Check auth log:**
```bash
journalctl -t mist-srt-auth -f
```

| Log message | Cause | Fix |
|---|---|---|
| `DENY: no token in 'geo+news'` | Streamid missing `/TOKEN` | Use `streamid=geo+news/TOKEN` |
| `DENY: no active channel_group for token=X` | Token not in PocketBase or `active=false` | Check PocketBase `channel_groups` |
| `DENY: stream 'geo+news' not in group` | Stream not in operator's `channels` list | Add stream to `channel_groups.channels` |
| `DENY: IP x.x.x.x not in allowed_ips` | Source IP not registered | Add IP to `channel_groups.allowed_ips` |
| `DENY: no active cable_operator` | No active operator record for this group | Check `cable_operators` collection |
| `ERROR: PocketBase auth failed` | Wrong credentials in `/etc/mist-auth.env` | Update `/etc/mist-auth.env` on VPS |

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
- Token value in KV is malformed JSON — must be `{"broadcaster":"geo","channels":[...]}`

**For `/hls/` path** (MistServer direct):
- Check auth log: `journalctl -t mist-srt-auth -f`
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
journalctl -u mist-hls-writer-geo-news -f
journalctl -u mist-seg-push-geo-news -f

# Check latest segment age
ls -lth /var/lib/mist-hls/geo+news/ | head -5

# Check Prometheus metrics
curl -s localhost:9101/metrics | grep r2_
```

- `r2_ffmpeg_up 0` → `systemctl restart mist-hls-writer-geo-news`
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
| Automated operator token issuance via PocketBase | Medium | Portal exists; integration pending |
| Grafana alerts → email/Slack | Medium | SMTP config pending |
| Multi-bitrate ladder in MistServer | Low | Requires MistServer transcoding (CPU cost) |
| Segment cleanup on pipeline restart | Low | Old segments persist on disk until 2h rclone cleanup |
| Move monitoring to separate VPS | Low | tfvars change + `terraform apply` only |
