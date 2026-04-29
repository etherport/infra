# Regional VPN Module Variables

variable "region_short" {
  description = "Short region identifier (e.g., 'bah' for me-south-1)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPN VPC"
  type        = string
  default     = "10.10.112.0/24"
}

variable "key_pair_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
  default     = "GS-EC2"
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # Restrict in production
}

variable "use_elastic_ip" {
  description = "Whether to allocate an Elastic IP (adds cost when instance stopped)"
  type        = bool
  default     = false
}

#------------------------------------------------------------------------------
# WireGuard Configuration
#------------------------------------------------------------------------------

variable "wg_private_key" {
  description = "WireGuard private key for this server"
  type        = string
  sensitive   = true
}

variable "wg_address" {
  description = "WireGuard interface address (e.g., 10.255.255.5/30)"
  type        = string
  default     = "10.255.255.5/30"
}

variable "wg_peer_public_key" {
  description = "Public key of the homelab WireGuard peer"
  type        = string
}

variable "wg_peer_endpoint" {
  description = "Endpoint of homelab WireGuard (e.g., wind.etherport.net:51820)"
  type        = string
  default     = "wind.etherport.net:51820"
}

variable "wg_peer_allowed_ips" {
  description = "Allowed IPs for homelab peer (routes to send through tunnel)"
  type        = string
  default     = "10.10.192.0/19,10.255.255.0/30"
}

variable "client_public_key" {
  description = "Your device's WireGuard public key for remote access"
  type        = string
}

variable "client_allowed_ips" {
  description = "Your device's allowed IP in the VPN"
  type        = string
  default     = "10.254.0.10/32"
}

#------------------------------------------------------------------------------
# VPC Peering (Optional)
#------------------------------------------------------------------------------

variable "enable_vpc_peering" {
  description = "Enable VPC peering to us-west-2 hub"
  type        = bool
  default     = false
}

variable "hub_vpc_id" {
  description = "VPC ID of the us-west-2 hub (required if enable_vpc_peering=true)"
  type        = string
  default     = ""
}
