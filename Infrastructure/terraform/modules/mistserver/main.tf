locals {
  srt_output_csv = join(",", [for p in var.srt_output_ports : tostring(p)])
  streams_json   = jsonencode([for n in var.stream_names : { name = n }])
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
    exporter_script = filemd5("${path.module}/../../scripts/tsduck-exporter.sh")
    exporter_py     = filemd5("${path.module}/../../scripts/tsduck-exporter.py")
    vps_ip          = var.vps_ip
    stream_names    = join(",", var.stream_names)
    exporter_port   = var.exporter_port
    mist_api_port   = var.api_port
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

  # Write env file directly — avoids shell quoting issues with JSON
  provisioner "file" {
    content     = "STREAMS_JSON=${local.streams_json}\nEXPORTER_PORT=${var.exporter_port}\nMIST_API_PORT=${var.api_port}\n"
    destination = "/etc/tsduck-exporter.env"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/tsduck-exporter.sh",
      join(" ", [
        "MIST_API_PORT=${var.api_port}",
        "EXPORTER_PORT=${var.exporter_port}",
        "/tmp/tsduck-exporter.sh",
      ]),
    ]
  }

  depends_on = [null_resource.provision]
}

resource "null_resource" "provision_srt_auth" {
  triggers = {
    script      = filemd5("${path.module}/../../scripts/mist-srt-auth.sh")
    vps_ip      = var.vps_ip
    pb_email    = var.pb_email
    pb_password = var.pb_password
  }

  connection {
    type        = "ssh"
    host        = var.vps_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p /opt/mist-scripts"]
  }

  provisioner "file" {
    source      = "${path.module}/../../scripts/mist-srt-auth.sh"
    destination = "/opt/mist-scripts/mist-srt-auth.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /opt/mist-scripts/mist-srt-auth.sh",
      "printf 'PB_URL=http://127.0.0.1:8090\\nPB_EMAIL=${var.pb_email}\\nPB_PASS=${var.pb_password}\\n' > /etc/mist-auth.env",
      "chmod 600 /etc/mist-auth.env",
    ]
  }

  depends_on = [null_resource.provision]
}
