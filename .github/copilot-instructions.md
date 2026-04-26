# Castology IP Broadcast Platform

## Validation commands

This repo is primarily Terraform plus provisioning scripts.

- Terraform root: `cd Infrastructure/terraform`
- First-time setup: `terraform init`
- Format check: `terraform fmt -check -recursive`
- Validate config: `terraform validate`
- Preview changes: `terraform plan`
- Target a single component when iterating on one area:
  - `terraform apply -target=module.worker`
  - `terraform apply -target=module.mistserver`
  - `terraform apply -target=null_resource.mistserver_r2_push`
- Existing Python utility: `python3 tools/hls-loadtest.py --help`
- Focused load-test run: `python3 tools/hls-loadtest.py --operators 1 --duration 30 --stream geo+news --token <token>`

There is no in-repo automated test suite or per-test runner today. Targeted `terraform apply` is the normal narrow-scope validation path.

## High-level architecture

The main control plane is `Infrastructure/terraform/main.tf`. It wires Cloudflare resources and VPS provisioning together with Terraform modules plus `null_resource` + SSH `remote-exec` scripts. `local.unique_vps` deduplicates shared IPs, so nginx and firewall config are merged per unique server even when `streaming` and `monitoring` point at the same host.

MistServer is provisioned by `modules/mistserver` and `scripts/mistserver.sh`. It accepts SRT ingest on port `1235`, exposes HLS on `:8080`, and creates a wildcard `geo` push source so encoders can publish streams like `geo+news`. The same module also installs the Prometheus exporter and the `PLAY_REWRITE` auth hook in `scripts/mist-srt-auth.sh`.

Delivery has two distinct paths that must not be conflated:

- `play.castology.tv/live/*` is served by the Cloudflare Worker in `modules/worker/src/index.js`. It authenticates tokens from KV (`OPERATOR_TOKENS`), serves playlists and segments from R2, and rewrites playlist entries to append the caller token.
- `play.castology.tv/hls/*` intentionally bypasses the Worker and goes through nginx to MistServer origin. Authentication on that path happens inside MistServer through the `PLAY_REWRITE` trigger, not in the Worker.

The HLS-to-R2 pipeline is installed by `null_resource.mistserver_r2_push` via `scripts/mistserver-r2-push.sh`. For each stream it creates:

- an ffmpeg writer service that pulls MistServer HLS from localhost and writes segments to `/var/lib/mist-hls/{stream}/`
- a Python uploader service that reads `index.m3u8`, uploads new `.ts` segments and the playlist to R2 with boto3
- a cleanup service/timer that deletes old `.ts` objects from R2 and local disk

PocketBase is provisioned by `scripts/pocketbase.sh`. The current collections are `broadcasters` and `affiliates`. `affiliates` drives playout auth; `broadcasters` is used by monitoring/exporter logic.

## Script deployment paths

All scripts live in `Infrastructure/terraform/scripts/`. Terraform provisions them to the VPS at first deploy; after that, manual hotfixes use `scp` directly to the canonical path below.

All scripts deploy to `/usr/local/bin/` on the VPS. There is no `/opt/mist-scripts/`.

| Script | VPS path | Deployed by | Consumer |
|--------|----------|-------------|----------|
| `mist-exporter.py` | `/usr/local/bin/mist-exporter.py` | `mist-exporter.sh` (via `/tmp/`) | `mist-exporter.service` |
| `mist-srt-auth.sh` | `/usr/local/bin/mist-srt-auth.sh` | Terraform file provisioner | MistServer `PLAY_REWRITE` trigger |
| `mist-hls-writer-{stream}.sh` | `/usr/local/bin/mist-hls-writer-{safe}.sh` | `mistserver-r2-push.sh` | `mist-hls-writer-{safe}.service` |
| `mist-seg-push-{stream}.py` | `/usr/local/bin/mist-seg-push-{safe}.py` | `mistserver-r2-push.sh` | `mist-seg-push-{safe}.service` |
| `mist-r2-cleanup-{stream}.py` | `/usr/local/bin/mist-r2-cleanup-{safe}.py` | `mistserver-r2-push.sh` | `mist-r2-cleanup-{safe}.service` |

Hotfix deploy commands (run from `Infrastructure/terraform/scripts/`):
```bash
# Exporter
scp -i ~/.ssh/id_ed25519 mist-exporter.py root@83.147.18.124:/usr/local/bin/mist-exporter.py
ssh -i ~/.ssh/id_ed25519 root@83.147.18.124 systemctl restart mist-exporter

# Auth trigger (no restart needed — MistServer spawns it per-request)
scp -i ~/.ssh/id_ed25519 mist-srt-auth.sh root@83.147.18.124:/usr/local/bin/mist-srt-auth.sh
```

## Key conventions

- Stream names use `+` as a meaningful separator: `geo+news`, `geo+ent`. Do not replace `+` with `-` in real stream identifiers. Hyphenated names are only for derived safe names like systemd units (`mist-hls-writer-geo-news`).
- Keep the Worker path and MistServer-origin path aligned when changing auth or playback behavior. `/live/*` uses Cloudflare KV + R2; `/hls/*` uses MistServer `PLAY_REWRITE`.
- `mist-srt-auth.sh` restores `+` after MistServer decodes it as a space, reads affiliate tokens from `token_key`, and allows HLS sub-requests with `?tkn=` to pass through without revalidation. Preserve that behavior unless you are intentionally changing session handling.
- The ffmpeg wrapper in `mistserver-r2-push.sh` fetches the master playlist from localhost, extracts the track playlist, and strips MistServer's rotating `?tkn=` token before handing the URL to ffmpeg. That token-stripping is required so long-running ffmpeg jobs survive token rotation.
- Use PocketBase `affiliates` fields `token_key`, `streams`, `allowed_ips`, and `active` for viewer/operator authorization. Older notes about `channel_groups` or `cable_operators` are stale.
- Worker KV values are JSON shaped like `{"affiliate":"Name","streams":["geo+news","geo+ent"]}`. If you change token payload structure, update both the Worker and any onboarding/runbook docs.
- Provisioning is script-driven and idempotent. Most Terraform resources re-run because of `filemd5(...)` trigger changes in the shell/Python scripts, not because of cloud-init or image baking.
- Secrets belong in Terraform sensitive variables or deployed env files such as `/etc/mist-auth.env` and `/etc/mist-exporter.env`, never in checked-in scripts.
- MistServer API and PocketBase admin are intentionally accessed through SSH tunnels rather than public nginx routes. Preserve that access model unless the infrastructure design changes.
- The root Terraform defaults and `terraform.tfvars.example` still show `geo-news`/`geo-ent` in some places, but the active MistServer/Worker/auth flow uses `geo+...` names. Treat `+` naming as authoritative unless you are intentionally performing a repo-wide migration.

## Reference docs

- `docs/solution-design.md` is the best high-level system overview and operational runbook.
- `docs/mistserver-api.md` documents the MistServer API shapes used by `scripts/mist-exporter.py`.
