# Infrastructure Instance Migration Runbook

## Overview

This runbook covers the process of migrating critical infrastructure instances
for scenarios like EBS encryption, instance type changes, or disaster recovery.

**Covered instances:**
- AWS EC2: vpn-aws, dns-aws
- Proxmox: vpn-local, dns-fallback

> 🟡 **M110 (2026-07, in progress):** `vpn-aws` was resized to **t4g.small** (AWS tag
> renamed `private-infra_vpn` → `private-infra_edge`, 2026-07-01); `dns-aws` is being
> consolidated onto that box and will be **destroyed** — its section below becomes
> historical once M110 lands.

## Prerequisites

- Terraform applies run **in CI, not locally** (M82, 2026-06-24): the devbox/mini
  hold no standing AWS/PVE creds. Dispatch the relevant workflow (see each "Apply
  Terraform" step). To dispatch you need the Actions:write PAT (M92) / `gh`.
- Age key available for SOPS decryption
- SSH access to existing instances (cert-only, M76 — `ssh ubuntu@<host>`)
- Ansible installed (the playbook steps still run locally)
- **Rare local-debug TF escape hatch (M82):** render throwaway creds with
  `scripts/render-aws-credentials.sh` (writes `~/.aws` `[homelab]` from SOPS) and,
  for proxmox stacks, run `scripts/tf-proxmox.sh <stack> <args>` (injects the PVE
  token from SOPS). The standing AWS profile is named `homelab`, not
  `terraform-homelab` (that's the IAM user/key name).

## Architecture

### VPN Instance (vpn-aws)
- **Purpose**: Site-to-site VPN hub, remote access VPN
- **Private IP**: 10.10.100.10 (must be preserved)
- **Public IP**: 44.240.60.80 (EIP - preserved automatically)
- **Services**: WireGuard (wg0, wg1), nftables
- **Config stored in**: `platform/wireguard/servers/vpn-aws.sops.yaml`

### DNS Instance (dns-aws)
- **Purpose**: Remote DNS server, Technitium cluster member
- **Private IP**: 10.10.100.5 (must be preserved)
- **Public IP**: EIP (preserved automatically)
- **Services**: Technitium DNS Server
- **Config**: Part of DNS cluster, syncs automatically

---

## VPN Instance Migration

### Pre-Migration

1. **Verify backup exists**
   ```bash
   # Check DLM snapshots (daily at 1 PM UTC)
   aws ec2 describe-snapshots --filters "Name=volume-id,Values=<volume-id>"
   ```

2. **Verify SOPS keys are current**
   ```bash
   cd platform/wireguard/servers
   sops -d vpn-aws.sops.yaml | head -20
   ```

### Migration Steps

1. **Update Terraform config** (`infra/terraform/aws/compute/main.tf`)
   - Add `private_ip = "10.10.100.10"` if not present
   - Comment out `prevent_destroy = true` (temporarily)

2. **Apply Terraform** — dispatch the `Compute Terraform` workflow
   (`terraform-compute.yml`, AWS via OIDC) with `action=plan` first to verify the
   replacement, then `action=apply` (instance will be destroyed and recreated).
   ```bash
   gh workflow run terraform-compute.yml -f action=plan   # verify replacement
   gh workflow run terraform-compute.yml -f action=apply  # destroy + recreate
   ```

3. **Capture new ENI ID** from Terraform output
   ```
   vpn_network_interface_id = "eni-XXXXXXXXX"
   ```

4. **Update routing table** (`infra/terraform/aws/networking/route_tables.tf`)
   ```hcl
   locals {
     vpn_network_interface_id = "eni-XXXXXXXXX"  # New ENI
   }
   ```

5. **Apply networking changes** — dispatch the `Networking Terraform` workflow
   (`terraform-networking.yml`, AWS via OIDC) after committing the new ENI.
   ```bash
   gh workflow run terraform-networking.yml -f action=apply
   ```

6. **Run WireGuard Ansible playbook**
   ```bash
   cd infra/ansible
   ansible-playbook -i inventory/aws/ playbooks/wireguard.yml --limit vpn-aws
   ```

7. **Verify tunnel reconnection**
   ```bash
   ssh ubuntu@44.240.60.80 "sudo wg show"
   # Check for recent handshake timestamp
   ```

8. **Restore lifecycle protection**
   - Uncomment `prevent_destroy = true` in compute/main.tf
   - Commit, then dispatch `terraform-compute.yml -f action=apply` to confirm no changes

### Post-Migration Verification

- [ ] WireGuard wg0 (site-to-site) handshake within last minute
- [ ] WireGuard wg1 (remote access) accepting connections
- [ ] nftables rules loaded (`sudo nft list ruleset`)
- [ ] Routing from AWS to homelab working (`dig @10.10.201.5 google.com`, or
      `ping 10.10.201.6` — 10.10.201.5 is a BGP-only MetalLB VIP, ICMP fails by design)
- [ ] Routing from homelab to AWS working

---

## DNS Instance Migration

### Pre-Migration

1. **Backup Technitium config**
   ```bash
   ssh ubuntu@10.10.100.5 "sudo tar -czvf /tmp/technitium-backup.tar.gz -C /opt/technitium config/"
   scp ubuntu@10.10.100.5:/tmp/technitium-backup.tar.gz ./backups/technitium-backup-$(date +%Y%m%d).tar.gz
   ```

### Migration Steps

1. **Update Terraform config** (`infra/terraform/aws/compute/main.tf`)
   - Verify `private_ip = "10.10.100.5"` is set
   - Comment out `prevent_destroy = true` (temporarily)

2. **Apply Terraform** — dispatch the `Compute Terraform` workflow
   (`terraform-compute.yml`, AWS via OIDC); `action=plan` then `action=apply`.
   ```bash
   gh workflow run terraform-compute.yml -f action=plan
   gh workflow run terraform-compute.yml -f action=apply
   ```

3. **Run Technitium Ansible playbook with restore**
   ```bash
   cd infra/ansible
   ansible-playbook -i inventory/aws/ playbooks/technitium.yml --limit dns-aws \
     -e "technitium_restore_backup=../../backups/technitium-backup-YYYYMMDD.tar.gz"
   ```

   Or, if DNS cluster is healthy, let it sync automatically:
   ```bash
   ansible-playbook -i inventory/aws/ playbooks/technitium.yml --limit dns-aws
   # Then join cluster via web UI
   ```

4. **Restore lifecycle protection**

### Post-Migration Verification

- [ ] Technitium web UI accessible at `http://10.10.100.5:5380`
- [ ] DNS resolution working (`dig @10.10.100.5 google.com`)
- [ ] Internal zones resolving (`dig @10.10.100.5 grafana.wind.etherport.net`)
- [ ] Cluster sync status healthy (check web UI)

---

## Proxmox VPN Instance Migration (vpn-local)

### Overview
- **VM ID**: 1002
- **Purpose**: Site-to-site VPN endpoint, local site gateway
- **IP**: 10.10.201.15 (VLAN 201)
- **Services**: WireGuard (wg0)
- **Config stored in**: `platform/wireguard/servers/vpn-local.sops.yaml`

> **C2 done (2026-05).** vpn-local was rebuilt from the current Packer
> template (VM 9001) and uses `ubuntu` like the K8s nodes. SSH is
> cert-only (M76) — `ssh ubuntu@<host>` presents the cert via ssh-config.

> **Watchdog reattach:** if you import this VM from a backup rather than
> recreating via Terraform, the `i6300esb` hardware watchdog device is not
> reattached on a hot `qm set`. Stop the VM, then start it again to pick
> up the device. See `docs/runbooks/vm-watchdog.md`.

### Pre-Migration

1. **Verify SOPS keys are current**
   ```bash
   export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
   cd platform/wireguard/servers
   sops -d vpn-local.sops.yaml | head -10
   ```

2. **Verify AWS-side peer config**
   ```bash
   ssh ubuntu@44.240.60.80 "sudo wg show wg0"
   # Note the local site peer public key and endpoint
   ```

### Migration Steps

1. **Apply Terraform** (creates VM from cloud-init template) — dispatch the
   `Proxmox Standalone VMs Terraform` workflow (`terraform-proxmox-standalone-vms.yml`;
   runs on the self-hosted `lifecycle` runner with the PVE token as a GH secret).
   ```bash
   gh workflow run terraform-proxmox-standalone-vms.yml -f action=plan
   gh workflow run terraform-proxmox-standalone-vms.yml -f action=apply
   ```
   For rare local debugging (M82 escape hatch): `scripts/render-aws-credentials.sh`
   then `scripts/tf-proxmox.sh standalone-vms plan` / `apply`.

2. **Run WireGuard Ansible playbook**
   ```bash
   cd infra/ansible
   export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
   ansible-playbook -i inventory/wind/ playbooks/wireguard.yml --limit vpn-local
   ```

3. **Verify tunnel reconnection**
   ```bash
   ssh ubuntu@10.10.201.15 "sudo wg show"
   # Check for recent handshake timestamp
   ```

### Post-Migration Verification

- [ ] WireGuard wg0 handshake within last minute
- [ ] nftables rules loaded (`sudo nft list ruleset`)
- [ ] Routing from homelab to AWS working (`ping 10.10.100.10`)
- [ ] AWS-side tunnel shows recent handshake

---

## Proxmox DNS Instance Migration (dns-fallback)

### Overview
- **VM ID**: 1001
- **Purpose**: Technitium DNS fallback, cluster member
- **IP**: 10.10.201.6 (VLAN 201)
- **Services**: Technitium DNS Server
- **Config**: Part of DNS cluster, syncs automatically

> **C2 done (2026-05).** dns-fallback was rebuilt from the current
> Packer template (VM 9001) and uses `ubuntu` like the K8s nodes.
> SSH is cert-only (M76) — `ssh ubuntu@<host>` presents the cert.

> **Watchdog reattach:** as with vpn-local, imported VMs need a full
> stop+start (not just reboot) to reattach the `i6300esb` watchdog
> device. See `docs/runbooks/vm-watchdog.md`.

### Pre-Migration

1. **Backup Technitium config** (optional - cluster will sync)
   ```bash
   ssh ubuntu@10.10.201.6 "sudo tar -czvf /tmp/technitium-backup.tar.gz -C /opt/technitium config/"
   scp ubuntu@10.10.201.6:/tmp/technitium-backup.tar.gz ./backups/technitium-local-$(date +%Y%m%d).tar.gz
   ```

### Migration Steps

1. **Apply Terraform** — dispatch the `Proxmox Standalone VMs Terraform` workflow
   (`terraform-proxmox-standalone-vms.yml`; self-hosted `lifecycle` runner, PVE token
   as a GH secret).
   ```bash
   gh workflow run terraform-proxmox-standalone-vms.yml -f action=plan
   gh workflow run terraform-proxmox-standalone-vms.yml -f action=apply
   ```
   For rare local debugging (M82 escape hatch): `scripts/render-aws-credentials.sh`
   then `scripts/tf-proxmox.sh standalone-vms plan` / `apply`.

2. **Run Technitium Ansible playbook**
   ```bash
   cd infra/ansible
   ansible-playbook -i inventory/wind/ playbooks/technitium.yml --limit dns-fallback
   ```

3. **Join cluster via web UI** (if cluster is healthy)
   - Access `http://10.10.201.6:5380`
   - Set admin password
   - Go to Settings → Cluster
   - Add cluster peers: 10.10.201.5, 10.10.100.5
   - Zones will sync automatically

### Post-Migration Verification

- [ ] Technitium web UI accessible at `http://10.10.201.6:5380`
- [ ] DNS resolution working (`dig @10.10.201.6 google.com`)
- [ ] Internal zones resolving (`dig @10.10.201.6 grafana.wind.etherport.net`)
- [ ] Cluster sync status healthy (check web UI)

---

## Disaster Recovery

### Complete Instance Loss

If instances are lost and need to be recreated from scratch:

**AWS Instances:**

1. **vpn-aws**
   - Terraform will recreate with correct settings
   - Run WireGuard playbook (keys are in SOPS)
   - Update route_tables.tf with new ENI
   - Local site will auto-reconnect (PersistentKeepalive=25)

2. **dns-aws**
   - Terraform will recreate with correct settings
   - Run Technitium playbook with backup restore
   - Or configure fresh instance and join cluster

**Proxmox Instances:**

3. **vpn-local**
   - Terraform will recreate VM from cloud-init template
   - Run WireGuard playbook (keys are in SOPS)
   - AWS side will reconnect automatically

4. **dns-fallback**
   - Terraform will recreate VM from cloud-init template
   - Run Technitium playbook
   - Join cluster via web UI (zones sync automatically)

### Key Recovery

WireGuard keys are stored in:
- `platform/wireguard/servers/vpn-aws.sops.yaml`
- `platform/wireguard/servers/vpn-local.sops.yaml`
- `platform/wireguard/clients/*.sops.yaml`

To decrypt:
```bash
sops -d platform/wireguard/servers/vpn-aws.sops.yaml
```

---

## Troubleshooting

### VPN Tunnel Not Connecting

1. Check security groups allow UDP 51820-51821
2. Verify EIP is associated
3. Check WireGuard is running: `sudo systemctl status wg-quick@wg0`
4. Check keys match: `sudo wg show` vs SOPS file

### DNS Not Resolving

1. Check Technitium running: `sudo systemctl status technitium`
2. Check port 53 listening: `sudo ss -tulnp | grep :53`
3. Check cluster status in web UI
4. Verify security groups allow UDP/TCP 53

### Routing Broken After Migration

1. Verify ENI in route_tables.tf matches new instance
2. Check source/dest check is disabled on instance
3. Verify routes in AWS console: VPC → Route Tables
