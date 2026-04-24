variable "vps_ip" {
  description = "Public IP of the VPS to provision MistServer on"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Local path to SSH private key"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "prometheus_passphrase" {
  description = "Passphrase used as the MistServer Prometheus metrics URL path"
  type        = string
  sensitive   = true
}

variable "srt_ingest_port" {
  description = "UDP port MistServer listens on for SRT ingest"
  type        = number
  default     = 1235
}

variable "srt_output_ports" {
  description = "UDP ports MistServer uses for SRT output to viewers"
  type        = list(number)
  default     = [1236, 1238]
}

variable "api_port" {
  description = "MistServer HTTP API port"
  type        = number
  default     = 4242
}

variable "exporter_port" {
  description = "TSduck Prometheus exporter port"
  type        = number
  default     = 9101
}

variable "stream_names" {
  description = "Stream names to monitor (e.g. [\"geo+news\", \"geo+ent\"])"
  type        = list(string)
  default     = ["geo+news", "geo+ent"]
}

variable "pb_email" {
  description = "PocketBase admin email for SRT auth"
  type        = string
  default     = "admin@castology.tv"
}

variable "pb_password" {
  description = "PocketBase admin password for SRT auth"
  type        = string
  sensitive   = true
}
