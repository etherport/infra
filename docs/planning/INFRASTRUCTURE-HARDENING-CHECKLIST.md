# Infrastructure Hardening Checklist

**Created:** 2026-04-07
**Purpose:** Track production-readiness improvements identified during infrastructure review

---

## Quick Wins (In Progress)

### 1. EBS Volume Encryption ✅
- [x] Enable encryption on VPN instance root volume (`compute/main.tf:130`)
- [x] Enable encryption on DNS instance root volume (`compute/main.tf:182`)
- [x] DNS instance migrated (i-050de21bdad2603bb with encrypted EBS)
- [x] VPN instance migrated (i-011086cefc7ab3cc1 with encrypted EBS)
- [x] WireGuard keys restored, tunnel reconnected
- [x] nftables MSS clamping configured

### 2. Grafana Admin Password
- [x] Remove hardcoded password from `clusters/wind/helm-releases/monitoring.yaml:67`
- [x] Reference existing SOPS secret `platform/kubernetes/monitoring/grafana-admin-secret.sops.yaml`
- [x] Verify Flux reconciliation

### 3. Homeassistant-Alexa Deprecation Fix
- [x] Change `data.aws_region.current.name` to `.id` in `homeassistant-alexa/iam.tf:52`
- [x] Run `terraform plan` to verify no changes (just warning removal)

