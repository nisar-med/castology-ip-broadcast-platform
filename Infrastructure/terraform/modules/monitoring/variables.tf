variable "vps_ip" {
  description = "Public IP of the VPS to provision Prometheus + Grafana on"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Local path to SSH private key"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "scrape_ip" {
  description = "IP of the MistServer VPS that Prometheus will scrape (private IP if available)"
  type        = string
}

variable "mist_api_port" {
  description = "MistServer HTTP API port on the scrape target"
  type        = number
  default     = 4242
}

variable "exporter_port" {
  description = "TSduck Prometheus exporter port on the scrape target"
  type        = number
  default     = 9101
}

variable "prometheus_passphrase" {
  description = "Passphrase used as the MistServer Prometheus metrics URL path"
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
}

variable "grafana_port" {
  description = "Grafana HTTP port"
  type        = number
  default     = 3000
}
