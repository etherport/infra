variable "aws_profile" {
  description = "AWS profile to use for S3 backend (empty string for environment variables in CI)"
  type        = string
  default     = "homelab"
}

variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint URL"
  type        = string
  default     = "https://pve.wind.etherport.net:8006/api2/json"
}

variable "proxmox_token_id" {
  description = "Proxmox API token ID, e.g. root@pam!terraform"
  type        = string
}

variable "proxmox_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

# M76 cutover (2026-06-26): this is now the per-host BOOTSTRAP key only. A freshly
# provisioned VM must be SSH-reachable before it can be enrolled into step-ca cert
# trust (playbooks/step-ca-trust.yml + -hostcerts.yml). After enrollment the key is
# removed from the running host (playbooks/step-ca-remove-static-key.yml) and SSH is
# cert-only. Keep this default so new VMs stay provisionable; it is NOT standing access.
variable "ssh_public_key" {
  description = "automation@homelab BOOTSTRAP pubkey (cloud-init) — removed post-enroll; fleet SSH is cert-only (M76)"
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDbuFR+hru9VgMct+C7pCxrxXB0O3mrhFcBP3QJ/D8IR automation@homelab"
}
