# Infrastructure Hardening Checklist

**Created:** 2026-04-07
**Purpose:** Track production-readiness improvements identified during infrastructure review

---

## Quick Wins (In Progress)

### 1. EBS Volume Encryption
- [x] Enable encryption on VPN instance root volume (`compute/main.tf:130`)
- [x] Enable encryption on DNS instance root volume (`compute/main.tf:182`)
- [ ] Run `terraform plan` to verify changes
- [ ] **Note:** Applying requires instance replacement - schedule maintenance window

### 2. Grafana Admin Password
- [x] Remove hardcoded password from `clusters/wind/helm-releases/monitoring.yaml:67`
- [x] Reference existing SOPS secret `platform/kubernetes/monitoring/grafana-admin-secret.sops.yaml`
- [ ] Verify Flux reconciliation

### 3. Homeassistant-Alexa Deprecation Fix
- [x] Change `data.aws_region.current.name` to `.id` in `homeassistant-alexa/iam.tf:52`
- [ ] Run `terraform plan` to verify no changes (just warning removal)

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
- [ ] Remove bucket from email-forward state: `terraform state rm aws_s3_bucket.email aws_s3_bucket_lifecycle_configuration.email`
- [ ] Run `terraform plan` to verify no changes

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
| 2026-04-07 | Deleted orphaned IAM roles (4) | DataSync, dns_restrict_ip, SESEmailForwarder |
| 2026-04-07 | Deleted orphaned IAM policies (12) | AWSLambdaBasicExecutionRole-*, misc |
| 2026-04-07 | Cleaned up us-east-1 log groups (2) | Legacy empty log groups |
| 2026-04-07 | Updated AWS documentation | aws-infrastructure.md, remote-state-backend.md |
| 2026-04-07 | Completed Phase 6 cleanup | EventBridge, log groups, IAM roles, S3 bucket |

---

## Notes

- **EBS Encryption:** Changing encryption requires instance replacement. Both VPN and DNS instances will need to be recreated. Ensure WireGuard keys and Technitium config are backed up or can be restored from Ansible.

- **Email-Forward Bucket:** The `email-fwd.grahamsmith.net` bucket is managed by both `s3` module (with tags) and `email-forward` module (without tags). Resolution: email-forward should use a data source to reference the bucket owned by s3 module.

- **Grafana Password:** The existing SOPS secret is at `platform/kubernetes/monitoring/grafana-admin-secret.sops.yaml`. The Helm release should reference this via `existingSecret`.
