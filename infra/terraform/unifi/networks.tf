# UniFi corporate + guest VLANs.
#
# Imported from live UDM state on 2026-05-17 via /tmp/unifi-state/networks.json.
# WAN interfaces (WAN1/WAN2/LTE) and the WireGuard VPN are EXCLUDED from this
# Phase 1 import — different schemas, higher risk, separate PRs.
#
# Convention for each network:
#   resource "unifi_network" "<lowercase-name>" { ... }
#   import { to = ... id = "<_id from dump>" }
#
# Plan must report "no changes" before any apply. If diffs appear, the live
# UDM is the source of truth — edit the HCL to match, not the other way.
#
# Subnet normalization: the provider stores `subnet` as the network address
# (e.g. 10.10.201.0/24), NOT the gateway (.1/24). Use .0.

# Note: `ignore_changes` takes unquoted attribute references and must live
# inside each resource's `lifecycle` block — it can't be shared from `locals`.
# The list is repeated per-resource below; if it grows or shifts, search/replace.
#
# Standard internal DNS pushed by DHCP: K8s technitium VIP (10.10.201.5),
# dns-fallback (10.10.201.6), AWS technitium on the edge box (44.240.60.80 — M110).
#
# `network_isolation_enabled` is in the live UDM state but NOT in the
# paultyng/unifi provider schema — UI-managed only. The Security VLAN
# isolation flag stays where it is in the UDM regardless of this code.

resource "unifi_network" "default" {
  name    = "Default"
  purpose = "corporate"
  subnet  = "10.10.199.0/24"
  # vlan_id intentionally omitted — Default is the untagged native network

  dhcp_enabled = true
  dhcp_start   = "10.10.199.100"
  dhcp_stop    = "10.10.199.254"
  dhcp_lease   = 86400
  domain_name  = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  network_group                = "LAN"
  igmp_snooping                = false
  multicast_dns                = false
  intra_network_access_enabled = true
  internet_access_enabled      = true

  lifecycle {
    ignore_changes = [
      dhcp_v6_dns, dhcp_v6_dns_auto, dhcp_v6_enabled, dhcp_v6_lease,
      dhcp_v6_start, dhcp_v6_stop, ipv6_interface_type, ipv6_pd_interface,
      ipv6_pd_prefixid, ipv6_pd_start, ipv6_pd_stop, ipv6_ra_enable,
      ipv6_ra_preferred_lifetime, ipv6_ra_priority, ipv6_ra_valid_lifetime,
      ipv6_static_subnet, wan_dhcp_v6_pd_size,
    ]
  }
}

import {
  to = unifi_network.default
  id = "5ed7f1c8f2a1050260a8b423"
}

resource "unifi_network" "management" {
  name    = "Management"
  purpose = "corporate"
  vlan_id = 200
  subnet  = "10.10.200.0/24"

  dhcp_enabled = true
  dhcp_start   = "10.10.200.100"
  dhcp_stop    = "10.10.200.254"
  # M110 (2026-07-02): tertiary resolver = 44.240.60.80 (the consolidated AWS edge
  # box; was 52.40.219.113 on the destroyed standalone dns instance).
  dhcp_dns     = ["10.10.201.5", "10.10.201.6", "44.240.60.80"]
  dhcp_lease   = 86400
  domain_name  = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  network_group                = "LAN"
  igmp_snooping                = false
  multicast_dns                = false
  intra_network_access_enabled = true
  internet_access_enabled      = true

  lifecycle {
    ignore_changes = [
      dhcp_v6_dns, dhcp_v6_dns_auto, dhcp_v6_enabled, dhcp_v6_lease,
      dhcp_v6_start, dhcp_v6_stop, ipv6_interface_type, ipv6_pd_interface,
      ipv6_pd_prefixid, ipv6_pd_start, ipv6_pd_stop, ipv6_ra_enable,
      ipv6_ra_preferred_lifetime, ipv6_ra_priority, ipv6_ra_valid_lifetime,
      ipv6_static_subnet, wan_dhcp_v6_pd_size,
    ]
  }
}

import {
  to = unifi_network.management
  id = "60915addf2a1050260a8debc"
}

