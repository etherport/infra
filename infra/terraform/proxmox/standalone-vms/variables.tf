variable "proxmox_token_id" {
  description = "Proxmox API token ID, e.g. root@pam!terraform"
  type        = string
}

variable "proxmox_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}
