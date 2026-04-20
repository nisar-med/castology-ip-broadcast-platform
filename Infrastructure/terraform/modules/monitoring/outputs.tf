output "grafana_url" {
  description = "Grafana dashboard URL (direct, pre-nginx)"
  value       = "http://${var.vps_ip}:${var.grafana_port}"
}

output "grafana_port" {
  description = "Grafana HTTP port"
  value       = var.grafana_port
}
