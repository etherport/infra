# Outstanding Work — Consolidated Priority List

Latest revision: 2026-05-22 (file renamed from `outstanding-work-2026-05-21.md`
to drop the date suffix — canonical name is stable; predecessors live in `archive/`).

Successor to `archive/outstanding-work-2026-05-16.md`. Resets the priority lattice
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
- **Source:** `archive/outstanding-work-2026-05-16.md` C1; `archive/long-term-stability-review-2026-05-12.md`
- Velero FS backup of a live Postgres pod is not crash-consistent. Without Barman + ScheduledBackup we have no PITR; a corrupt pgdata = data loss.
- **Effort:** M
- **Blockers:** None — S3 bucket already exists; just wire the Cluster manifest.

### ✅ C2. Rebuild `dns-fallback` (1001) + `vpn-local` (1002) from VM 9001 template
- **Done:** 2026-05-16. Both standalone VMs recreated from the new Packer template; TF in sync with live state. Tracked as task #4.

### ✅ C3. Encrypt Ceph key in plaintext inventory
- **Done:** 2026-05-22 (commit `88e34d2`). Moved `ceph_k8s_key` from plaintext `infra/ansible/inventory/wind/group_vars/all/ceph.yml` to SOPS-encrypted sibling `ceph-k8s-secret.sops.yaml`. Loaded at runtime in `playbooks/ceph/ceph-k8s.upstream-reference.yml` via `community.sops.load_vars` (same pattern as wireguard.yml). The kubespray-side `infra/kubespray/inventory/group_vars/all/ceph.sops.yaml` was already encrypted. **Source:** `archive/outstanding-work-2026-05-16.md` C3.

---

## HIGH — production-readiness; 1–2 weeks

### ✅ H1. GPU Secure Boot disable on VM 120
- **Done:** 2026-05-16. Plex + Ollama now running on GPU. Tracked as task #13.

### ✅ H2. Pin Kubespray submodule to release tag
- **Done:** 2026-05-22 (commit `6bfd964`). `.gitmodules` now pins to `release-2.30` branch (currently at v2.30.0 commit). Receives v2.30.x patches without jumping minor/major. Bump to release-2.31 only after a DR-rebuild test against the new release. **Source:** `archive/outstanding-work-2026-05-16.md` H2.

### 🟡 H3. NetworkPolicies + ResourceQuotas + PDBs (Phase 1 — audit-only)
- **Source:** `archive/outstanding-work-2026-05-16.md` H3; task #2 (in_progress)
- Phase 1: LimitRanges + audit-only CNPs + conservative quotas already deployed via `platform/kubernetes/policy-baseline/`. Phase 2/3 (enforcement) pending Hubble observation window.
- **Effort:** L for Phase 2+3 (observation + tuning).

### ✅ H4. `Secrets: write` on claude-cli PAT
- **Done:** 2026-05-16. PAT scope updated, `FLUX_DEPLOY_KEY` + `SOPS_AGE_KEY` populated. Tracked as task #6.

### ✅ H5. Increase replica counts → enable PDBs
- **Done:** 2026-05-22 (commit `0851d26`). Prometheus + Alertmanager both bumped to `replicas=2` with podAntiAffinity in `kube-prometheus-stack-values.yaml`. cert-manager + cert-manager-cainjector + cert-manager-webhook were already 2/2 per kubectl (no change needed). Traefik was already 2/2. Grafana stays at 1 (RWO PVC + sticky session — HA needs external DB).

### ⏳ H6. Hardcoded WAN IPs in AWS security groups
- **Source:** `archive/outstanding-work-2026-05-16.md` H6
- **Concrete plan** (2026-05-22 audit): three hardcoded entries in `infra/terraform/aws/networking/security_groups.tf`:
  - `aws_security_group.allow_ssh` port 22 from `47.34.215.233/32` ("remote location")
  - `aws_security_group.dns_server` port 53 UDP+TCP from `66.215.210.75/32` + `47.159.189.5/32` ("homelab WAN")
