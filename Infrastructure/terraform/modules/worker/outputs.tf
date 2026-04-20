output "kv_namespace_id" {
  description = "KV namespace ID for operator tokens — used by PocketBase onboarding"
  value       = cloudflare_workers_kv_namespace.operator_tokens.id
}

output "play_url" {
  value = "https://play.castology.tv"
}
