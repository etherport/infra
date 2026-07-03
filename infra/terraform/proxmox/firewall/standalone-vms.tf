# =============================================================================
# M77 — Selective PVE firewall for the STANDALONE VMs (k8s nodes EXCLUDED — their
# traffic is owned by Cilium H3 NetPol + M66 WireGuard + UDM zones).
#
# CURRENT STATE: ALL 6 standalone VMs are DEFAULT-DENY INBOUND
# (input_policy = DROP, complete 2026-06-28) with per-VM allow-lists below.
# asterisk's external legs were SOURCE-SCOPED to Twilio ranges (Stage 2b,
# 2026-06-29). vpn-fallback's WireGuard stays any-source deliberately (WG is
# crypto-authenticated; IP-scoping to the single AWS EIP peer is marginal).
#
# Rollout was staged like H37 (lock-out-safe): Stage 1 permissive/observe
# (ACCEPT + inbound logging, allow-lists built from `ss` + the firewall log),
# then per-VM ACCEPT -> DROP flips — batch 1 dns-fallback (1001) + gh-runner
# (1003), batch 2 step-ca (1006), devbox (1005), vpn-fallback (1002),
# asterisk (1004). This avoided the H37 Ceph/IPMI latent-break class (a needed
# allow missing from a default-deny that only bites later). History:
# docs/planning/session-log.md 2026-06-25 → 2026-06-29.
#
# The NIC firewall flag (`firewall = true`) is set in ../standalone-vms/main.tf.
# Apply THIS stack FIRST so the rules exist before the NIC firewall activates
# (no lockout window). rpcbind:111 (exposed on every VM by default) is
# intentionally NOT allowed -> the eventual default-deny closes that exposure.
#
# Per-VM required inbound (from `ss -tlnp/-ulnp`, 2026-06-25):
#   dns-fallback 1001: 53 tcp+udp (DNS clients), 5380 (mgmt), + baseline   [Stage 2: DROP 2026-06-28]
#   vpn-fallback    1002: WireGuard udp (any-src; AWS peer 44.240.60.80), + baseline  [Stage 2: DROP 2026-06-28]
#   gh-runner    1003: baseline only (outbound-only runner)                [Stage 2: DROP 2026-06-28]
#   asterisk-sbc 1004: SIP 5060/5061 + RTP range (any-src; Twilio scope=2b), + baseline  [Stage 2: DROP 2026-06-28]
#   devbox       1005: tailscale udp + baseline (Claude session host)      [Stage 2: DROP 2026-06-28]
#   step-ca      1006: step-ca API :8443 (cert clients + tailnet) + baseline (M76 SSH CA)  [Stage 2: DROP 2026-06-28]
# =============================================================================

