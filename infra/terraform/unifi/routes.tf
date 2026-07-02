# UniFi static routes.
#
# Three routes — the AWS supernet + the two WireGuard tunnel ranges — all routed
# to the K8s WireGuard VIP (10.10.201.20) on VLAN 201, installed on the UDM.
#
# History (why this used to be 6 routes in switch/UDM pairs):
#   Servers/201 was originally L3-switch-routed, so each destination had two
#   routes — a UDM-side one (next-hop 10.255.253.3, the 4040 transit: UDM ->
#   switch -> WG VIP) and a switch-side "(L3)" one (next-hop 10.10.201.20,
#   directly reachable because the switch had L3 on 201).
#   After BGP Phase B (2026-05-30) moved Servers/201 to UDM-routed, the switch
#   lost its L3 SVI on 201: the "(L3)" routes became dead (switch can no longer
#   reach 10.10.201.20) and the UDM-side 10.255.253.3 next-hop broke (it hops to
#   a switch that can't complete the path). The UDM now routes 201 directly, so
#   a single route per destination with next-hop 10.10.201.20 — directly
#   reachable by the UDM via its 201 SVI — is correct. The three "(L3)" switch
#   routes were removed. See docs/runbooks/bgp-phase-b-201-udm-routed.md.
#
# Risk: medium. Misconfigured routes break cross-cloud connectivity. Safety
# net: K8s WG VPN is the primary path; UDM WG WAN1 is backup.

# =============================================================================
# AWS Environment (10.10.100.0/22) — us-west-2 homelab AWS supernet
# =============================================================================

resource "unifi_static_route" "aws_environment_udm" {
  name     = "AWS Environment"
  network  = "10.10.100.0/22"
  next_hop = "10.10.201.20"
  type     = "nexthop-route"
  distance = 1 # M125: fork validates 1-255; paultyng recorded 0 (controller default) — sole route per prefix, metric moot
}

import {
  to = unifi_static_route.aws_environment_udm
  id = "69138164db626702ae5ba878"
}

# =============================================================================
# WG Tunnel (AWS) (10.255.255.0/30) — point-to-point WG tunnel between
# homelab and AWS WG endpoint
# =============================================================================

resource "unifi_static_route" "wg_tunnel_aws_udm" {
  name     = "WG Tunnel (AWS)"
  network  = "10.255.255.0/30"
  next_hop = "10.10.201.20"
  type     = "nexthop-route"
  distance = 1 # M125: fork validates 1-255; paultyng recorded 0 (controller default) — sole route per prefix, metric moot
}

import {
  to = unifi_static_route.wg_tunnel_aws_udm
  id = "6913818fdb626702ae5ba87d"
}

# =============================================================================
# WG Client Tunnel (10.254.0.0/24) — remote-user-vpn subnet for clients
# connecting to the K8s WG server. Different from UDM-side WG WAN1's
# 192.168.3.0/24.
# =============================================================================

resource "unifi_static_route" "wg_client_tunnel_udm" {
  name     = "WG Client Tunnel"
  network  = "10.254.0.0/24"
  next_hop = "10.10.201.20"
  type     = "nexthop-route"
  distance = 1 # M125: fork validates 1-255; paultyng recorded 0 (controller default) — sole route per prefix, metric moot
}

import {
  to = unifi_static_route.wg_client_tunnel_udm
  id = "69138a6cdb626702ae5bad8c"
}
