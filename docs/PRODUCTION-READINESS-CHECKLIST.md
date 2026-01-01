# Homelab Infrastructure - Production Readiness Checklist

**Created**: 2025-12-31
**Repository**: sparked-diamond/infra (private)
**Purpose**: Track improvements to production-standard infrastructure

---

## 🚨 Critical Security (Priority 1)

### Secrets Management

- [ ] **Encrypt Route53 credentials with SOPS**
  - File: `platform/kubernetes/secrets/route53-credentials.yaml`
  - Status: ✅ Already in `.gitignore`, not in git history
  - Action: Encrypt with SOPS for consistency with other secrets
  - Assignee:
  - Due:

- [ ] **Encrypt Ceph key**
  - File: `infra/ansible/inventory/wind/group_vars/all/ceph.yml`
  - Current: Plaintext Ceph authentication key
  - Decision needed: SOPS vs ansible-vault (see comparison below)
  - Assignee:
  - Due:

- [x] **Grafana admin password**
  - Status: ✅ Already changed via web UI
  - Note: Consider moving to secret management for IaC consistency
  - Completed: 2025-12-31

---

## ⚙️ Infrastructure Stability (Priority 2)

### Version Pinning

- [ ] **Pin Kubespray to stable release**
  - Current: Git submodule pointing to `main` branch
  - Target: Lock to specific release tag (e.g., `v2.25.0`)
  - File: `.gitmodules`
  - Assignee:
  - Due:

- [ ] **Pin container images in platform manifests**
  - [ ] Kopia: `kopia/kopia:latest` → `kopia/kopia:0.18.2`
  - [ ] Review all manifests for `:latest` tags
  - [ ] Document version update process
  - Files: `platform/kubernetes/apps/`, `platform/kubernetes/monitoring/`
  - Assignee:
  - Due:

- [ ] **Pin Helm chart versions**
  - [ ] kube-prometheus-stack
  - [ ] Traefik (if using Helm)
  - Files: Helm values files
  - Assignee:
  - Due:

- [ ] **Create version update policy document**
  - Define update cadence (monthly? quarterly?)
  - Testing requirements before updating
  - Rollback procedures
  - File: `docs/processes/version-management.md`
  - Assignee:
  - Due:

### Terraform State Management

- [x] **Migrate to S3 remote state**
  - Current: ✅ Migrated from local tfstate files
  - Target: S3 bucket with DynamoDB locking
  - Benefits: Team collaboration, state locking, versioning
  - File: `infra/terraform/proxmox/k8s-vms/backend.tf`
  - Completed: 2025-12-31

- [x] **Create S3 bucket for Terraform state**
  - Bucket name: `terraform.wind.etherport.net`
  - Region: `us-west-2`
  - Versioning: ✅ Enabled
  - Encryption: ✅ Enabled (AES256)
  - Completed: 2025-12-31

- [x] **Create DynamoDB table for state locking**
  - Table name: `homelab-terraform-locks`
  - Primary key: `LockID` (String)
  - Billing mode: Pay-per-request
  - Completed: 2025-12-31

---

## 📚 Documentation (Priority 3)

### Disaster Recovery

- [ ] **Document etcd backup procedures**
  - Automated backup schedule
  - Backup storage location
  - Retention policy
  - File: `docs/runbooks/etcd-backup-restore.md`
  - Assignee:
  - Due:

- [ ] **Document cluster recovery procedures**
  - Full cluster rebuild from scratch
  - Control plane recovery
  - Worker node recovery
  - Data restoration from backups
  - File: `docs/runbooks/cluster-disaster-recovery.md`
  - Assignee:
  - Due:

- [ ] **Document AWS S3 backup restore procedures**
  - Current: Backup system is comprehensive ✅
  - Missing: Step-by-step restore process
  - File: Update `platform/kubernetes/backups/aws-s3/README.md`
  - Assignee:
  - Due:

