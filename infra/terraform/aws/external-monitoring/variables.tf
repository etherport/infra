# External Monitoring Configuration
# Route53 health checks for homelab endpoints

variable "aws_profile" {
  description = "AWS profile to use (empty string for environment variables in CI)"
  type        = string
  default     = "homelab"
}

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-west-2"
}

variable "alert_email" {
  description = "Email address for alerts"
  type        = string
  default     = "graham.m.smith@me.com"
}

variable "alert_email_backup" {
  description = "Backup email address for alerts"
  type        = string
  default     = "grahamsm@gmail.com"
}

variable "monthly_budget_usd" {
  description = "Monthly AWS spend budget (USD) — triggers SNS+email at 80%/100% actual and 100% forecasted."
  type        = number
  default     = 75
}

variable "homelab_domain" {
  description = "Primary homelab domain"
  type        = string
  default     = "wind.etherport.net"
}

# Endpoints to monitor
# These are accessed via the public IP / dynamic DNS
variable "endpoints" {
  description = "Endpoints to monitor with health checks"
  type = map(object({
    fqdn              = string
    port              = number
    type              = string # HTTP, HTTPS, TCP
    resource_path     = optional(string, "/")
    search_string     = optional(string, "")
    failure_threshold = optional(number, 3)
    request_interval  = optional(number, 30)
    enabled           = optional(bool, true)
  }))
  default = {
    # Home Assistant - critical, mission-critical home automation
    home-assistant = {
      fqdn              = "ha.wind.etherport.net"
      port              = 443
      type              = "HTTPS"
      resource_path     = "/"
      failure_threshold = 2
      request_interval  = 30
      enabled           = true
    }
    # Grafana - monitoring dashboard
    grafana = {
      fqdn              = "grafana.wind.etherport.net"
      port              = 443
      type              = "HTTPS"
      resource_path     = "/api/health"
      failure_threshold = 3
      request_interval  = 30
      enabled           = false # Disabled — endpoint sits behind CF Access now (health path isn't publicly probeable unauthenticated)
    }
    # Traefik ingress controller
    traefik = {
      fqdn              = "traefik.wind.etherport.net"
      port              = 443
      type              = "HTTPS"
      resource_path     = "/ping"
      failure_threshold = 3
      request_interval  = 30
      enabled           = false # Disabled — hostname is VPN/internal-only since the 2026-05-27 ALB decom (external DNS = NXDOMAIN)
    }
    # Plex media server
    plex = {
      fqdn              = "plex.wind.etherport.net"
      port              = 443
      type              = "HTTPS"
      resource_path     = "/identity"
      failure_threshold = 3
      request_interval  = 30
      enabled           = true
    }
    # Open WebUI (Chat) - AI chat interface
    chat = {
      fqdn              = "chat.wind.etherport.net"
      port              = 443
      type              = "HTTPS"
      resource_path     = "/"
      failure_threshold = 3
      request_interval  = 30
      enabled           = true
    }
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Project     = "homelab"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
