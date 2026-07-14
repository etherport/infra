# UniFi corporate + guest VLANs.
#
# Imported from live UDM state on 2026-05-17 via /tmp/unifi-state/networks.json.
# WAN interfaces (WAN1/WAN2/LTE) and the WireGuard VPN are EXCLUDED from this
# Phase 1 import — different schemas, higher risk, separate PRs.
#
# M125 (2026-07-02): converted from the archived paultyng/unifi provider schema
# to the ubiquiti-community/unifi fork v0.41.25 schema:
#   - `purpose` / `network_group` removed (no fork equivalent; corporate implied)
#   - `vlan_id` → `vlan`
#   - `internet_access_enabled` → `internet_access`
#   - `intra_network_access_enabled` → `network_isolation` (INVERTED semantics:
#     isolation = NOT intra-network access; intra=true → isolation=false)
#   - flat `dhcp_enabled/dhcp_start/dhcp_stop/dhcp_lease/dhcp_dns` → nested
#     `dhcp_server = { enabled/start/stop/leasetime/dns_enabled/dns_servers }`
#     (attributes syntax with `=`, per the fork docs)
#   - the old `dhcp_v6_*` / `ipv6_*` ignore_changes entries: only
#     `ipv6_interface_type` exists in the fork; the rest were dropped (see the
#     per-resource lifecycle comment).
#
# Convention for each network:
#   resource "unifi_network" "<lowercase-name>" { ... }
#   import { to = ... id = "<_id from dump>" }
#
# Plan must report "no changes" before any apply. If diffs appear, the live
# UDM is the source of truth — edit the HCL to match, not the other way.
#
# Subnet normalization: the fork wants GATEWAY-style subnets ("10.10.201.1/24")
# — confirmed on the M125 migration plans. (The archived paultyng provider
# stored the network address, .0/24; that convention is dead.)

# Note: `ignore_changes` takes unquoted attribute references and must live
# inside each resource's `lifecycle` block — it can't be shared from `locals`.
# The list is repeated per-resource below; if it grows or shifts, search/replace.
#
# Standard internal DNS pushed by DHCP: K8s technitium VIP (10.10.201.5),
# dns-fallback (10.10.201.6), AWS technitium on the edge box (44.240.60.80 — M110).
#
# M125: `network_isolation` (was `network_isolation_enabled`, UI-managed only
# under paultyng) IS exposed by the fork as the inversion of the old
# intra_network_access_enabled. The Security VLAN's live isolation flag is
# now modelable — see the warning on that resource before the first apply.

resource "unifi_network" "default" {
  # M125: fork defaults differ from live when unset — pin live values explicitly.
  auto_scale         = false
  lte_lan            = true
  setting_preference = "manual"

  name   = "Default"
  subnet = "10.10.199.1/24" # fork normalizes to gateway-style
  # vlan intentionally omitted — Default is the untagged native network

  dhcp_server = {
    enabled   = true
    start     = "10.10.199.100"
    stop      = "10.10.199.254"
    leasetime = 86400
  }
  domain_name = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  igmp_snooping     = false
  multicast_dns     = false
  network_isolation = false # M125: was intra_network_access_enabled = true (inverted)
  internet_access   = true

  lifecycle {
    ignore_changes = [
      # M125: of the old paultyng dhcp_v6_*/ipv6_* ignore list, only
      # ipv6_interface_type exists in the fork schema. Dropped (no fork
      # equivalent): dhcp_v6_dns, dhcp_v6_dns_auto, dhcp_v6_enabled,
      # dhcp_v6_lease, dhcp_v6_start, dhcp_v6_stop, ipv6_pd_interface,
      # ipv6_pd_prefixid, ipv6_pd_start, ipv6_pd_stop, ipv6_ra_enable,
      # ipv6_ra_preferred_lifetime, ipv6_ra_priority, ipv6_ra_valid_lifetime,
      # ipv6_static_subnet, wan_dhcp_v6_pd_size.
      ipv6_interface_type,
    ]
  }
}

import {
  to = unifi_network.default
  id = "5ed7f1c8f2a1050260a8b423"
}

