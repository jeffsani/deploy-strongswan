output "tunnel_generated_psks" {
  description = "The dynamically generated Pre-Shared Keys for the IPsec tunnels"
  value       = cloudflare_magic_wan_ipsec_tunnel.tunnels[*].psk
  sensitive   = true
}

output "tunnel_custom_fqdns" {
  description = "The discrete Custom FQDNs applied to the IPsec tunnels"
  value       = local.custom_fqdns
}

output "tunnel_interface_addresses" {
  description = "The calculated VTI interface addresses"
  value       = cloudflare_magic_wan_ipsec_tunnel.tunnels[*].interface_address
}
