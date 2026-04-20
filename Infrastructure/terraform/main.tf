# ---------------------------------------------------------------------------
# Castology IP Broadcast Platform
#
# var.vps is a map of VPS definitions. Each entry declares an IP, nginx
# sites, and firewall rules. Use the same IP for multiple entries to share
# a single VPS — nginx and firewall modules use for_each over unique IPs
# so no duplicate resources are created.
#
# Apply individual modules:
#   terraform apply -target=module.mistserver
#   terraform apply -target=module.monitoring
#   terraform apply -target=module.nginx
#   terraform apply -target=module.firewall
#   terraform apply -target=module.pocketbase
#   terraform apply -target=module.dns
# ---------------------------------------------------------------------------

locals {
  # Deduplicate VPS entries by IP so nginx and firewall run once per unique IP.
  # Merges nginx_sites and firewall ports across all entries sharing the same IP.
  unique_vps = {
    for ip, entries in {
      for k, v in var.vps : v.ip => v...
    } : ip => {
      ip          = ip
      nginx_sites = distinct(flatten([for e in entries : e.nginx_sites]))
      firewall = {
        allow_tcp      = distinct(flatten([for e in entries : e.firewall.allow_tcp]))
        allow_udp      = distinct(flatten([for e in entries : e.firewall.allow_udp]))
        allow_tcp_from = merge([for e in entries : e.firewall.allow_tcp_from]...)
        allow_udp_from = merge([for e in entries : e.firewall.allow_udp_from]...)
      }
    }
  }
}

# ---------------------------------------------------------------------------
# MistServer + TSduck exporter
# ---------------------------------------------------------------------------
module "mistserver" {
  source = "./modules/mistserver"

  vps_ip                = var.vps[var.mistserver_vps].ip
  ssh_private_key_path  = var.ssh_private_key_path
  prometheus_passphrase = var.prometheus_passphrase
  srt_ingest_port       = var.srt_ingest_port
  srt_output_ports      = var.srt_output_ports
  api_port              = var.mist_api_port
  exporter_port         = var.exporter_port
}

# ---------------------------------------------------------------------------
# Prometheus + Grafana
# ---------------------------------------------------------------------------
module "monitoring" {
  source = "./modules/monitoring"

  vps_ip                 = var.vps[var.monitoring_vps].ip
  ssh_private_key_path   = var.ssh_private_key_path
  scrape_ip              = var.vps[var.mistserver_vps].ip
  mist_api_port          = var.mist_api_port
  exporter_port          = var.exporter_port
  prometheus_passphrase  = var.prometheus_passphrase
  grafana_admin_password = var.grafana_admin_password
  grafana_port           = var.grafana_port

  depends_on = [module.mistserver]
}

# ---------------------------------------------------------------------------
# PocketBase + operator portal
# ---------------------------------------------------------------------------
module "pocketbase" {
  source = "./modules/pocketbase"

  vps_ip               = var.vps[var.monitoring_vps].ip
  ssh_private_key_path = var.ssh_private_key_path
  admin_email          = var.pocketbase_admin_email
  admin_password       = var.pocketbase_admin_password
  streaming_public_ip  = var.vps[var.mistserver_vps].ip
  srt_ingest_port      = var.srt_ingest_port
  srt_output_ports     = var.srt_output_ports

  depends_on = [module.nginx]
}

# ---------------------------------------------------------------------------
# nginx — one instance per unique IP, sites merged from all VPS entries
# ---------------------------------------------------------------------------
module "nginx" {
  source   = "./modules/nginx"
  for_each = local.unique_vps

  vps_ip               = each.value.ip
  ssh_private_key_path = var.ssh_private_key_path
  sites                = each.value.nginx_sites

  depends_on = [module.mistserver, module.monitoring]
}

# ---------------------------------------------------------------------------
# Firewall — one instance per unique IP, ports merged from all VPS entries
# ---------------------------------------------------------------------------
module "firewall" {
  source   = "./modules/firewall"
  for_each = local.unique_vps

  vps_ip               = each.value.ip
  ssh_private_key_path = var.ssh_private_key_path
  allow_tcp            = each.value.firewall.allow_tcp
  allow_udp            = each.value.firewall.allow_udp
  allow_tcp_from       = each.value.firewall.allow_tcp_from
  allow_udp_from       = each.value.firewall.allow_udp_from
}

# ---------------------------------------------------------------------------
# Cloudflare DNS
# ---------------------------------------------------------------------------
module "dns" {
  source = "./modules/dns"

  streaming_ip     = var.vps[var.mistserver_vps].ip
  monitoring_ip    = var.vps[var.monitoring_vps].ip
  srt_ingest_port  = var.srt_ingest_port
  srt_output_ports = var.srt_output_ports
}