- A `dns-restrict-ip` Lambda already exists (`infra/terraform/aws/dns-restrict-ip/`) — it watches Route53 record changes and rewrites `security_group_id` ingress rules. Currently targets one SG (`sg-08d12e417159c18d2`). Plan:
  1. Add Route53 A records for the three IPs above (or reuse `wan1.wind.etherport.net` / `wan2` if they're the same source).
  2. Extend `dns-restrict-ip` to accept a list of `(security_group_id, port, protocol)` rule specs and update each from its corresponding DNS record.
  3. Remove the three hardcoded TF entries.
- Effort: M. Needs careful state migration (the Lambda must own each rule entirely; partial overlap with TF state → drift).
- Periodic rotation via Lambda exists but bootstrap IPs are hardcoded.

### ✅ H7. Doc drift cleanup
- **Done:** 2026-05-19 to 2026-05-21 in multiple commits. Architecture/overview/network/firewall-zones docs reflect VLAN 210, enp6s22, SDN bridges, RSA wildcard cert. `node-vlan-setup.md` updated 4→5 interfaces. `regional-vpn-deployment.md` drops 1.1.1.1 from DNS push.

### ✅ H8. Archive completed migration docs
- **Done:** 2026-05-22. Eleven planning docs moved to `docs/planning/archive/` with a `README.md` table listing why each was archived. Includes the just-completed `proxmox-sdn-implementation-2026-05-18.md` (PRs 1-6 all shipped). Top-level `docs/planning/` now holds only the canonical tracker + active design docs + ADRs.

### ⏳ H9. Deploy swap + CloudWatch agent on vpn-aws / dns-aws
- **Source:** `archive/outstanding-work-2026-05-16.md` H9
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

### ✅ H27. Re-enable Ceph msgr2 (v2 protocol) on port 3300
- **Done:** 2026-05-22. Applied via the new containerized CI path (see H28). Verified post-apply: `ss -tlnp` shows ceph-mon LISTENING on 10.10.210.41:**3300** and :6789, monmap upgraded by `ceph mon enable-msgr2`, mon back in quorum (HEALTH_OK), all OSDs up. K8s ceph-csi configmap now lists `:3300` ahead of `:6789`; existing pod RBD mounts keep v1 until restart, new mounts prefer msgr2. Tracked as task #30.

### ✅ H28. Containerized ansible CI (gh-runner reliability fix)
- **Done:** 2026-05-22. Root cause for repeated CI flakiness on `ansible-proxmox.yml`: per-run `apt-get update + install ansible` was saturating gh-runner's outbound network, leaving the immediate-next ansible SSH to PVE timing out at the TCP layer. Fix:
  - `infra/ci/ansible-runner/Dockerfile` — Ubuntu 24.04 + ansible + openssh-client + python3 + jq + git, with community.general + ansible.posix collections.
  - `.github/workflows/ansible-runner-image.yml` — builds and pushes `ghcr.io/sparked-diamond/ansible-runner:main` on Dockerfile changes (public package; one-time flip via UI).
  - `.github/workflows/ansible-proxmox.yml` — adds `container:` block pointing at the image; drops the apt-install step entirely. Sets `ANSIBLE_PRIVATE_KEY_FILE` explicitly because the container's `HOME=/github/home` isn't picked up by ansible's default key lookup.
  - `infra/ansible/playbooks/gh-runner.yml` — installs `docker.io` and adds the runner user to the docker group as part of the standard runner provisioning (durable across rebuilds; a one-shot `debug-install-docker.yml` workflow bootstrapped today's runner past the chicken-and-egg, then was removed).
- Side benefit: pattern generalizes — terraform/kubectl/etc. can be pre-baked the same way in future image variants.

---

## MEDIUM — quality / hygiene

### ⏳ M1. Static-PV recovery pattern in `disaster-recovery.md`
- Source: `archive/outstanding-work-2026-05-16.md` M1.

### ✅ M2. cert-manager wildcard runbook (renewal + rotation)
- **Done:** 2026-05-22 (commit `6c896ee`). `docs/runbooks/cert-manager-wildcard.md` rewritten from the thin prior version. Now covers the dual-cert architecture (ECDSA shortlived for Traefik vs RSA classic for UniFi-OS — unifi-core silently rejects ECDSA and certs without CN-in-Subject), automatic renewal cadence (day-4 / day-60), manual rotation procedures (per-cert renew, Route53 cred rotation, ACME account key regen), failure modes (dns01 challenge failure, LE rate-limit, stale Traefik secret, unifi-cert-sync auth break), and a what-NOT-to-do list. Source: `archive/outstanding-work-2026-05-16.md` M2.

### ✅ M3. Kustomize ConfigMapGenerator for S3-sync excludes
- **Done:** already implemented; verified 2026-05-22. Per-share `excludes-share.txt` is mounted via `configMapGenerator` in each `platform/kubernetes/backups/aws-s3/shares/<share>/kustomization.yaml`, and `base/kustomization.yaml` generates the global `aws-s3-sync-excludes-global` ConfigMap. Kustomize's `namePrefix: s3-sync-<share>-` automatically rewrites the CronJob patch's `configMap.name` references so a single edit to `base/excludes-global.txt` propagates to all 7 shares on the next Flux reconcile (which is exactly what the original `TODO-configmap-migration.md` aimed to fix). Migration TODO doc archived. Source: `archive/outstanding-work-2026-05-16.md` M3.

### ✅ M4. Pin container images + Helm charts; document Renovate policy
- **Done:** 2026-05-22 (commit `6cdcc1a`). New runbook at `docs/runbooks/image-pinning-policy.md` documents the three buckets: A (Flux ImagePolicy / image-update-automation — base images + apps), B (Renovate — workflows + Terraform + Helm charts), C (internally-built GHCR images on `:main` with `:sha-<sha>` as the immutable companion). Tabulates which images live in which bucket today, anti-patterns to flag in review, and the steps to add a new image. Also aligned the new service-status-report cronjob to `python:3.14-slim` with the `flux-system:python-slim` ImagePolicy marker so Flux owns its bump cadence. Source: `archive/outstanding-work-2026-05-16.md` M4.

### ⏳ M5. Velero schedule kustomization ordering + ResourceQuota CR
- Source: `archive/outstanding-work-2026-05-16.md` M5.

### ⏳ M6. Packer + ansible netplan dedup (F1.3)
- Source: `archive/outstanding-work-2026-05-16.md` M6.

### ✅ M7. More `dependsOn` declarations across Flux HRs (F4.2)
- **Done:** 2026-05-22. Audited all 10 HelmReleases under `clusters/wind/helm-releases/`. Pre-existing dependsOn: `monitoring`, `gpu-operator`, `pushgateway`, `github-actions-runner` (4). Added on this pass:
  - `traefik` → `cert-manager` — Traefik consumes the cert-manager-issued wildcard via the default TLSStore; without cert-manager Ready first, Traefik comes up serving its built-in self-signed during cold-start until the wildcard exists. (1 added.)
- Skipped (no useful dependency exists):
  - `cert-manager` — foundation; no upstream HR.
  - `cnpg`, `kured`, `tailscale-operator` — standalone operators; no HR dependencies. (tailscale-operator's only external dependency is a SOPS-decrypted Secret, which Flux's source controller produces — not a HR.)
  - `velero` — `serviceMonitor.enabled: false`, so no monitoring CRD dependency. If serviceMonitor is ever enabled, add `dependsOn: monitoring` at that time.
- Source: `archive/outstanding-work-2026-05-16.md` M7.

### ✅ M8. Auto-remediation COVERAGE.md refresh
- **Done:** 2026-05-22. Wrote `platform/kubernetes/auto-remediation/COVERAGE.md`: inventories all 22 defined rules, identifies what's covered, what isn't (CNPG, ceph-csi-provisioner, WG K8s pod, MetalLB speakers, Multus DS), and the big-finger discovery — **the webhook receiver isn't wired in alertmanager**, so all rules are dormant until that's fixed. Includes the exact YAML diff to wire it. Source: `archive/outstanding-work-2026-05-16.md` M8.

### ⏳ M9. Etcd backup automation + DR drill schedule
- Source: `archive/outstanding-work-2026-05-16.md` M9.

### ⏳ M10. Lifecycle / `ignore_changes` on Proxmox K8s VMs (F1.5)
- Source: `archive/outstanding-work-2026-05-16.md` M10.

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

### ⏳ M18. Evaluate UniFi eBGP + MetalLB BGP mode
- UniFi Network ≥10 added eBGP peering. Switch MetalLB from L2Advertisement to BGP mode with UDM as peer. Eliminates ARP-based advertisement quirks (see M19 / task #33). Cost: UDM BGP config, MetalLB BGPPeer/BGPAdvertisement CRs, private ASN allocation. Evaluate after SDN migration complete; weigh value vs effort against fixing M19 standalone. Source: task #34.

### ✅ M19. MetalLB not advertising technitium aggregator LB IP (.201.5)
- **Done:** 2026-05-22. `kubectl -n metallb-system rollout restart daemonset/speaker` re-emitted gratuitous ARP for `.5`; DNS resolution via `10.10.201.5` now works (verified `dig @.5 pve.wind.etherport.net = 10.10.200.41`). Resolved the cascading Teleport→DNS→Traefik blank-page issue. Source: task #33 (✅).

### ✅ M20. safety-check: relax single-ping flakiness over WG
- **Done:** 2026-05-22 (commit `70be67e`). All internal-host pings bumped from `-c 1 -W 2` to `-c 3 -W 5` (declare success if any 1/3 packets reply within 5s). UDM hop kept at `-c 2` — never flaky. Source: task #35 (✅).

### ✅ M21. WG K8s pod preStop / VRRP failover broken in practice
- **Done:** 2026-05-22. Three compounding fixes shipped to `platform/kubernetes/wireguard/03-deployment.yaml`: (a) `state MASTER` → `state BACKUP` (priority 150 still wins election, but preempt_delay 300 is now honored); (b) `init_fail` added to the `check_wg` vrrp_script so MASTER promotion is gated on wg0/wg1 readiness; (c) `procps` added to the keepalived container's apt-get install line so the preStop hook can actually find `pkill`. Net effect: on drain, old pod's preStop sends priority-0 advert → vpn-local elects MASTER in ~1s. New pod starts BACKUP, waits for wg-quick, then preempt_delay 300s before reclaiming. Source: task #36 (✅). Verification on next pod rollout.

### ✅ M22. Consolidated Grafana service-status dashboard
- **Done:** 2026-05-22 (commit `cc70da4`). New dashboard at `platform/kubernetes/monitoring/dashboards/service-status.yaml` (UID `service-status`). Four top-level counters (Healthy / Down / Unknown / Firing alerts) + per-category stat panel rows for ~28 services across Core platform, GitOps, Networking, Storage/data, DNS, Backup, Apps, External edge. Bottom panel is a firing-alerts table filtered on `ALERTS{alertstate="firing"}`. Auto-discovered by Grafana via the `grafana_dashboard: "1"` sidecar label. Source: task #37 (✅).

### ✅ M23. Daily service-status email digest
- **Done:** 2026-05-22 (commit `cc70da4`). New CronJob `service-status-report` in monitoring/ namespace, fires at 07:00 PT daily (staggered after the s3-sync 06:00 PT report). Queries Prometheus for deployment/statefulset/daemonset readiness across the same inventory as the dashboard (M22), fetches firing alerts from Alertmanager `/api/v2/alerts`, sends styled HTML via SMTP using the existing `alertmanager-smtp-config` secret (no new credentials, no AWS CLI dependency). Subject line is suffixed with overall status (`Homelab status — all healthy` / `… — 2 down`). Runs `python:3.13-slim` with the script mounted via ConfigMap so changes don't require a Docker rebuild. Source: task #38 (✅).

### ✅ M24. Modernize s3-sync daily-report HTML
- **Done:** 2026-05-22 (commit `cc70da4`). Replaced the bootstrap-y card grid in `platform/kubernetes/backups/aws-s3/image/scripts/daily-report.sh` with a refined neutral palette (CSS vars), `prefers-color-scheme` dark-mode support, tabular numerics, status pills with currentColor-dotted indicator instead of full pill bg, monospace timestamps, and a responsive 2-col grid on narrow viewports. Targets Apple Mail (iCloud) primarily — other clients degrade gracefully. Source: task #39 (✅).

### ⏳ M26. Grafana sidecar admin-API auth is broken — locks out admin user
- **Source:** discovered 2026-05-22 while verifying the new service-status dashboard.
- The `grafana-sc-dashboard` sidecar calls `POST /api/admin/provisioning/dashboards/reload` after writing each ConfigMap-sourced dashboard to `/tmp/dashboards/`. Auth is failing with 401 every minute (chart values has `adminPassword: "ChangeMe123!"` but the live admin password is different). Net effect: Grafana reports `too many consecutive incorrect login attempts for user - login for user temporarily blocked` on a rolling basis — the admin user is effectively unusable for human login via the UI.
- **Not a blocker for dashboards**: Grafana's file provisioner scans `/tmp/dashboards/` every 30s (see `/etc/grafana/provisioning/dashboards/*.yaml`, `updateIntervalSeconds: 30`) and loads valid JSON regardless of whether the reload API succeeds. So new dashboards still appear; this is just noisy and breaks human admin login.
- **Fix:** point both the sidecar and the chart at a real admin password. Options: (a) re-baseline the `monitoring-grafana` Secret with the password from `platform/kubernetes/monitoring/grafana-admin-secret.sops.yaml` (if it's the source of truth) + `admin.existingSecret` in chart values; (b) just update the chart-values plaintext to match the live secret (worse; not durable). Either way also rotate the admin password since it's been used in a thousand failed-login attempts.
- **Effort:** S.

### ⏳ M25. UDM / UniFi config audit — zones, inter-VLAN routing, modern features
- **Source:** user ask 2026-05-22 (this revision).
- Three-part audit:
  1. **Network docs vs. live UDM config.** Walk `docs/architecture/firewall-zones.md` + `docs/architecture/network.md` against the current zone-based firewall in UniFi Network ≥10 (Settings → Security → Firewall). Verify that the zone assignments documented match what's actually configured. Verify inter-VLAN routing restrictions (which VLANs can talk to which) are codified the way the docs describe them. Capture deltas as either a doc update or a UniFi config change — whichever is wrong, fix the wrong one.
  2. **Modern UniFi features evaluation.** UniFi Network ≥10 introduced "object-oriented" networking (named port groups, IP groups, zone groups), eBGP peering (already tracked separately as M18), VPN client-side hostname routing, and refactored firewall rule semantics. Identify which we should adopt and the migration effort for each. Output: short evaluation doc with adopt/skip recommendations per feature.
  3. **UDM best-practices sweep.** Items to confirm or fix: backup automation (Talk runbook flags no automated UDM backup — see `docs/runbooks/unifi-talk.md`), guest network isolation, IDS/IPS settings, DNS filtering, RADIUS/802.1X candidates, port-isolation on edge switches, threat-management posture, log retention + remote syslog.
- **Effort:** L (1-2 days). Worth doing once SDN/Ceph migration settles to a known-stable baseline.
- **Related outstanding UniFi items already in this tracker:**
  - **M13** Delete `/data/udm-le.removed-*` on UDM/Protect/Sequoia — the "old cert manager" remnants the user is thinking of (udm-le predates cert-manager-on-K8s for the wildcard); just needs SSH creds + a one-shot cleanup
  - **M18** Evaluate UniFi eBGP + MetalLB BGP mode (overlaps with audit part 2)
  - **M15-M17** Twilio Talk hygiene items (911 address, orphan DID, SIP UDP→TLS+sRTP) — out-of-band UDM Talk console

---

## LOW

### ⏳ L1. Proxmox HA cluster expansion
- Source: `archive/outstanding-work-2026-05-16.md` L1. Blocked on adding a 2nd PVE node.

---

## DROP — outdated or already done

(Carried forward from `archive/outstanding-work-2026-05-16.md`; nothing new in this revision.)

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
| H27 | Ceph msgr2 v2 re-enable | 2026-05-22 |
| H28 | Containerized ansible CI | 2026-05-22 |

---

## Process

- This file is the canonical work tracker. When an item completes, flip the glyph to ✅ and add a one-line `**Done:**` note with the date. Don't delete — preserve history.
- When the file gets too long (>500 lines or once per ~quarter), spin off a new dated successor and link forward like this one does.
- Items not yet captured here should be added with the next free ID in their tier — don't re-use deprecated IDs.
- TaskCreate IDs (`#NN`) are session-scoped and ephemeral; this file is the durable record. Reference TaskCreate IDs only to help cross-check while a session is active.
