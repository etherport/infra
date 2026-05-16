# Outstanding Work — Consolidated Priority List (2026-05-16)

Source consolidation across `docs/planning/*`, `docs/runbooks/*`,
`README.md`s, and code comments. Cluster is healthy (8/8 nodes, 11/11
HRs, HA + CNPG + cert-manager wildcard + Velero schedules all in git);
priorities reflect that baseline.

---

## CRITICAL — production outage / data-loss risk

### C1. CNPG continuous backup (Barman) not configured cluster-wide
- **Source:** `long-term-stability-review-2026-05-12.md` §C4; `doc-drift-2026-05-16.md` (postgres-barman.md exists but `cnpg/README.md` still calls Barman "optional")
- Velero FS backup of a live Postgres pod is not crash-consistent. Without Barman + ScheduledBackup we have no PITR; a corrupt pgdata = data loss.
- **Effort:** M (S3 bucket + ServerSideEncryption + Cluster manifest patch + ScheduledBackup CR)
- **Blockers:** S3 bucket `postgres-barman.wind.etherport.net` already exists per doc-drift; need to wire the Cluster manifest.

### C2. Rebuild `dns-fallback` (1001) + `vpn-local` (1002) from VM 9001 template
- **Source:** long-term-stability-review §Task #4; migration-questions §5
- TF currently disagrees with live state — next unguarded `terraform apply` on standalone-vms will destroy and recreate, taking VPN + fallback DNS down unscheduled. vpn-local also carries the WireGuard VRRP backup VIP.
- **Effort:** M (maintenance window: rebuild vpn-local first while K8s WG pod holds VIP; then dns-fallback while K8s technitium serves)
- **Blockers:** None — manual sequencing only.

### C3. Encrypt Ceph key in plaintext inventory
- **Source:** `PRODUCTION-READINESS-CHECKLIST.md` §Secrets; `sops-vs-ansible-vault.md`
- `infra/kubespray/inventory/wind/group_vars/all/ceph.yml` contains plaintext `ceph_k8s_key` checked into git. Compromises the entire Ceph cluster if repo leaks.
- **Effort:** S (decision already drafted: SOPS to match existing pattern)
- **Blockers:** None.

---

## HIGH — production-readiness; 1–2 weeks

### H1. GPU Secure Boot disable on VM 120
- **Source:** long-term-stability-review §1; `docs/runbooks/gpu-secureboot.md`
- Plex + Ollama pods Pending until NVIDIA driver loads. Runbook ready (3 SSH commands).
- **Effort:** S (~5 min downtime)

### H2. Pin Kubespray submodule to release tag
- **Source:** `PRODUCTION-READINESS-CHECKLIST.md` §Version Pinning
- `.gitmodules` tracks `main`; any rebuild pulls drift-of-the-day, breaking reproducibility validated on 2026-05-12.
- **Effort:** S

