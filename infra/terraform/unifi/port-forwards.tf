# UniFi port forwards.
#
# Four entries imported from live UDM state:
#   - Twilio-Media-Signal: UDP 10000-20000 → 10.10.201.40 (Asterisk SBC RTP)
#   - Twilio-SIP:          TCP 5061        → 10.10.201.40 (Asterisk SBC TLS SIP)
#   - Wireguard Local:     tcp+udp 9821    → 10.10.201.20 (K8s WG VIP, primary site VPN)
#   - Wireguard Travel:    UDP 9820        → 10.10.201.20 (DISABLED — regional VPN now outbound)
#
# Twilio cutover (task #80, 2026-06-06): the two Twilio forwards were repointed
# from UniFi Talk (10.10.199.1, UDP 6767 + RTP 10000-60000) to the Asterisk SBC
# (10.10.201.40). Twilio now reaches the SBC over TLS:5061 + sRTP; the SBC
# bridges to Talk on the LAN. Talk no longer faces the WAN. UniFi auto-creates
# the matching "Allow Port Forward" firewall policy for each (External→Trusted).
#
# `port_forward_interface` is on every live record but the provider field is
# being deprecated — added to `lifecycle.ignore_changes` to avoid noise.

resource "unifi_port_forward" "twilio_media_signal" {
  name     = "Twilio-Media-Signal"
  enabled  = true
  fwd_ip   = "10.10.201.40" # Asterisk SBC (was 10.10.199.1 Talk)
  fwd_port = "10000-20000"  # Asterisk rtp.conf range (was 10000-60000)
  dst_port = "10000-20000"
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
  fwd_ip   = "10.10.201.40" # Asterisk SBC (was 10.10.199.1 Talk)
  fwd_port = "5061"         # TLS SIP (was UDP 6767)
  dst_port = "5061"
  protocol = "tcp" # TLS = TCP (was udp)
  # src_ip omitted — live has null; inbound INVITEs are ACL'd to Twilio's
  # signaling ranges at the Asterisk layer (pjsip identify), matching prior posture.

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
