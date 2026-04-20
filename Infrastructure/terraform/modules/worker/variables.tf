variable "account_id" {
  description = "Cloudflare account ID"
  type        = string
}

variable "r2_bucket_name" {
  description = "Name of the R2 bucket containing HLS segments"
  type        = string
}
