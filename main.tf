terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.22"
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

# Math logic to increment the 4th octet by 2 for each subsequent tunnel
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
}

# Generate secure PSKs dynamically
resource "random_password" "psk" {
  count   = var.num_of_tunnels
  length  = 32
  special = false
}

# Cloudflare Magic WAN / Transit Tunnels
resource "cloudflare_magic_wan_ipsec_tunnel" "tunnels" {
  count = var.num_of_tunnels

  account_id          = var.cloudflare_account_id
  name                = "strongSwan-vpn-${count.index + 1}"
  description         = count.index < 2 ? "Primary ISP to Anycast ${count.index % 2 + 1}" : "Secondary ISP to Anycast ${count.index % 2 + 1}"
  customer_endpoint   = count.index < 2 ? var.remote_wan_ip_1 : var.remote_wan_ip_2
  cloudflare_endpoint = count.index % 2 == 0 ? var.cloudflare_anycast_ip_1 : var.cloudflare_anycast_ip_2
  interface_address   = local.tunnel_ips[count.index]
  psk                 = random_password.psk[count.index].result

  health_check = {
    enabled   = true
    type      = "request"
    direction = "unidirectional"
    rate      = "mid"
    # Attempts to pull a custom target from the list; otherwise falls back to the respective WAN IP
    target    = { saved = try(var.health_check_targets[count.index], count.index < 2 ? var.remote_wan_ip_1 : var.remote_wan_ip_2) }
  }
}

# Remote execution on the instance
resource "null_resource" "strongswan_install" {
  triggers = {
    remote_ip   = var.remote_wan_ip_1
    ssh_user    = var.ssh_user
    private_key = var.ssh_private_key
    
    template_checksum = md5(templatefile("${path.module}/templates/strongswan.sh.tpl", {
      num_of_tunnels  = var.num_of_tunnels
      remote_wan_ip_1 = var.remote_wan_ip_1
      remote_wan_ip_2 = var.remote_wan_ip_2 != null ? var.remote_wan_ip_2 : ""
      tunnels = [
        for i in range(var.num_of_tunnels) : {
          fqdn      = cloudflare_magic_wan_ipsec_tunnel.tunnels[i].fqdn_id
          psk       = random_password.psk[i].result
          local_ip  = i < 2 ? var.remote_wan_ip_1 : var.remote_wan_ip_2
          remote_ip = i % 2 == 0 ? var.cloudflare_anycast_ip_1 : var.cloudflare_anycast_ip_2
          vti_if    = "vti${i}"
          mark      = 41 + i
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
      num_of_tunnels  = var.num_of_tunnels
      remote_wan_ip_1 = var.remote_wan_ip_1
      remote_wan_ip_2 = var.remote_wan_ip_2 != null ? var.remote_wan_ip_2 : ""
      tunnels = [
        for i in range(var.num_of_tunnels) : {
          fqdn      = cloudflare_magic_wan_ipsec_tunnel.tunnels[i].fqdn_id
          psk       = random_password.psk[i].result
          local_ip  = i < 2 ? var.remote_wan_ip_1 : var.remote_wan_ip_2
          remote_ip = i % 2 == 0 ? var.cloudflare_anycast_ip_1 : var.cloudflare_anycast_ip_2
          vti_if    = "vti${i}"
          mark      = 41 + i
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

  # Ensure all 4 potential VTI interfaces are cleaned up on destroy
  provisioner "remote-exec" {
    when = destroy
    inline = [
      "echo 'Starting strongSwan teardown...'",
      "IPSEC_BIN=$(command -v ipsec || echo \"/usr/local/sbin/ipsec\")",
      "sudo $IPSEC_BIN stop || true",
      "sudo ip link set vti0 down || true",
      "sudo ip tunnel del vti0 || true",
      "sudo ip link set vti1 down || true",
      "sudo ip tunnel del vti1 || true",
      "sudo ip link set vti2 down || true",
      "sudo ip tunnel del vti2 || true",
      "sudo ip link set vti3 down || true",
      "sudo ip tunnel del vti3 || true",
      "sudo ip route del default table viatunicmp 2>/dev/null || true",
      "sudo ip rule del lookup viatunicmp 2>/dev/null || true",
      "sudo sed -i '/200 viatunicmp/d' /etc/iproute2/rt_tables || true",
      "sudo iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1387 2>/dev/null || true",
      "sudo rm -rf /etc/ipsec.conf /etc/ipsec.secrets /etc/strongswan.conf /etc/strongswan.d/",
      "echo 'strongSwan configuration successfully removed.'"
    ]
  }

  depends_on = [
    cloudflare_magic_wan_ipsec_tunnel.tunnels
  ]
}
