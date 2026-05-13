# Ubuntu 24.04 cloud-init template for Proxmox via proxmox-clone.
#
# This clones a pre-existing base VM (VM 9000 — Ubuntu 24.04 cloud image
# imported via scripts/setup-cloud-base.sh) and customizes it via shell
# provisioners. The result is saved as a template at VM ID 9001 for
# Terraform to clone.
#
# Why proxmox-clone (not proxmox-iso): Ubuntu cloud images ship with
# cloud-init, qemu-guest-agent, the ubuntu user, and SSH server already
# configured. We avoid the autoinstall/subiquity quirks (qemu-guest-agent
# install failures, chpasswd in chroot, datasource confusion) entirely.
#
# Usage:
#   packer init .
#   packer build -var-file=variables.pkrvars.hcl .

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.2"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

#------------------------------------------------------------------------------
# Variables
#------------------------------------------------------------------------------

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

variable "base_template_id" {
  type        = number
  description = "VM ID of the base cloud-image template to clone from"
  default     = 9000
}

variable "template_vm_id" {
  type        = number
  description = "VM ID for the customized template Packer produces"
  default     = 9001
}

variable "template_name" {
  type        = string
  description = "Name for the produced template VM"
  default     = "ubuntu-2404-cloud-init"
}

variable "storage_pool" {
  type        = string
  description = "Storage pool for the template"
  default     = "local-zfs"
}

variable "ssh_username" {
  type        = string
  description = "Cloud-init username and SSH user during build"
  default     = "ubuntu"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key injected into the template via cloud-init"
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to SSH private key Packer uses to connect during build"
  default     = "~/.ssh/id_ed25519"
}

#------------------------------------------------------------------------------
# Source - proxmox-clone
#------------------------------------------------------------------------------

source "proxmox-clone" "ubuntu" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  # Source template - the Ubuntu cloud image imported by setup-cloud-base.sh
  clone_vm_id = var.base_template_id

  # Destination VM (becomes the new template)
  vm_id                = var.template_vm_id
  vm_name              = var.template_name
  template_description = "Ubuntu 24.04 LTS cloud-init template - Built by Packer from cloud image"

  # Hardware. Packer defaults scsi_controller to lsi when cloning, which
  # loses the base template's virtio-scsi-single setting and breaks boot
  # (Ubuntu cloud image doesn't find the disk via LSI). Explicitly preserve.
  cores           = 2
  memory          = 2048
  scsi_controller = "virtio-scsi-single"

  # Cloud-init drive for post-clone configuration by Terraform
  cloud_init              = true
  cloud_init_storage_pool = var.storage_pool

  # ciuser/sshkeys/ipconfig are inherited from VM 9000 (set in
  # setup-cloud-base.sh). The proxmox-clone source doesn't accept those
  # fields directly; configuring them on the source template is the
  # canonical pattern. Terraform overrides per-clone for workload VMs.

  qemu_agent = true

  tags = "template;ubuntu;cloud-init;packer"

  # SSH connection - connect directly to the static IP
  ssh_host               = "10.10.201.250"
  ssh_username           = var.ssh_username
  ssh_private_key_file   = var.ssh_private_key_file
  ssh_timeout            = "10m"
  ssh_handshake_attempts = 50
}

#------------------------------------------------------------------------------
# Build
#------------------------------------------------------------------------------

build {
  sources = ["source.proxmox-clone.ubuntu"]

  # Wait for cloud-init to finish first-boot config before we start changing
  # things underneath it.
  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init to finish...'",
      "sudo cloud-init status --wait || true",
      "echo 'Cloud-init done.'",
    ]
  }

  # System update and base packages. Cloud image already has cloud-init,
  # qemu-guest-agent, openssh-server, etc., so this is mostly upgrades plus
  # the homelab-specific additions.
  provisioner "shell" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-pip curl wget git vim htop ca-certificates gnupg lsb-release open-iscsi nfs-common qemu-guest-agent",
      "sudo systemctl enable --now qemu-guest-agent",
    ]
  }

  # VLAN parent interfaces for Multus macvlan. Workload VMs (K8s nodes)
  # attach extra vNICs on VLAN 202/204/205 (visible as enp6s19/20/21);
  # without this netplan stanza they boot DOWN and Multus macvlan pods
  # cannot attach to them, breaking IoT (HA -> Hue/Tuya/Roomba) and
  # security camera workloads. `optional: true` means the boot doesn't
  # block waiting for them, and absence of the interface (e.g. the
  # standalone-vms class with only 1 NIC) is silently fine. See
  # docs/runbooks/vlan-interfaces-netplan.md.
  provisioner "shell" {
    inline = [
      "sudo tee /etc/netplan/51-vlan-interfaces.yaml > /dev/null <<'NETPLAN'",
      "network:",
      "  version: 2",
      "  ethernets:",
      "    enp6s19:",
      "      optional: true",
      "      dhcp4: no",
      "      dhcp6: no",
      "    enp6s20:",
      "      optional: true",
      "      dhcp4: no",
      "      dhcp6: no",
      "    enp6s21:",
      "      optional: true",
      "      dhcp4: no",
      "      dhcp6: no",
      "NETPLAN",
      "sudo chmod 600 /etc/netplan/51-vlan-interfaces.yaml",
      "sudo netplan generate",
    ]
  }

  # Cleanup for templating - clear caches, machine-id, cloud-init state.
  # The next time this template is cloned, cloud-init runs fresh on first
  # boot and applies the new VM's identity.
  provisioner "shell" {
    inline = [
      "sudo apt-get autoremove -y",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo cloud-init clean --logs --seed",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",
      "sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -rf /tmp/* /var/tmp/*",
      "sudo sync",
    ]
  }
}
