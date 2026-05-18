# Single VLAN zone bound to the existing vmbr0. Every VNet defined in
# vnets.tf hangs off this zone and creates a bridge interface on the PVE
# host (named after the VNet id) that's a sub-interface of vmbr0 with the
# VNet's `tag` VLAN baked in.
#
# WHY VLAN zone (not QinQ, VXLAN, EVPN): we have a single PVE node, a
# single upstream trunk, and UniFi switches doing all the L2 routing. The
# VLAN zone is the simplest model that maps 1:1 to what we have today.
resource "proxmox_sdn_zone_vlan" "wind" {
  id     = "wind"
  bridge = "vmbr0"
  nodes  = [local.node_name]
  mtu    = 1500
}
