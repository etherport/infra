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

  # Standalone VMs - services outside of Kubernetes
  # VM IDs: 1000-1099 reserved for standalone services
  #
  # VMs are split into two categories:
  # - standalone_vms: Created fresh from cloud-init template
  # - imported_vms: Pre-existing VMs imported into Terraform (no clone block)

  # Per-VM bridge + vlan_tag introduced 2026-05-18 (SDN migration PR 3+).
  # When bridge is an SDN VNet (`servers`, `clients`, etc.), the VNet itself
  # carries the VLAN tag — set vlan_tag = null to avoid double-tagging. For
  # legacy VMs still on `vmbr0`, set bridge = "vmbr0" + vlan_tag = 201.
  standalone_vms = {
    dns-fallback = {
      vm_id       = 1001
      ip          = "10.10.201.6"
      bridge      = "servers" # SDN VNet (VLAN 201) — migrated 2026-05-18
      vlan_tag    = null      # VNet handles VLAN tagging
      vcpus       = 1
      memory_mb   = 1024
      disk_gb     = 20
      description = "Technitium DNS fallback server"
      tags        = ["terraform", "dns", "standalone"]
    }
    vpn-local = {
      vm_id       = 1002
      ip          = "10.10.201.15"
      bridge      = "servers" # SDN VNet (VLAN 201) — migrated 2026-05-18 (PR 4)
      vlan_tag    = null      # VNet handles VLAN tagging
      vcpus       = 1
      memory_mb   = 512
      disk_gb     = 10
      description = "WireGuard VPN gateway - local site S2S endpoint"
      tags        = ["terraform", "vpn", "standalone"]
    }
    gh-runner = {
      vm_id    = 1003
      ip       = "10.10.201.30"
      bridge   = "servers" # SDN VNet (VLAN 201) — migrated 2026-05-18 (PR 4)
      vlan_tag = null      # VNet handles VLAN tagging
      # Self-touch caveat: bpg/proxmox hot-modifies the NIC (no VM stop+start)
      # for bridge changes, so this apply CAN run via gh-runner workflow
      # without self-killing. dns-fallback's PR 3 apply confirmed 0s apply
      # time = hot-modify. If this stops working in a future provider
      # version, fall back to local-apply.
      vcpus       = 2
      memory_mb   = 2048
      disk_gb     = 20
      description = "GitHub Actions self-hosted runner for K8s-lifecycle workflows (outside the cluster it manages)"
      tags        = ["terraform", "runner", "standalone"]
    }
  }

  # Imported VMs - pre-existing VMs adopted into Terraform (no clone block)
  # Currently empty - vpn-local moved to standalone_vms for fresh deployment
  imported_vms = {}
}

# VMs created fresh from cloud-init template
resource "proxmox_virtual_environment_vm" "standalone" {
  for_each = local.standalone_vms

  node_name   = local.node_name
  vm_id       = each.value.vm_id
  name        = each.key
  description = each.value.description
  tags        = each.value.tags

  clone {
    vm_id = 9001 # Ubuntu 24.04 customized template (Packer-built; VM 9000 is the raw cloud-image base)
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
    bridge  = each.value.bridge
    model   = "virtio"
    vlan_id = each.value.vlan_tag
  }

  initialization {
    datastore_id = local.storage_name
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = local.gateway_201
      }
    }
    # Both technitium VIPs — no public DNS fallback. systemd-resolved
    # silently rolls over to a public server if the primary stalls,
    # which breaks split-horizon resolution (caused the gh-runner to
    # resolve `pve.wind.etherport.net` to the public *.wind.etherport.net
    # ALB ALIAS instead of the local PVE IP). If both technitiums die
    # simultaneously, DNS breakage is correct — fail loud rather than
    # silently giving public answers for internal hosts.
    dns {
      servers = ["10.10.201.5", "10.10.201.6"]
    }
  }

  # Hardware watchdog (see k8s-vms/main.tf for rationale).
  watchdog {
    model  = "i6300esb"
    action = "reset"
  }

  started = true
  on_boot = true

  # Don't try to mutate the watchdog device on existing VMs. Attaching
  # the i6300esb requires a VM stop+start, which is fatal for gh-runner
  # (1003) when the apply is RUNNING ON gh-runner — the runner pauses
  # mid-job, the job is cancelled, and state can corrupt. This bit us
  # on 2026-05-16. Once the device is on, leave it; if we ever need to
  # change action mode (reset/shutdown/poweroff), remove this guard
  # temporarily AND run TF apply from outside gh-runner.
  lifecycle {
    ignore_changes = [watchdog]
  }
}

# Imported VMs - pre-existing VMs adopted into Terraform
# No clone block to prevent forced replacement
resource "proxmox_virtual_environment_vm" "imported" {
  for_each = local.imported_vms

  node_name   = local.node_name
  vm_id       = each.value.vm_id
  name        = each.key
  description = each.value.description
  tags        = each.value.tags

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
  }

  network_device {
    bridge  = each.value.bridge
    model   = "virtio"
    vlan_id = each.value.vlan_tag
  }

  agent {
    enabled = true
  }

  # Hardware watchdog (see k8s-vms/main.tf). Imported VMs need a stop+
  # start to attach the device; will happen on the next planned outage
  # (or a one-off `qm set <vmid> --watchdog model=i6300esb,action=reset`
  # while the VM is running, which takes effect on next reboot).
  watchdog {
    model  = "i6300esb"
    action = "reset"
  }

  started = true
  on_boot = true

  # Ignore changes to attributes that can't be changed on existing VMs
  lifecycle {
    ignore_changes = [
      bios,
      disk,
      efi_disk,
      initialization,
      operating_system,
      scsi_hardware,
    ]
  }
}
