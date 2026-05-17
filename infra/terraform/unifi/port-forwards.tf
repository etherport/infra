# UniFi port forwards.
#
# Four entries imported from live UDM state:
#   - Twilio-Media-Signal: UDP 10000-60000 → 10.10.199.1 (Unifi Talk media)
#   - Twilio-SIP:          UDP 6767        → 10.10.199.1 (Unifi Talk SIP signalling)
#   - Wireguard Local:     tcp+udp 9821    → 10.10.201.20 (K8s WG VIP, primary site VPN)
#   - Wireguard Travel:    UDP 9820        → 10.10.201.20 (DISABLED — regional VPN now outbound)
#
# Note: target IPs `10.10.199.1` for Twilio are the UDM-on-Default-VLAN; Talk
# listens on that interface for SIP/RTP. Confirmed in the unifi-talk runbook.
#
# `port_forward_interface` is on every live record but the provider field is
# being deprecated — added to `lifecycle.ignore_changes` to avoid noise.

resource "unifi_port_forward" "twilio_media_signal" {
  name     = "Twilio-Media-Signal"
  enabled  = true
  fwd_ip   = "10.10.199.1"
  fwd_port = "10000-60000"
  dst_port = "10000-60000"
  protocol = "udp"


  lifecycle {
    ignore_changes = [port_forward_interface, src_ip]
  }
}

import {
  to = unifi_port_forward.twilio_media_signal
  id = "68574dc6eba671484c835ce3"
}

resource "unifi_port_forward" "twilio_sip" {
  name     = "Twilio-SIP"
  enabled  = true
  fwd_ip   = "10.10.199.1"
  fwd_port = "6767"
  dst_port = "6767"
  protocol = "udp"
  # src_ip omitted — live has null

  lifecycle {
    ignore_changes = [port_forward_interface, src_ip]
  }
}

import {
  to = unifi_port_forward.twilio_sip
  id = "685778d7cde5956cd3eb8cac"
}

resource "unifi_port_forward" "wireguard_local" {
  name     = "Wireguard Local"
  enabled  = true
  fwd_ip   = "10.10.201.20"
  fwd_port = "9821"
  dst_port = "9821"
  protocol = "tcp_udp"
  # src_ip omitted — live has null

  lifecycle {
    ignore_changes = [port_forward_interface, src_ip]
  }
}

import {
  to = unifi_port_forward.wireguard_local
  id = "69eadd2dd1dc5893673d8362"
}

# Currently disabled — regional VPN flow is now homelab→AWS (outbound),
# so this inbound rule isn't needed. Leaving in code as disabled so the
# port reservation is documented; flip enabled=true if we re-architect
# back to inbound regional VPN.
resource "unifi_port_forward" "wireguard_travel" {
  name     = "Wireguard Travel"
  enabled  = false
  fwd_ip   = "10.10.201.20"
  fwd_port = "9820"
  dst_port = "9820"
  protocol = "udp"
  # src_ip omitted — live has null

  lifecycle {
    ignore_changes = [port_forward_interface, src_ip]
  }
}

import {
  to = unifi_port_forward.wireguard_travel
  id = "69f898115433d627dfc677c0"
}
