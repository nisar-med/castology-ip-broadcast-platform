variable "vps_ip" {
  description = "Public IP of the VPS to install nginx on"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Local path to SSH private key"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "sites" {
  description = "List of sites to enable: any combination of 'play', 'mist', 'monitoring', 'onboard'"
  type        = list(string)
  validation {
    condition     = length([for s in var.sites : s if !contains(["play", "mist", "monitoring", "onboard"], s)]) == 0
    error_message = "Each site must be one of: play, mist, monitoring, onboard"
  }
}
