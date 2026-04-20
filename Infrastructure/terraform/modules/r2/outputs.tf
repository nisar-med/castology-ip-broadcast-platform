output "bucket_name" {
  value = cloudflare_r2_bucket.hls.name
}

output "s3_endpoint" {
  description = "S3-compatible endpoint for MistServer push config"
  value       = "https://${var.account_id}.r2.cloudflarestorage.com"
}
