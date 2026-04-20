locals {
  srt_output_csv = join(",", [for p in var.srt_output_ports : tostring(p)])
}

resource "null_resource" "provision" {
  triggers = {
    script       = filemd5("${path.module}/../../scripts/mistserver.sh")
    vps_ip       = var.vps_ip
    passphrase   = var.prometheus_passphrase
  }

  connection {
    type        = "ssh"
    host        = var.vps_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "30m"
  }

  provisioner "file" {
    source      = "${path.module}/../../scripts/mistserver.sh"
    destination = "/tmp/mistserver.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/mistserver.sh",
      join(" ", [
        "PROMETHEUS_PASSPHRASE=${var.prometheus_passphrase}",
        "SRT_INGEST_PORT=${var.srt_ingest_port}",
        "SRT_OUTPUT_PORTS=${local.srt_output_csv}",
        "MIST_API_PORT=${var.api_port}",
        "/tmp/mistserver.sh",
      ]),
    ]
  }
}

resource "null_resource" "provision_exporter" {
  triggers = {
    exporter_script  = filemd5("${path.module}/../../scripts/tsduck-exporter.sh")
    exporter_py      = filemd5("${path.module}/../../scripts/tsduck-exporter.py")
    vps_ip           = var.vps_ip
    srt_output_ports = local.srt_output_csv
    exporter_port    = var.exporter_port
    mist_api_port    = var.api_port
  }

  connection {
    type        = "ssh"
    host        = var.vps_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "30m"
  }

  provisioner "file" {
    source      = "${path.module}/../../scripts/tsduck-exporter.sh"
    destination = "/tmp/tsduck-exporter.sh"
  }

  provisioner "file" {
    source      = "${path.module}/../../scripts/tsduck-exporter.py"
    destination = "/tmp/tsduck-exporter.py"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/tsduck-exporter.sh",
      join(" ", [
        "SRT_OUTPUT_PORTS=${local.srt_output_csv}",
        "MIST_API_PORT=${var.api_port}",
        "EXPORTER_PORT=${var.exporter_port}",
        "/tmp/tsduck-exporter.sh",
      ]),
    ]
  }

  depends_on = [null_resource.provision]
}
