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
