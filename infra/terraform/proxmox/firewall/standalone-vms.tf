# =============================================================================
# M77 — Selective PVE firewall for the STANDALONE VMs (k8s nodes EXCLUDED — their
# traffic is owned by Cilium H3 NetPol + M66 WireGuard + UDM zones). Staged like
# H37 (lock-out-safe):
#   STAGE 1 (this config): per-VM firewall ENABLED but PERMISSIVE
#     (input_policy = ACCEPT) with inbound logging ON. NOTHING is denied; we
#     install the full allow-list and watch the PVE firewall log to confirm it
#     covers real inbound (and to pin the external source IPs — Twilio for SIP,
#     the AWS peer for WireGuard) before denying anything. This avoids repeating
#     the H37 Ceph/IPMI latent-break class (a needed allow missing from a
#     default-deny that only bites later).
#   STAGE 2 (later, per-VM, deliberate): flip `local.vm_input_policy` ACCEPT ->
#     DROP for a VM once its log is clean, after scoping the external sources.
#
# The NIC firewall flag (`firewall = true`) is set in ../standalone-vms/main.tf.
# Apply THIS stack FIRST so the rules exist before the NIC firewall activates
# (no lockout window). rpcbind:111 (exposed on every VM by default) is
# intentionally NOT allowed -> the eventual default-deny closes that exposure.
#
# Per-VM required inbound (from `ss -tlnp/-ulnp`, 2026-06-25):
#   dns-fallback 1001: 53 tcp+udp (DNS clients), 5380 (mgmt), + baseline
#   vpn-local    1002: WireGuard udp (AWS peer — scope at Stage 2), + baseline
#   gh-runner    1003: baseline only (outbound-only runner)
#   asterisk-sbc 1004: SIP 5060/5061 + RTP range (Twilio+LAN — scope at Stage 2), + baseline
#   devbox       1005: tailscale udp + baseline (Claude session lives here — Stage 2 with care)
# =============================================================================

locals {
  # Stage 1: permissive everywhere (nothing denied). Flip to "DROP" per-VM at
  # Stage 2 by overriding this per resource (or split the local) once observed.
  vm_input_policy = "ACCEPT"
}

# Baseline allows every standalone VM gets: SSH from trusted admin (mgmt-admin
# IPset, reused from H37) + the node_exporter scrape from the K8s/Servers VLAN.
resource "proxmox_virtual_environment_cluster_firewall_security_group" "vm_baseline" {
  name    = "vm-baseline"
  comment = "M77: SSH(22) from mgmt-admin + node_exporter(9100) from the K8s/Servers VLAN"

  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+${proxmox_virtual_environment_firewall_ipset.mgmt_admin.name}"
    proto   = "tcp"
    dport   = "22"
    log     = "nolog"
    comment = "SSH from mgmt-admin"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = var.ipmi_scrape_cidr # 10.10.201.0/24 — Prometheus node_exporter scrape (masqueraded to node IPs)
    proto   = "tcp"
    dport   = "9100"
    log     = "nolog"
    comment = "node_exporter scrape from the K8s/Servers VLAN"
  }
}

# ---- dns-fallback (1001): Technitium DNS secondary + admin UI ----------------
resource "proxmox_virtual_environment_firewall_options" "dns_fallback" {
  node_name     = var.node_name
  vm_id         = 1001
  enabled       = true
  input_policy  = local.vm_input_policy
  output_policy = "ACCEPT"
  log_level_in  = "info"
}
resource "proxmox_virtual_environment_firewall_rules" "dns_fallback" {
  node_name  = var.node_name
  vm_id      = 1001
  depends_on = [proxmox_virtual_environment_firewall_options.dns_fallback]

  rule {
    security_group = proxmox_virtual_environment_cluster_firewall_security_group.vm_baseline.name
    comment        = "M77 baseline (SSH + node_exporter)"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "udp"
    dport   = "53"
    log     = "nolog"
    comment = "DNS (udp) from clients (it's a resolver)"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "53"
    log     = "nolog"
    comment = "DNS (tcp) from clients"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+${proxmox_virtual_environment_firewall_ipset.mgmt_admin.name}"
    proto   = "tcp"
    dport   = "5380"
    log     = "nolog"
    comment = "Technitium admin UI from mgmt-admin only"
  }
}

