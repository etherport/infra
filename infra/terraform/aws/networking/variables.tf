# Variables for networking module

variable "ssh_allowed_ip" {
  description = "IP address allowed to SSH (CIDR notation)"
  type        = string
  default     = "47.159.189.230/32"
}
