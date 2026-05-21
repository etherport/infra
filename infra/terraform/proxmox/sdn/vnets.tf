# VNets — one per workload VLAN. The VNet `id` becomes the Linux bridge
# name on the PVE host (e.g. `servers`, `iot`); the `tag` is the 802.1Q
# VLAN this bridge is bound to upstream on vmbr0.
#
# Constraints (bpg/proxmox + Proxmox VE):
#   - `id` must be 8 chars max, lowercase alphanumeric
#   - `tag` is REQUIRED for VLAN zones (omit it and apply fails)
#
# Hard constraint discovered 2026-05-18 incident:
#   Any VLAN the PVE host itself has an `vmbr0.<N>` sub-interface on
#   MUST NOT be modeled here. Defining an SDN VNet for that VLAN
#   produces a `/etc/network/interfaces.d/sdn` stanza that conflicts
#   with the existing manually-defined sub-interface, and `ifreload`
#   tears down the host's mgmt IP. Recovery requires iKVM access.
#
# Currently excluded for this reason:
#   - VLAN 200 (mgmt)   — vmbr0.200 holds 10.10.200.41 (PVE web UI)
#   - VLAN 210 (storage) — vmbr0.210 holds 10.10.210.41 (PVE Ceph mon),
#                          added 2026-05-18 during the Ceph VLAN
#                          migration. K8s VMs reach VLAN 210 via the
#                          legacy `vmbr0` + `vlan_id=210` pattern on
#                          NIC 5 (enp6s22), NOT via an SDN VNet. PR 5
#                          of the SDN migration migrates NICs 1-4 only.
#   - VLAN 4040 (intervl) — UDM↔L3-switch inter-VLAN routing transit,
#                          UI-only, never carries VM traffic
#
# Note on VLAN 201 (servers): we plan to delete the unnecessary
# vmbr0.201 sub-interface (PVE's vestigial secondary IP 10.10.201.41)
# BEFORE applying this module, so VLAN 201 is safe to model.
locals {
  vnets = {
    servers = {
      tag   = 201
      alias = "K8s and standalone VMs"
    }
    clients = {
      tag   = 202
      alias = "K8s Multus secondary NIC (clients VLAN)"
    }
    iot = {
      tag   = 204
      alias = "K8s Multus secondary NIC (IoT VLAN)"
    }
    security = {
      tag   = 205
      alias = "K8s Multus secondary NIC and SimpliSafe"
    }
    vsan = {
      tag   = 209
      alias = "UNAS LAG and future use"
    }
    guest = {
      tag   = 206
      alias = "Guest network (defined for completeness)"
    }
    unifi = {
      tag   = 212
      alias = "UniFi controller traffic"
    }
  }
}

resource "proxmox_sdn_vnet" "this" {
  for_each = local.vnets

  id    = each.key
  zone  = proxmox_sdn_zone_vlan.wind.id
  tag   = each.value.tag
  alias = each.value.alias
  # vlan_aware = false (default) — none of these VNets need to push
  # further-tagged frames upstream.
}
