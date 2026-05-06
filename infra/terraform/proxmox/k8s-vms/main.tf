terraform {
  required_version = ">= 1.4.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.106"
    }
  }
}

provider "proxmox" {
  # base URL of your Proxmox API
  endpoint = "https://pve.wind.etherport.net:8006/api2/json"

  # bpg/proxmox expects a single api_token string in the form:
  #   <TOKEN_ID>=<TOKEN_SECRET>
  api_token = "${var.proxmox_token_id}=${var.proxmox_token_secret}"

  insecure = true
}

locals {
  node_name    = "pve" # Proxmox node short name (as seen in UI)
  storage_name = "local-zfs"
  bridge_name  = "vmbr0"
  vlan_tag     = 201
  gateway_201  = "10.10.201.1"

  # IMPORTANT: Use a modern CPU type for Kubernetes nodes.
  # `qemu64` can hide CPU flags and break some containers (e.g., glibc x86-64-v2 requirement).
  # Recommended by the provider docs: "x86-64-v2-AES". Using "host" is fine for single-node labs.
  cpu_type = "host"

  k8s_nodes = {
    k8s-cp1 = {
      ip        = "10.10.201.50"
      vcpus     = 4
      memory_mb = 8192
      disk_gb   = 60
    }
    k8s-w1 = {
      ip        = "10.10.201.51"
      vcpus     = 4
      memory_mb = 8192
      disk_gb   = 80
    }
    k8s-w2 = {
      ip        = "10.10.201.52"
      vcpus     = 4
      memory_mb = 8192
      disk_gb   = 80
    }
    k8s-w3 = {
      ip        = "10.10.201.53"
      vcpus     = 4
      memory_mb = 8192
      disk_gb   = 80
    }
  }
}

resource "proxmox_virtual_environment_vm" "k8s_nodes" {
  for_each = local.k8s_nodes

  node_name   = local.node_name
  name        = each.key
  description = "Managed by Terraform (k8s node)"
  tags        = ["terraform", "k8s"]

  # Clone from your existing Ubuntu 24.04 cloud-init template (VM 9000)
  clone {
    vm_id = 9000
    full  = true
  }

  cpu {
    cores = each.value.vcpus
    type  = local.cpu_type
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = local.storage_name
    interface    = "scsi0"
    size         = each.value.disk_gb
    file_format  = "raw"
    discard      = "on"
    ssd          = true
  }

  # Primary network interface (VLAN 201 - management)
  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = local.vlan_tag
  }

  # Additional network interfaces for multi-VLAN support (Home Assistant, etc.)
  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 202 # Client VLAN
  }

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 204 # IoT devices VLAN
  }

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 205 # Security VLAN
  }

  # cloud-init: static IPs for each node
  # Note: cloud-init only configures the first interface (eth0)
  # Additional interfaces (eth1-eth3) must be configured via systemd-networkd
  initialization {
    datastore_id = local.storage_name

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = local.gateway_201
      }
    }
  }

  started = true
  on_boot = true
}

# GPU worker node with Tesla P40 passthrough
resource "proxmox_virtual_environment_vm" "k8s_gpu1" {
  node_name   = local.node_name
  name        = "k8s-gpu1"
  description = "Managed by Terraform (k8s GPU worker node)"
  tags        = ["terraform", "k8s", "gpu"]

  # Q35 machine type is required for PCI passthrough
  machine = "q35"

  # BIOS configuration - disable Secure Boot for NVIDIA driver compatibility
  bios = "ovmf"

  efi_disk {
    datastore_id      = local.storage_name
    file_format       = "raw"
    type              = "4m"
    pre_enrolled_keys = false # Disable Secure Boot for NVIDIA driver compatibility
  }

  # Clone from your existing Ubuntu 24.04 cloud-init template (VM 9000)
  clone {
    vm_id = 9000
    full  = true
  }

  cpu {
    cores = 8
    type  = local.cpu_type
  }

  memory {
    dedicated = 24576 # 24GB RAM
  }

  disk {
    datastore_id = local.storage_name
    interface    = "scsi0"
    size         = 80
    file_format  = "raw"
    discard      = "on"
    ssd          = true
  }

  # Primary network interface (VLAN 201 - management)
  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = local.vlan_tag
  }

  # Additional network interfaces for multi-VLAN support (Home Assistant, etc.)
  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 202 # Client VLAN
  }

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 204 # IoT devices VLAN
  }

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 205 # Security VLAN
  }

  # GPU passthrough - Tesla P40
  # IMPORTANT: You must configure this in Proxmox first:
  # 1. Enable IOMMU in host BIOS and /etc/default/grub
  # 2. Blacklist nouveau driver
  # 3. Load vfio-pci driver
  # 4. Identify GPU PCI address (lspci | grep NVIDIA)
  # 5. Create resource mapping in Proxmox UI (Datacenter > Resource Mappings)
  hostpci {
    device  = "hostpci0"
    mapping = "gpu-tesla-p40" # Resource mapping name in Proxmox
    pcie    = true
    rombar  = true
  }

  # cloud-init: static IP (changed from .53 to .60 for clean IP organization)
  initialization {
    datastore_id = local.storage_name

    ip_config {
      ipv4 {
        address = "10.10.201.60/24"
        gateway = local.gateway_201
      }
    }
  }

  started = true
  on_boot = true
}

output "k8s_nodes" {
  value = {
    for name, vm in proxmox_virtual_environment_vm.k8s_nodes :
    name => {
      name = vm.name
      ip   = local.k8s_nodes[name].ip
    }
  }
}

output "k8s_gpu_node" {
  value = {
    name = proxmox_virtual_environment_vm.k8s_gpu1.name
    ip   = "10.10.201.60"
  }
}