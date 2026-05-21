# Outstanding Work — Consolidated Priority List (2026-05-21)

Successor to `outstanding-work-2026-05-16.md`. Resets the priority lattice
after a multi-day session covering SDN migration, Ceph VLAN move, post-
migration cleanup, and IaC durability hardening.

**How to read this:** Items keep their original ID (`C1`, `H3`, …) across
revisions so history is grep-able. New items added since the prior
revision use the next free ID per tier. Status legend:

| Glyph | Meaning |
|---|---|
| ✅ | Done — landed in main, applied where applicable |
| 🟡 | In progress — partially landed or actively being worked |
| ⏳ | Pending — scheduled or queued |
| 📋 | Drafted — code/playbook ready, awaiting human-supervised apply |

---

## CRITICAL — production outage / data-loss risk

### ⏳ C1. CNPG continuous backup (Barman) not configured cluster-wide
- **Source:** `outstanding-work-2026-05-16.md` C1; `long-term-stability-review-2026-05-12.md`
- Velero FS backup of a live Postgres pod is not crash-consistent. Without Barman + ScheduledBackup we have no PITR; a corrupt pgdata = data loss.
- **Effort:** M
- **Blockers:** None — S3 bucket already exists; just wire the Cluster manifest.

### ✅ C2. Rebuild `dns-fallback` (1001) + `vpn-local` (1002) from VM 9001 template
- **Done:** 2026-05-16. Both standalone VMs recreated from the new Packer template; TF in sync with live state. Tracked as task #4.

### ⏳ C3. Encrypt Ceph key in plaintext inventory
- **Source:** `outstanding-work-2026-05-16.md` C3
- `infra/kubespray/inventory/wind/group_vars/all/ceph.yml` still contains plaintext `ceph_k8s_key`. Move to SOPS to match existing pattern.
- **Effort:** S
- **Blockers:** None.

---

## HIGH — production-readiness; 1–2 weeks

### ✅ H1. GPU Secure Boot disable on VM 120
- **Done:** 2026-05-16. Plex + Ollama now running on GPU. Tracked as task #13.

### ⏳ H2. Pin Kubespray submodule to release tag
- **Source:** `outstanding-work-2026-05-16.md` H2
- `.gitmodules` still tracks `main`. Effort: S.

### 🟡 H3. NetworkPolicies + ResourceQuotas + PDBs (Phase 1 — audit-only)
- **Source:** `outstanding-work-2026-05-16.md` H3; task #2 (in_progress)
- Phase 1: LimitRanges + audit-only CNPs + conservative quotas already deployed via `platform/kubernetes/policy-baseline/`. Phase 2/3 (enforcement) pending Hubble observation window.
- **Effort:** L for Phase 2+3 (observation + tuning).

### ✅ H4. `Secrets: write` on claude-cli PAT
- **Done:** 2026-05-16. PAT scope updated, `FLUX_DEPLOY_KEY` + `SOPS_AGE_KEY` populated. Tracked as task #6.

### ⏳ H5. Increase replica counts → enable PDBs
- **Source:** `outstanding-work-2026-05-16.md` H5
- Traefik already at replicas=2 (cluster/wind/helm-releases/traefik.yaml). cert-manager + Prometheus still single-replica.

### ⏳ H6. Hardcoded WAN IPs in AWS security groups
- **Source:** `outstanding-work-2026-05-16.md` H6
- Periodic rotation via Lambda exists but bootstrap IPs are hardcoded.

### ✅ H7. Doc drift cleanup
- **Done:** 2026-05-19 to 2026-05-21 in multiple commits. Architecture/overview/network/firewall-zones docs reflect VLAN 210, enp6s22, SDN bridges, RSA wildcard cert. `node-vlan-setup.md` updated 4→5 interfaces. `regional-vpn-deployment.md` drops 1.1.1.1 from DNS push.

