output "api_port" {
  description = "MistServer HTTP API port"
  value       = var.api_port
}

output "exporter_port" {
  description = "TSduck Prometheus exporter port"
  value       = var.exporter_port
}

output "srt_ingest_port" {
  description = "SRT ingest port"
  value       = var.srt_ingest_port
}

output "srt_output_ports" {
  description = "SRT output ports"
  value       = var.srt_output_ports
}
