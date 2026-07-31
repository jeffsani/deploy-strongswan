output "tunnel_generated_psks" {
  description = "The dynamically generated Pre-Shared Keys for the IPsec tunnels"
  value       = cloudflare_magic_wan_ipsec_tunnel.tunnels[*].psk
  sensitive   = true
}

output "tunnel_fqdn_ids" {
  description = "The Cloudflare auto-generated FQDN IDs for the IPsec tunnels"
  value       = cloudflare_magic_wan_ipsec_tunnel.tunnels[*].fqdn_id
}

output "tunnel_interface_addresses" {
  description = "The calculated VTI interface addresses"
  value       = cloudflare_magic_wan_ipsec_tunnel.tunnels[*].interface_address
}
