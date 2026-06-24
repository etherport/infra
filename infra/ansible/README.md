# Ansible

Playbooks that configure hosts the GitOps/Flux layer doesn't manage: the Proxmox
host, standalone VMs, the UDM/UniFi appliances, the devbox, and one-off K8s node
patches. Kubespray uses this directory's inventory as its single source of truth
(`infra/kubespray/inventory/inventory.ini` symlinks to `inventory/wind/inventory.ini`).

## What's here

| Area | Playbook(s) | Notes |
|------|-------------|-------|
| Proxmox host | `proxmox.yml`, `proxmox-setup.yml`, `pve-network.yml`, `pve-cpu-boost.yml`, `pve-sshd.yml` | PVE host config, networking/SDN, sshd |
| Standalone VMs | `technitium.yml`, `wireguard.yml`, `gh-runner.yml` | Per-service config for the `proxmox/standalone-vms` TF VMs |
| UDM / UniFi | `udm-firewall.yml`, `udm-firmware-policy.yml`, `usw-acls.yml` | Drives the internal `/proxy/network/v2/api/...` (zone firewall, DNS) — **full-reconciles** |
| devbox | `devbox.yml` | Provisions the always-on dev-session host (`10.10.201.45`) |
| K8s nodes | `k8s-node-fixes.yml`, `k8s-node-patch.yml`, `swap.yml` | Out-of-band node fixes/patches (kubespray is the primary node IaC) |
| Monitoring/backup | `ipmi-monitoring.yml`, `cloudwatch-agent.yml`, `etcd-backup.yml` | Exporters + etcd backup |
| Misc | `asterisk-sbc.yml`, `tailscale.yml`, `base.yml`, `ceph/`, `ceph-msgr2.yml` | |

## Inventory

- `inventory/wind/inventory.ini` — homelab hosts (PVE, K8s nodes, standalone VMs). Shared with kubespray.
- `inventory/aws/inventory.ini` — AWS VPN/DNS hosts.
- `inventory/wind/group_vars/`, `host_vars/` — per-group/host vars.

## Secrets

Encrypted with SOPS+age (key at `~/.config/sops/age/keys.txt`). The agent-readable
ops bundle is `playbooks/secrets/homelab-ops.sops.yaml` (`sops -d` for
aws/udm/cloudflare/etc. creds). A pre-commit hook blocks plaintext secrets.

## Safety rule

**Always `--check --diff` first** and only apply if the diff is exactly your change.
This matters most for `udm-firewall.yml`, which **full-reconciles** the UDM config —
an unexpected diff means you'd overwrite live appliance state.

```bash
ansible-playbook -i inventory/wind/inventory.ini playbooks/udm-firewall.yml --check --diff
```

See **CLAUDE.md §3 (operating model)** and **§4 (secrets & access)** for the full
rules on how change ships and how to handle credentials headlessly.