- [ ] **Define and document RTO/RPO targets**
  - RTO: Recovery Time Objective (how fast?)
  - RPO: Recovery Point Objective (how much data loss?)
  - Per-service/data criticality matrix
  - File: `docs/architecture/disaster-recovery-targets.md`
  - Assignee:
  - Due:

- [ ] **Create backup restore testing schedule**
  - Monthly restore drills for critical data
  - Quarterly full cluster recovery test
  - File: `docs/processes/backup-testing-schedule.md`
  - Assignee:
  - Due:

### Operational Runbooks

- [ ] **Monitoring & alerting runbook**
  - Common alert meanings and severity levels
  - Response procedures per alert type
  - Escalation paths
  - Silence/acknowledge procedures
  - File: `docs/runbooks/monitoring-alerting.md`
  - Assignee:
  - Due:

- [ ] **Kubernetes upgrade procedures**
  - Version upgrade planning (compatibility checks)
  - Kubespray upgrade playbook execution
  - Component upgrade order (control plane → workers)
  - Rollback procedures
  - File: `docs/runbooks/kubernetes-upgrade.md`
  - Assignee:
  - Due:

- [ ] **Troubleshooting guide**
  - Common issues and solutions
  - Debug commands per component
  - Log locations and analysis
  - File: `docs/runbooks/troubleshooting-common-issues.md`
  - Assignee:
  - Due:

- [ ] **Secrets rotation procedures**
  - Which secrets need rotation and how often
  - Rotation procedures per secret type
  - Testing after rotation
  - File: `docs/runbooks/secrets-rotation.md`
  - Assignee:
  - Due:

### New Node Addition

- [ ] **Document worker node addition process**
  - Terraform changes required
  - Ansible inventory updates
  - Kubespray node addition playbook
  - Verification steps
  - File: `docs/kubernetes/add-worker-node.md`
  - Assignee:
  - Due:

---

## 🎮 GPU Worker Implementation (Priority 2)

### Infrastructure Code

- [x] **Create GPU worker VM in Terraform**
  - VM name: `k8s-gpu1`
  - IP: `10.10.201.53`
  - Resources: 8 vCPU / 32GB RAM / 80GB disk
  - GPU passthrough: Tesla P40 (hostpci0)
  - File: `infra/terraform/proxmox/k8s-vms/main.tf`
  - Completed: 2025-12-31
  - Note: Requires Q35 machine type for PCI passthrough

- [x] **Update Ansible inventory for GPU worker**
  - Add to `[kube_node]` group
  - Configure GPU-specific node labels
  - Configure GPU node taints
  - File: `infra/ansible/inventory/wind/inventory.ini`
  - Completed: 2025-12-31
  - Host vars: `infra/ansible/inventory/wind/host_vars/k8s-gpu1.yml`

- [x] **Deploy GPU worker via Terraform + Kubespray**
  - `terraform apply` for VM creation
  - Ansible playbook to join cluster
  - Verification of GPU availability
  - Completed: 2025-12-31
  - Note: Pre-flight playbook required for CNI directory permissions

### Kubernetes Platform

- [x] **Deploy NVIDIA GPU Operator**
  - ✅ Installed via Helm (nvidia/gpu-operator)
  - ✅ Configured for time-slicing (2 replicas)
  - ✅ Driver v580.105.08 installed successfully
  - ✅ GPU resources available: nvidia.com/gpu.shared: 2
  - File: `platform/kubernetes/gpu-operator/values.yaml`
  - Completed: 2025-12-31
  - Note: Fixed Secure Boot incompatibility with NVIDIA drivers

- [x] **Configure GPU time-slicing**
  - ✅ Time-slicing ConfigMap created via Helm values
  - ✅ Replicas: 2 (Plex + LLM simultaneously)
  - ✅ Resource name: nvidia.com/gpu.shared
  - File: `platform/kubernetes/gpu-operator/values.yaml`
  - Completed: 2025-12-31

