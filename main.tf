terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.22"
    }
  }
}

resource "cloudflare_magic_wan_ipsec_tunnel" "tunnel_1" {
  account_id          = var.cloudflare_account_id
  name                = "ubuntu-tunnel-1"
  customer_endpoint   = var.ubuntu_wan_ip
  cloudflare_endpoint = var.cloudflare_anycast_ip_1
  interface_address   = var.tunnel_1_interface_address

  health_check = {
    enabled   = true
    type      = "request"
    direction = "bidirectional"
    rate      = "mid"
    target    = { saved = var.tunnel_1_health_check_target }
  }
}

resource "cloudflare_magic_wan_ipsec_tunnel" "tunnel_2" {
  account_id          = var.cloudflare_account_id
  name                = "ubuntu-tunnel-2"
  customer_endpoint   = var.ubuntu_wan_ip
  cloudflare_endpoint = var.cloudflare_anycast_ip_2
  interface_address   = var.tunnel_2_interface_address

  health_check = {
    enabled   = true
    type      = "request"
    direction = "bidirectional"
    rate      = "mid"
    target    = { saved = var.tunnel_2_health_check_target }
  }
}
