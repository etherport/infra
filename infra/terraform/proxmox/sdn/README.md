# Proxmox SDN

Terraform module that manages Proxmox VE SDN — VLAN zone + VNets per workload
VLAN. Replaces the per-VM `vlan_id` tag-on-`vmbr0` pattern with named bridge
interfaces on PVE (one bridge per VLAN), so VM resources declare
`bridge = "servers"` instead of `bridge = "vmbr0"; vlan_id = 201`.

## Why SDN

- **Self-documenting topology.** A VM's `network_device { bridge = "iot" }`
  reads as "this NIC is on the IoT network" — no need to cross-reference a
  VLAN ID with the UniFi network catalog.
- **PVE-side ACL surface.** SDN zones support per-VNet firewall rules,
  isolation flags (`isolate_ports`), and IPAM if we ever want PVE-managed
  DHCP for sandbox VLANs.
- **Easier future moves.** Adding a new workload VLAN is one VNet entry +
  one apply, instead of editing every VM's `vlan_id`.

## Scope

This module defines zone + VNets only. Subnets/DHCP/IPAM stay with UniFi
(authoritative DHCP today). Re-evaluate IPAM in PVE if we adopt PVE-managed
DHCP for sandbox networks.

| VNet id  | VLAN tag | Purpose                                                   |
|----------|----------|-----------------------------------------------------------|
| `servers`  | 201    | K8s + standalone VMs (default workload VLAN)              |
| `clients`  | 202    | K8s Multus secondary NIC                                  |
| `iot`      | 204    | K8s Multus secondary NIC                                  |
| `security` | 205    | K8s Multus secondary NIC + SimpliSafe (do NOT retire)     |
| `vsan`     | 209    | UNAS LAG + future use                                     |
| `guest`    | 206    | Guest network (no VM today; defined for completeness)     |
| `unifi`    | 212    | UniFi controller traffic (no VM today)                    |

### Excluded VLANs and why

- **VLAN 200 (mgmt)** — PVE host has `vmbr0.200` carrying 10.10.200.41 (web UI / mgmt access). Modeling this VLAN as an SDN VNet creates a competing bridge in `/etc/network/interfaces.d/sdn` that `ifreload` honors over `vmbr0.200`, stealing the host's mgmt IP and requiring iKVM recovery (this is exactly what happened 2026-05-18). **Never model the host's mgmt VLAN here.**
- **VLAN 210 (ceph)** — PVE host has `vmbr0.210` carrying 10.10.210.41 (Ceph mon + OSDs). Same conflict mode as VLAN 200. Storage networks should always stay manually-configured. K8s VMs reach VLAN 210 via the legacy `vmbr0` + `vlan_id=210` pattern on NIC 5 (enp6s22), NOT via an SDN VNet.
- **VLAN 4040 (intervl)** — UDM↔L3-switch inter-VLAN routing transit. UI-only L3 infrastructure, never carries VM traffic.

**General rule:** any VLAN with a `vmbr0.<N>` host sub-interface in `/etc/network/interfaces` is forbidden here. Check before adding new VNets. Conversely, **do NOT re-add a `vmbr0.201` stanza** while this module is in place — the `servers` VNet (VLAN 201) collides with it (see `docs/planning/archive/proxmox-sdn-implementation-2026-05-18.md`).

## Provider

`bpg/proxmox ~> 0.106`. SDN resources use the **short alias** form
(`proxmox_sdn_zone_vlan`, `proxmox_sdn_vnet`, `proxmox_sdn_applier`) that
the provider added in v0.100.0 — both forms work; short is the documented
default. `proxmox_sdn_applier` is marked EXPERIMENTAL upstream — re-pin
the provider before bumping past 0.106.

## Operator prerequisites

Identical to `../standalone-vms/README.md` "Operator prerequisites" section,
**except** no SSH private key is needed (this module doesn't touch VMs).

| Prereq | Source |
|--------|--------|
| AWS credentials (for S3 state) | 1Password — "AWS — claude-admin IAM keys" |
| Proxmox API token | 1Password — "Proxmox VE Terraform Token" |

## Apply path: GitHub Actions (default)

```bash
gh workflow run terraform-proxmox-sdn.yml -f action=apply
```

Runs on `[self-hosted, lifecycle]` (the gh-runner VM). Safe choice for this
module because the SDN module never touches the gh-runner's NIC — it just
runs `pvesh set /cluster/sdn` on the PVE host, which reloads bridge config
without disrupting any live tap device.

## Apply path: local Terraform

```bash
cd ~/code/infra/infra/terraform/proxmox/sdn
terraform init
export TF_VAR_proxmox_token_id="$(op read 'op://Private/Proxmox VE Terraform Token/token id')"
export TF_VAR_proxmox_token_secret="$(op read 'op://Private/Proxmox VE Terraform Token/token secret')"
terraform plan
terraform apply
```

## Verifying after apply

On PVE:

```bash
ssh root@pve.wind.etherport.net 'ls /sys/class/net/ | grep -E "^(servers|clients|iot|security|vsan|guest|unifi)$"'
# Expected: all 7 bridge names present
ssh root@pve.wind.etherport.net 'cat /etc/pve/sdn/vnets.cfg'
# Expected: 7 vnet stanzas, one per VLAN
```

## Migration history

How this module was built and rolled out (the 6-PR migration sequence — zone/VNet
definition, the per-VM `vmbr0`+`vlan_id` → SDN-bridge cutover, and per-VM rollback
procedures) is archived in
[`docs/planning/archive/proxmox-sdn-implementation-2026-05-18.md`](../../../../docs/planning/archive/proxmox-sdn-implementation-2026-05-18.md).
