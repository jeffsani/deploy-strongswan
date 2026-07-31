variable "cloudflare_account_id" { type = string }
variable "cloudflare_anycast_ip_1" { type = string }
variable "cloudflare_anycast_ip_2" { type = string }
variable "remote_wan_ip_1" { type = string }
variable "remote_wan_ip_2" { type = string }
variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}
variable "ssh_user" { 
  type    = string
  default = "terraform" 
}
variable "ssh_private_key" { 
  type      = string
  sensitive = true 
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
