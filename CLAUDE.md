# VPS SSH access
ssh root@51.254.136.32

# Deployment
Make changes locally, then deploy to VPS:

```bash
bash Infrastructure/docker/deploy.sh 51.254.136.32
```

Or for incremental updates (no full redeploy):
```bash
# Sync files
rsync -az --delete \
  --exclude='.git' --exclude='Infrastructure/docker/.env' \
  --exclude='Infrastructure/terraform/.terraform' --exclude='Infrastructure/terraform/terraform.tfstate*' \
  --exclude='__pycache__' --exclude='*.pyc' \
  -e "ssh -o StrictHostKeyChecking=no" \
  "Infrastructure/" root@51.254.136.32:/opt/castology/Infrastructure/

# Rebuild and restart a specific service
ssh root@51.254.136.32 "cd /opt/castology/Infrastructure/docker && docker compose build <service> && docker compose up -d <service>"
```

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
