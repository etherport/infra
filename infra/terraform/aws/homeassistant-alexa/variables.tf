variable "aws_profile" {
  description = "AWS profile to use (empty string for environment variables in CI)"
  type        = string
  default     = "homelab"
}

variable "ha_base_url" {
  description = "Home Assistant base URL"
  type        = string
  default     = "https://ha.wind.etherport.net"
}

variable "ha_access_token" {
  description = "Long-lived access token for Home Assistant"
  type        = string
  sensitive   = true
}

variable "alexa_skill_id" {
  description = "Alexa Smart Home skill ID"
  type        = string
  default     = "amzn1.ask.skill.66f45757-5a96-485e-a2b3-63379f31c14d"
}

variable "debug" {
  description = "Enable debug mode"
  type        = bool
  default     = false
}

variable "cf_access_client_id" {
  description = <<-EOT
    CF Access Service Token client ID for ha.wind.etherport.net bypass.
    Get from the cloudflare module:
      cd ../../cloudflare && terraform output -raw alexa_service_token_client_id
    Pass via TF_VAR_cf_access_client_id (workflow env) or terraform.tfvars.
    Empty string = skip the CF headers (lambda will fall back to no CF auth,
    only works if HA isn't behind CF Access — i.e., via the ALB legacy path).
  EOT
  type        = string
  default     = ""
}

variable "cf_access_client_secret" {
  description = <<-EOT
    CF Access Service Token client secret — companion to cf_access_client_id.
    Get from the cloudflare module:
      cd ../../cloudflare && terraform output -raw alexa_service_token_client_secret
    Pass via TF_VAR_cf_access_client_secret. Stored in Lambda env vars
    (visible to anyone with Lambda Read on this account — acceptable for
    a service-scoped bypass token; rotate via taint on the CF resource).
  EOT
  type        = string
  default     = ""
  sensitive   = true
}
