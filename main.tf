terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.22"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Math logic to calculate both the tunnel allocations and the customer host IPs
locals {
  base_ip = split("/", var.tunnel_interface_prefix_base)[0]
  prefix  = split("/", var.tunnel_interface_prefix_base)[1]
  octets  = split(".", local.base_ip)
  o1      = local.octets[0]
  o2      = local.octets[1]
  o3      = local.octets[2]
  o4      = tonumber(local.octets[3])

  tunnel_ips = [
    "${local.o1}.${local.o2}.${local.o3}.${local.o4}/${local.prefix}",
    "${local.o1}.${local.o2}.${local.o3}.${local.o4 + 2}/${local.prefix}",
    "${local.o1}.${local.o2}.${local.o3}.${local.o4 + 4}/${local.prefix}",
    "${local.o1}.${local.o2}.${local.o3}.${local.o4 + 6}/${local.prefix}"
  ]

  customer_ips = [
    "${local.o1}.${local.o2}.${local.o3}.${local.o4 + 1}",
    "${local.o1}.${local.o2}.${local.o3}.${local.o4 + 3}",
    "${local.o1}.${local.o2}.${local.o3}.${local.o4 + 5}",
    "${local.o1}.${local.o2}.${local.o3}.${local.o4 + 7}"
  ]
}

# Generate secure PSKs dynamically
resource "random_password" "psk" {
  count   = var.num_of_tunnels
  length  = 32
  special = false
}

# Cloudflare WAN / Transit Tunnels
resource "cloudflare_magic_wan_ipsec_tunnel" "tunnels" {
  count = var.num_of_tunnels

  account_id  = var.cloudflare_account_id
  name        = "strongSwan-vpn-${count.index + 1}"
  description = count.index < 2 ? "Primary ISP to Anycast ${count.index % 2 + 1}" : "Secondary ISP to Anycast ${count.index % 2 + 1}"

  customer_endpoint   = count.index < 2 ? trimspace(var.remote_wan_ip_1) : trimspace(var.remote_wan_ip_2)
  cloudflare_endpoint = count.index % 2 == 0 ? trimspace(var.cloudflare_anycast_ip_1) : trimspace(var.cloudflare_anycast_ip_2)
  interface_address   = local.tunnel_ips[count.index]
  psk                 = random_password.psk[count.index].result

  health_check = {
    enabled   = true
    type      = "request"
    direction = "bidirectional"
    rate      = "mid"
  }
}

# Retrieve auto-generated FQDN identities from the Cloudflare API
# The tunnel ID in the URL is only known after apply, so Terraform
# automatically defers these reads to the apply phase.
data "http" "tunnel_identity" {
  count = var.num_of_tunnels

  url = "https://api.cloudflare.com/client/v4/accounts/${var.cloudflare_account_id}/magic/ipsec_tunnels/${cloudflare_magic_wan_ipsec_tunnel.tunnels[count.index].id}"

  request_headers = {
    Authorization = "Bearer ${var.cloudflare_api_token}"
    Content-Type  = "application/json"
  }
}

locals {
  tunnel_fqdn_ids = [
    for i in range(var.num_of_tunnels) :
    jsondecode(data.http.tunnel_identity[i].response_body).result.ipsec_tunnel.remote_identities.fqdn_id
  ]
}

