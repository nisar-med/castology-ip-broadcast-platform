# ---------------------------------------------------------------------------
# Castology IP Broadcast Platform — Terraform
#
# Manages cloud/network infrastructure only. Service provisioning is handled
# by Docker Compose (Infrastructure/docker/).
#
# Resources managed here:
#   - Cloudflare DNS
#   - Cloudflare R2 bucket
#   - Cloudflare Worker + KV namespace
#   - VPS firewall (ufw)
#
# Apply individual modules:
#   terraform apply -target=module.dns
#   terraform apply -target=module.firewall
#   terraform apply -target=module.r2
#   terraform apply -target=module.worker
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
module "firewall" {
  source = "./modules/firewall"

  vps_ip               = var.vps_ip
  ssh_private_key_path = var.ssh_private_key_path
  allow_tcp            = [22]
  allow_udp            = concat([var.srt_ingest_port], var.srt_output_ports)
  allow_tcp_from = {
    "4242" = ["127.0.0.1/32"]  # MistServer API — loopback only
    "9101" = ["127.0.0.1/32"]  # Prometheus exporter — loopback only
    "3000" = ["127.0.0.1/32"]  # Grafana — loopback only
  }
}

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
