output "vps_ip" {
  description = "IP of the VPS running all services"
  value       = var.vps_ip
}

output "play_url" {
  value = module.dns.play_url
}

output "srt_ingest" {
  value = "srt://${module.dns.ingest_host}:${var.srt_ingest_port}"
}

output "hls_play_url" {
  value = "https://play.castology.tv/live/{stream-name}/index.m3u8"
}

output "r2_bucket" {
  value = module.r2.bucket_name
}

output "operator_tokens_kv_namespace_id" {
  description = "KV namespace ID for operator tokens"
  value       = module.worker.kv_namespace_id
}
