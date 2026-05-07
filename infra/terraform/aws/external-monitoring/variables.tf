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
}

variable "alert_email_backup" {
  description = "Backup email address for alerts"
  type        = string
  default     = ""
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
    type              = string  # HTTP, HTTPS, TCP
    resource_path     = optional(string, "/")
    search_string     = optional(string, "")
    failure_threshold = optional(number, 3)
    request_interval  = optional(number, 30)
    enabled           = optional(bool, true)
  }))
  default = {
    # Home Assistant - critical
    home-assistant = {
      fqdn          = "ha.wind.etherport.net"
      port          = 443
      type          = "HTTPS"
      resource_path = "/api/"
      failure_threshold = 2
      request_interval  = 30
    }
    # Grafana - monitoring dashboard
    grafana = {
      fqdn          = "grafana.wind.etherport.net"
      port          = 443
      type          = "HTTPS"
      resource_path = "/api/health"
      search_string = "ok"
      failure_threshold = 3
      request_interval  = 30
    }
    # Traefik dashboard
    traefik = {
      fqdn          = "traefik.wind.etherport.net"
      port          = 443
      type          = "HTTPS"
      resource_path = "/ping"
      failure_threshold = 3
      request_interval  = 30
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