### H3. NetworkPolicies + ResourceQuotas + PDBs (Phase 1 — audit-only)
- **Source:** long-term-stability-review §3 (Task #2); `INFRASTRUCTURE-HARDENING-CHECKLIST.md` §4,7,13
- Phase 1 of the designed 3-phase rollout: LimitRanges + audit-only CNPs + conservative quotas. Phase 2/3 need Hubble observation window. Multus VLAN-204 bypasses Cilium — firewall stays at UDM.
- **Effort:** M (Phase 1); L (Phase 2 + 3 incl. observation)

### H4. `Secrets: write` on claude-cli PAT → populate `FLUX_DEPLOY_KEY` + `SOPS_AGE_KEY`
- **Source:** long-term-stability-review §2 (Task #6); migration-questions §4
- `post-bootstrap.yml` workflow already exists but fails fast without these — full-DR rebuild stays manual.
- **Effort:** S (UI change + 2 secrets)

### H5. Increase replica counts → enable PDBs
- **Source:** `INFRASTRUCTURE-HARDENING-CHECKLIST.md` §4, §12; long-term-stability §"Nice-to-have"
- Traefik/cert-manager/Prometheus replicas≥2 with PDBs unblocks safe node drains during kubespray upgrades. PDB work in H-CHECKLIST is explicitly blocked on this.
- **Effort:** M

### H6. Hardcoded WAN IPs in AWS security groups
- **Source:** `INFRASTRUCTURE-HARDENING-CHECKLIST.md` §10
- `networking/security_groups.tf` hardcodes homelab WAN IPs; DDNS changes silently break SSH/admin access. Wrap in variables sourced from DDNS data.
- **Effort:** S

### H7. Doc drift cleanup (cluster shape + cert-manager + ssh user)
- **Source:** `doc-drift-2026-05-16.md` (20+ files)
- Wrong cluster shape (1 CP claims) in `architecture/overview.md`, `operations-guide.md`, `disaster-recovery.md`, `kubernetes-upgrade.md`, `PLATFORM-MANAGEMENT.md`; wrong ssh user (`graham` vs `ubuntu`); stale ACME/Traefik TLS instructions.
- **Effort:** M
- **Blockers:** Best done as one sweep PR; coordinate with H8.

### H8. Archive completed migration docs
- **Source:** `doc-drift-2026-05-16.md`
- Move/banner: `k8s-ha-migration.md`, `K8S-W3-DEPLOYMENT-PLAN.md`, `infra/ansible/KUBESPRAY_MIGRATION.md` — describe past work as if future.
- **Effort:** S

### H9. Deploy swap + CloudWatch agent on vpn-aws / dns-aws
- **Source:** `INFRASTRUCTURE-HARDENING-CHECKLIST.md` §6
- t4g.nano OOMs Technitium under .NET load; playbooks built, not yet applied. CW alarms stuck `INSUFFICIENT_DATA`.
- **Effort:** S

### H10. Inventory consolidation (ansible vs kubespray)
- **Source:** long-term-stability §5 (Task #5); migration-questions Q1, Q3
- Two `group_vars` trees duplicate the host list; only one is live. Generate kubespray inventory from ansible via make target or symlink.
- **Effort:** M

---

## MEDIUM — quality / clarity / cost; within a month

### M1. Static-PV recovery pattern in `disaster-recovery.md`
- Source: `doc-drift-2026-05-16.md`. DR runbook only mentions Velero restore which would `initdb` over Ceph pgdata. Cross-link CNPG `03/04-*.yaml` pattern.
- Effort: S

### M2. cert-manager wildcard runbook (renewal + rotation)
- Source: `doc-drift-2026-05-16.md` §Missing. No runbook covers cluster-issuer + wildcard + TLSStore wiring.
- Effort: S

### M3. Kustomize ConfigMapGenerator for S3-sync excludes
- Source: `TODO-configmap-migration.md`. Repeat of Jan 5 incident (`.smbdelete` uploaded due to stale per-share CM). Fully designed.
- Effort: S

### M4. Pin container images + Helm charts; document Renovate policy
- Source: `PRODUCTION-READINESS-CHECKLIST.md` §Version Pinning
- Kopia still `:latest`; verify all manifests; codify update cadence.
- Effort: S

### M5. Velero schedule kustomization ordering + ResourceQuota CR
- Source: long-term-stability §F4.3, §13. Schedules currently apply before HR; quotas mentioned in 3 places never written.
- Effort: S

### M6. Packer + ansible netplan dedup (F1.3)
- Source: long-term-stability "Nice-to-have". Same netplan stanza in two places; drift risk if only one is updated.
- Effort: S

### M7. More `dependsOn` declarations across Flux HRs (F4.2)
- Source: long-term-stability. Reduce cold-start retry storms beyond monitoring + gpu-operator.
- Effort: S

### M8. Auto-remediation COVERAGE.md refresh
- Source: `doc-drift-2026-05-16.md`. Stale stats; CNPG / Velero schedule failure / barman archiving lag not covered.
- Effort: S

### M9. Etcd backup automation + DR drill schedule
- Source: `PRODUCTION-READINESS-CHECKLIST.md` §DR; `INFRASTRUCTURE-HARDENING-CHECKLIST.md` §9
- Runbook exists; automate snapshots off-cluster + schedule monthly Velero restore drills.
- Effort: M

### M10. Lifecycle / `ignore_changes` on Proxmox K8s VMs (F1.5)
- Source: long-term-stability. Prevent TF churn on agent-modified fields.
- Effort: S

---

## LOW — speculative / nice-to-have

- **L1.** Proxmox HA cluster expansion (`proxmox-ha-expansion.md` §"NOT done yet") — blocked on adding 2nd PVE node.
- **L2.** Multi-region travel VPN (`aws-cost-analysis.md` Phase 2/3) — only if travel cadence justifies.
- **L3.** External-secrets-operator / automated secrets rotation (`PRODUCTION-READINESS-CHECKLIST.md` §P4).
- **L4.** Image scanning (Trivy) in CI (`INFRASTRUCTURE-HARDENING-CHECKLIST.md` §15).
- **L5.** SLO/SLI definitions doc (`INFRASTRUCTURE-HARDENING-CHECKLIST.md` §14).
- **L6.** Semantic versioning for in-house container images (`VERSIONING-STRATEGY.md`) — current `:main` + `:sha-*` works.
- **L7.** Terraform MFA-protected role assumption (`INFRASTRUCTURE-HARDENING-CHECKLIST.md` §11).
- **L8.** Phase 2/3 NetworkPolicy enforcement (after H3 audit window).
- **L9.** Long-tail Terraform-via-Actions automation (`github-actions-automation-roadmap.md` Phases 2/3 — Route53/external-monitoring Phase 1 still pending too).

---

## DROP — outdated or already done

- **D1.** `INFRASTRUCTURE-HARDENING-CHECKLIST.md` §6 "HA Control Plane (Future)" — **done** 2026-05-12.
- **D2.** `INFRASTRUCTURE-HARDENING-CHECKLIST.md` §8 "Etcd Backup Documentation" — **done** (`docs/runbooks/etcd-backup-restore.md` exists; automation tracked as M9).
- **D3.** `PRODUCTION-READINESS-CHECKLIST.md` §GPU sub-items (✅ marked but interleaved with TODOs) — GPU stack live; only Secure-Boot disable (H1) and `gpu-worker-setup.md` doc remain (folded into H7).
- **D4.** `infra/kubespray/...k8s-cluster.yml:133` upstream nftables TODO — vendored from kubespray; not our concern, drop from grep noise.
- **D5.** `docs/guides/localtuya/get_tuya_devices.py:16` — placeholder credential comment in a one-shot helper script; intentional, leave.
- **D6.** `migration-questions-2026-05-12.md` Q4 (kubeconfig location) — moot; ops use `~/.kube/config` already.
- **D7.** `PRODUCTION-READINESS-CHECKLIST.md` "Cluster recovery runbook" — superseded by `post-bootstrap.sh` + CNPG `03/04-*.yaml` + the long-term-stability commit set.

---

## Long-tail (not in top-20)

Doc-drift sub-items (per-README polish in `home-automation`, `traefik`,
`plex`, `wireguard`, `technitium`, `aws-infrastructure.md`,
`network.md`, `flux-overview.md`, `node-vlan-setup.md`,
`ingress-traefik.md`, `cluster-build-kubespray.md`, `vlan-interfaces-netplan.md`
formatting bug) — bundle into H7 sweep. Missing-doc items from
doc-drift (gh-runner README, sinkhole records note, WAF retention,
Prometheus AWS shift, post-bootstrap usage) — fold into H7 or M2.
CRD pre-install (long-term-stability §8) — partially addressed by
kubespray Multus/MetalLB enable; remaining cert-manager/traefik/cnpg
come via Helm with `dependsOn` — acceptable.
