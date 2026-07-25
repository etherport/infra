# UniFi port forwards.
#
# Three entries imported from live UDM state:
#   - Twilio-Media-Signal: UDP 10000-20000 → 10.10.201.40 (Asterisk SBC RTP)
#   - Twilio-SIP:          TCP 5061        → 10.10.201.40 (Asterisk SBC TLS SIP)
#   - Wireguard Local:     tcp+udp 9821    → 10.10.201.20 (K8s WG VIP, primary site VPN)
#
# Twilio cutover (task #80, 2026-06-06): the two Twilio forwards were repointed
# from UniFi Talk (10.10.199.1, UDP 6767 + RTP 10000-60000) to the Asterisk SBC
# (10.10.201.40). Twilio now reaches the SBC over TLS:5061 + sRTP; the SBC
# bridges to Talk on the LAN. Talk no longer faces the WAN. UniFi auto-creates
# the matching "Allow Port Forward" firewall policy for each (External→Trusted).
#
# M125 (2026-07-02): converted from the archived paultyng/unifi schema to the
# ubiquiti-community/unifi fork v0.41.25 schema:
#   - fwd_ip/fwd_port → forward = { ip, port }
#   - dst_port → wan = { port } (fork nested `wan` attr: interface/ip_address/port)
#   - src_ip → source_limiting = { ip, ... } (nested; still only in ignore_changes)
#   - paultyng's flat `port_forward_interface` → the fork's `wan.interface` —
#     it's on every live record, kept in `lifecycle.ignore_changes` to avoid noise.
#   - `enabled` is deprecated in the fork (default on) — dropped.

resource "unifi_port_forward" "twilio_media_signal" {
  name = "Twilio-Media-Signal"
  # M125: `enabled = true` dropped — deprecated in fork; default on.
  protocol = "udp"

  forward = {
    ip   = "10.10.201.40" # Asterisk SBC (was 10.10.199.1 Talk)
    port = "10000-20000"  # Asterisk rtp.conf range (was 10000-60000)
  }

  wan = {
    port = "10000-20000" # M125: was dst_port
  }

  lifecycle {
    # M125: was [port_forward_interface, src_ip] — mapped to the fork's
    # wan.interface (nested path) + the whole source_limiting attribute
    # (src_ip → source_limiting.ip).
    ignore_changes = [wan, source_limiting] # fork reads wan.ip_address="any" but rejects it as config; ignore whole wan (masks wan.port drift — rule is static)
  }
}

import {
  to = unifi_port_forward.twilio_media_signal
  id = "68574dc6eba671484c835ce3"
}

resource "unifi_port_forward" "twilio_sip" {
  name = "Twilio-SIP"
  # M125: `enabled = true` dropped — deprecated in fork; default on.
  protocol = "tcp" # TLS = TCP (was udp)

  forward = {
    ip   = "10.10.201.40" # Asterisk SBC (was 10.10.199.1 Talk)
    port = "5061"         # TLS SIP (was UDP 6767)
  }

  wan = {
    port = "5061" # M125: was dst_port
  }
  # source_limiting.ip omitted — live has null (was src_ip); inbound INVITEs are
  # ACL'd to Twilio's signaling ranges at the Asterisk layer (pjsip identify),
  # matching prior posture.

  lifecycle {
    # M125: was [port_forward_interface, src_ip] — mapped to the fork's
    # wan.interface (nested path) + the whole source_limiting attribute
    # (src_ip → source_limiting.ip).
    ignore_changes = [wan.interface, source_limiting]
  }
}

import {
  to = unifi_port_forward.twilio_sip
  id = "685778d7cde5956cd3eb8cac"
}

resource "unifi_port_forward" "wireguard_local" {
  name = "Wireguard Local"
  # M125: `enabled = true` dropped — deprecated in fork; default on.
  protocol = "tcp_udp"

  forward = {
    ip   = "10.10.201.20"
    port = "9821"
  }

  wan = {
    port = "9821" # M125: was dst_port
  }
  # source_limiting.ip omitted — live has null (was src_ip)

  lifecycle {
    # M125: was [port_forward_interface, src_ip] — mapped to the fork's
    # wan.interface (nested path) + the whole source_limiting attribute
    # (src_ip → source_limiting.ip).
    ignore_changes = [wan.interface, source_limiting]
  }
}

import {
  to = unifi_port_forward.wireguard_local
  id = "69eadd2dd1dc5893673d8362"
}

# "Wireguard Travel" (UDP 9820, disabled) was removed 2026-07-01 with the travel-VPN
# tooling deletion (M110). The rule had been disabled since the 2026-05 outbound
# re-architecture; the forward was destroyed via this stack (plan = 1 to destroy).

# M154 (2026-07-25): Tailscale subnet-router static endpoint. Gives TS the same
# deterministic inbound path the WG VIP has — without it, every TS connection
# depends on NAT hole-punching and silently degrades to the DERP relay when the
# client-side NAT is uncooperative (the "slow over TS, fine over WG" issue).
# Path: WAN:41641/udp → MetalLB VIP 10.10.201.74 (svc tailscale/
# ts-router-static-endpoint) → router pod's pinned tailscaled :41641. The pod
# advertises WAN:41641 via TS_DEBUG_PRETENDPOINT (proxyclass-static-endpoint.yaml).
resource "unifi_port_forward" "tailscale_static_endpoint" {
  name     = "Tailscale-Static-Endpoint"
  protocol = "udp"

  forward = {
    ip   = "10.10.201.74" # MetalLB VIP → ts-router pod :41641
    port = "41641"
  }

  wan = {
    port = "41641"
  }

  lifecycle {
    ignore_changes = [wan.interface, source_limiting]
  }
}
