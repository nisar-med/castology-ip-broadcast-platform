# VPS SSH access
ssh root@51.254.136.32

# Deployment
**All deploys go through the GitHub Actions workflow (`.github/workflows/deploy.yml`),
not manual rsync/ssh.** This keeps `main`, the VPS git checkout at `/opt/castology`,
and CI in lockstep. Manual rsync leaves the server out of sync with git, and the
workflow's `git reset --hard origin/main` will later clobber any rsync-only state.

Standard flow:
1. Commit changes and push.
2. Open a PR into `main`. Merging to `main` triggers `deploy.yml` (incremental:
   `deploy-incremental.sh`, which SSHes in as `ubuntu`, `git reset --hard origin/main`,
   then `docker compose up -d --build`).
3. For a full rebuild (install Docker, write `.env` from `secrets.DOCKER_ENV`, run
   `deploy.sh`), trigger `deploy.yml` via `workflow_dispatch` with `full_deploy: true`.

The VPS is a git checkout at `/opt/castology` owned by `ubuntu`. Secrets live only
in the VPS `.env` and are re-injected into config at container start (e.g. the
`mistserver.conf` `RUNTIME_INJECTED` placeholder) — never commit injected values.

## Break-glass / first-time provisioning only
Manual `deploy.sh` is for bootstrapping a fresh VPS, not routine deploys:

```bash
bash Infrastructure/docker/deploy.sh 51.254.136.32
```

After `deploy.sh` on a fresh VPS, add the CI deploy public key to the `ubuntu`
user so the workflow can SSH in as `ubuntu`:

```bash
ssh-copy-id -i <ci-deploy-key>.pub ubuntu@51.254.136.32
# or manually append the key to /home/ubuntu/.ssh/authorized_keys
```

`deploy.sh` already handles `usermod -aG docker ubuntu` and chowning
`/opt/castology` to ubuntu. Also ensure `/opt/castology` is a git checkout
(`git init` + `git remote add origin <repo>` + `git fetch` + checkout `main`),
since `deploy-incremental.sh` does `git reset --hard origin/main` there.

# Infrastructure
- Terraform manages Cloudflare only: DNS, R2, Worker
  - `cd Infrastructure/terraform && terraform apply -target=module.dns`
- Docker Compose manages all services on the VPS
  - Services: mistserver, pocketbase, cast-exporter, prometheus, grafana, nginx

# Architecture
- SRT ingest: `srt://ingest.castology.tv:1235`
- HLS play: `https://play.castology.tv/live/{stream}/index.m3u8`
- SRT output: `srt://stream.castology.tv:1234`
- Admin UIs via SSH tunnel: `ssh -L 4242:localhost:4242 -L 8090:localhost:8090 -L 3000:localhost:3000 root@51.254.136.32`

# API Authentication
- Api auth requires double MD5 hash not single e.g. MD5(MD5(password) + challenge)