resource "unifi_network" "servers" {
  name    = "Servers"
  purpose = "corporate"
  vlan_id = 201
  subnet  = "10.10.201.0/24"

  dhcp_enabled = true
  dhcp_start   = "10.10.201.100"
  dhcp_stop    = "10.10.201.254"
  dhcp_dns     = ["10.10.201.5", "10.10.201.6", "44.240.60.80"]
  dhcp_lease   = 86400
  domain_name  = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  network_group                = "LAN"
  igmp_snooping                = false
  multicast_dns                = false
  intra_network_access_enabled = true
  internet_access_enabled      = true

  lifecycle {
    ignore_changes = [
      dhcp_v6_dns, dhcp_v6_dns_auto, dhcp_v6_enabled, dhcp_v6_lease,
      dhcp_v6_start, dhcp_v6_stop, ipv6_interface_type, ipv6_pd_interface,
      ipv6_pd_prefixid, ipv6_pd_start, ipv6_pd_stop, ipv6_ra_enable,
      ipv6_ra_preferred_lifetime, ipv6_ra_priority, ipv6_ra_valid_lifetime,
      ipv6_static_subnet, wan_dhcp_v6_pd_size,
    ]
  }
}

import {
  to = unifi_network.servers
  id = "60915afff2a1050260a8e2de"
}

resource "unifi_network" "clients" {
  name    = "Clients"
  purpose = "corporate"
  vlan_id = 202
  subnet  = "10.10.202.0/24"

  dhcp_enabled = true
  dhcp_start   = "10.10.202.100"
  dhcp_stop    = "10.10.202.254"
  dhcp_dns     = ["10.10.201.5", "10.10.201.6", "44.240.60.80"]
  dhcp_lease   = 86400
  domain_name  = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  network_group                = "LAN"
  igmp_snooping                = false
  multicast_dns                = false
  intra_network_access_enabled = true
  internet_access_enabled      = true

  lifecycle {
    ignore_changes = [
      dhcp_v6_dns, dhcp_v6_dns_auto, dhcp_v6_enabled, dhcp_v6_lease,
      dhcp_v6_start, dhcp_v6_stop, ipv6_interface_type, ipv6_pd_interface,
      ipv6_pd_prefixid, ipv6_pd_start, ipv6_pd_stop, ipv6_ra_enable,
      ipv6_ra_preferred_lifetime, ipv6_ra_priority, ipv6_ra_valid_lifetime,
      ipv6_static_subnet, wan_dhcp_v6_pd_size,
    ]
  }
}

import {
  to = unifi_network.clients
  id = "60915b16f2a1050260a8e574"
}

resource "unifi_network" "iot" {
  name    = "IoT"
  purpose = "corporate"
  vlan_id = 204
  subnet  = "10.10.204.0/24"

  dhcp_enabled = true
  dhcp_start   = "10.10.204.100"
  dhcp_stop    = "10.10.204.254"
  dhcp_dns     = ["10.10.201.5", "10.10.201.6", "44.240.60.80"]
  dhcp_lease   = 86400
  domain_name  = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  network_group                = "LAN"
  igmp_snooping                = false
  multicast_dns                = false
  intra_network_access_enabled = true
  internet_access_enabled      = true

  lifecycle {
    ignore_changes = [
      dhcp_v6_dns, dhcp_v6_dns_auto, dhcp_v6_enabled, dhcp_v6_lease,
      dhcp_v6_start, dhcp_v6_stop, ipv6_interface_type, ipv6_pd_interface,
      ipv6_pd_prefixid, ipv6_pd_start, ipv6_pd_stop, ipv6_ra_enable,
      ipv6_ra_preferred_lifetime, ipv6_ra_priority, ipv6_ra_valid_lifetime,
      ipv6_static_subnet, wan_dhcp_v6_pd_size,
    ]
  }
}

import {
  to = unifi_network.iot
  id = "60915b49f2a1050260a8eb7f"
}

