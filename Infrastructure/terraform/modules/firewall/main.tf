locals {
  # Flatten map(port => [cidr]) into "port:cidr" strings for the shell script
  tcp_from_csv = join(",", flatten([
    for port, cidrs in var.allow_tcp_from : [for cidr in cidrs : "${port}:${cidr}"]
  ]))
  udp_from_csv = join(",", flatten([
    for port, cidrs in var.allow_udp_from : [for cidr in cidrs : "${port}:${cidr}"]
  ]))
}

resource "null_resource" "provision" {
  triggers = {
    script       = filemd5("${path.module}/../../scripts/firewall.sh")
    vps_ip       = var.vps_ip
    allow_tcp    = join(",", [for p in var.allow_tcp : tostring(p)])
    allow_udp    = join(",", [for p in var.allow_udp : tostring(p)])
    tcp_from     = local.tcp_from_csv
    udp_from     = local.udp_from_csv
  }

  connection {
    type        = "ssh"
    host        = var.vps_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  provisioner "file" {
    source      = "${path.module}/../../scripts/firewall.sh"
    destination = "/tmp/firewall.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/firewall.sh",
      join(" ", [
        "ALLOW_TCP=${join(",", [for p in var.allow_tcp : tostring(p)])}",
        "ALLOW_UDP=${join(",", [for p in var.allow_udp : tostring(p)])}",
        "ALLOW_TCP_FROM=${local.tcp_from_csv}",
        "ALLOW_UDP_FROM=${local.udp_from_csv}",
        "/tmp/firewall.sh",
      ]),
    ]
  }
}
