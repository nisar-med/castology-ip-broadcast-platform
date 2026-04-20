resource "null_resource" "provision" {
  triggers = {
    script     = filemd5("${path.module}/../../scripts/monitoring.sh")
    vps_ip     = var.vps_ip
    scrape_ip  = var.scrape_ip
    passphrase = var.prometheus_passphrase
  }

  connection {
    type        = "ssh"
    host        = var.vps_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "20m"
  }

  provisioner "file" {
    source      = "${path.module}/../../scripts/monitoring.sh"
    destination = "/tmp/monitoring.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/monitoring.sh",
      join(" ", [
        "STREAMING_PRIVATE_IP=${var.scrape_ip}",
        "PROMETHEUS_PASSPHRASE=${var.prometheus_passphrase}",
        "GRAFANA_ADMIN_PASSWORD=${var.grafana_admin_password}",
        "MIST_API_PORT=${var.mist_api_port}",
        "EXPORTER_PORT=${var.exporter_port}",
        "GRAFANA_PORT=${var.grafana_port}",
        "/tmp/monitoring.sh",
      ]),
    ]
  }
}