# ---- vpn-local (1002): WireGuard site-to-site to AWS -------------------------
resource "proxmox_virtual_environment_firewall_options" "vpn_local" {
  node_name     = var.node_name
  vm_id         = 1002
  enabled       = true
  input_policy  = local.vm_input_policy
  output_policy = "ACCEPT"
  log_level_in  = "info"
}
resource "proxmox_virtual_environment_firewall_rules" "vpn_local" {
  node_name  = var.node_name
  vm_id      = 1002
  depends_on = [proxmox_virtual_environment_firewall_options.vpn_local]

  rule {
    security_group = proxmox_virtual_environment_cluster_firewall_security_group.vm_baseline.name
    comment        = "M77 baseline (SSH + node_exporter)"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "udp"
    dport   = "9820:9821"
    log     = "nolog"
    comment = "WireGuard to AWS. STAGE 2: scope source to the AWS VPN peer public IP."
  }
}

# ---- gh-runner (1003): outbound-only CI runner — baseline only ---------------
resource "proxmox_virtual_environment_firewall_options" "gh_runner" {
  node_name     = var.node_name
  vm_id         = 1003
  enabled       = true
  input_policy  = local.vm_input_policy
  output_policy = "ACCEPT"
  log_level_in  = "info"
}
resource "proxmox_virtual_environment_firewall_rules" "gh_runner" {
  node_name  = var.node_name
  vm_id      = 1003
  depends_on = [proxmox_virtual_environment_firewall_options.gh_runner]

  rule {
    security_group = proxmox_virtual_environment_cluster_firewall_security_group.vm_baseline.name
    comment        = "M77 baseline (SSH + node_exporter) — runner is outbound-only otherwise"
  }
}

# ---- asterisk-sbc (1004): SIP/RTP SBC to Twilio -----------------------------
resource "proxmox_virtual_environment_firewall_options" "asterisk_sbc" {
  node_name     = var.node_name
  vm_id         = 1004
  enabled       = true
  input_policy  = local.vm_input_policy
  output_policy = "ACCEPT"
  log_level_in  = "info"
}
resource "proxmox_virtual_environment_firewall_rules" "asterisk_sbc" {
  node_name  = var.node_name
  vm_id      = 1004
  depends_on = [proxmox_virtual_environment_firewall_options.asterisk_sbc]

  rule {
    security_group = proxmox_virtual_environment_cluster_firewall_security_group.vm_baseline.name
    comment        = "M77 baseline (SSH + node_exporter)"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "udp"
    dport   = "5060"
    log     = "nolog"
    comment = "SIP (udp). STAGE 2: scope source to Twilio SIP signaling ranges + LAN."
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "5061"
    log     = "nolog"
    comment = "SIP-TLS (tcp). STAGE 2: scope to Twilio + LAN."
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "udp"
    dport   = "10000:20000"
    log     = "nolog"
    comment = "RTP media range (asterisk rtp.conf). STAGE 2: scope to Twilio media ranges."
  }
}

# ---- devbox (1005): Claude dev session host + Tailscale ---------------------
# ⚠️ The Claude Code dev sessions run ON this VM. Stage 2 (DROP) needs EXTRA care
# (keep SSH from mgmt-admin + the tailnet, + the tailscale UDP, or you lose access
# / the operator's path in). Stage 1 (ACCEPT) is harmless here.
resource "proxmox_virtual_environment_firewall_options" "devbox" {
  node_name     = var.node_name
  vm_id         = 1005
  enabled       = true
  input_policy  = local.vm_input_policy
  output_policy = "ACCEPT"
  log_level_in  = "info"
}
resource "proxmox_virtual_environment_firewall_rules" "devbox" {
  node_name  = var.node_name
  vm_id      = 1005
  depends_on = [proxmox_virtual_environment_firewall_options.devbox]

  rule {
    security_group = proxmox_virtual_environment_cluster_firewall_security_group.vm_baseline.name
    comment        = "M77 baseline (SSH + node_exporter)"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "100.64.0.0/10"
    proto   = "udp"
    log     = "nolog"
    comment = "Tailscale (tailnet CGNAT range) — direct WireGuard/DERP. Keep for Stage 2."
  }
}