# Security VLAN — SimpliSafe panel + sensors. Explicitly NO internal DNS
# (DHCP hands out empty DNS list) so devices don't try to resolve through
# the homelab. network_isolation prevents lateral movement.
resource "unifi_network" "security" {
  name    = "Security"
  purpose = "corporate"
  vlan_id = 205
  subnet  = "10.10.205.0/24"

  # network_isolation_enabled=true exists in live UDM but is NOT in the
  # provider schema — UI-managed only. Stays on regardless.
  dhcp_enabled = true
  dhcp_start   = "10.10.205.100"
  dhcp_stop    = "10.10.205.254"
  dhcp_lease   = 86400
  domain_name  = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  network_group                = "LAN"
  igmp_snooping                = false
  multicast_dns                = false
  intra_network_access_enabled = true
  internet_access_enabled      = true

  lifecycle {
    ignore_changes = [
      dhcp_v6_dns, dhcp_v6_dns_auto, dhcp_v6_enabled, dhcp_v6_lease,
      dhcp_v6_start, dhcp_v6_stop, ipv6_interface_type, ipv6_pd_interface,
      ipv6_pd_prefixid, ipv6_pd_start, ipv6_pd_stop, ipv6_ra_enable,
      ipv6_ra_preferred_lifetime, ipv6_ra_priority, ipv6_ra_valid_lifetime,
      ipv6_static_subnet, wan_dhcp_v6_pd_size,
    ]
  }
}

import {
  to = unifi_network.security
  id = "60915b64f2a1050260a8ee99"
}

# Guest VLAN — hands out public DNS (1.1.1.1, 8.8.8.8) by design so guests
# can't resolve internal hostnames.
resource "unifi_network" "guest" {
  name    = "Guest"
  purpose = "guest"
  vlan_id = 206
  subnet  = "10.10.206.0/24"

  dhcp_enabled = true
  dhcp_start   = "10.10.206.100"
  dhcp_stop    = "10.10.206.254"
  dhcp_dns     = ["1.1.1.1", "8.8.8.8"]
  dhcp_lease   = 86400


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  network_group                = "LAN"
  igmp_snooping                = false
  multicast_dns                = false
  intra_network_access_enabled = true
  internet_access_enabled      = true

  lifecycle {
    # dhcp_dns added to ignore_changes — provider doesn't READ the field
    # back for purpose=guest, causing a perpetual plan diff. Live UDM
    # state keeps the values.
    ignore_changes = [
      dhcp_dns,
      dhcp_v6_dns, dhcp_v6_dns_auto, dhcp_v6_enabled, dhcp_v6_lease,
      dhcp_v6_start, dhcp_v6_stop, ipv6_interface_type, ipv6_pd_interface,
      ipv6_pd_prefixid, ipv6_pd_start, ipv6_pd_stop, ipv6_ra_enable,
      ipv6_ra_preferred_lifetime, ipv6_ra_priority, ipv6_ra_valid_lifetime,
      ipv6_static_subnet, wan_dhcp_v6_pd_size,
    ]
  }
}

import {
  to = unifi_network.guest
  id = "60915b81f2a1050260a8f1b3"
}

resource "unifi_network" "vsan" {
  name    = "vSAN"
  purpose = "corporate"
  vlan_id = 209
  subnet  = "10.10.209.0/24"

  dhcp_enabled = true
  dhcp_start   = "10.10.209.100"
  dhcp_stop    = "10.10.209.254"
  dhcp_dns     = ["10.10.201.5", "10.10.201.6", "44.240.60.80"]
  dhcp_lease   = 86400
  domain_name  = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  network_group                = "LAN"
  igmp_snooping                = false
  multicast_dns                = false
  intra_network_access_enabled = true
  internet_access_enabled      = true

  lifecycle {
    ignore_changes = [
      dhcp_v6_dns, dhcp_v6_dns_auto, dhcp_v6_enabled, dhcp_v6_lease,
      dhcp_v6_start, dhcp_v6_stop, ipv6_interface_type, ipv6_pd_interface,
      ipv6_pd_prefixid, ipv6_pd_start, ipv6_pd_stop, ipv6_ra_enable,
      ipv6_ra_preferred_lifetime, ipv6_ra_priority, ipv6_ra_valid_lifetime,
      ipv6_static_subnet, wan_dhcp_v6_pd_size,
    ]
  }
}

import {
  to = unifi_network.vsan
  id = "60b63aebc13e31049b39e673"
}

