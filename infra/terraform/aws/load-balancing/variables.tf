# Variables for load-balancing module

variable "aws_profile" {
  description = "AWS profile to use (empty string for environment variables in CI)"
  type        = string
  default     = "homelab"
}

variable "traefik_ip" {
  description = "IP address of Traefik ingress controller"
  type        = string
  default     = "10.10.201.70"
}

variable "wind_etherport_hostnames" {
  description = "Hostnames to route to Traefik for wind.etherport.net services"
  type        = list(string)
  default = [
    "ha.wind.etherport.net",
    "plex.wind.etherport.net",
    "chat.wind.etherport.net"
  ]
}
