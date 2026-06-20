# Homelab Infrastructure Documentation

Central documentation index for the homelab infrastructure project.

## Quick Start

| I want to... | Go to... |
|--------------|----------|
| Understand the platform | [runbooks/PLATFORM-MANAGEMENT.md](runbooks/PLATFORM-MANAGEMENT.md) |
| Check update status | [runbooks/UPDATE-PROCEDURES.md](runbooks/UPDATE-PROCEDURES.md) |
| Run operational commands | [runbooks/operations-guide.md](runbooks/operations-guide.md) |
| Deploy changes via GitOps | [setup/gitops/making-changes.md](setup/gitops/making-changes.md) |
| Recover from failures | [runbooks/disaster-recovery.md](runbooks/disaster-recovery.md) |

---

## Documentation Structure

```
docs/
├── runbooks/          # Day-to-day operations
├── architecture/      # System design
├── setup/             # Initial setup guides
│   ├── kubernetes/    # K8s cluster setup
│   ├── terraform/     # Infrastructure as code
│   ├── gitops/        # Flux/GitOps setup
│   └── secrets/       # SOPS/1Password setup
├── reference/         # Quick reference docs
├── guides/            # Step-by-step tutorials
└── planning/          # Temporary planning docs (delete when done)
```

---

## Runbooks (Operations)

| Document | Description |
|----------|-------------|
| [PLATFORM-MANAGEMENT.md](runbooks/PLATFORM-MANAGEMENT.md) | High-level platform overview and quick links |
| [UPDATE-PROCEDURES.md](runbooks/UPDATE-PROCEDURES.md) | All update procedures - automatic, semi-auto, manual |
| [operations-guide.md](runbooks/operations-guide.md) | Command reference for all operations |
| [kubernetes-upgrade.md](runbooks/kubernetes-upgrade.md) | Kubernetes version upgrade procedures |
| [disaster-recovery.md](runbooks/disaster-recovery.md) | Recovery procedures for failure scenarios |
| [dns-resolution-issues.md](runbooks/dns-resolution-issues.md) | DNS troubleshooting |
| [gpu-dcgm-exporter-wedge.md](runbooks/gpu-dcgm-exporter-wedge.md) | Empty GPU dashboard / `TargetDown` dcgm — driver wedge on gpu1, reboot VM 120 |
| [unas-nvme-cache-apst-hang.md](runbooks/unas-nvme-cache-apst-hang.md) | UNAS pool "At Risk"/SSD cache "Repairing" while drives show healthy — NVMe cache member dropped off the bus (APST hang); reboot + md rebuild |
| [vlan-interfaces-netplan.md](runbooks/vlan-interfaces-netplan.md) | VLAN interface configuration |
| [cert-manager-wildcard.md](runbooks/cert-manager-wildcard.md) | Wildcard cert issuance + Traefik TLSStore |
| [cilium-cni-dir-owner.md](runbooks/cilium-cni-dir-owner.md) | Cilium CrashLoop after a kubespray run (/opt/cni/bin owner) + the real kubespray run path |
| [secrets-rotation.md](runbooks/secrets-rotation.md) | SOPS age-key rotation (routine + post-compromise) + offline backup recipient |
| [ceph-vlan-migration.md](runbooks/archive/ceph-vlan-migration.md) | Ceph mon/OSD migration to VLAN 210 (2026-05-18, done) |
| [regional-vpn-deployment.md](runbooks/regional-vpn-deployment.md) | Multi-region AWS spoke VPN deployment |
| [grafana-admin-password.md](runbooks/grafana-admin-password.md) | Rotate/recover Grafana admin password |
| [syslog-onboard-device.md](runbooks/syslog-onboard-device.md) | Add a new syslog-emitting device to Alloy |
| [postgres-barman.md](runbooks/postgres-barman.md) | CNPG Barman backup config + tuning |
| [etcd-backup-restore.md](runbooks/etcd-backup-restore.md) | etcd snapshot + restore (cluster-rebuild path) |
| [image-pinning-policy.md](runbooks/image-pinning-policy.md) | Container image pinning + Renovate cadence |
| [dependency-update-cadence.md](runbooks/dependency-update-cadence.md) | Renovate/Helm-release update cadence |
| [auto-remediation/](runbooks/auto-remediation/) | Automated issue resolution system (legacy rule-based) |
| **AI advisor (M41 / M45)** — ⚠️ system is **LIVE** (advisory + approve-via-email active); the per-phase *enable* runbooks below are **archived** because the one-time enablement is done, not because the feature is retired | |
| [ai-advisor-phase1-enable.md](runbooks/archive/ai-advisor-phase1-enable.md) | Enable advisory-only diagnosis email path |
| [ai-advisor-phase2-enable.md](runbooks/archive/ai-advisor-phase2-enable.md) | Enable approve-via-email (HMAC-signed buttons) |
| [ai-advisor-phase3-enable.md](runbooks/archive/ai-advisor-phase3-enable.md) | Enable opt-in autonomous execute (`ai_remediation: auto`) |
| [ai-advisor-phase-b-cloudwatch.md](runbooks/archive/ai-advisor-phase-b-cloudwatch.md) | M45 Phase B — IAM + creds so advisor reads AWS CW Logs |
| [cloudwatch-to-loki-enable.md](runbooks/archive/cloudwatch-to-loki-enable.md) | M45 Phase C — CW Logs → in-cluster Loki forwarder |
| **Cloudflare cutover** | |
| [cloudflare-access-enable.md](runbooks/cloudflare-access-enable.md) | Full-zone migration (Route53 → CF) + CF Access for approve.wind |

