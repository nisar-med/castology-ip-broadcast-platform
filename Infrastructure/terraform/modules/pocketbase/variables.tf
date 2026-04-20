variable "vps_ip" {
  description = "Public IP of the VPS to install PocketBase on"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Local path to SSH private key"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "admin_email" {
  description = "PocketBase superadmin email"
  type        = string
}

variable "admin_password" {
  description = "PocketBase superadmin password"
  type        = string
  sensitive   = true
}

variable "streaming_public_ip" {
  description = "Public IP of the streaming VPS (embedded in operator SRT URIs)"
  type        = string
}

variable "srt_ingest_port" {
  description = "SRT ingest port on the streaming VPS"
  type        = number
  default     = 1235
}

variable "srt_output_ports" {
  description = "SRT output ports on the streaming VPS"
  type        = list(number)
  default     = [1236, 1238]
}