resource "unifi_network" "management" {
  # M125: fork defaults differ from live when unset — pin live values explicitly.
  auto_scale         = false
  lte_lan            = false
  setting_preference = "manual"

  name   = "Management"
  vlan   = 200
  subnet = "10.10.200.1/24" # fork normalizes to gateway-style

  dhcp_server = {
    enabled   = true
    start     = "10.10.200.100"
    stop      = "10.10.200.254"
    leasetime = 86400
    # M110 (2026-07-02): tertiary resolver = 44.240.60.80 (the consolidated AWS edge
    # box; was 52.40.219.113 on the destroyed standalone dns instance).
    dns_enabled = true
    dns_servers = ["10.10.201.5", "10.10.201.6", "44.240.60.80"]
  }
  domain_name = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  igmp_snooping     = false
  multicast_dns     = false
  network_isolation = false # M125: was intra_network_access_enabled = true (inverted)
  internet_access   = true

  lifecycle {
    ignore_changes = [
      # M125: see unifi_network.default for the dropped dhcp_v6_*/ipv6_* list.
      ipv6_interface_type,
    ]
  }
}

import {
  to = unifi_network.management
  id = "60915addf2a1050260a8debc"
}

resource "unifi_network" "servers" {
  # M125: fork defaults differ from live when unset — pin live values explicitly.
  auto_scale         = false
  lte_lan            = false
  setting_preference = "manual"

  name   = "Servers"
  vlan   = 201
  subnet = "10.10.201.1/24" # fork normalizes to gateway-style

  dhcp_server = {
    enabled     = true
    start       = "10.10.201.100"
    stop        = "10.10.201.254"
    leasetime   = 86400
    dns_enabled = true
    dns_servers = ["10.10.201.5", "10.10.201.6", "44.240.60.80"]
  }
  domain_name = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  igmp_snooping     = false
  multicast_dns     = false
  network_isolation = false # M125: was intra_network_access_enabled = true (inverted)
  internet_access   = true

  lifecycle {
    ignore_changes = [
      # M125: see unifi_network.default for the dropped dhcp_v6_*/ipv6_* list.
      ipv6_interface_type,
    ]
  }
}

import {
  to = unifi_network.servers
  id = "60915afff2a1050260a8e2de"
}

resource "unifi_network" "clients" {
  gateway_type = "switch" # live value (fork defaults to "default" when unset)

  # M125: fork defaults differ from live when unset — pin live values explicitly.
  auto_scale         = false
  lte_lan            = true
  setting_preference = "manual"

  name   = "Clients"
  vlan   = 202
  subnet = "10.10.202.1/24" # fork normalizes to gateway-style

  dhcp_server = {
    enabled     = true
    start       = "10.10.202.100"
    stop        = "10.10.202.254"
    leasetime   = 86400
    dns_enabled = true
    dns_servers = ["10.10.201.5", "10.10.201.6", "44.240.60.80"]
  }
  domain_name = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  igmp_snooping     = false
  multicast_dns     = false
  network_isolation = false # M125: was intra_network_access_enabled = true (inverted)
  internet_access   = true

  lifecycle {
    ignore_changes = [
      # M110 (2026-07-02): dhcp_dns was ignored — the archived paultyng provider
      # 400'd on PUT for THIS network (api.err.Invalid); the dhcpd_dns_3=
      # 44.240.60.80 cutover went in via a direct UDM API PUT instead.
      # M125: dhcp_dns is now nested → the WHOLE dhcp_server attribute is
      # ignored (note this also masks range/leasetime drift). The 400 was a
      # paultyng bug and the fork FIXED it (all PUTs clean in the M125
      # migration) → this entry is a REMOVAL CANDIDATE: drop it, confirm the
      # plan stays clean, keep live UDM as source of truth.
      dhcp_server,
      # M125: see unifi_network.default for the dropped dhcp_v6_*/ipv6_* list.
      ipv6_interface_type,
    ]
  }
}

import {
  to = unifi_network.clients
  id = "60915b16f2a1050260a8e574"
}