### ⏳ H8. Archive completed migration docs
- **Source:** `outstanding-work-2026-05-16.md` H8
- Several files in `docs/planning/` are now historical (e.g. `migration-questions-2026-05-12.md`). Move to `docs/planning/archive/`.

### ⏳ H9. Deploy swap + CloudWatch agent on vpn-aws / dns-aws
- **Source:** `outstanding-work-2026-05-16.md` H9
- Ansible playbooks `swap.yml` + `cloudwatch-agent.yml` exist; never run against AWS VMs.

### ✅ H10. Inventory consolidation (ansible vs kubespray)
- **Done:** 2026-05-16. Tracked as task #5.

### ✅ H11. Multus VLAN parent interfaces — durable fix
- **Done:** 2026-05-16. Baked into Packer template via netplan. Tracked as task #11.

### ✅ H12. Velero backup strategy captures PV data
- **Done:** 2026-05-16. Switched from snapshot-of-pod to volume-level. Tracked as task #10.

### ✅ H13. PV data recovery for HA config + other stateful workloads
- **Done:** 2026-05-16. Tracked as task #9.

### ✅ H14. Tame PVE SSH ban/rate-limit for IaC tooling
- **Done:** 2026-05-21. Root cause was OpenSSH 9.8+ `PerSourcePenalties` (default-on in PVE 9.x); `noauth:1` + `min:15` banned sources after a handful of TCP-only probes. Fix landed in `pve-sshd.yml`: `PerSourcePenaltyExemptList 10.10.0.0/16,...`. Followed up 2026-05-21 by bumping `PerSourceMaxStartups 20 → 100` and switching `state: reloaded → restarted` after observing the SIGHUP path doesn't reset internal counters on OpenSSH 10.0. Also dropped redundant `ssh-keyscan` step in `ansible-proxmox.yml`. Switched `ansible_user` to `root` (PVE convention; no NOPASSWD sudo gymnastics). Tracked as task #27.

### ✅ H15. Fix WG K8s pod preStop hook for clean keepalived release
- **Done:** 2026-05-19. Reordered keepalived shutdown: SIGTERM (priority-0 advert) → wait → SIGKILL → strip VIP. Sub-second VRRP failover. Tracked as task #28.

### ✅ H16. CI drift detection for terraform applies
- **Done:** 2026-05-19. Daily scheduled workflow across 14 AWS modules; opens GH issue on drift. Latest run 14/14 clean. Excludes deploy-on-demand `aws-regional-vpn`. Tracked as task #29.

### ✅ H17. AWS Budget alarm at $75/mo
- **Done:** 2026-05-21. `homelab-monthly` budget with 80%/100% actual + 100% forecasted notifications via SNS + email. Tracked as task #18.

### ✅ H18. Post-migration P0: stale Ceph mon IP + safety-check coverage
- **Done:** 2026-05-19. Verified ceph-csi config in `default` ns has correct `10.10.210.41:6789` (orphan in `ceph-csi` ns is unused). Extended `scripts/network/safety-check.sh` with AWS DNS resolver, Sequoia, UniFi device-state via API, ceph-csi mon IP regression guard. Tracked as tasks #15, #31.

### ✅ H19. Push terraform-dns IAM policy v3 (Route53 zone perms)
- **Done:** 2026-05-19. v3 default in AWS includes `CreateHostedZone`, `DeleteHostedZone`, `AssociateVPCWithHostedZone`, etc. Unblocked the `aws.etherport.net` private zone creation in route53 module. Tracked as task #32.

### ✅ H20. Standalone gh-runner VM for K8s-lifecycle workflows
- **Done:** 2026-05-16. Tracked as task #3.

### ✅ H21. Pre-install common CRDs in bootstrap workflow
- **Done:** 2026-05-16. Tracked as task #8.

### ✅ H22. Fix /opt/cni ownership in kubespray
- **Done:** 2026-05-16. Tracked as task #7.

