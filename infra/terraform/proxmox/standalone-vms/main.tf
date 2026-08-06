terraform {
  required_version = ">= 1.14"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "${var.proxmox_token_id}=${var.proxmox_token_secret}"
  insecure  = true
}

locals {
  node_name    = "pve"
  storage_name = "local-zfs"
  gateway_201  = "10.10.201.1"
  cpu_type     = "host"
  # `bridge_name` + `vlan_tag` locals were removed 2026-05-18 after all
  # standalone VMs migrated to per-VM bridge fields (SDN VNets). See
  # `standalone_vms` map below — each entry now declares its own
  # `bridge` and `vlan_tag`.

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
    vpn-fallback = {
      vm_id       = 1002
      ip          = "10.10.201.15"
      bridge      = "servers" # SDN VNet (VLAN 201) — migrated 2026-05-18 (PR 4)
      vlan_tag    = null      # VNet handles VLAN tagging
      vcpus       = 1
      memory_mb   = 512
      disk_gb     = 10
      description = "WireGuard VPN gateway - local site S2S endpoint (VRRP backup; renamed vpn-local->vpn-fallback 2026-07-02, M128)"
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
    asterisk-sbc = {
      vm_id    = 1004
      ip       = "10.10.201.40"
      bridge   = "servers" # SDN VNet (VLAN 201) — Trusted zone, has a Trusted→Internal allow to reach Talk
      vlan_tag = null      # VNet handles VLAN tagging
      # SBC for task #80: Asterisk PJSIP B2BUA bridging Twilio (TLS+sRTP,
      # internet-facing) ⇄ UniFi Talk (plain UDP/RTP on the LAN). Replaces
      # Talk's fragile WAN-facing 3rd-party-SIP listener, which died on the
      # 2026-06-05 firmware update (nothing in port-forward/firewall/IaC held
      # it open). 2 vCPU / 2 GB is ample for one low-volume trunk with no
      # transcoding (both legs negotiate PCMU/PCMA).
      vcpus       = 2
      memory_mb   = 2048
      disk_gb     = 20
      description = "Asterisk PJSIP SBC — Twilio TLS+sRTP ⇄ UniFi Talk UDP bridge (task #80)"
      tags        = ["terraform", "voip", "sbc", "standalone"]
    }
    devbox = {
      vm_id    = 1005
      ip       = "10.10.201.45"
      bridge   = "servers" # SDN VNet (VLAN 201)
      vlan_tag = null      # VNet handles VLAN tagging
      # Persistent remote dev box: runs Claude Code (+ other terminal tools) in
      # tmux so a session survives the laptop dropping connectivity/power. Reached
      # from anywhere over Tailscale (direct node) or the existing subnet route.
      # Lean on RAM by design — Claude Code idles ~250 MB, spikes ~1 GB; a 4 GB
      # swapfile (host has no swap) absorbs spikes so 2 GB never OOMs. Host had
      # ~17 GB free at provision time (2026-06-08). Bump memory_mb if it feels
      # tight — the host can afford 3-4 GB.
      # 4 vCPU: Claude Code's main loop is light, but parallel sub-agents/tool
      # calls + builds benefit from the extra cores; host has plenty of CPU.
      vcpus       = 4
      memory_mb   = 2048
      disk_gb     = 40
      description = "Dev box — persistent tmux/Claude Code remote workstation"
      tags        = ["terraform", "devbox", "standalone"]
    }
    step-ca = {
      vm_id    = 1006
      ip       = "10.10.201.46"
      bridge   = "servers" # SDN VNet (VLAN 201)
      vlan_tag = null      # VNet handles VLAN tagging
      # M76 Phase 1: smallstep step-ca SSH Certificate Authority. Deliberately a
      # DEDICATED OFF-CLUSTER host so a k8s outage can't strand node SSH (the CA
      # that authorizes SSH must not live inside the thing you SSH in to fix).
      # Lightweight service (a Go CA + small badger DB). Provisioned by
      # infra/ansible/playbooks/step-ca.yml. NB: like every VM here, a REBUILD
      # bootstraps with the automation key via cloud-init; post-enrollment the key
      # is stripped and SSH is cert-only (M76 cutover complete 2026-06-26).
      vcpus       = 1
      memory_mb   = 1024
      disk_gb     = 15
      description = "step-ca — SSH Certificate Authority (M76 short-lived SSH)"
      tags        = ["terraform", "step-ca", "ssh-ca", "standalone"]
    }
  }

  # Imported VMs - pre-existing VMs adopted into Terraform (no clone block)
  # Currently empty - vpn-fallback (ex vpn-local) moved to standalone_vms for fresh deployment
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
    # M77: route this NIC through the PVE firewall — the per-VM rules live in
    # ../firewall/standalone-vms.tf and are ENFORCING (default-deny inbound
    # since 2026-06-28). For a NEW VM, apply the firewall stack (rules + a
    # per-VM input policy) BEFORE or together with this, or its inbound is
    # dropped. The k8s nodes are a SEPARATE stack and are intentionally NOT
    # firewalled here.
    firewall = true
    # Jumbo frames to match bond0/vmbr0/SDN-zone MTU. Without this, the
    # tap device defaults to MTU 1500, becoming the path bottleneck even
    # though every other hop is 9000. Caught 2026-05-18 when gh-runner
    # (just migrated to bridge="servers") couldn't complete TLS to PVE
    # API — small packets (ICMP, SYN) worked, large ones got dropped.
    mtu = 9000
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
    # M77: route this NIC through the PVE firewall — the per-VM rules live in
    # ../firewall/standalone-vms.tf and are ENFORCING (default-deny inbound
    # since 2026-06-28). For a NEW VM, apply the firewall stack (rules + a
    # per-VM input policy) BEFORE or together with this, or its inbound is
    # dropped. The k8s nodes are a SEPARATE stack and are intentionally NOT
    # firewalled here.
    firewall = true
    # Jumbo frames to match bond0/vmbr0/SDN-zone MTU. Without this, the
    # tap device defaults to MTU 1500, becoming the path bottleneck even
    # though every other hop is 9000. Caught 2026-05-18 when gh-runner
    # (just migrated to bridge="servers") couldn't complete TLS to PVE
    # API — small packets (ICMP, SYN) worked, large ones got dropped.
    mtu = 9000
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

# M128 (2026-07-02): vpn-local renamed vpn-fallback (consistency with dns-fallback).
# The for_each key IS the resource address AND the VM name — moved{} migrates the
# state address so the apply is an in-place `name` update, not destroy/recreate.
moved {
  from = proxmox_virtual_environment_vm.standalone["vpn-local"]
  to   = proxmox_virtual_environment_vm.standalone["vpn-fallback"]
}
