output "vps_ips" {
  description = "IP of each VPS entry"
  value       = { for k, v in var.vps : k => v.ip }
}

output "onboard_url" {
  value = module.dns.onboard_url
}

output "play_url" {
  value = module.dns.play_url
}

output "srt_ingest" {
  value = "srt://${module.dns.ingest_host}:${var.srt_ingest_port}"
}