resource "unifi_network" "unifi" {
  name    = "Unifi"
  purpose = "corporate"
  vlan_id = 212
  subnet  = "10.10.212.0/24"

  dhcp_enabled = true
  dhcp_start   = "10.10.212.100"
  dhcp_stop    = "10.10.212.254"
  dhcp_dns     = ["10.10.201.5", "10.10.201.6", "44.240.60.80"]
  dhcp_lease   = 86400
  domain_name  = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  network_group                = "LAN"
  igmp_snooping                = false
  multicast_dns                = false
  intra_network_access_enabled = true
  internet_access_enabled      = true

  lifecycle {
    ignore_changes = [
      dhcp_v6_dns, dhcp_v6_dns_auto, dhcp_v6_enabled, dhcp_v6_lease,
      dhcp_v6_start, dhcp_v6_stop, ipv6_interface_type, ipv6_pd_interface,
      ipv6_pd_prefixid, ipv6_pd_start, ipv6_pd_stop, ipv6_ra_enable,
      ipv6_ra_preferred_lifetime, ipv6_ra_priority, ipv6_ra_valid_lifetime,
      ipv6_static_subnet, wan_dhcp_v6_pd_size,
    ]
  }
}

import {
  to = unifi_network.unifi
  id = "67461c442eac4e0cafee495e"
}

# Ceph storage VLAN. Created 2026-05-18 to migrate Ceph cluster off VLAN 201,
# where it was colocated with general K8s/VM workload traffic. The PVE host
# had a `vmbr0.201` sub-interface (10.10.201.41) bound for Ceph mon + OSD
# traffic, which prevented modeling VLAN 201 as a Proxmox SDN VNet.
#
# Router: Switch Rack PoE (US624P) — L3 forwarding offloaded to that switch
# instead of the UDM, for lower latency on storage traffic. The "Router"
# selection is a UI-only setting (paultyng/unifi provider does not currently
# expose per-network L3 device assignment), so it must be verified manually
# after import.
#
# DHCP enabled with reserved range 100-254. Static IPs 1-99 for the storage
# fabric (PVE host, K8s nodes via Multus secondary NIC, etc.).
resource "unifi_network" "ceph" {
  name    = "Ceph"
  purpose = "corporate"
  vlan_id = 210
  subnet  = "10.10.210.0/24"

  dhcp_enabled = true
  dhcp_start   = "10.10.210.100"
  dhcp_stop    = "10.10.210.254"
  dhcp_dns     = ["10.10.201.5", "10.10.201.6", "44.240.60.80"]
  dhcp_lease   = 86400
  domain_name  = "wind.etherport.net"

  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  network_group                = "LAN"
  igmp_snooping                = false
  multicast_dns                = false
  intra_network_access_enabled = true
  internet_access_enabled      = true

  lifecycle {
    ignore_changes = [
      dhcp_v6_dns, dhcp_v6_dns_auto, dhcp_v6_enabled, dhcp_v6_lease,
      dhcp_v6_start, dhcp_v6_stop, ipv6_interface_type, ipv6_pd_interface,
      ipv6_pd_prefixid, ipv6_pd_start, ipv6_pd_stop, ipv6_ra_enable,
      ipv6_ra_preferred_lifetime, ipv6_ra_priority, ipv6_ra_valid_lifetime,
      ipv6_static_subnet, wan_dhcp_v6_pd_size,
    ]
  }
}

import {
  to = unifi_network.ceph
  id = "6a0b267a5433d627dfcf5ae1"
}

# Inter-VLAN routing transit network. Special purpose: holds the L3 nexthop
# (10.255.253.3) that VLANs use to reach the UDM for upstream routing.
# DHCP disabled (static peers only).
resource "unifi_network" "inter_vlan_routing" {
  name    = "Inter-VLAN routing"
  purpose = "corporate"
  vlan_id = 4040
  subnet  = "10.255.253.0/24"

  dhcp_enabled = false
  # Provider default is 86400; live is 0 because DHCP is disabled. Match live.
  dhcp_lease  = 0
  domain_name = "routing"

  lifecycle {
    ignore_changes = [
      dhcp_v6_dns, dhcp_v6_dns_auto, dhcp_v6_enabled, dhcp_v6_lease,
      dhcp_v6_start, dhcp_v6_stop, ipv6_interface_type, ipv6_pd_interface,
      ipv6_pd_prefixid, ipv6_pd_start, ipv6_pd_stop, ipv6_ra_enable,
      ipv6_ra_preferred_lifetime, ipv6_ra_priority, ipv6_ra_valid_lifetime,
      ipv6_static_subnet, wan_dhcp_v6_pd_size,
    ]
  }
}

import {
  to = unifi_network.inter_vlan_routing
  id = "67683e2bd9b8db69dd02b5b2"
}
