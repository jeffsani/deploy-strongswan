variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare Account ID"
}

variable "cloudflare_anycast_ip_1" {
  type        = string
  description = "First Cloudflare Magic Transit Anycast IP"
}

variable "cloudflare_anycast_ip_2" {
  type        = string
  description = "Second Cloudflare Magic Transit Anycast IP"
}

variable "remote_wan_ip_1" {
  type        = string
  description = "The primary public WAN IP of the remote customer endpoint"
}

variable "remote_wan_ip_2" {
  type        = string
  description = "The secondary public WAN IP of the remote customer endpoint (required if num_of_tunnels is 4)"
}

variable "cloudflare_api_token" {
  type        = string
  description = "Cloudflare API Token"
  sensitive   = true
}

variable "ssh_user" {
  type        = string
  description = "SSH username for the remote host"
  default     = "terraform"
}

variable "ssh_private_key" {
  type        = string
  description = "SSH private key for the remote host"
  sensitive   = true
}

# --- Tunnel Endpoints ---
variable "tunnel_interface_prefix_base" {
  type        = string
  description = "The base /31 CIDR block to use for the first tunnel"
}

variable "num_of_tunnels" {
  type        = number
  description = "Number of tunnels to deploy (2 or 4). Use 4 if you have 2 discrete ISP links."
  default     = 2
  validation {
    condition     = contains([2, 4], var.num_of_tunnels)
    error_message = "The number of tunnels must be either 2 or 4."
  }
}

variable "health_check_targets" {
  type        = list(string)
  description = "Optional list of custom health check target IPs (e.g., internal IPs for NAT scenarios). If an index is omitted, it defaults to the respective remote WAN IP."
  default     = []
}

variable "tunnel_flow_traffic_only" {
  type        = bool
  description = "If true, only network flow logging traffic (sFlow/NetFlow to 162.159.65.1) is directed through the tunnels. If false, the tunnels act as the default gateway for the 192.168.15.0/24 LAN network."
  default     = false
}

variable "tunnel_flow_nat_ip" {
  type        = string
  description = "Source NAT IP for network flow traffic (NetFlow/IPFIX and sFlow). Must be an IP within the customer's Magic Transit protected prefix. Required when tunnel_flow_traffic_only = true."
  default     = null
}
