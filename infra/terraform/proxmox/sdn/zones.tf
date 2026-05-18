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
  # Jumbo frames to match the underlying bond0 + vmbr0 (both MTU 9000).
  # If left at 1500 (provider default), TLS handshakes and other large
  # packets from VMs (whose NICs are MTU 9000 from the cloud image)
  # get blackholed because path MTU drops to 1500 at the SDN bridge.
  # Discovered 2026-05-18 when gh-runner couldn't reach PVE API after
  # being migrated to bridge="servers".
  mtu = 9000
}
