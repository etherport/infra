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

# M76 cutover (2026-06-26): per-host BOOTSTRAP key only. A new node must be SSH-reachable
# before step-ca cert enrollment (playbooks/step-ca-trust.yml + -hostcerts.yml); the key
# is then removed from the running host (step-ca-remove-static-key.yml) → fleet SSH is
# cert-only. Keep this default so new nodes provision; it is NOT standing access.
variable "ssh_public_key" {
  description = "automation@homelab BOOTSTRAP pubkey (cloud-init) — removed post-enroll; fleet SSH is cert-only (M76)"
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDbuFR+hru9VgMct+C7pCxrxXB0O3mrhFcBP3QJ/D8IR automation@homelab"
}