# Infrastructure Instance Migration Runbook

## Overview

This runbook covers the process of migrating critical infrastructure instances
for scenarios like EBS encryption, instance type changes, or disaster recovery.

**Covered instances:**
- AWS EC2: vpn-aws, dns-aws
- Proxmox: vpn-local, dns-fallback

## Prerequisites

- AWS credentials configured (`terraform-homelab` profile)
- Age key available for SOPS decryption
- SSH access to existing instances
- Terraform and Ansible installed

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

2. **Apply Terraform**
   ```bash
   cd infra/terraform/aws/compute
   terraform plan   # Verify replacement
   terraform apply  # Instance will be destroyed and recreated
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

5. **Apply networking changes**
   ```bash
   cd infra/terraform/aws/networking
   terraform apply
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
   - Run `terraform apply` to confirm no changes

### Post-Migration Verification

- [ ] WireGuard wg0 (site-to-site) handshake within last minute
- [ ] WireGuard wg1 (remote access) accepting connections
- [ ] nftables rules loaded (`sudo nft list ruleset`)
- [ ] Routing from AWS to homelab working (`ping 10.10.201.5`)
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

2. **Apply Terraform**
   ```bash
   cd infra/terraform/aws/compute
   terraform plan
   terraform apply
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
> template (VM 9001) and now uses `ubuntu` + `/tmp/auto-key` like the
> K8s nodes. Updated SSH examples below.

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

1. **Apply Terraform** (creates VM from cloud-init template)
   ```bash
   cd infra/terraform/proxmox/standalone-vms
   terraform plan -var-file=terraform.tfvars.local
   terraform apply -var-file=terraform.tfvars.local
   ```

2. **Run WireGuard Ansible playbook**
   ```bash
   cd infra/ansible
   export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
   ansible-playbook -i inventory/wind/ playbooks/wireguard.yml --limit vpn-local
   ```

3. **Verify tunnel reconnection**
   ```bash
   ssh -i /tmp/auto-key ubuntu@10.10.201.15 "sudo wg show"
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
> Packer template (VM 9001) and now uses `ubuntu` + `/tmp/auto-key`
> like the K8s nodes. Updated SSH examples below.

> **Watchdog reattach:** as with vpn-local, imported VMs need a full
> stop+start (not just reboot) to reattach the `i6300esb` watchdog
> device. See `docs/runbooks/vm-watchdog.md`.

### Pre-Migration

1. **Backup Technitium config** (optional - cluster will sync)
   ```bash
   ssh -i /tmp/auto-key ubuntu@10.10.201.6 "sudo tar -czvf /tmp/technitium-backup.tar.gz -C /opt/technitium config/"
   scp -i /tmp/auto-key ubuntu@10.10.201.6:/tmp/technitium-backup.tar.gz ./backups/technitium-local-$(date +%Y%m%d).tar.gz
   ```

### Migration Steps

1. **Apply Terraform**
   ```bash
   cd infra/terraform/proxmox/standalone-vms
   terraform plan -var-file=terraform.tfvars.local
   terraform apply -var-file=terraform.tfvars.local
   ```

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