### 4. Pod Disruption Budgets
- [ ] **Blocked:** Requires replica count increase (#12) to be meaningful
- [ ] Add PDB to kube-prometheus-stack Helm values
- [ ] Add PDB to Traefik Helm values
- [ ] Add PDB to cert-manager Helm values
- [ ] Verify PDBs created: `kubectl get pdb -A`
- **Note:** With single replicas, PDBs with `minAvailable: 1` would block all voluntary disruptions. Defer until replicas are increased.

### 5. Email-Forward Bucket Conflict
- [x] Remove `aws_s3_bucket.email` resource from `email-forward/main.tf`
- [x] Add data source to reference bucket from s3 module
- [x] Update all references to use data source
- [x] Remove unused `email_retention_days` variable (lifecycle managed by s3 module)
- [x] Remove bucket from email-forward state: `terraform state rm aws_s3_bucket.email aws_s3_bucket_lifecycle_configuration.email`
- [x] Run `terraform plan` to verify no changes

### 6. CloudWatch Agent on EC2 Instances
- [x] Create Ansible playbook for CloudWatch agent installation (`infra/ansible/playbooks/cloudwatch-agent.yml`)
- [x] Create swap file playbook for memory-constrained instances (`infra/ansible/playbooks/swap.yml`)
- [ ] Deploy swap.yml to VPN instance (prevents OOM)
- [ ] Deploy swap.yml to DNS instance (prevents OOM)
- [ ] Deploy cloudwatch-agent.yml to VPN instance
- [ ] Deploy cloudwatch-agent.yml to DNS instance
- [ ] Verify CloudWatch alarms transition from INSUFFICIENT_DATA to OK
- **Note:** t4g.nano instances (512MB RAM) require swap file to prevent OOM crashes, especially when running Technitium (uses .NET runtime).

---

## Critical Issues

### 6. HA Control Plane (Future)
- [ ] Plan 3-node control plane architecture
- [ ] Update Proxmox Terraform for additional VMs
- [ ] Update Kubespray inventory for HA
- [ ] Schedule maintenance window for migration
- [ ] Execute migration
- [ ] Verify cluster health

### 7. NetworkPolicies (Future)
- [ ] Create default-deny ingress policy template
- [ ] Apply to non-system namespaces
- [ ] Whitelist necessary traffic (monitoring, backups)
- [ ] Test thoroughly before production

### 8. Etcd Backup Documentation (Future)
- [ ] Create `docs/runbooks/etcd-backup-restore.md`
- [ ] Document automated snapshot configuration
- [ ] Document manual backup procedures
- [ ] Document restoration steps
- [ ] Test restoration procedure

### 9. Disaster Recovery Testing (Future)
- [ ] Schedule monthly Velero restore drills
- [ ] Document test results
- [ ] Schedule quarterly full cluster recovery test
- [ ] Update DR runbook with lessons learned

---

## High Priority Issues

### 10. Hardcoded IPs in Security Groups
- [ ] Create variables for homelab WAN IPs
- [ ] Update `networking/security_groups.tf` to use variables
- [ ] Document IP update procedure

### 11. Terraform MFA Protection
- [ ] Implement IAM role assumption with MFA
- [ ] Update `docs/setup/terraform/aws-security-best-practices.md`
- [ ] Test workflow

### 12. Increase Replica Counts
- [ ] Home Automation: increase to 2 replicas
- [ ] Add pod anti-affinity rules
- [ ] Verify scheduling across nodes

---

## Medium Priority Issues

### 13. Resource Quotas per Namespace
- [ ] Create ResourceQuota templates
- [ ] Apply to all application namespaces
- [ ] Monitor for quota violations

### 14. SLO/SLI Definitions
- [ ] Create `docs/architecture/service-level-objectives.md`
- [ ] Define availability targets per service
- [ ] Align alerting thresholds with SLOs

### 15. Image Scanning
- [ ] Evaluate Trivy integration with Flux
- [ ] Implement scanning in CI/CD pipeline

---

## Completed Items

| Date | Item | Notes |
|------|------|-------|
| 2026-04-07 | VPN instance EBS encryption | Migrated to i-011086cefc7ab3cc1 with encrypted EBS, WireGuard restored |
| 2026-04-07 | DNS instance EBS encryption | Migrated to i-050de21bdad2603bb with encrypted EBS |
| 2026-04-07 | Deleted orphaned IAM roles (4) | DataSync, dns_restrict_ip, SESEmailForwarder |
| 2026-04-07 | Deleted orphaned IAM policies (12) | AWSLambdaBasicExecutionRole-*, misc |
| 2026-04-07 | Cleaned up us-east-1 log groups (2) | Legacy empty log groups |
| 2026-04-07 | Updated AWS documentation | aws-infrastructure.md, remote-state-backend.md |
| 2026-04-07 | Completed Phase 6 cleanup | EventBridge, log groups, IAM roles, S3 bucket |
| 2026-04-07 | WireGuard keys in SOPS | Server keys stored in `platform/wireguard/servers/*.sops.yaml` |
| 2026-04-10 | Fixed IAM permission gap | Added secretsmanager:GetResourcePolicy to terraform-ddns-secrets-iam |
| 2026-04-10 | Reconciled external-monitoring SNS | Recreated backup email subscription (grahamsm@gmail.com) |
| 2026-04-10 | Deleted orphaned SES IAM roles (4) | ses_put_s3_mark_role, ses_put_s3_role, ses_s3_put_role, ses_send_forward |
| 2026-04-10 | Fixed aws-websites Terraform | S3 native locking, Route53 data source fix |
| 2026-04-10 | Moved WordPress to public-web-vpc | Instance i-01d0fc79138b2dc9e now in proper VPC |
| 2026-04-07 | WireGuard playbook refactored | Uses community.sops to deploy keys from encrypted files |
| 2026-04-07 | Client configs in SOPS | Remote access and S2S configs in `platform/wireguard/clients/*.sops.yaml` |
| 2026-04-07 | vpn-local in Terraform | Proxmox VM (ID 1002) managed by standalone-vms module |
| 2026-04-07 | Full IaC deployment tested | vpn-local recreated from scratch via Terraform+Ansible |
| 2026-04-07 | Migration runbook created | `docs/runbooks/instance-migration.md` for all VPN/DNS instances |
| 2026-04-07 | Technitium playbook updated | Added backup restoration capability |
| 2026-04-13 | Tailscale mesh VPN deployed | K8s operator + AWS subnet router, split DNS configured |
| 2026-04-13 | CloudWatch agent playbook created | `infra/ansible/playbooks/cloudwatch-agent.yml` |
| 2026-04-13 | Swap file playbook created | `infra/ansible/playbooks/swap.yml` for t4g.nano instances |
| 2026-04-13 | Tailscale documentation | `docs/architecture/vpn-tailscale.md` |
| 2026-04-23 | WireGuard K8s HA deployment | K8s pod (primary) + vpn-local (backup) with Keepalived VRRP failover |
| 2026-04-23 | WireGuard cleanup DaemonSet | Removes orphaned wg0/VIP when pod moves between nodes |
| 2026-04-23 | WireGuard documentation update | Updated `docs/architecture/vpn-wireguard.md` with HA architecture |

---

## Notes

- **EBS Encryption:** ✅ Completed. Both VPN and DNS instances migrated to encrypted EBS. WireGuard keys now stored in SOPS and deployed via Ansible.

- **WireGuard IaC:** All WireGuard configuration is now fully IaC-managed:
  - **K8s (primary):** `platform/kubernetes/wireguard/` - Deployed via Flux
  - **vpn-local (backup):** Deployed via Ansible `playbooks/wireguard.yml`
  - **vpn-aws:** Deployed via Ansible `playbooks/wireguard.yml`
  - Server keys: `platform/wireguard/servers/{vpn-aws,vpn-local}.sops.yaml`
  - K8s secrets: `platform/kubernetes/wireguard/01-secrets.sops.yaml` (same keys as vpn-local)
  - Failover: Keepalived VRRP with floating VIP 10.10.201.20
  - Requires: `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`

- **Proxmox Standalone VMs:** vpn-local (1002) and dns-fallback (1001) managed by `infra/terraform/proxmox/standalone-vms/`

- **Email-Forward Bucket:** The `email-fwd.grahamsmith.net` bucket is managed by both `s3` module (with tags) and `email-forward` module (without tags). Resolution: email-forward should use a data source to reference the bucket owned by s3 module.

- **Grafana Password:** The existing SOPS secret is at `platform/kubernetes/monitoring/grafana-admin-secret.sops.yaml`. The Helm release should reference this via `existingSecret`.