# Remote execution on the instance
resource "null_resource" "strongswan_install" {
  triggers = {
    remote_ip    = trimspace(var.remote_wan_ip_1)
    ssh_user     = var.ssh_user
    private_key  = var.ssh_private_key
    anycast_ip_1 = trimspace(var.cloudflare_anycast_ip_1)
    anycast_ip_2 = trimspace(var.cloudflare_anycast_ip_2)

    template_checksum = md5(templatefile("${path.module}/templates/strongswan.sh.tpl", {
      num_of_tunnels           = var.num_of_tunnels
      remote_wan_ip_1          = trimspace(var.remote_wan_ip_1)
      remote_wan_ip_2          = var.remote_wan_ip_2 != null ? trimspace(var.remote_wan_ip_2) : ""
      tunnel_flow_traffic_only = var.tunnel_flow_traffic_only
      tunnels = [
        for i in range(var.num_of_tunnels) : {
          psk         = random_password.psk[i].result
          local_ip    = i < 2 ? trimspace(var.remote_wan_ip_1) : trimspace(var.remote_wan_ip_2)
          remote_ip   = i % 2 == 0 ? trimspace(var.cloudflare_anycast_ip_1) : trimspace(var.cloudflare_anycast_ip_2)
          customer_ip = local.customer_ips[i]
          fqdn_id     = local.tunnel_fqdn_ids[i]
          vti_if      = "vti${i + 1}"
          mark        = 41 + i
          rt_table    = 10 + i
        }
      ]
    }))
  }

  connection {
    type        = "ssh"
    user        = self.triggers.ssh_user
    private_key = self.triggers.private_key
    host        = self.triggers.remote_ip
  }

  provisioner "file" {
    content = templatefile("${path.module}/templates/strongswan.sh.tpl", {
      num_of_tunnels           = var.num_of_tunnels
      remote_wan_ip_1          = trimspace(var.remote_wan_ip_1)
      remote_wan_ip_2          = var.remote_wan_ip_2 != null ? trimspace(var.remote_wan_ip_2) : ""
      tunnel_flow_traffic_only = var.tunnel_flow_traffic_only
      tunnels = [
        for i in range(var.num_of_tunnels) : {
          psk         = random_password.psk[i].result
          local_ip    = i < 2 ? trimspace(var.remote_wan_ip_1) : trimspace(var.remote_wan_ip_2)
          remote_ip   = i % 2 == 0 ? trimspace(var.cloudflare_anycast_ip_1) : trimspace(var.cloudflare_anycast_ip_2)
          customer_ip = local.customer_ips[i]
          fqdn_id     = local.tunnel_fqdn_ids[i]
          vti_if      = "vti${i + 1}"
          mark        = 41 + i
          rt_table    = 10 + i
        }
      ]
    })
    destination = "/tmp/install_strongswan.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/install_strongswan.sh && sudo bash /tmp/install_strongswan.sh && rm /tmp/install_strongswan.sh"
    ]
  }

  provisioner "remote-exec" {
    when = destroy
    inline = [
      "echo 'Starting strongSwan teardown...'",
      "IPSEC_BIN=$(command -v ipsec || echo \"/usr/local/sbin/ipsec\")",
      "sudo $IPSEC_BIN stop || true",
      "sudo ip link set vti1 down || true",
      "sudo ip tunnel del vti1 || true",
      "sudo ip link set vti2 down || true",
      "sudo ip tunnel del vti2 || true",
      "sudo ip link set vti3 down || true",
      "sudo ip tunnel del vti3 || true",
      "sudo ip link set vti4 down || true",
      "sudo ip tunnel del vti4 || true",
      "sudo ip rule del lookup 10 2>/dev/null || true",
      "sudo ip rule del lookup 11 2>/dev/null || true",
      "sudo ip rule del lookup 12 2>/dev/null || true",
      "sudo ip rule del lookup 13 2>/dev/null || true",
      "sudo ip rule del ipproto tcp sport 22 lookup main 2>/dev/null || true",
      "sudo ip rule del to ${self.triggers.anycast_ip_1} lookup main 2>/dev/null || true",
      "sudo ip rule del to ${self.triggers.anycast_ip_2} lookup main 2>/dev/null || true",
      "sudo ip rule del to 162.159.65.1/32 2>/dev/null || true",
      "sudo ip rule del from 192.168.15.0/24 2>/dev/null || true",
      "sudo ip rule del priority 71 2>/dev/null || true",
      "sudo ip rule del priority 72 2>/dev/null || true",
      "sudo ip rule del priority 73 2>/dev/null || true",
      "sudo ip rule del priority 74 2>/dev/null || true",
      "sudo ip rule del priority 81 2>/dev/null || true",
      "sudo ip rule del priority 82 2>/dev/null || true",
      "sudo ip rule del priority 83 2>/dev/null || true",
      "sudo ip rule del priority 84 2>/dev/null || true",
      "sudo systemctl stop tunnel-watchdog.service 2>/dev/null || true",
      "sudo systemctl disable tunnel-watchdog.service 2>/dev/null || true",
      "sudo rm -f /etc/systemd/system/tunnel-watchdog.service 2>/dev/null || true",
      "sudo systemctl daemon-reload 2>/dev/null || true",
      "sudo iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1387 2>/dev/null || true",
      "sudo rm -rf /etc/ipsec.conf /etc/ipsec.secrets /etc/strongswan.conf /etc/strongswan.d/",
      "sudo rm -f /etc/modules-load.d/ip_vti.conf 2>/dev/null || true",
      "sudo sed -i '/ip_vti/d' /etc/modules 2>/dev/null || true",
      "sudo rm -f /etc/sysctl.d/99-strongswan.conf 2>/dev/null || true",
      "sudo sysctl --system 2>/dev/null || true",
      "echo 'strongSwan configuration successfully removed.'"
    ]
  }

  depends_on = [
    cloudflare_magic_wan_ipsec_tunnel.tunnels
  ]
}
