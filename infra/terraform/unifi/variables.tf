variable "aws_profile" {
  description = "AWS profile to use for S3 backend (empty string in CI; uses env vars)"
  type        = string
  default     = "homelab"
}

variable "unifi_username" {
  description = "UniFi local admin username for tf-admin (NOT the Ubiquiti SSO account)"
  type        = string
  sensitive   = true
}

variable "unifi_password" {
  description = "UniFi local admin password — pull from 1Password 'Windroute (tf-admin)'"
  type        = string
  sensitive   = true
}

variable "unifi_api_url" {
  description = "UDM controller URL. Use the mgmt-VLAN address (10.10.200.1) for production runs."
  type        = string
  default     = "https://10.10.200.1"
}

variable "unifi_site" {
  description = "UniFi site identifier (default for single-site deployments)"
  type        = string
  default     = "default"
}

variable "unifi_allow_insecure" {
  description = "Skip TLS verification on the UDM API. UDM uses a self-signed cert by default; set true until cert-manager sync is wired up."
  type        = bool
  default     = true
}
