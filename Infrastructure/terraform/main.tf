# ---------------------------------------------------------------------------
# Castology IP Broadcast Platform — Terraform
#
# Manages cloud resources only. Service provisioning, firewall policy, and
# optional Tailscale admin access are handled by Infrastructure/docker/.
#
# Resources managed here:
#   - Cloudflare DNS
#   - Cloudflare R2 bucket
#   - Cloudflare Worker + KV namespace
#
# Apply individual modules:
#   terraform apply -target=module.dns
#   terraform apply -target=module.r2
#   terraform apply -target=module.worker
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Cloudflare DNS
# ---------------------------------------------------------------------------
module "dns" {
  source = "./modules/dns"

  streaming_ip     = var.vps_ip
  monitoring_ip    = var.vps_ip
  srt_ingest_port  = var.srt_ingest_port
  srt_output_ports = var.srt_output_ports
}

# ---------------------------------------------------------------------------
# R2 bucket — HLS segment storage
# ---------------------------------------------------------------------------
module "r2" {
  source = "./modules/r2"

  account_id  = var.cloudflare_account_id
  bucket_name = var.r2_bucket_name
}

# ---------------------------------------------------------------------------
# Cloudflare Worker — HLS delivery via play.castology.tv
# ---------------------------------------------------------------------------
module "worker" {
  source = "./modules/worker"

  account_id     = var.cloudflare_account_id
  r2_bucket_name = module.r2.bucket_name
  depends_on     = [module.r2]
}
