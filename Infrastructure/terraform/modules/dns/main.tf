# ---------------------------------------------------------------------------
# Cloudflare DNS — castology.tv
#
# Proxied (orange cloud) — Cloudflare terminates HTTPS, nginx routes by Host:
#   play.castology.tv        → streaming VPS  → MistServer HLS :8080
#   mist.castology.tv        → streaming VPS  → MistServer API :4242
#   monitoring.castology.tv  → monitoring VPS → Grafana :3000
#   onboard.castology.tv     → monitoring VPS → PocketBase :8090
#
# DNS only (grey cloud) — SRT/UDP bypasses Cloudflare:
#   ingest.castology.tv      → streaming VPS  → SRT ingest :${var.srt_ingest_port}
#   stream.castology.tv      → streaming VPS  → SRT output
# ---------------------------------------------------------------------------

data "cloudflare_zone" "castology_tv" {
  name = "castology.tv"
}

locals {
  proxied_records = {
    play    = { ip = var.streaming_ip, comment = "MistServer HLS/MPEG-TS player" }
    onboard = { ip = var.monitoring_ip, comment = "Broadcaster onboarding portal" }
  }

  dns_only_records = {
    ingest = { ip = var.streaming_ip, comment = "SRT ingest for broadcasters (UDP ${var.srt_ingest_port})" }
    stream = { ip = var.streaming_ip, comment = "SRT output for affiliates (UDP ${join("/", [for p in var.srt_output_ports : tostring(p)])})" }
  }
}

resource "cloudflare_record" "proxied" {
  for_each = local.proxied_records

  zone_id = data.cloudflare_zone.castology_tv.id
  name    = each.key
  type    = "A"
  content = each.value.ip
  proxied = true
  ttl     = 1
  comment = each.value.comment
}

resource "cloudflare_record" "dns_only" {
  for_each = local.dns_only_records

  zone_id = data.cloudflare_zone.castology_tv.id
  name    = each.key
  type    = "A"
  content = each.value.ip
  proxied = false
  ttl     = 300
  comment = each.value.comment
}