locals {
  # M77 per-VM inbound policy. "ACCEPT" = Stage-1 permissive (nothing denied);
  # "DROP" = Stage-2 default-deny inbound — only the per-VM allow-list below
  # passes. PVE's firewall is STATEFUL, so established/related replies to
  # outbound-initiated connections are always allowed regardless of this policy
  # (a DROP only blocks NEW unsolicited inbound). Flip a VM to DROP once its
  # Stage-1 allow-list is confirmed complete (ss-enumerated listeners, above).
  vm_input_policy = {
    dns_fallback = "DROP" # Stage 2 (2026-06-28): 53 tcp/udp + 5380(mgmt) + baseline → all allow-listed
    gh_runner    = "DROP" # Stage 2 (2026-06-28): outbound-only runner; baseline (SSH + 9100) only
    # Stage 2 batch 2 (2026-06-28): the remaining 4 → default-deny inbound. The existing per-VM
    # port allows are KEPT as-is (source narrowing is a separate, deliberate follow-up — see notes),
    # so the flip only closes UNLISTED ports (e.g. rpcbind:111). PVE firewall is stateful, so live
    # sessions (WG tunnel, SIP registrations, the devbox session) survive the policy change.
    step_ca      = "DROP" # :8443 from Servers VLAN + tailnet, SSH from mgmt — allows ALREADY source-scoped.
    devbox       = "DROP" # closes rpcbind:111; access kept via SSH(mgmt-admin) + tailscale (devbox-initiated
    #                       → conntrack); no VNC listener. Recoverable via CI (apply runs on gh-runner, not devbox).
    vpn_fallback = "DROP" # WireGuard 9820-9821 (any-source kept — WG is crypto-authenticated, so IP-scoping
    #                       is marginal; the single peer is the AWS EIP 44.240.60.80 if ever wanted) + baseline.
    asterisk_sbc = "DROP" # SIP 5060/5061 + RTP 10000-20000 + baseline. Stage-2b (2026-06-29) SOURCE-SCOPED
    #                       these: 5061←twilio-signaling IPset, 5060←asterisk-internal (Talk/LAN), RTP←Twilio
    #                       media (168.86.128.0/18)+internal. Mirrors the SBC pjsip identify ACL (can't drop a
    #                       call the SBC would accept). ⚠️ 911-CRITICAL: confirm with a live in/outbound call.
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
  # NB encrypted DNS (DoT tcp/853, DoH tcp/443) is intentionally NOT opened here: this is the
  # plain-:53 VM FALLBACK resolver (10.10.201.6) — encrypted DNS terminates at the k8s Technitium
  # VIP (10.10.201.5), not this box. Under the M77 default-deny, 853/443 are therefore closed BY
  # DESIGN, not oversight. If DoT/DoH is ever enabled on this VM, add the matching allow(s) here.
}

# ---- vpn-fallback (1002): WireGuard site-to-site to AWS -------------------------
resource "proxmox_virtual_environment_firewall_options" "vpn_fallback" {
  node_name     = var.node_name
  vm_id         = 1002
  enabled       = true
  input_policy  = local.vm_input_policy.vpn_fallback
  output_policy = "ACCEPT"
  log_level_in  = "info"
}
resource "proxmox_virtual_environment_firewall_rules" "vpn_fallback" {
  node_name  = var.node_name
  vm_id      = 1002
  depends_on = [proxmox_virtual_environment_firewall_options.vpn_fallback]

  rule {
    security_group = proxmox_virtual_environment_cluster_firewall_security_group.vm_baseline.name
    comment        = "M77 baseline (SSH + node_exporter)"
  }
  # NB the live rule's comment string predates the Stage-2 decision: source
  # stays ANY deliberately (WG is crypto-authenticated; scoping to the sole
  # AWS EIP peer 44.240.60.80 was judged marginal — see vm_input_policy notes).
  # Don't edit the `comment` argument just to fix the prose — it's applied
  # PVE-side and would show as a plan diff.
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "udp"
    dport   = "9820:9821"
    log     = "nolog"
    comment = "WireGuard to AWS. STAGE 2: scope source to the AWS VPN peer public IP."
  }
  rule {
    # VRRP (IP proto 112) from the Servers VLAN — WITHOUT this, vpn-fallback can
    # never HEAR the K8s WG pod's higher-priority adverts and refuses to yield the
    # VIP -> persistent split-brain (both hold 10.10.201.20; ARP-race blackhole of
    # all UDM-routed AWS traffic). Root-caused 2026-07-03: M77's default-deny
    # (2026-06-28) silently broke VRRP convergence; the first real failover exposed
    # it. Its own adverts always went OUT (output ACCEPT) — asymmetric.
    type    = "in"
    action  = "ACCEPT"
    proto   = "112"
    source  = "10.10.201.0/24"
    log     = "nolog"
    comment = "VRRP adverts from the K8s WG pod (keepalived) - split-brain fix 2026-07-03"
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
# ---- asterisk Stage-2b source scoping (2026-06-29) --------------------------------------
# Twilio SIP-signaling /30s (8 edges) — the SAME set the SBC's pjsip `identify` ACL trusts
# (infra/ansible/playbooks/asterisk-sbc.yml twilio_signaling_nets), so this firewall scope can
# only ever be a SUPERSET-or-equal of what the SBC accepts → it cannot drop a call the SBC would
# have answered. SIP-TLS :5061 is the INTERNET-facing leg (UDM forwards it to .40).
resource "proxmox_virtual_environment_firewall_ipset" "twilio_signaling" {
  name    = "twilio-signaling"
  comment = "M77 Stage-2b: Twilio SIP signaling /30s (8 edges) — mirrors the SBC pjsip identify ACL"
  dynamic "cidr" {
    for_each = toset([
      "54.172.60.0/30", "54.244.51.0/30", "54.171.127.192/30", "35.156.191.128/30",
      "54.65.63.192/30", "54.169.127.128/30", "54.252.254.64/30", "177.71.206.192/30",
    ])
    content { name = cidr.value }
  }
}
# Internal legs: the UniFi Talk bridge (VLAN-199) + the Servers VLAN (201, for SBC-local
# mgmt/testing). 5060 (plain SIP) + RTP from these are LAN-only (NOT internet-facing).
resource "proxmox_virtual_environment_firewall_ipset" "asterisk_internal" {
  name    = "asterisk-internal"
  comment = "M77 Stage-2b: internal SIP/RTP sources for the SBC — UniFi Talk (199) + Servers (201)"
  dynamic "cidr" {
    for_each = toset(["10.10.199.0/24", "10.10.201.0/24"])
    content { name = cidr.value }
  }
}

resource "proxmox_virtual_environment_firewall_rules" "asterisk_sbc" {
  node_name  = var.node_name
  vm_id      = 1004
  depends_on = [proxmox_virtual_environment_firewall_options.asterisk_sbc]

  rule {
    security_group = proxmox_virtual_environment_cluster_firewall_security_group.vm_baseline.name
    comment        = "M77 baseline (SSH + node_exporter)"
  }
  # Plain SIP (udp 5060) — internal UniFi Talk bridge leg only (NOT Twilio; Twilio uses 5061/TLS).
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+${proxmox_virtual_environment_firewall_ipset.asterisk_internal.name}"
    proto   = "udp"
    dport   = "5060"
    log     = "nolog"
    comment = "SIP (udp) from the internal Talk/LAN bridge only"
  }
  # SIP-TLS (tcp 5061) — Twilio-only (internet-facing; backstopped by pjsip identify).
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+${proxmox_virtual_environment_firewall_ipset.twilio_signaling.name}"
    proto   = "tcp"
    dport   = "5061"
    log     = "nolog"
    comment = "SIP-TLS (tcp) from Twilio signaling edges only"
  }
  # RTP media (udp 10000:20000) — Twilio media range (the higher-value scope: RTP has NO app-layer
  # ACL) + the internal Talk/LAN media. Two rules (different source sets).
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "168.86.128.0/18" # twilio_media_net (asterisk-sbc.yml)
    proto   = "udp"
    dport   = "10000:20000"
    log     = "nolog"
    comment = "RTP media from Twilio (sRTP)"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+${proxmox_virtual_environment_firewall_ipset.asterisk_internal.name}"
    proto   = "udp"
    dport   = "10000:20000"
    log     = "nolog"
    comment = "RTP media from the internal Talk/LAN bridge"
  }
}

# ---- devbox (1005): Claude dev session host + Tailscale ---------------------
# ⚠️ The Claude Code dev sessions run ON this VM and it is default-deny inbound —
# NEVER drop the SSH-from-mgmt-admin baseline or the tailscale UDP allow, or you
# lose access / the operator's path in. Recovery if it happens: CI applies run on
# gh-runner (not devbox), plus PVE console.
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

# M128 (2026-07-02): vpn-local -> vpn-fallback resource-address migration (state-only).
moved {
  from = proxmox_virtual_environment_firewall_options.vpn_local
  to   = proxmox_virtual_environment_firewall_options.vpn_fallback
}
moved {
  from = proxmox_virtual_environment_firewall_rules.vpn_local
  to   = proxmox_virtual_environment_firewall_rules.vpn_fallback
}
