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
  # bridge_name retained for NIC 5 (VLAN 210 storage) which still uses
  # vmbr0+vlan_id=210 — see comment block above network_device blocks.
  # local.vlan_tag was removed in PR 6 of the SDN migration (2026-05-22);
  # NICs 1-4 now use SDN VNets directly (bridge="servers"/"clients"/etc.).
  bridge_name = "vmbr0"
  gateway_201 = "10.10.201.1"
  cpu_type    = "host"

  # Control plane nodes - 3 for HA (etcd quorum requires odd number)
  # 8 GB each (was 4 GB until 2026-05-24). The original 4 GB assumed
  # CPs only run apiserver+etcd+controller-manager+scheduler, but in
  # this homelab Prometheus replicas (H5 HA work) + home-assistant
  # + cilium agents also land on CPs because there's no anti-affinity
  # away from them. Apiserver alone steady-states at ~3.5 GiB; with
  # 4 GiB total the CP runs at >90% mem and fires
  # NodeMemoryHighUtilization repeatedly (18 alerts/day surfaced by
  # the AI advisor as "real signal but noop" — M44).
  # VM ID scheme: control planes 100-102, workers 110-113, GPU 120.
  control_plane_nodes = {
    k8s-cp1 = {
      vm_id     = 100
      ip        = "10.10.201.50"
      vcpus     = 4
      memory_mb = 8192
      disk_gb   = 50
    }
    k8s-cp2 = {
      vm_id     = 101
      ip        = "10.10.201.51"
      vcpus     = 4
      memory_mb = 8192
      disk_gb   = 50
    }
    k8s-cp3 = {
      vm_id     = 102
      ip        = "10.10.201.52"
      vcpus     = 4
      memory_mb = 8192
      disk_gb   = 50
    }
  }

  # Worker nodes - run actual workloads
  worker_nodes = {
    k8s-w1 = {
      vm_id     = 110
      ip        = "10.10.201.53"
      vcpus     = 4
      memory_mb = 10240
      disk_gb   = 80
    }
    k8s-w2 = {
      vm_id     = 111
      ip        = "10.10.201.54"
      vcpus     = 4
      memory_mb = 10240
      disk_gb   = 80
    }
    k8s-w3 = {
      vm_id     = 112
      ip        = "10.10.201.55"
      vcpus     = 4
      memory_mb = 10240
      disk_gb   = 80
    }
    k8s-w4 = {
      vm_id     = 113
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
  vm_id       = each.value.vm_id
  name        = each.key
  description = "Managed by Terraform (k8s control plane)"
  tags        = ["terraform", "k8s", "control-plane"]

  clone {
    vm_id = 9001
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

  # MTU 9000 on every NIC to match bond0/vmbr0/SDN-zone jumbo frames.
  # Without explicit mtu, taps default to 1500 — bottleneck for TLS,
  # rbd, kubelet pulls. Caught 2026-05-18 with standalone-VMs flip to
  # SDN bridges. Preventive here for PR 5 (K8s VMs → bridge="servers").
  network_device {
    bridge = "servers"
    model  = "virtio"
    mtu    = 9000
  }

  # Additional VLANs for multi-network support
  network_device {
    bridge = "clients"
    model  = "virtio"
    mtu    = 9000
  }

  network_device {
    bridge = "iot"
    model  = "virtio"
    mtu    = 9000
  }

  network_device {
    bridge = "security"
    model  = "virtio"
    mtu    = 9000
  }

  # Storage VLAN — Ceph mon + OSDs live on 10.10.210.0/24 (VLAN 210).
  # MTU 9000 to match the underlying bond0/vmbr0 jumbo frames.
  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 210
    mtu     = 9000
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
  }

  # Wait for qemu-guest-agent IP report before considering create complete.
  # Template already enables guest agent in Packer.
  agent {
    enabled = true
  }

  # Hardware watchdog: Proxmox attaches an emulated i6300esb device.
  # The guest watchdog daemon pets it every few seconds; if the kernel
  # or userspace hangs past the timeout, Proxmox forcibly resets the
  # VM. Configured via the ansible task `Enable hardware watchdog` in
  # infra/ansible/playbooks/k8s-node-fixes.yml.
  watchdog {
    model  = "i6300esb"
    action = "reset"
  }

  started = true
  on_boot = true
}

# Worker nodes
resource "proxmox_virtual_environment_vm" "workers" {
  for_each = local.worker_nodes

  node_name   = local.node_name
  vm_id       = each.value.vm_id
  name        = each.key
  description = "Managed by Terraform (k8s worker)"
  tags        = ["terraform", "k8s", "worker"]

  clone {
    vm_id = 9001
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

  # MTU 9000 on every NIC to match bond0/vmbr0/SDN-zone jumbo frames.
  # See note in control_plane resource.
  network_device {
    bridge = "servers"
    model  = "virtio"
    mtu    = 9000
  }

  network_device {
    bridge = "clients"
    model  = "virtio"
    mtu    = 9000
  }

  network_device {
    bridge = "iot"
    model  = "virtio"
    mtu    = 9000
  }

  network_device {
    bridge = "security"
    model  = "virtio"
    mtu    = 9000
  }

  # Storage VLAN — Ceph mon + OSDs live on 10.10.210.0/24 (VLAN 210).
  # MTU 9000 to match the underlying bond0/vmbr0 jumbo frames.
  # See docs/runbooks/ceph-vlan-migration.md for the migration story.
  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 210
    mtu     = 9000
  }

  # NAS/storage VLAN 209 (net5 → enp6s23) — M18 BGP Phase A. Direct L2 path
  # to the UNAS (sequoia 10.10.209.10) so kubelet NFS mounts (Plex, s3-sync,
  # rclone) stay on the switch fabric after Servers/201 → UDM-routed (Phase B).
  # `vsan` SDN VNet (conflict-free; no PVE-host IP on 209). Append-only.
  # REQUIRES the enp6s23 netplan stanza (k8s-node-fixes.yml) to be applied
  # FIRST + the node drained before this reboots it — see
  # docs/runbooks/bgp-phase-a-209-node-interface.md (failed-attempt warning).
  network_device {
    bridge = "vsan"
    model  = "virtio"
    mtu    = 9000
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
  }

  agent {
    enabled = true
  }

  # Hardware watchdog: Proxmox attaches an emulated i6300esb device.
  # The guest watchdog daemon pets it every few seconds; if the kernel
  # or userspace hangs past the timeout, Proxmox forcibly resets the
  # VM. Configured via the ansible task `Enable hardware watchdog` in
  # infra/ansible/playbooks/k8s-node-fixes.yml.
  watchdog {
    model  = "i6300esb"
    action = "reset"
  }

  started = true
  on_boot = true
}

# GPU worker node with Tesla P40 passthrough
resource "proxmox_virtual_environment_vm" "k8s_gpu1" {
  node_name   = local.node_name
  vm_id       = 120
  name        = "k8s-gpu1"
  description = "Managed by Terraform (k8s GPU worker)"
  tags        = ["terraform", "k8s", "worker", "gpu"]

  machine = "q35"
  bios    = "ovmf"

  # Secure Boot caveat: `pre_enrolled_keys = false` only controls the
  # INITIAL contents of the EFI vars when the disk is first created. The
  # underlying cloud image still ships with SB enabled in OVMF, and the
  # bpg/proxmox provider does not expose a `secure_boot` toggle.
  # NVIDIA out-of-tree kernel modules are not signed by Canonical, so
  # SB-enabled = blocked drivers (see docs/runbooks/gpu-secureboot.md).
  #
  # To DISABLE Secure Boot after the EFI disk has been created (one-time):
  #   ssh root@pve.wind.etherport.net \
  #     'qm set 120 --delete efidisk0 && \
  #      qm set 120 --efidisk0 local-zfs:0,efitype=4m,pre-enrolled-keys=0'
  #   # then reboot VM 120 — OVMF rebuilds vars with SB off.
  #
  # Alternative: enroll NVIDIA's signing key via MOK (more maintenance burden
  # on driver version bumps — not recommended for a homelab).
  efi_disk {
    datastore_id      = local.storage_name
    file_format       = "raw"
    type              = "4m"
    pre_enrolled_keys = false
  }

  clone {
    vm_id = 9001
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

  # MTU 9000 on every NIC to match bond0/vmbr0/SDN-zone jumbo frames.
  # See note in control_plane resource.
  network_device {
    bridge = "servers"
    model  = "virtio"
    mtu    = 9000
  }

  network_device {
    bridge = "clients"
    model  = "virtio"
    mtu    = 9000
  }

  network_device {
    bridge = "iot"
    model  = "virtio"
    mtu    = 9000
  }

  network_device {
    bridge = "security"
    model  = "virtio"
    mtu    = 9000
  }

  # Storage VLAN — Ceph mon + OSDs live on 10.10.210.0/24 (VLAN 210).
  # MTU 9000 to match the underlying bond0/vmbr0 jumbo frames.
  network_device {
    bridge  = local.bridge_name
    model   = "virtio"
    vlan_id = 210
    mtu     = 9000
  }

  # NAS/storage VLAN 209 (net5 → enp6s23) — M18 BGP Phase A. gpu1 runs NAS
  # workloads (Plex GPU transcode). See workers resource + the Phase A runbook.
  network_device {
    bridge = "vsan"
    model  = "virtio"
    mtu    = 9000
  }

  hostpci {
    device  = "hostpci0"
    mapping = "gpu-tesla-p40"
    pcie    = true
    rombar  = true
  }

  initialization {
    datastore_id = local.storage_name
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
    ip_config {
      ipv4 {
        address = "10.10.201.60/24"
        gateway = local.gateway_201
      }
    }
  }

  agent {
    enabled = true
  }

  # Hardware watchdog: Proxmox attaches an emulated i6300esb device.
  # The guest watchdog daemon pets it every few seconds; if the kernel
  # or userspace hangs past the timeout, Proxmox forcibly resets the
  # VM. Configured via the ansible task `Enable hardware watchdog` in
  # infra/ansible/playbooks/k8s-node-fixes.yml.
  watchdog {
    model  = "i6300esb"
    action = "reset"
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
    workers        = 5                   # 4 standard + 1 GPU
    total_vcpus    = 3 * 4 + 4 * 4 + 8   # 36 vCPUs
    total_ram_gb   = 3 * 4 + 4 * 10 + 20 # 72 GB
  }
}
