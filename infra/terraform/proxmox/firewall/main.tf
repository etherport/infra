terraform {
  required_version = ">= 1.14"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.106"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "${var.proxmox_token_id}=${var.proxmox_token_secret}"
  insecure  = true
}

# =============================================================================
# H37 — Proxmox HOST firewall (management plane). STAGED, lock-out-safe.
#
# STAGE 1 (this config): firewall ENABLED but PERMISSIVE — input_policy = ACCEPT
#   + inbound logging on. Nothing is denied; we install the full ruleset
#   (mgmt-admin IPset + pve-mgmt security group + node rule) and watch the host
#   firewall log to confirm admin access (TS / WG / mini / laptop) matches the
#   allows and to pin the real SNAT source IPs.
#
# STAGE 2 (later, deliberate, with IPMI/console break-glass confirmed): flip
#   `local.input_policy` ACCEPT -> DROP. Then only mgmt-admin reaches the host
#   management plane; everything else (IoT/guest/security VLANs, internet) is
#   dropped. Reversible by flipping back.
#
# k8s nodes + standalone VMs are NOT touched here (all VM NICs are firewall=0).
# Selective VM firewalling is tracked separately as M77. See
# docs/planning/zero-trust-assessment-2026-06-17.md.
# =============================================================================

locals {
  # STAGE 1 = "ACCEPT" (permissive/observe). STAGE 2 = "DROP" (enforce).
  # Flipped to DROP 2026-06-17 after the observation window confirmed all admin
  # sources (mini, TS/WG via 201, backup-WG 192.168.3.2) are in mgmt-admin and
  # nothing legit hits 22/8006/3128 from outside it. Revert to "ACCEPT" to roll back.
  input_policy = "DROP"
}

# --- Datacenter firewall framework -------------------------------------------
resource "proxmox_virtual_environment_cluster_firewall" "this" {
  enabled = true

  # Host inbound default. Stage 1 = ACCEPT (deny nothing). Flip to DROP for Stage 2.
  input_policy = local.input_policy
  # Never constrain the host's own egress or VM-forwarded (bridged) traffic —
  # the k8s VXLAN/BGP/pod fabric bridges through this host.
  output_policy  = "ACCEPT"
  forward_policy = "ACCEPT"
  ebtables       = false
}

# --- Node firewall (pve) -----------------------------------------------------
resource "proxmox_node_firewall" "pve" {
  node_name = var.node_name
  enabled   = true

  # Stage 1 observation: log inbound so we can see real admin source IPs
  # (TS subnet-router / WG-pod SNAT / mini / laptop) before the DROP flip.
  log_level_in = "info"

  depends_on = [proxmox_virtual_environment_cluster_firewall.this]
}

# --- Trusted admin sources (IPset) -------------------------------------------
resource "proxmox_virtual_environment_firewall_ipset" "mgmt_admin" {
  name    = "mgmt-admin"
  comment = "H37: trusted admin sources for the PVE host management plane"

  dynamic "cidr" {
    for_each = var.mgmt_admin_cidrs
    content {
      name = cidr.value
    }
  }
}

# --- Security group: allow management services from trusted admin sources -----
resource "proxmox_virtual_environment_cluster_firewall_security_group" "pve_mgmt" {
  name    = "pve-mgmt"
  comment = "H37: PVE host management plane allows (API/SSH/SPICE/ping)"

  rule {
    type   = "in"
    action = "ACCEPT"
    source = "+${proxmox_virtual_environment_firewall_ipset.mgmt_admin.name}"
    proto  = "tcp"
    dport  = "22,3128,8006"
    # Enforcing (Stage 2): nolog on the allow rule to cut noise. (Set back to
    # "info" if you need to re-observe admin matches.)
    log     = "nolog"
    comment = "SSH(22) + SPICE(3128) + PVE API/UI(8006) from mgmt-admin"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+${proxmox_virtual_environment_firewall_ipset.mgmt_admin.name}"
    macro   = "Ping"
    log     = "nolog"
    comment = "ICMP echo from mgmt-admin"
  }
}

# --- Security group: allow Ceph storage traffic from the storage VLAN --------
# H37 OVERSIGHT FIX (2026-06-18). The host runs the Ceph mon + OSDs on the
# dedicated storage VLAN interface vmbr0.210 (10.10.210.41); the K8s nodes are
# Ceph RBD CLIENTS on that same VLAN (10.10.210.0/24). When input_policy flipped
# to DROP (Stage 2, 2026-06-17) there was NO rule permitting Ceph, so every NEW
# rbd map/create from K8s was dropped. Existing connections survived via
# conntrack (mounted volumes kept working) so it stayed LATENT until a fresh map
# — which wedged technitium-1 and blocked all dynamic provisioning ~30h later.
# This restores Ceph client access. Scoped to the dedicated storage VLAN only
# (not a general open-up). See docs/planning/session-log.md 2026-06-18.
resource "proxmox_virtual_environment_cluster_firewall_security_group" "pve_ceph" {
  name    = "pve-ceph"
  comment = "H37: Ceph mon/OSD access from the storage VLAN (K8s RBD clients)"

  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = var.ceph_storage_cidr
    proto   = "tcp"
    dport   = "3300,6789,6800:7300"
    log     = "nolog"
    comment = "Ceph mon (3300/6789) + OSD/MGR/MDS (6800-7300) from storage VLAN"
  }
}

# --- Attach the security groups to the node (host) ---------------------------
resource "proxmox_virtual_environment_firewall_rules" "pve_node" {
  node_name = var.node_name

  rule {
    security_group = proxmox_virtual_environment_cluster_firewall_security_group.pve_mgmt.name
    comment        = "H37: PVE host management plane (see pve-mgmt security group)"
  }

  rule {
    security_group = proxmox_virtual_environment_cluster_firewall_security_group.pve_ceph.name
    comment        = "H37 fix: Ceph storage plane (see pve-ceph security group)"
  }

  depends_on = [proxmox_node_firewall.pve]
}
