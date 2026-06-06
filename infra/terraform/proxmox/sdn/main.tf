terraform {
  required_version = ">= 1.4.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.109"
    }
  }
}

provider "proxmox" {
  endpoint  = "https://pve.wind.etherport.net:8006/api2/json"
  api_token = "${var.proxmox_token_id}=${var.proxmox_token_secret}"
  insecure  = true
}

locals {
  node_name = "pve"
}