resource "unifi_network" "iot" {
  # M125: fork defaults differ from live when unset — pin live values explicitly.
  auto_scale         = false
  lte_lan            = false
  setting_preference = "manual"

  name   = "IoT"
  vlan   = 204
  subnet = "10.10.204.1/24" # fork normalizes to gateway-style

  dhcp_server = {
    enabled     = true
    start       = "10.10.204.100"
    stop        = "10.10.204.254"
    leasetime   = 86400
    dns_enabled = true
    dns_servers = ["10.10.201.5", "10.10.201.6", "44.240.60.80"]
  }
  domain_name = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  igmp_snooping     = false
  multicast_dns     = false
  network_isolation = false # M125: was intra_network_access_enabled = true (inverted)
  internet_access   = true

  lifecycle {
    ignore_changes = [
      # M125: see unifi_network.default for the dropped dhcp_v6_*/ipv6_* list.
      ipv6_interface_type,
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
  # M125: fork defaults differ from live when unset — pin live values explicitly.
  auto_scale         = false
  lte_lan            = true
  setting_preference = "manual"

  name   = "Security"
  vlan   = 205
  subnet = "10.10.205.1/24" # fork normalizes to gateway-style

  # M125 NB: under paultyng, the live UDM's network_isolation_enabled=true was
  # UI-managed only (not in that schema) while intra_network_access_enabled
  # was true. The fork's `network_isolation` attribute maps to the INVERSE of
  # the old intra-access flag, and the M125 migration plans converged clean
  # with isolation=false below — i.e. the fork attribute does NOT read the
  # UI-level network_isolation_enabled flag, which stays UI-managed. If a
  # future provider bump starts diffing here, match live (isolation=true)
  # rather than applying a diff that would touch the Security VLAN's isolation.
  dhcp_server = {
    enabled   = true
    start     = "10.10.205.100"
    stop      = "10.10.205.254"
    leasetime = 86400
  }
  domain_name = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  igmp_snooping     = false
  multicast_dns     = false
  network_isolation = false # M125: was intra_network_access_enabled = true (inverted) — SEE WARNING ABOVE
  internet_access   = true

  lifecycle {
    ignore_changes = [
      # M125: see unifi_network.default for the dropped dhcp_v6_*/ipv6_* list.
      ipv6_interface_type,
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
  # M125: fork defaults differ from live when unset — pin live values explicitly.
  auto_scale         = false
  lte_lan            = false
  setting_preference = "manual"

  # M125: dropped `purpose = "guest"` (no fork equivalent — the purpose arg is
  # gone from the schema entirely). The M125 migration plan/apply converged
  # clean on this network and the guest policy survived in the UDM UI; the
  # guest-portal semantics live controller-side, not in the provider schema.
  name   = "Guest"
  vlan   = 206
  subnet = "10.10.206.1/24" # fork normalizes to gateway-style

  dhcp_server = {
    enabled     = true
    start       = "10.10.206.100"
    stop        = "10.10.206.254"
    leasetime   = 86400
    dns_enabled = true
    dns_servers = ["1.1.1.1", "8.8.8.8"]
  }


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  igmp_snooping     = false
  multicast_dns     = false
  network_isolation = false # M125: was intra_network_access_enabled = true (inverted)
  internet_access   = true

  lifecycle {
    # 2026-07-14: `dhcp_server` REMOVED from ignore_changes. The paultyng-era
    # mask silently hid a REAL drift for months: live `dhcpd_dns_enabled` was
    # false (guests got the gateway as resolver, defeating the public-DNS-only
    # design above) while plan said "No changes". Found by the weekly doc-drift
    # audit; live converged to this config 2026-07-14 via a direct UDM API PUT
    # (networkconf 60915b81…, verified). TF now owns the block again — a future
    # UI-side change to the DHCP range/DNS shows up as a plan diff, as intended.
    ignore_changes = [
      # M125: see unifi_network.default for the dropped dhcp_v6_*/ipv6_* list.
      ipv6_interface_type,
    ]
  }
}

import {
  to = unifi_network.guest
  id = "60915b81f2a1050260a8f1b3"
}

resource "unifi_network" "vsan" {
  gateway_type = "switch" # live value (fork defaults to "default" when unset)

  # M125: fork defaults differ from live when unset — pin live values explicitly.
  auto_scale         = false
  lte_lan            = false
  setting_preference = "manual"

  name   = "vSAN"
  vlan   = 209
  subnet = "10.10.209.1/24" # fork normalizes to gateway-style

  dhcp_server = {
    enabled     = true
    start       = "10.10.209.100"
    stop        = "10.10.209.254"
    leasetime   = 86400
    dns_enabled = true
    dns_servers = ["10.10.201.5", "10.10.201.6", "44.240.60.80"]
  }
  domain_name = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  igmp_snooping     = false
  multicast_dns     = false
  network_isolation = false # M125: was intra_network_access_enabled = true (inverted)
  internet_access   = true

  lifecycle {
    ignore_changes = [
      # M110 (2026-07-02): dhcp_dns was ignored — the archived paultyng provider
      # 400'd on PUT for THIS network (api.err.Invalid); the dhcpd_dns_3=
      # 44.240.60.80 cutover went in via a direct UDM API PUT instead.
      # M125: dhcp_dns is now nested → the WHOLE dhcp_server attribute is
      # ignored (note this also masks range/leasetime drift). The 400 was a
      # paultyng bug and the fork FIXED it (all PUTs clean in the M125
      # migration) → this entry is a REMOVAL CANDIDATE: drop it, confirm the
      # plan stays clean, keep live UDM as source of truth.
      dhcp_server,
      # M125: see unifi_network.default for the dropped dhcp_v6_*/ipv6_* list.
      ipv6_interface_type,
    ]
  }
}

import {
  to = unifi_network.vsan
  id = "60b63aebc13e31049b39e673"
}

resource "unifi_network" "unifi" {
  # M125: fork defaults differ from live when unset — pin live values explicitly.
  auto_scale         = false
  lte_lan            = false
  setting_preference = "manual"

  name   = "Unifi"
  vlan   = 212
  subnet = "10.10.212.1/24" # fork normalizes to gateway-style

  dhcp_server = {
    enabled     = true
    start       = "10.10.212.100"
    stop        = "10.10.212.254"
    leasetime   = 86400
    dns_enabled = true
    dns_servers = ["10.10.201.5", "10.10.201.6", "44.240.60.80"]
  }
  domain_name = "wind.etherport.net"


  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  igmp_snooping     = false
  multicast_dns     = false
  network_isolation = false # M125: was intra_network_access_enabled = true (inverted)
  internet_access   = true

  lifecycle {
    ignore_changes = [
      # M125: see unifi_network.default for the dropped dhcp_v6_*/ipv6_* list.
      ipv6_interface_type,
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
# selection is a UI-only setting (neither paultyng nor the fork currently
# exposes per-network L3 device assignment), so it must be verified manually
# after import.
#
# DHCP enabled with reserved range 100-254. Static IPs 1-99 for the storage
# fabric (PVE host, K8s nodes via Multus secondary NIC, etc.).
resource "unifi_network" "ceph" {
  gateway_type = "switch" # live value (fork defaults to "default" when unset)

  # M125: fork defaults differ from live when unset — pin live values explicitly.
  auto_scale         = false
  lte_lan            = true
  setting_preference = "manual"

  name   = "Ceph"
  vlan   = 210
  subnet = "10.10.210.1/24" # fork normalizes to gateway-style

  dhcp_server = {
    enabled     = true
    start       = "10.10.210.100"
    stop        = "10.10.210.254"
    leasetime   = 86400
    dns_enabled = true
    dns_servers = ["10.10.201.5", "10.10.201.6", "44.240.60.80"]
  }
  domain_name = "wind.etherport.net"

  # Explicit defaults — provider would set these implicitly but having them
  # in source means a drift in the UI shows up as a plan diff.
  igmp_snooping     = false
  multicast_dns     = false
  network_isolation = false # M125: was intra_network_access_enabled = true (inverted)
  internet_access   = true

  lifecycle {
    ignore_changes = [
      # M110 (2026-07-02): dhcp_dns was ignored — the archived paultyng provider
      # 400'd on PUT for THIS network (api.err.Invalid); the dhcpd_dns_3=
      # 44.240.60.80 cutover went in via a direct UDM API PUT instead.
      # M125: dhcp_dns is now nested → the WHOLE dhcp_server attribute is
      # ignored (note this also masks range/leasetime drift). The 400 was a
      # paultyng bug and the fork FIXED it (all PUTs clean in the M125
      # migration) → this entry is a REMOVAL CANDIDATE: drop it, confirm the
      # plan stays clean, keep live UDM as source of truth.
      dhcp_server,
      # M125: see unifi_network.default for the dropped dhcp_v6_*/ipv6_* list.
      ipv6_interface_type,
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
  # M125: fork defaults differ from live when unset — pin live values explicitly.
  auto_scale = false
  lte_lan    = true

  name   = "Inter-VLAN routing"
  vlan   = 4040
  subnet = "10.255.253.1/24" # fork normalizes to gateway-style

  dhcp_server = {
    enabled = false # transit net — never DHCP; controller echoes template values (fork read-back quirk)
  }

  lifecycle {
    ignore_changes = [
      # M125: see unifi_network.default for the dropped dhcp_v6_*/ipv6_* list.
      ipv6_interface_type,
    ]
  }
}

import {
  to = unifi_network.inter_vlan_routing
  id = "67683e2bd9b8db69dd02b5b2"
}
