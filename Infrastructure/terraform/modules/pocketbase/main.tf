locals {
  srt_output_csv = join(",", [for p in var.srt_output_ports : tostring(p)])
}

resource "null_resource" "provision" {
  triggers = {
    script              = filemd5("${path.module}/../../scripts/pocketbase.sh")
    vps_ip              = var.vps_ip
    admin_email         = var.admin_email
    streaming_public_ip = var.streaming_public_ip
  }

  connection {
    type        = "ssh"
    host        = var.vps_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "10m"
  }

  provisioner "file" {
    source      = "${path.module}/../../scripts/pocketbase.sh"
    destination = "/tmp/pocketbase.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/pocketbase.sh",
      join(" ", [
        "PB_ADMIN_EMAIL=${var.admin_email}",
        "PB_ADMIN_PASSWORD=${var.admin_password}",
        "STREAMING_PUBLIC_IP=${var.streaming_public_ip}",
        "SRT_INGEST_PORT=${var.srt_ingest_port}",
        "SRT_OUTPUT_PORTS=${local.srt_output_csv}",
        "/tmp/pocketbase.sh",
      ]),
    ]
  }
}
