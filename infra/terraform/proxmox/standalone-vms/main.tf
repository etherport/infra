terraform {
  required_version = ">= 1.4.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.50"
    }
  }
}

provider "proxmox" {
  endpoint  = "https://pve.wind.etherport.net:8006/api2/json"
  api_token = "${var.proxmox_token_id}=${var.proxmox_token_secret}"
  insecure  = true
}

locals {
  node_name    = "pve"
  storage_name = "local-zfs"
  bridge_name  = "vmbr0"
  vlan_tag     = 201
  gateway_201  = "10.10.201.1"
  cpu_type     = "host"

  # Standalone VMs - services outside of Kubernetes
  # VM IDs: 1000-1099 reserved for standalone services
  standalone_vms = {
    dns-fallback = {
      vm_id     = 1001
      ip        = "10.10.201.6"
      vcpus     = 1
      memory_mb = 1024
      disk_gb   = 20
    }
  }
}

resource "proxmox_virtual_environment_vm" "standalone" {
  for_each = local.standalone_vms

  node_name   = local.node_name
  vm_id       = each.value.vm_id
  name        = each.key
  description = "Managed by Terraform (standalone service)"
  tags        = ["terraform", "dns", "standalone"]

  clone {
    vm_id = 9000 # Ubuntu 24.04 cloud-init template
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

  # Single network interface (VLAN 201 - management only)
  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = local.vlan_tag
  }

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
