locals {
  sites_csv = join(",", var.sites)
}

resource "null_resource" "provision" {
  triggers = {
    script = filemd5("${path.module}/../../scripts/nginx.sh")
    vps_ip = var.vps_ip
    sites  = local.sites_csv
  }

  connection {
    type        = "ssh"
    host        = var.vps_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "10m"
  }

  provisioner "file" {
    source      = "${path.module}/../../scripts/nginx.sh"
    destination = "/tmp/nginx.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/nginx.sh",
      "NGINX_SITES=${local.sites_csv} /tmp/nginx.sh",
    ]
  }
}