### ✅ H23. Disable auto-update on UniFi devices
- **Done:** 2026-05-16. Tracked as task #16.

### ✅ H24. USW Aggregation LAG port 2 — pair re-toggle
- **Done:** 2026-05-16. Quirk documented in memory. Tracked as task #17.

### ✅ H25. Ceph migration to dedicated VLAN 210
- **Done:** 2026-05-18. Mon on `10.10.210.41:6789`, K8s VMs got `enp6s22` (MTU 9000) with netplan `dhcp4-overrides` to prevent bad-route injection. Tracked as task #26.

### 🟡 H26. Proxmox SDN migration — Phase 1
- **Status:** PRs 1–4 done; PR 5 (K8s VMs) paused; PR 6 (cleanup) blocked on PR 5.
- **PR 1** (TF module + workflow): done.
- **PR 2** (zone + VNets, mgmt + storage VNets intentionally absent): done.
- **PR 3** (dns-fallback canary): done 2026-05-18.
- **PR 4** (vpn-local + gh-runner): done 2026-05-18.
- **PR 5** (K8s VMs, 8 VMs, 4–6h drain-and-migrate): **pending**, needs supervision per CP. Plan revised: NIC 5 (VLAN 210) stays on `vmbr0+vlan_id=210` because the storage VNet would conflict with PVE's own vmbr0.210.
- **PR 6** (cleanup `local.bridge_name`/`local.vlan_tag`): pending PR 5.
- Tracked as task #19.

