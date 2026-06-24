# Technitium DNS Server Configuration

> **⚠️ The canonical Technitium doc is `platform/kubernetes/technitium/README.md`.**
> This file covers only the Ansible / standalone-VM bits. The AWS-instance
> (`10.10.100.5`, dns-aws) and Route53-sinkhole language below is **historical** —
> Route53 was deleted 2026-05-27 (DNS is authoritative on Cloudflare). Trust the
> canonical doc for current cluster/zone state.

## Overview

Technitium DNS Server configuration is managed through a combination of:
1. **Ansible playbook** (`infra/ansible/playbooks/technitium.yml`) - Installs Technitium
2. **Config backup** (`backups/`) - Stores encrypted config for disaster recovery
3. **Manual configuration** - Initial setup via web UI

## Configuration Files

Technitium stores its configuration in `/opt/technitium/config/`:

| File | Purpose |
|------|---------|
| `auth.config` | Admin credentials (encrypted) |
| `dns.config` | DNS server settings |
| `cluster.config` | DNS cluster configuration |
| `blocklist.config` | Blocklist sources |
| `zones/` | Authoritative DNS zones |

## Backup and Restore

### Creating a Backup

```bash
# SSH to DNS server
ssh ubuntu@10.10.100.5

# Create backup
sudo tar -czvf /tmp/technitium-backup.tar.gz -C /opt/technitium config/

# Copy locally
scp ubuntu@10.10.100.5:/tmp/technitium-backup.tar.gz ./backups/
```

### Restoring from Backup

```bash
# Copy backup to server
scp backups/technitium-backup.tar.gz ubuntu@10.10.100.5:/tmp/

# SSH and restore
ssh ubuntu@10.10.100.5
sudo systemctl stop technitium
sudo rm -rf /opt/technitium/config
sudo tar -xzvf /tmp/technitium-backup.tar.gz -C /opt/technitium/
sudo systemctl start technitium
```

## DNS Cluster Configuration

The DNS cluster consists of:
- **10.10.201.5** - Kubernetes cluster VIP (primary)
- **10.10.201.6** - Local fallback (dns-fallback)
- **10.10.100.5** - AWS remote (dns-aws)

### Adding a New Cluster Member

1. Install Technitium via Ansible
2. Access web UI at `http://<ip>:5380`
3. Set admin password
4. Go to Settings → Cluster
5. Add cluster peer addresses
6. Zones will sync automatically

## Zones

| Zone | Type | Purpose |
|------|------|---------|
| `wind.etherport.net` | Primary | Homelab internal DNS |
| `dns-cluster.wind.etherport.net` | Cluster catalog | Cluster sync |

### Route53 sinkhole records under `wind.etherport.net` (commit d542853)

`pve.wind.etherport.net` and `ceph.wind.etherport.net` are pinned to
sinkhole (RFC5737) addresses in the public Route53 zone so that off-net
clients (or anything that resolves via 1.1.1.1 instead of the Technitium
cluster) can't accidentally reach our infrastructure UIs. The
authoritative on-net answers still come from this Technitium cluster.

### AWS private hosted zone `aws.etherport.net` (DELETED 2026-05-27)

This Route53 private hosted zone was deleted as part of the
etherport.net → Cloudflare migration. It never had any real content,
so no clients are affected. The Technitium conditional forwarder for
`aws.etherport.net` was removed in `infra/ansible/playbooks/technitium.yml`.
The `us-west-2.compute.internal` forwarder (EC2 internal hostnames)
remains — it's served by the same dns-aws hop and is unaffected.

See [`docs/runbooks/aws-private-dns.md`](../../docs/runbooks/aws-private-dns.md)
for historical context and a restoration recipe should a future
VPC-internal DNS need arise.

## Initial Setup (New Instance)

After running the Ansible playbook:

1. Access `http://<ip>:5380`
2. Set admin password
3. Configure DNS settings:
   - Forwarders: 1.1.1.1, 8.8.8.8
   - Enable DNSSEC validation
4. Configure clustering (if joining existing cluster)
5. Import blocklists (optional)

## Instance Migration

When migrating to a new instance (e.g., EBS encryption):

1. Create backup before migration
2. Run Terraform to replace instance
3. Run Ansible playbook to install Technitium
4. Restore backup (or let cluster sync)
5. Verify zones and settings

If part of a cluster, the new instance will automatically sync zones
from other cluster members after joining.
