# ---------------------------------------------------------------------------
# Cloudflare
# ---------------------------------------------------------------------------
variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS:Edit permission for castology.tv"
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------
variable "ssh_private_key_path" {
  description = "Local path to SSH private key used by Terraform provisioners"
  type        = string
  default     = "~/.ssh/id_rsa"
}

# ---------------------------------------------------------------------------
# VPS map
# Keys are arbitrary labels (e.g. "streaming", "monitoring").
# Use the same IP for multiple entries to share a single VPS.
# ---------------------------------------------------------------------------
variable "vps" {
  description = "Map of VPS definitions. Each entry declares an IP, nginx sites, and firewall rules."
  type = map(object({
    ip          = string
    nginx_sites = list(string)
    firewall = object({
      allow_tcp      = list(number)
      allow_udp      = list(number)
      allow_tcp_from = map(list(string))
      allow_udp_from = map(list(string))
    })
  }))
}

# ---------------------------------------------------------------------------
# Service routing — which VPS key runs each service
# ---------------------------------------------------------------------------
variable "mistserver_vps" {
  description = "Key in var.vps where MistServer runs"
  type        = string
  default     = "streaming"
}

variable "monitoring_vps" {
  description = "Key in var.vps where Prometheus + Grafana + PocketBase run"
  type        = string
  default     = "monitoring"
}

# ---------------------------------------------------------------------------
# Ports
# ---------------------------------------------------------------------------
variable "srt_ingest_port" {
  description = "UDP port MistServer listens on for SRT ingest"
  type        = number
  default     = 1235
}

variable "srt_output_ports" {
  description = "UDP ports MistServer uses for SRT output"
  type        = list(number)
  default     = [1236, 1238]
}

variable "mist_api_port" {
  description = "MistServer HTTP API port"
  type        = number
  default     = 4242
}

variable "exporter_port" {
  description = "TSduck Prometheus exporter port"
  type        = number
  default     = 9101
}

variable "grafana_port" {
  description = "Grafana HTTP port"
  type        = number
  default     = 3000
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
variable "prometheus_passphrase" {
  description = "Passphrase for the MistServer Prometheus metrics endpoint"
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
}

variable "pocketbase_admin_email" {
  description = "PocketBase superadmin email"
  type        = string
}

variable "pocketbase_admin_password" {
  description = "PocketBase superadmin password"
  type        = string
  sensitive   = true
}
