# ---------------------------------------------------------------------------
# R2 bucket for HLS segment storage
# MistServer writes segments here via S3-compatible API.
# The Cloudflare Worker reads from it and serves play.castology.tv.
#
# R2 API credentials (access key + secret) are created manually in the
# Cloudflare dashboard (R2 → Manage API tokens) and passed as variables.
# Terraform manages only the bucket itself.
# ---------------------------------------------------------------------------

resource "cloudflare_r2_bucket" "hls" {
  account_id = var.account_id
  name       = var.bucket_name
  location   = "WEUR"
}
