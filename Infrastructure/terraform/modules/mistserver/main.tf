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
    exporter_script = filemd5("${path.module}/../../scripts/cast-prom-metrics-install.sh")
    exporter_py     = filemd5("${path.module}/../../scripts/cast-prom-metrics.py")
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
    source      = "${path.module}/../../scripts/cast-prom-metrics-install.sh"
    destination = "/tmp/cast-prom-metrics-install.sh"
  }

  provisioner "file" {
    source      = "${path.module}/../../scripts/cast-prom-metrics.py"
    destination = "/tmp/cast-prom-metrics.py"
  }

  # Write env file directly — avoids shell quoting issues with JSON
  provisioner "file" {
    content     = "STREAMS_JSON=${local.streams_json}\nEXPORTER_PORT=${var.exporter_port}\nMIST_API_PORT=${var.api_port}\nPB_URL=http://127.0.0.1:8090\nPB_EMAIL=${var.pb_email}\nPB_PASS=${var.pb_password}\n"
    destination = "/etc/cast-prom-metrics.env"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/cast-prom-metrics-install.sh",
      join(" ", [
        "MIST_API_PORT=${var.api_port}",
        "EXPORTER_PORT=${var.exporter_port}",
        "/tmp/cast-prom-metrics-install.sh",
      ]),
    ]
  }

  depends_on = [null_resource.provision]
}

resource "null_resource" "provision_stream_auth" {
  triggers = {
    script      = filemd5("${path.module}/../../scripts/cast-mist-stream-auth.sh")
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

  provisioner "file" {
    source      = "${path.module}/../../scripts/cast-mist-stream-auth.sh"
    destination = "/usr/local/bin/cast-mist-stream-auth.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /usr/local/bin/cast-mist-stream-auth.sh",
      "printf 'PB_URL=http://127.0.0.1:8090\\nPB_EMAIL=${var.pb_email}\\nPB_PASS=${var.pb_password}\\n' > /etc/cast-mist-stream-auth.env",
      "chmod 600 /etc/cast-mist-stream-auth.env",
      "rm -f /usr/local/bin/mist-srt-auth.sh /etc/mist-auth.env",
    ]
  }

  depends_on = [null_resource.provision]
}

resource "null_resource" "provision_r2_writer" {
  triggers = {
    script = filemd5("${path.module}/../../scripts/cast-r2-writer")
    vps_ip = var.vps_ip
  }

  connection {
    type        = "ssh"
    host        = var.vps_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "10m"
  }

  provisioner "file" {
    source      = "${path.module}/../../scripts/cast-r2-writer"
    destination = "/usr/local/bin/cast-r2-writer"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /usr/local/bin/cast-r2-writer",
      "rm -f /usr/local/bin/mist-r2-writer /etc/mist-r2-writer.env",
    ]
  }

  depends_on = [null_resource.provision]
}

resource "null_resource" "provision_stream_probe" {
  triggers = {
    script = filemd5("${path.module}/../../scripts/cast-stream-probe.sh")
    vps_ip = var.vps_ip
  }

  connection {
    type        = "ssh"
    host        = var.vps_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "10m"
  }

  provisioner "file" {
    source      = "${path.module}/../../scripts/cast-stream-probe.sh"
    destination = "/usr/local/bin/cast-stream-probe.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /usr/local/bin/cast-stream-probe.sh",
      "rm -f /usr/local/bin/mist-ts-monitor.sh /usr/local/bin/mist-writer-test.sh",
    ]
  }

  depends_on = [null_resource.provision]
}