## Operations

| Document | Description |
|----------|-------------|
| [terminal-setup.md](operations/terminal-setup.md) | Terminal setup & disaster recovery for workstations |

## Architecture

| Document | Description |
|----------|-------------|
| [overview.md](architecture/overview.md) | High-level infrastructure design |
| [network.md](architecture/network.md) | Network topology and VLANs |
| [firewall-zones.md](architecture/firewall-zones.md) | Zone-based firewall configuration |
| [vpn-wireguard.md](architecture/vpn-wireguard.md) | Site-to-site VPN (production traffic) |
| [vpn-tailscale.md](architecture/vpn-tailscale.md) | Tailscale mesh VPN (remote access) |
| [aws-infrastructure.md](architecture/aws-infrastructure.md) | AWS hybrid cloud components |

## Setup Guides

### Kubernetes
| Document | Description |
|----------|-------------|
| [cluster-build-kubespray.md](setup/kubernetes/cluster-build-kubespray.md) | Cluster provisioning with Kubespray |
| [addons-metallb.md](setup/kubernetes/addons-metallb.md) | MetalLB load balancer setup |
| [ingress-traefik.md](setup/kubernetes/ingress-traefik.md) | Traefik ingress configuration |
| [storage-ceph-csi.md](setup/kubernetes/storage-ceph-csi.md) | Ceph CSI storage setup |
| [monitoring-kube-prometheus-stack.md](setup/kubernetes/monitoring-kube-prometheus-stack.md) | Prometheus monitoring stack |

### Terraform
| Document | Description |
|----------|-------------|
| [proxmox-k8s-vms.md](setup/terraform/proxmox-k8s-vms.md) | Proxmox VM provisioning |
| [remote-state-backend.md](setup/terraform/remote-state-backend.md) | Terraform state in S3 |

### GitOps
| Document | Description |
|----------|-------------|
| [flux-overview.md](setup/gitops/flux-overview.md) | Flux GitOps workflow and patterns |
| [making-changes.md](setup/gitops/making-changes.md) | How to make changes via GitOps |
| [repo-workflow.md](setup/gitops/repo-workflow.md) | Git repository workflow |

### Secrets
| Document | Description |
|----------|-------------|
| [SOPS-SETUP.md](setup/secrets/SOPS-SETUP.md) | **Canonical** secrets doc: SOPS + age, plus the `op` (1Password CLI) quick-reference |
| [1PASSWORD-CLI.md](setup/secrets/1PASSWORD-CLI.md) | ⟶ merged into SOPS-SETUP.md (2026-06-17); now a redirect stub |

### Network
| Document | Description |
|----------|-------------|
| [ubiquiti-ddns.md](setup/network/ubiquiti-ddns.md) | ⚠️ **Superseded** — Route53-based UDM DDNS (Route53 retired 2026-05-27; DDNS moved to Cloudflare). Kept for history. |

## Reference

| Document | Description |
|----------|-------------|
| [kubectl-cheatsheet.md](reference/kubectl-cheatsheet.md) | kubectl command reference |
| [kustomize-patterns.md](reference/kustomize-patterns.md) | Kustomize patterns and examples |
| [node-vlan-setup.md](reference/node-vlan-setup.md) | Node VLAN configuration reference |

## Guides

| Document | Description |
|----------|-------------|
| [localtuya/](guides/localtuya/) | LocalTuya setup for IoT devices |

## Planning

The canonical work tracker for active/upcoming/in-flight items is
**[outstanding-work.md](planning/outstanding-work.md)**. Anything not
in that file is either out of scope, already done, or hasn't been
captured yet.

