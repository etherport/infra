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
#   STAGE 2 (per-VM, deliberate): flip `local.vm_input_policy.<vm>` ACCEPT ->
#     DROP for a VM once its log is clean, after scoping the external sources.
#     STARTED 2026-06-28: dns-fallback (1001) + gh-runner (1003) -> DROP (the two
#     safe first candidates — no external-source scoping needed; allow-lists are
#     fully internal/baseline). The remaining 4 stay ACCEPT pending source scoping
#     (vpn-local AWS peer, asterisk Twilio ranges) or extra care (devbox session,
#     step-ca fleet clients).
#
# The NIC firewall flag (`firewall = true`) is set in ../standalone-vms/main.tf.
# Apply THIS stack FIRST so the rules exist before the NIC firewall activates
# (no lockout window). rpcbind:111 (exposed on every VM by default) is
# intentionally NOT allowed -> the eventual default-deny closes that exposure.
#
# Per-VM required inbound (from `ss -tlnp/-ulnp`, 2026-06-25):
#   dns-fallback 1001: 53 tcp+udp (DNS clients), 5380 (mgmt), + baseline   [Stage 2: DROP 2026-06-28]
#   vpn-local    1002: WireGuard udp (AWS peer — scope at Stage 2), + baseline
#   gh-runner    1003: baseline only (outbound-only runner)                [Stage 2: DROP 2026-06-28]
#   asterisk-sbc 1004: SIP 5060/5061 + RTP range (Twilio+LAN — scope at Stage 2), + baseline
#   devbox       1005: tailscale udp + baseline (Claude session lives here — Stage 2 with care)
#   step-ca      1006: step-ca API :8443 (cert clients + tailnet) + baseline (M76 SSH CA)
# =============================================================================

locals {
  # M77 per-VM inbound policy. "ACCEPT" = Stage-1 permissive (nothing denied);
  # "DROP" = Stage-2 default-deny inbound — only the per-VM allow-list below
  # passes. PVE's firewall is STATEFUL, so established/related replies to
  # outbound-initiated connections are always allowed regardless of this policy
  # (a DROP only blocks NEW unsolicited inbound). Flip a VM to DROP once its
  # Stage-1 allow-list is confirmed complete (ss-enumerated listeners, above).
  vm_input_policy = {
    dns_fallback = "DROP"   # Stage 2 (2026-06-28): listeners = 53 tcp/udp + 5380(mgmt) + baseline → all allow-listed
    vpn_local    = "ACCEPT" # Stage 1 — scope the AWS WireGuard peer source IP first
    gh_runner    = "DROP"   # Stage 2 (2026-06-28): outbound-only runner; baseline (SSH + 9100) only
    asterisk_sbc = "ACCEPT" # Stage 1 — scope Twilio SIP/RTP source ranges first
    devbox       = "ACCEPT" # Stage 1 — Claude session host; flip with extra care (keep SSH + tailnet)
    step_ca      = "ACCEPT" # Stage 1 — confirm the fleet + tailnet cert clients in the log first
  }
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
  input_policy  = local.vm_input_policy.dns_fallback
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
  input_policy  = local.vm_input_policy.vpn_local
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
  input_policy  = local.vm_input_policy.gh_runner
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
  input_policy  = local.vm_input_policy.asterisk_sbc
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
  input_policy  = local.vm_input_policy.devbox
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

# ---- step-ca (1006): SSH Certificate Authority (M76) ------------------------
# Clients that mint certs = the whole Ubuntu fleet (k8s nodes + standalone VMs +
# the devbox agent + the gh-runner CI) — all on the Servers/K8s VLAN — plus remote
# humans doing `step ssh login` over the tailnet. CA API listens on :8443.
resource "proxmox_virtual_environment_firewall_options" "step_ca" {
  node_name     = var.node_name
  vm_id         = 1006
  enabled       = true
  input_policy  = local.vm_input_policy.step_ca
  output_policy = "ACCEPT"
  log_level_in  = "info"
}
resource "proxmox_virtual_environment_firewall_rules" "step_ca" {
  node_name  = var.node_name
  vm_id      = 1006
  depends_on = [proxmox_virtual_environment_firewall_options.step_ca]

  rule {
    security_group = proxmox_virtual_environment_cluster_firewall_security_group.vm_baseline.name
    comment        = "M77 baseline (SSH + node_exporter)"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = var.ipmi_scrape_cidr # 10.10.201.0/24 — the cert-minting fleet (nodes + VMs + devbox + gh-runner)
    proto   = "tcp"
    dport   = "8443"
    log     = "nolog"
    comment = "step-ca API (:8443) from the Servers/K8s VLAN cert clients"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "100.64.0.0/10"
    proto   = "tcp"
    dport   = "8443"
    log     = "nolog"
    comment = "step-ca API (:8443) for remote human `step ssh login` over the tailnet"
  }
}
