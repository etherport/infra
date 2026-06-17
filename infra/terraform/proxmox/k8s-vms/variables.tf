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

variable "ssh_public_key" {
  description = "SSH public key injected into each VM via cloud-init for ansible/kubespray + admin access"
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDbuFR+hru9VgMct+C7pCxrxXB0O3mrhFcBP3QJ/D8IR automation@homelab"
}