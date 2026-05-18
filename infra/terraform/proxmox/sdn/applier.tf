# SDN config in Proxmox is staged in /etc/pve/sdn/*.cfg and only takes
# effect when you call `pvesh set /cluster/sdn` (the "Apply" button in
# the UI). bpg/proxmox exposes that operation as `proxmox_sdn_applier`.
#
# replace_triggered_by means: whenever any zone or vnet resource is
# created/updated/deleted, recreate this applier resource — which fires
# the apply call. Without this, TF leaves changes staged-but-unapplied
# until someone clicks Apply in the UI.
#
# NOTE: `proxmox_sdn_applier` is marked EXPERIMENTAL upstream. Functional
# in 0.106 but treat the resource as a target for provider-version
# regression testing before bumping.
resource "proxmox_sdn_applier" "finalizer" {
  lifecycle {
    replace_triggered_by = [
      proxmox_sdn_zone_vlan.wind,
      proxmox_sdn_vnet.this,
    ]
  }

  depends_on = [
    proxmox_sdn_zone_vlan.wind,
    proxmox_sdn_vnet.this,
  ]
}
