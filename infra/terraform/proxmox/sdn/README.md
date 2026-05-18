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
| `guest`    | 206    | Guest network (no VM today; defined for completeness)     |
| `unifi`    | 212    | UniFi controller traffic (no VM today)                    |

### Excluded VLANs and why

- **VLAN 200 (mgmt)** — PVE host has `vmbr0.200` carrying 10.10.200.41 (web UI / mgmt access). Modeling this VLAN as an SDN VNet creates a competing bridge in `/etc/network/interfaces.d/sdn` that `ifreload` honors over `vmbr0.200`, stealing the host's mgmt IP and requiring iKVM recovery (this is exactly what happened 2026-05-18). **Never model the host's mgmt VLAN here.**
- **VLAN 4040 (intervl)** — UDM↔L3-switch inter-VLAN routing transit. UI-only L3 infrastructure, never carries VM traffic.

### Pre-flight constraint for VLAN 201 (servers)

PVE historically had a `vmbr0.201` sub-interface (vestigial 10.10.201.41 secondary IP). Single-node PVE doesn't need this — VMs reach PVE via the mgmt IP on VLAN 200 (DNS authoritative answer for `pve.wind.etherport.net`). **Before applying this module, the `vmbr0.201` stanza must be removed from `/etc/network/interfaces`** (via the Ansible `pve-network.yml` playbook). Otherwise the `servers` VNet collides with `vmbr0.201` and recreates the 2026-05-18 outage. See `docs/runbooks/proxmox-sdn-prep.md` (TODO).

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
