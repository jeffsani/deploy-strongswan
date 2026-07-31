variable "cloudflare_account_id" { type = string }
variable "cloudflare_anycast_ip_1" { type = string }
variable "cloudflare_anycast_ip_2" { type = string }
variable "remote_wan_ip" { type = string }
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
variable "tunnel_1_interface_address" { 
  type        = string
  description = "The Cloudflare side of the /31 CIDR block for Tunnel 1"
}

variable "tunnel_2_interface_address" { 
  type        = string
  description = "The Cloudflare side of the /31 CIDR block for Tunnel 2"
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
