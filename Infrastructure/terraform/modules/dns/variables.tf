variable "streaming_ip" {
  description = "Public IP of the streaming VPS"
  type        = string
}

variable "monitoring_ip" {
  description = "Public IP of the monitoring VPS"
  type        = string
}

variable "srt_ingest_port" {
  description = "SRT ingest port (used in DNS record comment)"
  type        = number
  default     = 1235
}

variable "srt_output_ports" {
  description = "SRT output ports (used in DNS record comment)"
  type        = list(number)
  default     = [1236, 1238]
}
