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
  type        = integer
  description = "The number of tunnels to be created"
  default     = 2
}

variable "tunnel_1_health_check_target" { 
  type        = string
  description = "The Customer side health check target. Defaults to ubuntu_wan_ip if omitted."
  default     = null
}

variable "tunnel_2_health_check_target" { 
  type        = string
  description = "The Customer side health check target. Defaults to ubuntu_wan_ip if omitted."
  default     = null
}
