variable "vps_ip" {
  description = "Public IP of the VPS to protect"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Local path to SSH private key"
  type        = string
}

variable "allow_tcp" {
  description = "TCP ports open to all (e.g. [22, 80])"
  type        = list(number)
  default     = []
}

variable "allow_udp" {
  description = "UDP ports open to all (e.g. [1236, 1238])"
  type        = list(number)
  default     = []
}

variable "allow_tcp_from" {
  description = "TCP ports restricted to specific source CIDRs. Map of port => list of CIDRs."
  type        = map(list(string))
  default     = {}
}

variable "allow_udp_from" {
  description = "UDP ports restricted to specific source CIDRs. Map of port => list of CIDRs."
  type        = map(list(string))
  default     = {}
}
