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

# Automatically fall back to remote_wan_ip if targets are omitted
locals {
  t1_target = coalesce(var.tunnel_1_health_check_target, var.remote_wan_ip)
  t2_target = coalesce(var.tunnel_2_health_check_target, var.remote_wan_ip)
}

# Generate secure PSKs internally inside Terraform
resource "random_password" "psk_1" {
  length  = 32
  special = false
}

resource "random_password" "psk_2" {
  length  = 32
  special = false
}

# Cloudflare Magic WAN / Transit Tunnels
resource "cloudflare_magic_wan_ipsec_tunnel" "tunnel_1" {
  account_id          = var.cloudflare_account_id
  name                = "strongSwan-vpn-1"
  customer_endpoint   = var.remote_wan_ip
  cloudflare_endpoint = var.cloudflare_anycast_ip_1
  interface_address   = var.tunnel_1_interface_address
  psk                 = random_password.psk_1.result

  health_check = {
    enabled   = true
    type      = "request"
    direction = "unidirectional"
    rate      = "mid"
    target    = { saved = local.t1_target }
  }
}

resource "cloudflare_magic_wan_ipsec_tunnel" "tunnel_2" {
  account_id          = var.cloudflare_account_id
  name                = "strongSwan-vpn-2"
  customer_endpoint   = var.remote_wan_ip
  cloudflare_endpoint = var.cloudflare_anycast_ip_2
  interface_address   = var.tunnel_2_interface_address
  psk                 = random_password.psk_2.result

  health_check = {
    enabled   = true
    type      = "request"
    direction = "unidirectional"
    rate      = "mid"
    target    = { saved = local.t2_target }
  }
}

# Remote execution on the instance
resource "null_resource" "strongswan_install" {
  triggers = {
    remote_ip   = var.remote_wan_ip
    ssh_user    = var.ssh_user
    private_key = var.ssh_private_key
    
    template_checksum = md5(templatefile("${path.module}/templates/strongswan.sh.tpl", {
      cloudflare_account_id = var.cloudflare_account_id
      remote_wan_ip         = var.remote_wan_ip
      cf_anycast_1          = var.cloudflare_anycast_ip_1
      cf_anycast_2          = var.cloudflare_anycast_ip_2
      tunnel_1_id           = cloudflare_magic_wan_ipsec_tunnel.tunnel_1.id
      tunnel_2_id           = cloudflare_magic_wan_ipsec_tunnel.tunnel_2.id
      psk_1                 = random_password.psk_1.result
      psk_2                 = random_password.psk_2.result
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
      cloudflare_account_id = var.cloudflare_account_id
      remote_wan_ip         = var.remote_wan_ip
      cf_anycast_1          = var.cloudflare_anycast_ip_1
      cf_anycast_2          = var.cloudflare_anycast_ip_2
      tunnel_1_id           = cloudflare_magic_wan_ipsec_tunnel.tunnel_1.id
      tunnel_2_id           = cloudflare_magic_wan_ipsec_tunnel.tunnel_2.id
      psk_1                 = random_password.psk_1.result
      psk_2                 = random_password.psk_2.result
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
      "sudo ip link set vti0 down || true",
      "sudo ip tunnel del vti0 || true",
      "sudo ip link set vti1 down || true",
      "sudo ip tunnel del vti1 || true",
      "sudo ip route del default table viatunicmp 2>/dev/null || true",
      "sudo ip rule del lookup viatunicmp 2>/dev/null || true",
      "sudo sed -i '/200 viatunicmp/d' /etc/iproute2/rt_tables || true",
      "sudo iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1387 2>/dev/null || true",
      "sudo rm -rf /etc/ipsec.conf /etc/ipsec.secrets /etc/strongswan.conf /etc/strongswan.d/",
      "echo 'strongSwan configuration successfully removed.'"
    ]
  }

  depends_on = [
    cloudflare_magic_wan_ipsec_tunnel.tunnel_1,
    cloudflare_magic_wan_ipsec_tunnel.tunnel_2
  ]
}
