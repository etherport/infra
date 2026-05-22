# Proxmox SDN Migration Investigation

**Date:** 2026-05-17
**Status:** Investigation / planning (no changes made)
**Recommendation:** **GO (low-risk, high-payoff).** Migrate to **SDN VLAN zone** with one VNet per existing VLAN.

---

## 1. Why SDN exists, and the vDS analogy

Today `vmbr0` is a single VLAN-aware Linux bridge; every VM independently
declares `bridge = "vmbr0"` plus a `vlan_id`. Nothing in Proxmox enforces that
a VM landed on the "right" VLAN — the recent gh-runner footgun (forgot the
VLAN tag, VM came up but couldn't reach internal DNS) is exactly the failure
mode SDN eliminates.

| Proxmox SDN | vSphere vDS analog | What it does |
|---|---|---|
| **Zone** | Distributed Switch (vDS) | A datacenter-scoped network domain. Defines transport (Simple/VLAN/VXLAN). |
| **VNet** | Distributed Port Group | A named L2 segment (e.g. `servers`). VMs attach to the VNet by name. |
| **Subnet** | Port-group IP pool / IPAM | Optional CIDR + gateway + DHCP server bound to a VNet. |
| **IPAM** | NSX IP pool | Address allocator (Proxmox built-in, phpIPAM, or NetBox). |
| **SDN Controller** | NSX-T controller | Only needed for EVPN/BGP (irrelevant here). |

What SDN adds beyond `vmbr0` + `vlan_id`: declarative config in
`/etc/pve/sdn/*.cfg` (cluster-replicated); VNet name IS the QEMU bridge
name so `bridge="servers"` is the entire spec — no separate `vlan_id`;
VNets are first-class TF objects; optional integrated DHCP/IPAM; zone
config auto-propagates to new nodes. Core SDN is **fully supported as of
PVE 8.1** ([wiki](https://pve.proxmox.com/wiki/Software-Defined_Network));
only IPAM and FRR remain tech-preview.

---

## 2. Which zone type fits this homelab?

| Zone | Verdict |
|---|---|
| **Simple** | No physical uplink — isolated host-only networks. Wrong for us (VMs must reach 10.10.x.x via the switch). |
| **VLAN** | Uses an existing VLAN-aware bridge (`vmbr0`) as uplink, creates per-VNet sub-interfaces. **Recommended.** |
| QinQ / VXLAN / EVPN | Multi-site or stacked-tag scenarios. Overkill for one host. |

**Choose VLAN zone.** Same wire-format as today (802.1Q tags on `vmbr0`), so
the upstream UniFi switch needs zero changes. When a 2nd PVE node arrives,
the same zone/VNet definitions replicate via `/etc/pve` and the new node
gets identical bridges automatically — no per-node `interfaces` edits.

If you'd picked **Simple** zone, traffic would never leave the host, breaking
everything. Don't confuse "single host" with "Simple zone".

---

## 3. Concrete diff

Today (k8s-vms/main.tf has **12** `vlan_id` references, standalone has 2):

```hcl
locals {
  bridge_name = "vmbr0"
  vlan_tag    = 201
}

network_device {
  bridge  = local.bridge_name
  model   = "virtio"
  vlan_id = local.vlan_tag       # 201 = Servers
}
network_device {
  bridge  = local.bridge_name
  model   = "virtio"
  vlan_id = 202                  # Client — magic number
}
```

After:

```hcl
network_device {
  bridge = "servers"   # VNet -> VLAN 201, defined once in /etc/pve/sdn
  model  = "virtio"
}
network_device {
  bridge = "client"    # VNet -> VLAN 202
  model  = "virtio"
}
```

VLAN-ID-to-name mapping lives in **one** place (`proxmox_virtual_environment_sdn_vnet`).
Renumbering VLAN 202 → 222 becomes a one-line edit, not a hunt across 14 call sites.

---

## 4. Migration sequence

| Phase | Action | Downtime | Risk |
|---|---|---|---|
| 0 | Confirm `libpve-network-perl` + `dnsmasq` installed (default on PVE 8.x). | none | none |
| 1 | Define VLAN zone `wind` + VNets `servers`(201) `client`(202) `iot`(204) `security`(205) `vsan`(209) via UI or `/etc/pve/sdn/*.cfg`. Do NOT apply yet. | none | none |
| 2 | `pvesh set /cluster/sdn` (or click *Apply*) — creates VNet bridges alongside `vmbr0`. Existing VMs untouched. | none | very low |
| 3 | Migrate VMs one at a time: edit TF (`bridge = "servers"`, drop `vlan_id`), `plan`, `apply`. bpg provider hot-swaps the NIC; cloud-init not re-run. Start with dns-fallback (least blast radius), then gh-runner, then K8s workers one-at-a-time (Cilium tolerates a node bounce), control planes last. | ~5–30s per VM NIC swap | low (rollback = revert TF) |
| 4 | Multus NADs: macvlan uses raw `enp6sN` sub-interfaces inside the guest — **independent of SDN**. NADs keep working unchanged. Optional: rename NAD files (`vlan202-client.yaml` → `client.yaml`) for consistency. Treat as cosmetic. | none | none |
| 5 | Once all VMs migrated, audit `/etc/network/interfaces` on PVE for any handwritten VLAN stanzas. With this repo there are none (everything goes through `vmbr0` + tag), so nothing to remove. | none | none |

Total wall-clock: ~1 evening. Reversible at every phase.

---

## 5. Operational benefits (the vDS feel)

- **Single source of truth** for VLAN map (`/etc/pve/sdn/vnets.cfg` or TF).
- **TF validation**: a `bridge` referencing a missing VNet fails at `plan` time. Today `vlan_id = 207` silently boots a black-hole VM.
- **gh-runner footgun gone**: `bridge = "servers"` IS the VLAN; no separate field to forget. A typo errors at apply.
- **Optional DHCP/IPAM** per VNet via built-in dnsmasq (not needed today, cheap to enable for sandboxes).
- **Multi-host ready**: SDN config replicates via corosync; adding PVE #2 = `pvecm add` and bridges materialize.

---

## 6. Compatibility

- **bpg/proxmox provider:** Ships `proxmox_virtual_environment_sdn_zone_{simple,vlan,vxlan,evpn,qinq}`, `..._sdn_vnet`, `..._sdn_subnet`, `..._sdn_applier` ([GitHub repo](https://github.com/bpg/terraform-provider-proxmox)). Current pin (`~> 0.106`) is well above the 0.50 minimum. `network_device.bridge` accepts any bridge name including VNet names — same string field, no schema change.
- **Packer (`infra/packer/ubuntu-cloud-init/ubuntu-2404.pkr.hcl`):** Build VM uses `vmbr0` once at build time — change to a `servers` VNet (or leave on `vmbr0`; the build VM is ephemeral). Netplan `51-vlan-interfaces.yaml` stanza is unaffected (it names guest-side `enp6sN` interfaces, not the PVE bridge).
- **Template VM 9001 / snapshots:** No impact. Cloned VMs get the NIC config from the TF resource, not the template.

---

## 7. Risks / drawbacks

1. **Extra abstraction.** SDN config lives in `pmxcfs`; if pmxcfs is broken nothing in Proxmox works anyway, so no meaningful new failure mode.
2. **Single-host = no cluster-wide payoff yet.** Win today is config hygiene + TF validation, not multi-node propagation.
3. **PVE-specific names.** Leaving Proxmox would mean renaming `bridge = "servers"` references — single `locals` map, low cost.
4. **Multus is orthogonal.** NADs use guest-internal `enp6sN` names so they're unaffected — but SDN also does NOT simplify Multus.
5. **Apply semantics.** SDN changes are staged until applied; use the `sdn_applier` resource as a TF dependency or VNets stay pending.

---

## 8. Decision

**GO. Confidence: high.**

Strongest reason: the gh-runner-style "forgot a VLAN tag" class of bug
disappears entirely — the VNet *is* the VLAN, and TF `plan` validates the
name. Everything else (declarative config, multi-host readiness, optional
DHCP) is gravy. Effort is small (~3–4 hours), reversible per-VM, and
aligns the homelab's operational model with the vDS pattern you already
know.

**Phase 1 deliverable:** a new TF module `infra/terraform/proxmox/sdn/`
defining:

- one `proxmox_virtual_environment_sdn_zone_vlan` (`wind`, bridge `vmbr0`)
- five `proxmox_virtual_environment_sdn_vnet` resources (`servers`, `client`, `iot`, `security`, `vsan`)
- one `proxmox_virtual_environment_sdn_applier` to commit

Apply that module first (zero VM impact), then start Phase 3 migrations
one VM at a time.

---

## References

- [Proxmox VE Wiki: Software-Defined Network](https://pve.proxmox.com/wiki/Software-Defined_Network)
- [PVE Admin Guide: SDN chapter](https://pve.proxmox.com/pve-docs/chapter-pvesdn.html)
- [bpg/terraform-provider-proxmox](https://github.com/bpg/terraform-provider-proxmox) — SDN resources under `docs/resources/sdn_*`
- [vezpi blog: Simplifying VLAN Management in Proxmox VE with SDN](https://blog.vezpi.com/en/post/proxmox-cluster-networking-sdn/)
- [hybridops-tech/terraform-proxmox-sdn](https://github.com/hybridops-tech/terraform-proxmox-sdn) — reference module