### 📋 H27. Re-enable Ceph msgr2 (v2 protocol) on port 3300
- **Status:** Playbook `infra/ansible/playbooks/ceph-msgr2.yml` drafted; check-mode validated; latest apply (2026-05-21) hit the per-source-counter bug (#H14 follow-up). After PerSourceMaxStartups bump + sshd restart, re-dispatch:
  ```
  gh workflow run ansible-proxmox.yml -f playbook=ceph-msgr2 -f action=apply
  ```
- Discovery: monmap was v1-only — `ceph mon enable-msgr2` upgrades the addrvec.
- Follow-up landed: `platform/kubernetes/storage/ceph-csi/csi-config-map.yaml` now lists `10.10.210.41:3300` ahead of `:6789`. Flux reconciles; existing pod RBD mounts keep v1 until restart.
- Tracked as task #30.

---

## MEDIUM — quality / hygiene

### ⏳ M1. Static-PV recovery pattern in `disaster-recovery.md`
- Source: `outstanding-work-2026-05-16.md` M1.

### ⏳ M2. cert-manager wildcard runbook (renewal + rotation)
- Source: `outstanding-work-2026-05-16.md` M2.

### ⏳ M3. Kustomize ConfigMapGenerator for S3-sync excludes
- Source: `outstanding-work-2026-05-16.md` M3.

### ⏳ M4. Pin container images + Helm charts; document Renovate policy
- Source: `outstanding-work-2026-05-16.md` M4. Renovate is wired but policy doc is missing.

### ⏳ M5. Velero schedule kustomization ordering + ResourceQuota CR
- Source: `outstanding-work-2026-05-16.md` M5.

### ⏳ M6. Packer + ansible netplan dedup (F1.3)
- Source: `outstanding-work-2026-05-16.md` M6.

### ⏳ M7. More `dependsOn` declarations across Flux HRs (F4.2)
- Source: `outstanding-work-2026-05-16.md` M7.

### ⏳ M8. Auto-remediation COVERAGE.md refresh
- Source: `outstanding-work-2026-05-16.md` M8.

### ⏳ M9. Etcd backup automation + DR drill schedule
- Source: `outstanding-work-2026-05-16.md` M9.

### ⏳ M10. Lifecycle / `ignore_changes` on Proxmox K8s VMs (F1.5)
- Source: `outstanding-work-2026-05-16.md` M10.

### ⏳ M11. DR runbook with measured RTO/RPO targets
- Source: task #23. Needs your judgment on targets before measurement.

### ⏳ M12. CNPG restore drill Tier B (sibling cluster)
- Source: task #24. Destructive test; needs supervision and maintenance window.

### ⏳ M13. Delete `/data/udm-le.removed-*` on UDM / Protect / Sequoia
- Source: task #14. Runtime cleanup of orphaned cert backups; needs SSH paths configured (Sequoia rejected multi-key 1P agent with "too many auth failures"; UDM needs separate creds).

### ⏳ M14. Investigate aws-s3-sync daily-report SSL mismatch (if recurs)
- Source: task #25. Only act if it recurs.

### ⏳ M15. Twilio Talk: fix 911 emergency address
- Source: task #20. Out-of-band (Twilio console).

### ⏳ M16. Twilio Talk: route or release orphan DID
- Source: task #21. Out-of-band.

### ⏳ M17. Twilio Talk: migrate SIP trunk UDP → TLS+sRTP
- Source: task #22. Out-of-band.

---

## LOW

### ⏳ L1. Proxmox HA cluster expansion
- Source: `outstanding-work-2026-05-16.md` L1. Blocked on adding a 2nd PVE node.

---

## DROP — outdated or already done

(Carried forward from `outstanding-work-2026-05-16.md`; nothing new in this revision.)

- **D1.** `INFRASTRUCTURE-HARDENING-CHECKLIST.md` §6 "HA Control Plane (Future)" — done 2026-05-12.
- **D2.** `INFRASTRUCTURE-HARDENING-CHECKLIST.md` §8 "Etcd Backup Documentation" — done; runbook at `docs/runbooks/etcd-backup-restore.md`. Automation tracked as M9.
- **D3.** `PRODUCTION-READINESS-CHECKLIST.md` §GPU sub-items — GPU stack live since 2026-05-16; Secure Boot done (H1); doc folded into H7.

---

## Completed since 2026-05-16 — summary

For history. Anything ticked above has a brief inline note; this is the index.

| ID | Title | Done |
|---|---|---|
| C2 | Rebuild dns-fallback + vpn-local | 2026-05-16 |
| H1 | GPU Secure Boot disable | 2026-05-16 |
| H4 | Secrets:write on claude-cli PAT | 2026-05-16 |
| H7 | Doc drift cleanup | 2026-05-19 to 21 |
| H10 | Inventory consolidation | 2026-05-16 |
| H11 | Multus VLAN durable fix | 2026-05-16 |
| H12 | Velero captures PV data | 2026-05-16 |
| H13 | PV data recovery | 2026-05-16 |
| H14 | PVE SSH ban/rate-limit | 2026-05-21 |
| H15 | WG K8s pod preStop | 2026-05-19 |
| H16 | CI drift detection | 2026-05-19 |
| H17 | AWS Budget $75/mo | 2026-05-21 |
| H18 | Post-migration P0 | 2026-05-19 |
| H19 | terraform-dns IAM v3 | 2026-05-19 |
| H20 | Standalone gh-runner VM | 2026-05-16 |
| H21 | Pre-install CRDs in bootstrap | 2026-05-16 |
| H22 | /opt/cni ownership fix | 2026-05-16 |
| H23 | Disable UniFi auto-update | 2026-05-16 |
| H24 | USW LAG quirk | 2026-05-16 |
| H25 | Ceph VLAN 210 migration | 2026-05-18 |

---

## Process

- This file is the canonical work tracker. When an item completes, flip the glyph to ✅ and add a one-line `**Done:**` note with the date. Don't delete — preserve history.
- When the file gets too long (>500 lines or once per ~quarter), spin off a new dated successor and link forward like this one does.
- Items not yet captured here should be added with the next free ID in their tier — don't re-use deprecated IDs.
- TaskCreate IDs (`#NN`) are session-scoped and ephemeral; this file is the durable record. Reference TaskCreate IDs only to help cross-check while a session is active.
