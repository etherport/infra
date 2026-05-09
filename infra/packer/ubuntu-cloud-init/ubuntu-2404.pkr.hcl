# Ubuntu 24.04 LTS Cloud-Init Template for Proxmox
# This creates a VM template (ID 9000) that Terraform can clone
#
# Usage:
#   packer init .
#   packer build -var-file=variables.pkrvars.hcl .
#
# Prerequisites:
#   - Packer installed (https://www.packer.io/downloads)
#   - Proxmox API token with VM creation permissions

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.2"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# Variables
variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL"
  default     = "https://pve.wind.etherport.net:8006/api2/json"
}

variable "proxmox_token_id" {
  type        = string
  description = "Proxmox API token ID (e.g., user@pam!tokenname)"
  sensitive   = true
}

variable "proxmox_token_secret" {
  type        = string
  description = "Proxmox API token secret"
  sensitive   = true
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name"
  default     = "pve"
}

variable "template_vm_id" {
  type        = number
  description = "VM ID for the template"
  default     = 9000
}

variable "template_name" {
  type        = string
  description = "Name for the template VM"
  default     = "ubuntu-2404-cloud-init"
}

variable "storage_pool" {
  type        = string
  description = "Storage pool for the template"
  default     = "local-zfs"
}

variable "ssh_username" {
  type        = string
  description = "Username for SSH access during build"
  default     = "ubuntu"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key to add to the template"
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to SSH private key for Packer to connect"
  default     = "~/.ssh/id_ed25519"
}

variable "ubuntu_iso_url" {
  type        = string
  description = "URL to Ubuntu Server Live ISO (using CDN mirror for reliability)"
  default     = "https://mirror.arizona.edu/ubuntu-releases/24.04/ubuntu-24.04.3-live-server-amd64.iso"
}

variable "ubuntu_iso_checksum" {
  type        = string
  description = "SHA256 checksum for Ubuntu Server ISO"
  default     = "sha256:c3514bf0056180d09376462a7a1b4f213c1d6e8ea67fae5c25099c6fd3d8274b"
}

# Source definition for Proxmox
source "proxmox-iso" "ubuntu-cloud-init" {
  # Proxmox connection
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = true
  node                     = var.proxmox_node

  # VM settings
  vm_id                = var.template_vm_id
  vm_name              = var.template_name
  template_description = "Ubuntu 24.04 LTS cloud-init template - Built by Packer"

  # Hardware
  cores    = 2
  memory   = 2048
  cpu_type = "host"
  machine  = "q35"
  bios     = "seabios"  # BIOS mode - simpler boot sequence than UEFI

  # Storage
  disks {
    disk_size    = "10G"
    storage_pool = var.storage_pool
    type         = "scsi"
    format       = "raw"
    discard      = true
    ssd          = true
  }

  scsi_controller = "virtio-scsi-single"

  # Network
  network_adapters {
    bridge = "vmbr0"
    model  = "virtio"
  }

  # ISO/Boot - using boot_iso block (replaces deprecated iso_* fields)
  boot_iso {
    iso_url          = var.ubuntu_iso_url
    iso_checksum     = var.ubuntu_iso_checksum
    iso_storage_pool = "local"
    unmount          = true
  }

  # Cloud-init for post-install (Terraform will configure this)
  cloud_init              = true
  cloud_init_storage_pool = var.storage_pool

  # Boot configuration - autoinstall via subiquity (BIOS mode)
  # Uses S3-hosted autoinstall files (avoids HTTP server network issues with remote runners)
  boot_command = [
    "<esc><esc><esc><wait>",
    "<enter><wait>",
    "<f6><esc>",
    " autoinstall ip=dhcp ds=nocloud-net;s=http://s3.us-west-2.amazonaws.com/packer-autoinstall.etherport.net/ubuntu-2404/<enter>"
  ]
  boot_wait = "5s"

  # SSH connection - extended timeout for full ISO install
  ssh_username         = var.ssh_username
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = "45m"

  # Tags
  tags = "template;ubuntu;cloud-init;packer"
}

# Build definition
build {
  sources = ["source.proxmox-iso.ubuntu-cloud-init"]

  # Wait for cloud-init to complete
  provisioner "shell" {
    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for cloud-init...'; sleep 5; done"
    ]
  }

  # Update system packages
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo apt-get dist-upgrade -y"
    ]
  }

  # Install essential packages
  provisioner "shell" {
    inline = [
      "sudo apt-get install -y qemu-guest-agent cloud-init cloud-guest-utils",
      "sudo apt-get install -y python3 python3-pip",
      "sudo apt-get install -y curl wget git vim htop",
      "sudo apt-get install -y ca-certificates gnupg lsb-release",
      "sudo apt-get install -y open-iscsi nfs-common"
    ]
  }

  # Enable qemu-guest-agent
  provisioner "shell" {
    inline = [
      "sudo systemctl enable qemu-guest-agent",
      "sudo systemctl start qemu-guest-agent || true"
    ]
  }

  # Configure cloud-init for Proxmox
  provisioner "shell" {
    inline = [
      "sudo rm -f /etc/cloud/cloud.cfg.d/99-installer.cfg",
      "echo 'datasource_list: [NoCloud, ConfigDrive]' | sudo tee /etc/cloud/cloud.cfg.d/99-proxmox.cfg"
    ]
  }

  # Clean up for templating
  provisioner "shell" {
    inline = [
      "sudo apt-get autoremove -y",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo cloud-init clean --logs --seed",
      "sudo rm -f /etc/machine-id",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",
      "sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -rf /tmp/*",
      "sudo rm -rf /var/tmp/*",
      "sudo sync"
    ]
  }

  # Post-processor to convert to template
  post-processor "shell-local" {
    inline = [
      "echo 'Template ${var.template_name} (ID ${var.template_vm_id}) created successfully!'"
    ]
  }
}
