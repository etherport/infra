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

  # Control plane nodes - 3 for HA (etcd quorum requires odd number)
  # Slim configuration since they only run etcd, API server, controller-manager, scheduler
  control_plane_nodes = {
    k8s-cp1 = {
      ip        = "10.10.201.50"
      vcpus     = 4
      memory_mb = 4096
      disk_gb   = 50
    }
    k8s-cp2 = {
      ip        = "10.10.201.51"
      vcpus     = 4
      memory_mb = 4096
      disk_gb   = 50
    }
    k8s-cp3 = {
      ip        = "10.10.201.52"
      vcpus     = 4
      memory_mb = 4096
      disk_gb   = 50
    }
  }

  # Worker nodes - run actual workloads
  worker_nodes = {
    k8s-w1 = {
      ip        = "10.10.201.53"
      vcpus     = 4
      memory_mb = 10240
      disk_gb   = 80
    }
    k8s-w2 = {
      ip        = "10.10.201.54"
      vcpus     = 4
      memory_mb = 10240
      disk_gb   = 80
    }
    k8s-w3 = {
      ip        = "10.10.201.55"
      vcpus     = 4
      memory_mb = 10240
      disk_gb   = 80
    }
    k8s-w4 = {
      ip        = "10.10.201.56"
      vcpus     = 4
      memory_mb = 10240
      disk_gb   = 80
    }
  }
}

# Control plane nodes
resource "proxmox_virtual_environment_vm" "control_plane" {
  for_each = local.control_plane_nodes

  node_name   = local.node_name
  name        = each.key
  description = "Managed by Terraform (k8s control plane)"
  tags        = ["terraform", "k8s", "control-plane"]

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

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = local.vlan_tag
  }

  # Additional VLANs for multi-network support
  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 202 # Client VLAN
  }

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 204 # IoT VLAN
  }

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 205 # Security VLAN
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

# Worker nodes
resource "proxmox_virtual_environment_vm" "workers" {
  for_each = local.worker_nodes

  node_name   = local.node_name
  name        = each.key
  description = "Managed by Terraform (k8s worker)"
  tags        = ["terraform", "k8s", "worker"]

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

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = local.vlan_tag
  }

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 202
  }

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 204
  }

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 205
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

# GPU worker node with Tesla P40 passthrough
resource "proxmox_virtual_environment_vm" "k8s_gpu1" {
  node_name   = local.node_name
  name        = "k8s-gpu1"
  description = "Managed by Terraform (k8s GPU worker)"
  tags        = ["terraform", "k8s", "worker", "gpu"]

  machine = "q35"
  bios    = "ovmf"

  efi_disk {
    datastore_id      = local.storage_name
    file_format       = "raw"
    type              = "4m"
    pre_enrolled_keys = false
  }

  clone {
    vm_id = 9000
    full  = true
  }

  cpu {
    cores = 8
    type  = local.cpu_type
  }

  memory {
    dedicated = 20480 # 20GB - reduced from 24GB to fit new layout
  }

  disk {
    datastore_id = local.storage_name
    interface    = "scsi0"
    size         = 80
    file_format  = "raw"
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = local.vlan_tag
  }

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 202
  }

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 204
  }

  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 205
  }

  hostpci {
    device  = "hostpci0"
    mapping = "gpu-tesla-p40"
    pcie    = true
    rombar  = true
  }

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

# Outputs
output "control_plane_nodes" {
  value = {
    for name, vm in proxmox_virtual_environment_vm.control_plane :
    name => {
      name = vm.name
      ip   = local.control_plane_nodes[name].ip
    }
  }
}

output "worker_nodes" {
  value = {
    for name, vm in proxmox_virtual_environment_vm.workers :
    name => {
      name = vm.name
      ip   = local.worker_nodes[name].ip
    }
  }
}

output "gpu_node" {
  value = {
    name = proxmox_virtual_environment_vm.k8s_gpu1.name
    ip   = "10.10.201.60"
  }
}

# Summary output for quick reference
output "cluster_summary" {
  value = {
    control_planes = 3
    workers        = 5 # 4 standard + 1 GPU
    total_vcpus    = 3 * 4 + 4 * 4 + 8  # 36 vCPUs
    total_ram_gb   = 3 * 4 + 4 * 10 + 20 # 72 GB
  }
}