| Document | Description |
|----------|-------------|
| [outstanding-work.md](planning/outstanding-work.md) | **Source of truth** for prioritized open work (C/H/M/L tiers) + completed index |
| [zero-trust-assessment-2026-06-17.md](planning/zero-trust-assessment-2026-06-17.md) | Zero-trust posture: what's done vs gaps (H37/H38, M72–M76, L24) |
| [ai-alert-remediation-2026-05-23.md](planning/archive/ai-alert-remediation-2026-05-23.md) | AI advisor system design spec (M41) |
| [ai-advisor-phases-2-3-scope.md](planning/archive/ai-advisor-phases-2-3-scope.md) | M41 Phase 2/3 implementation scope |
| [firewall-zones-future-state-2026-05-29-completed.md](planning/archive/firewall-zones-future-state-2026-05-29-completed.md) | Proposed UDM zone design (M30) — ✅ implemented; archived. Live state: [architecture/firewall-zones.md](architecture/firewall-zones.md) |
| [hardcoded-ephemeral-ip-audit-2026-05-23.md](planning/archive/hardcoded-ephemeral-ip-audit-2026-05-23.md) | EIP / ephemeral-IP audit |
| [udm-audit-2026-05-23.md](planning/udm-audit-2026-05-23.md) | UDM / UniFi config audit (M25) |
| [udm-config-drift-2026-05-17.md](planning/archive/udm-config-drift-2026-05-17.md) | UDM config drift snapshot |
| [ubiquiti-config-as-code-2026-05-16.md](planning/archive/ubiquiti-config-as-code-2026-05-16.md) | UniFi config-as-code design (terraform-unifi) |
| [public-web-infrastructure.md](planning/public-web-infrastructure.md) | Status of public-facing web hosting |
| [VERSIONING-STRATEGY.md](planning/VERSIONING-STRATEGY.md) | Container image versioning approach |
| [sops-vs-ansible-vault.md](planning/sops-vs-ansible-vault.md) | SOPS vs Ansible-Vault comparison |

Older completed/superseded planning docs (kept for historical
context only) live in [docs/planning/archive/](planning/archive/).

---

## Platform Components

```
Infrastructure layer:
├── Proxmox (Terraform)               VM provisioning + SDN bridges
├── Kubernetes (Kubespray)            Container orchestration (Cilium CNI + Multus)
├── AWS (Terraform)                   VPC, EC2 (vpn-aws/dns-aws), ALB, Route53, SES, Lambdas
├── UniFi (Terraform — terraform-unifi) Networks/VLANs/routes/reservations/port-forwards
└── Cloudflare (Terraform)            etherport.net zone (NS-cutover pending), Tunnel, Access

Configuration layer:
├── Ansible                  Non-K8s host config (PVE, standalone VMs, UDM)
├── Flux                     K8s GitOps reconciler (clusters/wind/)
├── Helm                     Complex K8s apps via HelmRelease CRDs
└── Tailscale ACL (TF)       infra/tailscale/, applied via tailscale-policy.yml

Observability:
├── Prometheus (kube-prometheus-stack, replicas=2 antiAffinity)
├── Alertmanager → SES email (+ webhook to auto-remediation)
├── Grafana (https://grafana.wind.etherport.net)
├── Loki (single-binary) + Alloy DaemonSet
├── blackbox-exporter        ICMP/HTTPS probes for UDM / Protect / UNAS
├── cloudwatch-to-loki       AWS CW Logs → Loki every 5 min (M45 Phase C)
├── ipmi_exporter + ipmievd  PVE BMC metrics + syslog (M40)
└── service-status-report    Daily HTML email + Grafana dashboard

AI alert advisor (auto-remediation namespace):
├── Phase 1                  Advisory-only diagnosis emails (live)
├── Phase 2                  Approve-via-email HMAC buttons (live)
├── Phase 3                  Opt-in autonomous execute via `ai_remediation: auto` label (live)
├── 18 action types          3 tiers — pod/deploy, workload-aware, host-level via SSH
├── Closed-loop verification After-execute re-check; verification_passed/failed audit events
├── Cross-session memory     Prior-attempt outcomes surfaced to Claude prompt
├── Deep mode tool-use       Multi-turn promql/loki/kubectl tools (opt-in per alert)
└── CloudWatch context (M45 Phase B) AWS-side log fetch for Lambda/EC2 alerts

Data layer:
├── Ceph (external on PVE, mon 10.10.210.41 VLAN 210) + ceph-csi
├── Velero (10 schedules) → Kopia → S3 infra.wind.etherport.net/velero/
├── CNPG Barman              continuous WAL + nightly base → S3 postgres/barman/
├── unifi-backup CronJob     UDM controller-db + UDM/Protect core-config → S3 unifi/
├── s3-sync CronJobs (7)     per NAS share → per-share S3 buckets
├── rclone gdrive-sync       Google Drive → NFS mirror
└── SOPS + age               Secret encryption (per-workstation age key)

Edge / public access:
├── Traefik (10.10.201.70)   Wildcard cert via cert-manager TLSStore
├── AWS ALB                  Public *.wind.etherport.net (planned drop after CF migration)
├── Cloudflare Tunnel        cloudflared deploy → CF Access → approve.etherport.net
└── Tailscale operator       Per-service ingresses + subnet router for tailnet-only access
```
