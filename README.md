# Cloudflare Magic WAN Post-Quantum IPsec Deployment

This Terraform module automates the deployment of 2 or 4 Cloudflare Magic WAN IPsec tunnels to a remote Linux instance (Ubuntu, Debian, RHEL, or Oracle Linux). It securely negotiates hybrid post-quantum cryptography (ML-KEM / ECP384) with strict AES-GCM Phase 1 and Phase 2 encryption.

## Architecture

This deployment supports dynamic scaling based on your ISP links:
*   **2 Tunnels:** For a single public WAN connection, establishing primary and secondary Anycast connections.
*   **4 Tunnels:** For dual public WAN connections (discrete ISP links), establishing redundant connections across both WANs.

The deployment handles all inner VTI (Virtual Tunnel Interface) routing, TCP MSS clamping, and kernel-level IP forwarding dynamically.

## Prerequisites
*   Terraform v1.0+
*   A Cloudflare account with Magic WAN provisioned.
*   A target Linux machine reachable via SSH using key-based authentication.
*   The target machine must allow inbound UDP port 500 and 4500 from the Cloudflare Anycast IPs.

## Inputs

| Name | Type | Description | Required |
|------|------|-------------|:--------:|
| `cloudflare_api_token` | `string` | Your Cloudflare API Token | Yes |
| `cloudflare_account_id` | `string` | Your Cloudflare Account ID | Yes |
| `ssh_user` | `string` | SSH username for the remote host | Yes |
| `ssh_private_key` | `string` | SSH private key for the remote host | Yes |
| `cloudflare_anycast_ip_1` | `string` | First Cloudflare Magic Transit Anycast IP | Yes |
| `cloudflare_anycast_ip_2` | `string` | Second Cloudflare Magic Transit Anycast IP | Yes |
| `num_of_tunnels` | `number` | Number of tunnels to deploy (2 or 4) | No (Default: 2) |
| `remote_wan_ip_1` | `string` | Primary public WAN IP of the remote customer endpoint | Yes |
| `remote_wan_ip_2` | `string` | Secondary public WAN IP (Required if num_of_tunnels is 4) | No |
| `tunnel_interface_prefix_base` | `string` | The starting /31 prefix for the VTI interfaces (e.g., 172.20.15.2/31). The 4th octet is incremented by 2 for each subsequent tunnel. | Yes |
| `health_check_targets` | `list(string)`| Optional custom health check targets (e.g., internal NAT IPs). Defaults to the respective WAN IP if empty. | No |

## Usage

1. Create a `terraform.tfvars` file and populate the required variables:

```hcl
cloudflare_api_token         = "your-api-token"
cloudflare_account_id        = "your-account-id"
ssh_user                     = "ubuntu"
ssh_private_key              = "-----BEGIN OPENSSH PRIVATE KEY-----\n..."
cloudflare_anycast_ip_1      = "162.159.x.x"
cloudflare_anycast_ip_2      = "172.64.x.x"
remote_wan_ip_1              = "71.24.162.133"
tunnel_interface_prefix_base = "172.20.15.2/31"

# Set to 4 if using two ISPs, and provide remote_wan_ip_2
num_of_tunnels               = 2

# Optional: Set this if your server is behind a NAT router
# health_check_targets         = ["10.0.0.5", "10.0.0.5"]
