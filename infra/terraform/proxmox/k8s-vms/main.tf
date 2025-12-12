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
  # base URL of your Proxmox API
  endpoint  = "https://pve.wind.etherport.net:8006/api2/json"

  # bpg/proxmox expects a single api_token string in the form:
  #   <TOKEN_ID>=<TOKEN_SECRET>
  api_token = "${var.proxmox_token_id}=${var.proxmox_token_secret}"

  insecure  = true
}

locals {
  node_name    = "pve"        # Proxmox node short name (as seen in UI)
  storage_name = "local-zfs"
  bridge_name  = "vmbr0"
  vlan_tag     = 201
  gateway_201  = "10.10.201.1"

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

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = local.vlan_tag
  }

  # cloud-init: static IPs for each node
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

output "k8s_nodes" {
  value = {
    for name, vm in proxmox_virtual_environment_vm.k8s_nodes :
    name => {
      name = vm.name
      ip   = local.k8s_nodes[name].ip
    }
  }
}