- [x] **Configure GPU node taints/labels**
  - Taint: `nvidia.com/gpu=true:NoSchedule`
  - Label: `gpu=true`, `gpu-type=tesla-p40`
  - Prevent non-GPU workloads from landing on GPU node
  - Completed: 2025-12-31
  - Configured via Kubespray host_vars

### Documentation

- [ ] **Create GPU worker setup documentation**
  - GPU passthrough configuration (Proxmox)
  - NVIDIA driver installation
  - GPU Operator deployment
  - Time-slicing configuration
  - File: `docs/kubernetes/gpu-worker-setup.md` (new)
  - Assignee:
  - Due:

- [ ] **Update architecture overview**
  - Add GPU worker to cluster diagram
  - Document GPU workload patterns
  - File: `docs/architecture/overview.md`
  - Assignee:
  - Due:

- [x] **Create GPU workload examples**
  - ✅ Plex deployment with GPU hardware transcoding
  - ✅ Complete manifests: namespace, PVC, deployment, service, ingress
  - ✅ NFS media mounts (Movies, TV Shows)
  - ✅ 25GB Ceph storage for config/metadata
  - ✅ Accessible at https://plex.wind.etherport.net
  - File: `platform/kubernetes/plex/`
  - Completed: 2025-12-31
  - Note: Required linux-modules-extra installation on GPU node for Ceph RBD

---

## 🔄 Continuous Improvement (Priority 4)

### Platform Enhancements

- [ ] **Implement namespace resource quotas**
  - CPU/memory limits per namespace
  - Prevent resource exhaustion
  - File: `platform/kubernetes/namespaces/` (update)
  - Assignee:
  - Due:

- [ ] **Add Pod Disruption Budgets**
  - For critical workloads (control plane components, monitoring)
  - Ensure availability during node maintenance
  - Files: Various platform manifests
  - Assignee:
  - Due:

- [ ] **Document workload placement strategies**
  - When to use node affinity
  - When to use taints/tolerations
  - Resource request/limit best practices
  - File: `docs/kubernetes/workload-scheduling-patterns.md`
  - Assignee:
  - Due:

- [ ] **Implement automated secrets rotation**
  - Identify candidates for automation
  - External secrets operator or similar
  - File: TBD
  - Assignee:
  - Due:

### Testing & Validation

- [ ] **Create test plan for cluster changes**
  - Pre-change validation steps
  - Post-change verification
  - Rollback criteria
  - File: `docs/processes/change-testing-protocol.md`
  - Assignee:
  - Due:

---

## 📊 Progress Tracking

### Summary Statistics

- **Total Items**: 40
- **Completed**: 6 (15%)
- **In Progress**: 0 (0%)
- **Not Started**: 34 (85%)

### By Priority

| Priority | Total | Completed | Remaining |
|----------|-------|-----------|-----------|
| P1 (Critical Security) | 3 | 1 | 2 |
| P2 (Infrastructure Stability) | 19 | 5 | 14 |
| P3 (Documentation) | 14 | 0 | 14 |
| P4 (Continuous Improvement) | 4 | 0 | 4 |

---

## 📝 Notes & Decisions

### SOPS vs Ansible-Vault Decision
- **Pending**: Choose encryption method for Ceph key
- **Options**: See comparison in `docs/decisions/sops-vs-ansible-vault.md`
- **Deadline**: TBD

### Version Pinning Strategy
- **Pending**: Define version update cadence
- **Considerations**: Balance stability vs security updates
- **Deadline**: TBD

---

## 🔗 Related Documentation

- [Architecture Overview](./architecture/overview.md)
- [Kubernetes Ops Runbook](./runbooks/kubernetes-ops.md)
- [AWS S3 Backup System](../platform/kubernetes/backups/aws-s3/README.md)
- [Terraform Proxmox VMs](./terraform/proxmox-k8s-vms.md)

---

**Last Updated**: 2025-12-31
**Next Review**: TBD
