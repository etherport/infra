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

## Scope (Phase 1)

Phase 1 defines zone + VNets only. Subnets/DHCP/IPAM stay with UniFi
(authoritative DHCP today). Re-evaluate IPAM in PVE if we adopt PVE-managed
DHCP for sandbox networks.

| VNet id  | VLAN tag | Purpose                                                   |
|----------|----------|-----------------------------------------------------------|
| `servers`  | 201    | K8s + standalone VMs (default workload VLAN)              |
| `clients`  | 202    | K8s Multus secondary NIC                                  |
| `iot`      | 204    | K8s Multus secondary NIC                                  |
| `security` | 205    | K8s Multus secondary NIC + SimpliSafe (do NOT retire)     |
| `vsan`     | 209    | UNAS LAG + future use                                     |
| `mgmt`     | 200    | PVE host VLAN (no VM lives here; defined for completeness) |
| `guest`    | 206    | Guest network (no VM today; defined for completeness)     |
| `unifi`    | 212    | UniFi controller traffic (no VM today)                    |

VLAN 4040 (UDM↔L3-switch inter-VLAN routing transit) is intentionally
**not** modeled here — it's UI-only, never carries VM traffic, and exists
purely as L3 next-hop infrastructure.

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
ssh root@pve.wind.etherport.net 'ls /sys/class/net/ | grep -E "^(servers|clients|iot|security|vsan|mgmt|guest|unifi)$"'
# Expected: all 8 bridge names present
ssh root@pve.wind.etherport.net 'cat /etc/pve/sdn/vnets.cfg'
# Expected: 8 vnet stanzas, one per VLAN
```

## Migration plan reference

See `docs/planning/proxmox-sdn-implementation-2026-05-18.md` for the full
6-PR migration sequence and per-VM rollback procedures.
