# UniFi static routes.
#
# Six routes total, in pairs — each route is replicated to two gateway
# devices in the UDM controller:
#   - UDM Pro Max (MAC 28:70:4e:20:3e:d4) — handles inter-VLAN traffic at L3
#   - L3 switch  (MAC d8:b3:70:75:eb:df) — handles L3 routing for servers VLAN
#
# This dual-route setup is intentional: traffic destined for AWS or the WG
# tunnel range needs to be routed correctly regardless of which gateway
# the source VLAN uses as its default route. The L3-suffixed routes
# install on the switch; the un-suffixed ones install on the UDM.
#
# Imported from live UDM state on 2026-05-17 via /tmp/unifi-state/routing.json.
#
# Risk: medium. Misconfigured routes break cross-cloud connectivity. Safety
# net: K8s WG VPN is the primary path; UDM WG WAN1 is backup.

# =============================================================================
# AWS Environment (10.10.100.0/22) — us-west-2 homelab AWS supernet
# =============================================================================

resource "unifi_static_route" "aws_environment_udm" {
  name     = "AWS Environment"
  network  = "10.10.100.0/22"
  next_hop = "10.255.253.3"
  type     = "nexthop-route"
  distance = 0
}

import {
  to = unifi_static_route.aws_environment_udm
  id = "69138164db626702ae5ba878"
}

resource "unifi_static_route" "aws_environment_l3" {
  name     = "AWS Environment (L3)"
  network  = "10.10.100.0/22"
  next_hop = "10.10.201.20"
  type     = "nexthop-route"
  distance = 0
}

import {
  to = unifi_static_route.aws_environment_l3
  id = "690aa01bdb626702ae576226"
}

# =============================================================================
# WG Tunnel (AWS) (10.255.255.0/30) — point-to-point WG tunnel between
# homelab and AWS WG endpoint
# =============================================================================

resource "unifi_static_route" "wg_tunnel_aws_udm" {
  name     = "WG Tunnel (AWS)"
  network  = "10.255.255.0/30"
  next_hop = "10.255.253.3"
  type     = "nexthop-route"
  distance = 0
}

import {
  to = unifi_static_route.wg_tunnel_aws_udm
  id = "6913818fdb626702ae5ba87d"
}

resource "unifi_static_route" "wg_tunnel_aws_l3" {
  name     = "WG Tunnel (AWS) (L3)"
  network  = "10.255.255.0/30"
  next_hop = "10.10.201.20"
  type     = "nexthop-route"
  distance = 0
}

import {
  to = unifi_static_route.wg_tunnel_aws_l3
  id = "69136928db626702ae5b9bc3"
}

# =============================================================================
# WG Client Tunnel (10.254.0.0/24) — remote-user-vpn subnet for clients
# connecting to the K8s WG server. Different from UDM-side WG WAN1's
# 192.168.3.0/24.
# =============================================================================

resource "unifi_static_route" "wg_client_tunnel_udm" {
  name     = "WG Client Tunnel"
  network  = "10.254.0.0/24"
  next_hop = "10.255.253.3"
  type     = "nexthop-route"
  distance = 0
}

import {
  to = unifi_static_route.wg_client_tunnel_udm
  id = "69138a6cdb626702ae5bad8c"
}

resource "unifi_static_route" "wg_client_tunnel_l3" {
  name     = "WG Client Tunnel (L3)"
  network  = "10.254.0.0/24"
  next_hop = "10.10.201.20"
  type     = "nexthop-route"
  distance = 0
}

import {
  to = unifi_static_route.wg_client_tunnel_l3
  id = "69138a54db626702ae5bad89"
}
