# ---------------------------------------------------------------------------
# Cloudflare Worker — HLS delivery for play.castology.tv
#
# Sits in front of R2: validates operator token (KV lookup), fetches segment,
# returns with appropriate Cache-Control so Cloudflare CDN caches segments.
# ---------------------------------------------------------------------------

data "cloudflare_zone" "castology_tv" {
  name = "castology.tv"
}

resource "cloudflare_workers_script" "hls_delivery" {
  account_id = var.account_id
  name       = "castology-hls-delivery"
  content    = file("${path.module}/src/index.js")
  module     = true

  r2_bucket_binding {
    name        = "HLS_BUCKET"
    bucket_name = var.r2_bucket_name
  }

  kv_namespace_binding {
    name         = "OPERATOR_TOKENS"
    namespace_id = cloudflare_workers_kv_namespace.operator_tokens.id
  }


}

# KV namespace — key=token, value=operator_id
resource "cloudflare_workers_kv_namespace" "operator_tokens" {
  account_id = var.account_id
  title      = "castology-operator-tokens"
}

# Route: play.castology.tv/* → Worker
resource "cloudflare_workers_route" "play" {
  zone_id     = data.cloudflare_zone.castology_tv.id
  pattern     = "play.castology.tv/*"
  script_name = cloudflare_workers_script.hls_delivery.name
}

# Route: play.castology.tv/hls/* → no worker (bypass to origin, MistServer handles auth)
resource "cloudflare_workers_route" "hls_bypass" {
  zone_id = data.cloudflare_zone.castology_tv.id
  pattern = "play.castology.tv/hls/*"
}
