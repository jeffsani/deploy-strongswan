output "tunnel_1_generated_psk" {
  description = "The auto-generated PSK for the first IPsec tunnel"
  value       = cloudflare_magic_wan_ipsec_tunnel.tunnel_1.psk
  sensitive   = true
}

output "tunnel_2_generated_psk" {
  description = "The auto-generated PSK for the second IPsec tunnel"
  value       = cloudflare_magic_wan_ipsec_tunnel.tunnel_2.psk
  sensitive   = true
}
