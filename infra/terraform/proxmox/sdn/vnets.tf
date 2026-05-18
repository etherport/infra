# VNets — one per workload VLAN. The VNet `id` becomes the Linux bridge
# name on the PVE host (e.g. `servers`, `iot`); the `tag` is the 802.1Q
# VLAN this bridge is bound to upstream on vmbr0.
#
# Constraints (bpg/proxmox + Proxmox VE):
#   - `id` must be 8 chars max, lowercase alphanumeric
#   - `tag` is REQUIRED for VLAN zones (omit it and apply fails)
#
# VLAN 4040 (UDM↔L3-switch inter-VLAN routing transit) is intentionally
# omitted — it's L3 routing infrastructure, no VM ever lives on it.
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
    mgmt = {
      tag   = 200
      alias = "PVE host VLAN (defined for completeness)"
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
