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

# =============================================================================
# H37 — Proxmox HOST firewall (management plane). DEFAULT-DENY INBOUND
# (input_policy = DROP, enforced since 2026-06-17).
#
# Only the allow-listed traffic reaches the host: mgmt-admin sources to the
# management plane (pve-mgmt), the Ceph storage VLAN to mon/OSD (pve-ceph),
# and the K8s/Servers VLAN to the ipmi_exporter :9290 (pve-ipmi) +
# node_exporter :9100 (pve-nodeexp). ⚠️ These are the FOUR required allows —
# never tighten this stack without keeping all four (see CLAUDE.md §5; the
# Ceph and IPMI groups each began life as a latent default-deny break).
#
# Rollout history (Stage-1 permissive/observe window 2026-06-17, then the
# DROP flip): docs/planning/archive/zero-trust-assessment-2026-06-17.md +
# session-log. Rollback = flip `local.input_policy` back to "ACCEPT".
#
# k8s nodes are NOT touched here; the standalone VMs have their own per-VM
# firewall (M77) in standalone-vms.tf.
# =============================================================================

locals {
  # "DROP" = default-deny inbound (enforced). Flipped from the Stage-1 "ACCEPT"
  # observe mode on 2026-06-17 after the observation window confirmed all admin
  # sources (mini, TS/WG via 201, backup-WG 192.168.3.2) are in mgmt-admin and
  # nothing legit hits 22/8006/3128 from outside it. Revert to "ACCEPT" to roll back.
  input_policy = "DROP"
}

# --- Datacenter firewall framework -------------------------------------------
resource "proxmox_virtual_environment_cluster_firewall" "this" {
  enabled = true

  # Host inbound default — DROP (default-deny; see locals above for rollback).
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

  # Keep inbound logging on: under the DROP policy this records what gets
  # denied (the fastest way to spot the next missing-allow latent break).
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

# --- Security group: allow the IPMI exporter scrape from the K8s subnet -------
# H37 OVERSIGHT FIX (2026-06-20). The host runs the in-band ipmi_exporter on
# :9290 (deployed by infra/ansible/playbooks/ipmi-monitoring.yml); Prometheus in
# the K8s cluster scrapes it. When input_policy flipped to DROP (Stage 2) there
# was NO rule permitting :9290, so the scrape was dropped -> `up{job="pve-ipmi"}`
# went 0 -> TargetDown (2026-06-20T13:16Z). SAME latent-firewall class as
# pve-ceph (a needed allow missing from the default-deny). Pod->host scrape
# traffic is Cilium-masqueraded to the node IP, so the source is the Servers/K8s
# VLAN. Scoped to that /24 + the single port only.
resource "proxmox_virtual_environment_cluster_firewall_security_group" "pve_ipmi" {
  name    = "pve-ipmi"
  comment = "H37: IPMI exporter scrape (:9290) from the K8s/Servers VLAN"

  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = var.ipmi_scrape_cidr
    proto   = "tcp"
    dport   = "9290"
    log     = "nolog"
    comment = "Prometheus ipmi_exporter scrape (:9290) from K8s nodes"
  }
}

# --- Security group: allow the node_exporter scrape from the K8s subnet -------
# H42 (2026-07-01). The pve HOST's OS metrics were a monitoring blind spot —
# base.yml never ran here (its unattended-upgrades Automatic-Reboot would be a
# hypervisor-wide hazard), so node_exporter is deployed by the standalone
# infra/ansible/playbooks/node-exporter.yml instead. Same scrape path as
# pve-ipmi: Prometheus pod traffic is Cilium-masqueraded to the node IPs, so
# scope to the Servers/K8s VLAN + the single port. The PVE host firewall now
# has FOUR required allows — mgmt, Ceph, IPMI (:9290), node_exporter (:9100).
resource "proxmox_virtual_environment_cluster_firewall_security_group" "pve_nodeexp" {
  name    = "pve-nodeexp"
  comment = "H42: node_exporter scrape (:9100) from the K8s/Servers VLAN"

  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = var.ipmi_scrape_cidr
    proto   = "tcp"
    dport   = "9100"
    log     = "nolog"
    comment = "Prometheus node_exporter scrape (:9100) from K8s nodes"
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

  rule {
    security_group = proxmox_virtual_environment_cluster_firewall_security_group.pve_ipmi.name
    comment        = "H37 fix: IPMI exporter scrape (see pve-ipmi security group)"
  }

  rule {
    security_group = proxmox_virtual_environment_cluster_firewall_security_group.pve_nodeexp.name
    comment        = "H42: node_exporter scrape (see pve-nodeexp security group)"
  }

  depends_on = [proxmox_node_firewall.pve]
}
