variable "account_id" {
  description = "Cloudflare account ID"
  type        = string
}

variable "bucket_name" {
  description = "R2 bucket name for HLS segments"
  type        = string
  default     = "castology-hls"
}
