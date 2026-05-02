# ---------------------------------------------------------------------------
# Cloudflare
# ---------------------------------------------------------------------------
variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS:Edit + Workers:Edit + R2:Edit permissions"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (from dashboard URL or account overview)"
  type        = string
}

# ---------------------------------------------------------------------------
# R2 bucket
# ---------------------------------------------------------------------------
variable "r2_bucket_name" {
  description = "R2 bucket name for HLS segments"
  type        = string
  default     = "castology-hls"
}

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------
variable "ssh_private_key_path" {
  description = "Local path to SSH private key used by Terraform provisioners"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

# ---------------------------------------------------------------------------
# VPS
# ---------------------------------------------------------------------------
variable "vps_ip" {
  description = "Public IP of the VPS running all services"
  type        = string
}

# ---------------------------------------------------------------------------
# Ports — used for firewall rules and DNS record comments
# ---------------------------------------------------------------------------
variable "srt_ingest_port" {
  description = "UDP port for SRT ingest"
  type        = number
  default     = 1235
}

variable "srt_output_ports" {
  description = "UDP ports for SRT output"
  type        = list(number)
  default     = [1234]
}
