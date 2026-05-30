# Outstanding Work — Consolidated Priority List

Latest revision: 2026-05-29. Canonical filename `outstanding-work.md`
is stable; older dated snapshots live in `archive/`.

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

## Next-up checklist (updated 2026-05-29)

Active execution order. The zone migration + switch ACLs + Kopia decom +
personal-web CI all landed this session (see "Recently completed" below).

| # | Item | State | Action |
|---|---|---|---|
| 1 | **M18/M36 MetalLB BGP** ← *active target* | MetalLB L2 mode; no BGPPeer/BGPAdvertisement; UDM `.5`/`.71` IP-conflict alerts. **Phase A+B ✅** | **Phase A DONE 2026-05-29** (209 NIC on w1-4+gpu1; UNAS export ACL extended). **Phase B DONE 2026-05-30** (Servers/201 → UDM-routed, Internal zone; verified — NAS stays on 209 NIC, DNS/ingress/egress/cross-VLAN all green; see runbook). Remaining: **Phase C (BGP parallel)** → D (cutover). Trusted-zone for 201 deferred → M56. Properly fixes M36 (no L2 ARP ownership = no conflict) |
| 2 | **M15-M17 Twilio Talk** | 911 addr / orphan DID / SIP UDP→TLS+sRTP | M15 (911) safety-first; M16 release DID; M17 encryption |
| 3 | **M53 CF token scoping** | account-scoped token shared infra↔personal-web | Mint zone-scoped tokens; also unblocks M54 |
| 4 | **M54 smithforsb redirect IaC** | CF Single Redirect is manual in dashboard | Codify in `personal-web/cloudflare-dns/smithforsb.tf` once M53 lands |
| 5 | **M48/M49/M50 UNAS+Protect IaC** | UI-only | Per-device API keys → Ansible playbooks + coverage audit |

**Recently completed (this session, 2026-05-27 → 29):**
- ✅ BGP **Phase A** — 209 (vsan) NIC added to w1-4 + gpu1 (DHCP .100-.104); kubelet NFS to the UNAS now egresses `enp6s23` at L2. Caught + fixed the source-IP gap: UNAS NFS export ACL extended to the 209 IPs on all 9 shares (UI, not IaC — re-apply on rebuild). Runbook updated with the "additive path ≠ no behaviour change" lesson.
- ✅ Velero `kube-system-daily` PartiallyFailed (recurring ≥4d) root-caused — node-agent lacked control-plane tolerations so it skipped cilium's `tmp` fs-backup on cp1-3. Fix: `nodeAgent.tolerations` in velero values (Flux). No data loss (resource backup was 371/371; only an ephemeral emptyDir was un-backed-up).
- ✅ M32 firmware channel → `release` + M34 site-wide auto-upgrade → off (IaC: `udm-firmware-policy.yml`, commit `ea08bea`)
- ✅ M30 — UDM zone migration COMPLETE (IoT + Infrastructure/212 + Security/205 custom zones; Phase 4 skipped)
- ✅ M52 — L3-switch ACL IaC applied + verified (5 ACLs on Switch Rack PoE)
- ✅ M33 rsyslog → Loki; M31 backup + OOB verified; 14 firewall groups (`3271cea`)
- ✅ Kopia decommissioned (deployment + CF tunnel + monitoring + 205 GiB Ceph reclaimed)
- ✅ personal-web repo CI (GH Actions + secrets; all 3 modules plan clean)
- ✅ CF API token fixed (user-rotated) + etherport DS record re-imported + `ignore_changes` pinned
- ✅ M30 Phase 1: VLAN 212 → Infrastructure zone (commit set through `05d635c`); all 18 clients healthy
- ✅ M30 §7 questions resolved + L3-routing topology corrected (Switch Rack PoE routes 201/202/209/210)

---

## CRITICAL — production outage / data-loss risk

### ✅ C1. CNPG continuous backup (Barman) configured cluster-wide
- **Done:** 2026-05-15 (verified 2026-05-23). Tracker was stale. Live state:
  - `postgres-cluster.spec.backup.barmanObjectStore` wired in `platform/kubernetes/cnpg/01-cluster.yaml` — destination `s3://postgres-barman.wind.etherport.net`, WAL + data both gzip + AES256, 30d retention, `target: prefer-standby` to keep load off the primary.
  - SOPS-encrypted S3 creds at `platform/kubernetes/cnpg/05-barman-credentials.sops.yaml`.
  - `ScheduledBackup/postgres-cluster-daily` at 05:00 UTC daily (`platform/kubernetes/cnpg/06-scheduled-backup.yaml`) — verified 9 consecutive successful `barmanObjectStore` backups (2026-05-15 through 2026-05-23).
  - Restore runbook: `docs/runbooks/postgres-barman.md`.
- Continuous WAL archiving + daily full snapshots = PITR at ~second granularity, crash-consistent (Postgres-aware), separate bucket from Velero. Source: `archive/outstanding-work-2026-05-16.md` C1.

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
- **Done:** 2026-05-22 (commit `0851d26`). Prometheus + Alertmanager both bumped to `replicas=2` with podAntiAffinity in `clusters/wind/helm-releases/monitoring.yaml` (inline HelmRelease values; the stale `platform/kubernetes/monitoring/values.yaml` is not loaded by any kustomization and is queued for deletion under L8). cert-manager + cert-manager-cainjector + cert-manager-webhook were already 2/2 per kubectl (no change needed). Traefik was already 2/2. Grafana stays at 1 (RWO PVC + sticky session — HA needs external DB).

### ✅ H6. Hardcoded WAN IPs in AWS security groups
- **Done:** 2026-05-23 (commits `d0f3a36` + `cb102f8`). DNS-side: the 4 `dns_(udp|tcp)_homelab[12]` rules on `aws_security_group.dns_server` migrated from Terraform to the `dns-restrict-ip` Lambda via `removed { destroy = false }` blocks. SSH-side: extended the Lambda's `rule_specs` to also manage `allow_ssh:22:tcp`; the stale `/32`s (`47.34.215.233`, `47.159.189.230`, `146.70.238.13`, `86.98.93.115`) confirmed safe-to-drop by the user and revoked by the Lambda (after the `_permissions()` description-mismatch bug fix in M39). Verified: `sg-0079fee23ee54417a:22/tcp` contains only `47.159.189.5/32` + `66.215.210.75/32`, both labeled `Managed by dns-restrict-ip (22/tcp)`, kept in sync with `wan1`/`wan2.wind.etherport.net`.

### ✅ H7. Doc drift cleanup
- **Done:** 2026-05-19 to 2026-05-21 in multiple commits. Architecture/overview/network/firewall-zones docs reflect VLAN 210, enp6s22, SDN bridges, RSA wildcard cert. `node-vlan-setup.md` updated 4→5 interfaces. `regional-vpn-deployment.md` drops 1.1.1.1 from DNS push.

### ✅ H8. Archive completed migration docs
- **Done:** 2026-05-22. Eleven planning docs moved to `docs/planning/archive/` with a `README.md` table listing why each was archived. Includes the just-completed `proxmox-sdn-implementation-2026-05-18.md` (PRs 1-6 all shipped). Top-level `docs/planning/` now holds only the canonical tracker + active design docs + ADRs.

### ✅ H9. Deploy swap + CloudWatch agent + node_exporter on external VMs
- **Done:** 2026-05-23. All four external VMs now have node_exporter + swap + (AWS-only) cloudwatch-agent installed and reporting healthy in the service-status dashboard + email.
- **New IaC:** `.github/workflows/ansible-vm-fleet.yml` — generic dispatch wrapper that runs base.yml / swap.yml / cloudwatch-agent.yml against any subset of dns-fallback / vpn-local / dns-aws / vpn-aws on the self-hosted gh-runner (mirrors ansible-proxmox.yml pattern).
- **Per-host status:**
  - dns-fallback, vpn-local: base + swap applied via workflow. (swap is overkill on 8GB local VMs but applied for consistency.)
  - dns-aws, vpn-aws: base + swap + cloudwatch-agent applied via workflow. Initial dispatch blocked on missing `automation@homelab` pubkey on `~ubuntu/.ssh/authorized_keys`; pubkey appended via SSH from laptop, then re-dispatched cleanly.
- **Durable fix landed (M28 ✅ below):** cloud-init `user_data` on `aws_instance.{vpn,dns}` bakes the pubkey on first boot of any future recreate. `lifecycle.ignore_changes = [user_data]` prevents source diffs from touching existing instances.

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

### ✅ H26. Proxmox SDN migration — Phase 1
- **Done:** 2026-05-22. All 6 PRs shipped:
  - PR 1 (TF module + workflow), PR 2 (zone + VNets), PR 3 (dns-fallback canary 2026-05-18), PR 4 (vpn-local + gh-runner 2026-05-18).
  - PR 5 (8 K8s VMs migrated NICs 1-4 to SDN bridges `servers`/`clients`/`iot`/`security`; NIC 5 stays on `vmbr0+vlan_id=210` to avoid conflict with PVE's own vmbr0.210).
  - PR 6 (cleanup `local.vlan_tag` removed; `local.bridge_name` retained for NIC 5).
- The companion implementation doc has already been archived at `docs/planning/archive/proxmox-sdn-implementation-2026-05-18.md`. Tracked as task #19.

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

### ✅ M1. Static-PV recovery pattern in `disaster-recovery.md`
- **Done:** 2026-05-23 (commit follows). Added §2.3 "Static-PV adoption (orphaned RBD image → new cluster)" covering: when to use the pattern, the 3-manifest shape (PV + pre-bound PVC + workload), the CNPG worked example shipping in `platform/kubernetes/cnpg/`, how to find the right RBD image name via `rbd image-meta list`, the list of apps where this pattern applies (HA, plex, ollama, wikijs, postgres) vs. apps where vanilla Velero restore is fine, and operator-specific adoption gotchas (CNPG `pvcStatus: ready`, Helm `resource-policy: keep`, STS reuse-by-name). Source: `archive/outstanding-work-2026-05-16.md` M1.

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

### ✅ M9. Etcd backup automation
- **Done:** 2026-05-23 (commits `c9e9247`, `899a9d3`). New ansible playbook `infra/ansible/playbooks/etcd-backup.yml` installs a systemd timer + service + script on each `kube_control_plane` node that runs `etcdctl snapshot save` daily at 02:00 PT with 14-day retention. Snapshots land in `/var/lib/etcd-snapshots/`; Velero's existing kube-system FS backup ships them off-host.
- Verified via the new `ansible-vm-fleet.yml` workflow with `playbook=etcd-backup` choice: all 3 cp nodes took an initial 173MB snapshot at apply time (consistent hash `a9a4538e` across all 3 — etcd cluster is in sync). Next scheduled fire: 2026-05-24 02:00 PT.
- Idempotent (re-running just rewrites units in place). Uses kubespray cert paths (`/etc/ssl/etcd/ssl/{ca,admin-<hostname>}.pem`), NOT the kubeadm-style ones.
- **DR drill schedule** (the second half of the original M9 scope) tracked separately under M11 (RTO/RPO doc) + M12 (CNPG restore drill Tier B).

### ⏳ M10. Lifecycle / `ignore_changes` on Proxmox K8s VMs (F1.5)
- Source: `archive/outstanding-work-2026-05-16.md` M10.

### ⏳ M11. DR runbook with measured RTO/RPO targets
- Source: task #23. Needs your judgment on targets before measurement.

### ⏳ M12. CNPG restore drill Tier B (sibling cluster)
- Source: task #24. Destructive test; needs supervision and maintenance window.

### ✅ M13. Delete `/data/udm-le.removed-*` on UDM / Protect / Sequoia
- **Done:** 2026-05-23. All three devices cleaned:
  - **Sequoia** (`/data/udm-le.removed-20260517`, 57MB) — used 1P item `Sequoia SSH` (root, password auth via sshpass with `-o PreferredAuthentications=keyboard-interactive`)
  - **UDM** (`/ssd1/.data/udm-le.removed-20260517`, 98MB) — used one-shot K8s Job in the `unifi-cert-sync` ns mounting the existing `unifi-cert-sync-ssh` secret (same key path the cert-sync CronJob uses)
  - **Protect** (`/data/udm-le.removed-20260517`, 98MB) — same path as UDM
- **Cron/systemd check:** no remaining udm-le references in crontab, /etc/cron.*, systemd units, or timers on any of the three. The old triggers were inside the renamed `removed-*` directory itself, so dir-delete removes the only trigger surface.
- **Total freed:** ~253MB across the three devices.

### ✅ M23. DR runbook with measured RTO/RPO targets
- **Done partial:** 2026-05-24. `docs/runbooks/disaster-recovery.md` now has (a) a Recovery Priority table with both Target and Measured columns (currently `?` since no drills have run), (b) a backup ownership matrix mapping each workload to its backup tool / location / restore proc, (c) a CNPG point-in-time recovery section (was missing), (d) a §11 RTO/RPO measurement drill methodology with quarterly rotation (HA → Postgres PITR → etcd → Velero namespace recreate). When drills happen, the Measured columns + Last drill dates get updated by the operator. Targets stay aspirational until measured.

### ⏳ M14. Investigate aws-s3-sync daily-report SSL mismatch (if recurs)
- Source: task #25. Only act if it recurs.
- **Note on ID:** the *archived* outstanding-work-2026-05-16.md used M14 for a UDM WireGuard cleanup item; some older cross-references (e.g. `docs/architecture/firewall-zones.md`) still point at that older meaning. To disambiguate, that WireGuard cleanup is now M42 (below). The two are unrelated.

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

### ✅ M28. Bake homelab automation pubkey into AWS VMs' user_data
- **Done:** 2026-05-23 (commit `47aa528`). Added `local.aws_vm_cloud_init` to `infra/terraform/aws/compute/main.tf` — cloud-init payload that appends the automation pubkey to `ubuntu`'s `authorized_keys` on first boot. Wired to both `aws_instance.vpn` and `aws_instance.dns` with `lifecycle.ignore_changes = [user_data]` so the source change doesn't trip the existing running instances' `prevent_destroy`. Has zero effect on what's running today; future recreate gets the key baked in so the ansible-vm-fleet workflow works on day one.

### ✅ M29. kube-proxy metrics not scrapable (TargetDown warning)
- **Done:** 2026-05-23. Set `kube_proxy_metrics_bind_address: 0.0.0.0:10249` in `infra/kubespray/inventory/group_vars/k8s_cluster/k8s-cluster.yml` (durable across cluster rebuilds) AND patched the live `kube-system/kube-proxy` ConfigMap + `kubectl rollout restart ds/kube-proxy` so the change took effect immediately. All 16 kube-proxy targets (8 nodes × 2 Prometheus replicas) now report UP. The TargetDown alert has `for: 10m`, so it'll clear ~10 min after the rollout.

### ✅ M27. Wire service-status inventory drift-check into CI
- **Done:** 2026-05-23. New workflow at `.github/workflows/service-status-inventory-drift.yml` runs weekly (Mon 08:00 PT) on the self-hosted gh-runner. SCPs kubeconfig from k8s-cp1 (same pattern as `post-bootstrap.sh`), runs `scripts/check-service-status-inventory.py --untracked`, and opens / refreshes a GitHub Issue labeled `inventory-drift` when STALE entries are found. Mirrors the H16 terraform drift detector pattern. Stretch (auto-regenerating dashboard YAML on `services.py` change) deferred.

### ✅ M26. Grafana sidecar admin-API auth is broken — locks out admin user
- **Done:** 2026-05-23. Root cause was subtler than the original assessment: the chart's `admin.existingSecret: grafana-admin-credentials` IS wired and IS the SOPS-encrypted source-of-truth, but Grafana's env-var-driven admin password only takes effect on first-ever startup with an empty `grafana.db`. Once the DB exists, it's authoritative. Someone (or a UI password change) had drifted the DB hash from the env-var value, so the sidecar's basic-auth requests with the env-var password failed forever.
- Fixed with a one-shot reset: `grafana-cli admin reset-admin-password "$GF_SECURITY_ADMIN_PASSWORD"` inside the running pod. Sidecar now returns 200 on reload calls. No more rolling admin-user lockout.
- Documented the trigger conditions + recovery procedure in `docs/runbooks/grafana-admin-password.md` so this doesn't accumulate undiscovered noise across the next rebuild / password rotation. Considered a CronJob-as-IaC fix but rejected: would intrude on legitimate UI changes; manual is the right cadence.

### ✅ M25. UDM / UniFi config audit — zones, inter-VLAN routing, modern features
- **Done:** 2026-05-23. Full audit at `docs/planning/udm-audit-2026-05-23.md` (884 lines, read-only — no config changes made). Three parts: docs-vs-live drift, modern-features eval, best-practices sweep. 23 prioritized follow-up items at the end of the doc.
- **Biggest findings (P0):**
  - Zone architecture is largely aspirational — `firewall-zones.md` describes 6 custom zones; live UDM has **1 custom zone (IoT)**. Sensitive networks (Servers, vSAN, Unifi/212, Security/205, Ceph/210) sit in the wide-open `Internal` zone. Documented Infrastructure-zone + Security-zone rules **aren't enforced** by default-Allow-Internal-to-Internal. → spawned **M30** (decide reconcile direction) below.
  - **No automated UDM backup.** Talk DR + controller DB + all firewall/PSK config exists only on the UDM. → spawned **M31** below.
  - **UDM is on `beta` firmware channel** (probably unintentional). → spawned **M32** below.
  - **rsyslogd is "enabled" but `host` is empty** — UDM logs go nowhere off-host. → spawned **M33** below.
  - **H23 only protected the UDM itself**: all 9 switches + 7 APs have `auto_upgrade: true`; they upgrade nightly. → spawned **M34** below.
  - Security/205 has Network Isolation ON + DHCP DNS cleared (doc said opposite); Internal → Hotspot is Allow All; firewall groups partially adopted (5 of 18); WireGuard Travel port-forward disabled but orphan.
- **P2/P3 follow-ups** (NetFlow, edge-switch port isolation, eBGP migration, etc.) stay in the audit doc itself; promoting just the P0/P1 items into the tracker keeps this file readable.
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

### ✅ M30. UDM zone architecture — migration COMPLETE 2026-05-29
- **Done 2026-05-29.** Three custom UDM zones live (IoT, Infrastructure/212, Security/205) + L3-switch ACLs (M52) for the switch-routed fabric. Phase 4 (Trusted) skipped as cosmetic-only. Live state documented in `docs/architecture/firewall-zones.md`; planning companion archived at `docs/planning/archive/firewall-zones-future-state-2026-05-29-completed.md`. All verified live, zero device disruption. Remaining tidy-ups tracked separately: M52 CI-ify, Kopia Ceph-image reclaim, CF token (task #6).
- **Status 2026-05-28:** Pre-flight ✅ + Phase 1 ✅ shipped. Phases 2 + 4 re-scoped after an L3-routing correction (see below). Phase 3 (Security zone) is next.
- **Option (b) done** (commit `f5693c3`): rewrote `docs/architecture/firewall-zones.md` to match the live single-custom-zone (IoT) reality.
- **Future-state doc** (`docs/planning/firewall-zones-future-state.md`): the canonical migration plan. All §7 open questions resolved 2026-05-27 (commit `3271cea`); §9 design clarifications added.
- **Pre-flight ✅ (2026-05-27 → 28):**
  - M31 UDM backup verified (5 days of daily `.unf` + config tarballs in S3).
  - 14 firewall groups (11 IP + 3 port) created via `udm-firewall.yml` (commit `3271cea`); live count 8→22.
  - OOB SSH path: user-verified.
- **Phase 1 ✅ (2026-05-28):** VLAN 212 (Unifi) moved into new custom `Infrastructure` zone. 4 broad zone-allow rules (Internal↔Infrastructure user-created; Infrastructure→Gateway + Infrastructure→External auto-created by UDM). Verified healthy across 3 probes (T+0/+5/+30 min): all 18 clients present (3 Talk phones + 13 Protect cameras + UA-Gate + UA-Intercom + Protect ctrl), 4/4 critical online, zero 212 FW drops in UDM Loki. Internal zone went 4→3 networks.
- **L3-routing correction (2026-05-28, commit `05d635c`):** an earlier claim that "all switches are L2-only" was WRONG. **Switch Rack PoE (US624P @ 10.10.200.232)** is the L3 router for **Servers/201, Clients/202, vSAN/209, Ceph/210** (`gateway_type=switch`). UDM routes Default/199, Mgmt/200, IoT/204, Security/205, Guest/206, Unifi/212 (`gateway_type=default`). This is a textbook hybrid (firewall=north-south+zones; L3 switch=east-west line-rate for storage+compute). UDM is CPU-bound ~3.5-5 Gbps; US624P fabric is ~50 Gbps — storage MUST stay switch-routed.
- **Phase re-scope:**
  - **Phase 2 (vSAN/Ceph → Infrastructure): DROPPED.** Switch-routed networks can't go in a UDM zone (picker hides them; rules wouldn't fire). Replaced by **M52** (see below) — Ansible playbook for L3-switch ACLs as the primary east-west enforcement.
  - **Phase 3 (Security zone for VLAN 205): NEXT.** Security/205 is UDM-routed → executable as planned.
  - **Phase 4 (Trusted zone): SKIP (Option A).** Servers/201 + Clients/202 are switch-routed (can't be zoned); the only candidate left is Mgmt/200, and leaving it in Internal is functionally identical. Cosmetic-only; not worth doing.
  - **Phase 5 (cleanup + doc rewrite):** after Phase 3.

### ✅ M52. L3-switch ACL IaC (replaced dropped M30 Phase 2)
- **Done 2026-05-29.** `infra/ansible/playbooks/usw-acls.yml` manages ACLs on Switch Rack PoE (US624P @ 10.10.200.232) via the v2 acl-rules API. Design doc: `docs/planning/l3-switch-acl-iac-2026-05-28.md`. Import-validated (zero-diff against the 2 pre-existing rules) then staged apply. **5 ACLs live:** Hue-return ALLOW; Security/205→{201,202,209,210} BLOCK (gap-closed to include Ceph); Clients→Ceph BLOCK; vSAN↔Ceph BLOCK (both dirs). Default-allow preserved for Servers↔Clients + Servers→storage + Clients→vSAN. Full cluster-health check clean post-apply (K8s↔Ceph is intra-VLAN-210 L2 → never hits an L3 ACL). Now CI-runnable via `ansible-unifi.yml` (`usw_acls_apply_new` gate).
- **Open follow-up:** Phase 1.5 tightening pass (replace broad allows with per-port rules after a ≥7-day flow-observation soak) — optional.

### ⏳ M53. Mint zone-scoped CF API tokens (de-couple infra ↔ personal-web)
- **Source:** 2026-05-29. Both repos currently use the same account-scoped `cloudflare-tf-token` (1Password). It works across all zones, which is why personal-web TF applied locally before it had CI. Best practice: each repo gets a token scoped to ONLY its zones.
- **Scope:** (1) new CF token scoped to grahamsmith.net/smithforsb.com/stopthecastle.com (Zone:DNS:Edit + Zone:Read + the Single-Redirect/Ruleset perm needed for M54) → 1Password → update personal-web `CLOUDFLARE_API_TOKEN` secret. (2) optionally re-scope the infra token to etherport.net only.
- **Note:** the current account-scoped token reportedly can't manage CF Single Redirect rules — confirm whether that's a scope/permission gap; if so the new token must include the Ruleset edit permission (this is what blocks M54).
- **Effort:** S (dashboard token mint + secret update). Needs CF dashboard.
- **Ready-to-execute spec (prepared 2026-05-30 — only the CF-dashboard mint needs you):**
  - **Create token** — CF dashboard → My Profile → API Tokens → Create Token → *Custom token*:
    - Permissions: `Zone → Zone → Read`, `Zone → DNS → Edit`, `Zone → DNSSEC → Edit` (required by the `cloudflare_zone_dnssec` resources), `Zone → Dynamic Redirect → Edit` (covers the Single Redirect ruleset → also unblocks **M54**).
    - Zone Resources: *Include → Specific zone* ×3 — `grahamsmith.net`, `smithforsb.com`, `stopthecastle.com`. **Do NOT** include `etherport.net` or "All zones".
    - Optional hardening: Client-IP filter → gh-runner egress IP; set a TTL.
  - **Wire-in (targets verified 2026-05-30):** personal-web CI reads the token from GH secret **`CLOUDFLARE_API_TOKEN`** (`.github/workflows/terraform.yml:67`; provider auth via env var). Zone IDs are already separate `TF_VAR_*_ZONE_ID` secrets, so the token needs no name→ID lookup.
    1. `gh secret set CLOUDFLARE_API_TOKEN -R sparked-diamond/personal-web` (paste new token) + save to 1Password.
    2. `gh workflow run terraform.yml -R sparked-diamond/personal-web -f action=plan` → expect clean across all 3 zones incl. DNSSEC.
    3. Leave the infra/etherport token in place (still in use); re-scoping it (part 2) is optional/separate.
  - **Why not done autonomously:** CF token minting is dashboard-gated and no CF token is available locally (1Password locked this session) — this is the single step that requires you.

### ⏳ M54. Codify smithforsb.com redirect (CF Single Redirect) as IaC
- **Source:** 2026-05-29. `smithforsb.com` → `instagram.com/graham.m.smith` is currently a **manual CF Single Redirect rule** in the dashboard — the one non-IaC piece of personal-web. Comment in `personal-web/terraform/cloudflare-dns/smithforsb.tf` notes it's deferred "until token scope upgraded".
- **Blocked by:** M53 (the account-scoped token apparently lacks the Ruleset/Single-Redirect permission).
- **Scope:** add a `cloudflare_ruleset` (http_request_dynamic_redirect) resource in `smithforsb.tf`; import the existing rule or recreate. Verify the redirect still 301s after apply.
- **Effort:** S once M53 unblocks it.

### ⏳ M55. Add UniFi telemetry exporter (unifi-poller) for UDM/network metrics
- **Source:** 2026-05-30. UDM observability is logs-complete but metrics-thin. Syslog → Alloy → Loki works (UDM-Pro-Max actively shipping, verified). But Prometheus has NO full UniFi telemetry — only `probe_success` (blackbox reachability, fixed 2026-05-30) + `unifi_backup_*`. Missing: client counts, throughput, WAN, port/PoE, AP/client RSSI, per-device health.
- **Scope:** deploy unpoller (unifi-poller) as a Deployment scraping the UDM controller API → Prometheus `ServiceMonitor` (must carry label `release: monitoring`, per the probeSelector lesson) → Grafana dashboards. Needs a read-only UniFi local account + creds (SOPS secret). Keep the UI/API access internal (Tailscale-only constraint).
- **Effort:** M (exporter + creds + ServiceMonitor + dashboards).

### ⏳ M56. Migrate Servers/201 to a dedicated `Trusted` UDM zone (from Internal)
- **Source:** 2026-05-30, during BGP Phase B. 201 was placed in **Internal** for the gateway flip (minimal blast radius). A dedicated `Trusted` zone is the better end-state now that 201 is UDM-routed — intentional least-privilege vs Internal's allow-all.
- **Why deferred (not atomic with Phase B):** a fresh custom zone **default-denies inter-zone**, and 201 hosts homelab-wide deps — DNS VIP `10.10.201.5` (every VLAN resolves here), the WG remote-access endpoint `.20` (External→201 port-fwd), Traefik ingress `.70`. A single missing rule = LAN-wide DNS outage / remote lockout. Also every existing `X↔Servers` policy (currently keyed to Internal) must be re-pointed to Trusted — needs a live UDM zone-matrix audit.
- **Pre-staged allow matrix** (apply atomically with the zone; console/iKVM ready):
  - `Trusted→External` (egress); **`External→Trusted` udp/9820-9821→.20 (WG — lockout risk)**
  - `Internal↔Trusted` (DNS .5, Traefik .70, syslog .73, clients↔services)
  - `IoT/204→Trusted` (DNS .5 + existing Servers↔IoT); `Infra/212→Trusted` (DNS .5, syslog .73); `Security/205→Trusted` (DNS .5)
  - `Trusted→IoT/204` (→Home Assistant); `Trusted→Internal/Infra` (Prometheus scrape 200/212, storage)
- **Effort:** M. UI / v2-API (not TF — paultyng gap). Do in a window; verify DNS from every VLAN + WG reconnect after.

### ✅ M31. Automated UDM backup to S3 (P0 from M25 audit)
- **Done:** 2026-05-23. New CronJob `unifi-backup` in `backups` ns, fires daily 04:00 PT. Three targets per run:
  - **`udm-controller-db`** — newest `.unf` from `/data/unifi/data/backup/autobackup/` (UDM writes one daily at 07:00 UTC, ~8.5MB).
  - **`udm-core-config`** — tar+gz of `/data/unifi-core/config/` (firewall, fabric, firmware, cloud YAMLs ~21KB).
  - **`protect-core-config`** — tar+gz of Protect's `/data/unifi-core/config/`.
- Lands at `s3://infra.wind.etherport.net/{prefix}/{name}-{date}.{ext}`. New `infra.wind.etherport.net` general-purpose bucket created via TF (`4101a49`); IAM policy `s3-backup-kubernetes-policy` extended to v14 to allow PutObject. Lifecycle: 90d expiry under `unifi/` + 30d noncurrent-version cleanup.
- Reuses `unifi-cert-sync-ssh` SSH key (copied to a new SOPS-encrypted secret in `backups` ns). Status + bytes metrics pushed to pushgateway under `unifi_backup_*`.
- Verified end-to-end: first manual fire uploaded all 3 objects cleanly.

### ✅ M32. UDM firmware channel → `release` (DONE 2026-05-29, udm-firmware-policy.yml)
- **Live state 2026-05-27** (re-pulled via `/proxy/network/api/s/default/get/setting`):
  - `super_fwupdate.firmware_channel = "beta"` ← still wrong; this is the Network App's channel for managed-device updates (switches, APs).
  - `mgmt.gateway_release_channel = null` ← OK (defaults to release; the UDM-OS-side channel is fine).
  So only the Network App side is the issue — the user's "everything looks like release" intuition is correct for UniFi OS but missed the Network App toggle.
- **Fix path:** Network App → Settings → System → Updates → "Update Channel" (or "Use Beta Versions" / "Release Candidate" depending on 9.x build): flip `beta` → `release`. One click.
- **Verification after flip:** re-run `scripts/unifi/dump-state.sh` + extended settings pull; expect `super_fwupdate.firmware_channel = "release"`.

### ✅ M33. UDM rsyslog destination empty — wire to Alloy syslog receiver (P0 from M25 audit)
- **Done.** Verified 2026-05-27 — live config + Loki ingest both confirm working.
- **Live state** (`/proxy/network/api/s/default/get/setting`, `rsyslogd` key):
  ```json
  {"key":"rsyslogd","enabled":true,"ip":"10.10.201.73","port":"514","log_all_contents":true}
  ```
- **Loki ingest verified:** `{host="udm"}` actively flowing at ~100 lines/min over the last 10 min (WAN GeoInfo polling, earlyoom, ubios-udapi-server events).
- Path the user actually flipped: **Network App → Settings → CyberSecure → Traffic Logging → SIEM Server → `10.10.201.73:514`**. This populates `rsyslogd.ip` + `rsyslogd.port` (despite the "SIEM" UI label, it's a general syslog forwarder).
- The alternative `super_fabric_system_log` path that was originally proposed turned out to be the UniFi cloud aggregator (`enabled: false`) — not needed; the rsyslog path covers it.
- Query in Grafana: **Explore → Loki → `{host="udm"}`**.

### ⏳ M36. UDM "IP conflict" alerts for MetalLB VIPs (.5 + .71)
- **Source:** user report 2026-05-23. UDM repeatedly fires IP-conflict alerts for `10.10.201.5` (Technitium aggregator/cluster VIP) and `10.10.201.71` (technitium-0 LoadBalancer IP). Both are MetalLB-managed.
- **Why it happens:** MetalLB L2Advertisement mode picks ONE speaker pod per IP to send gratuitous ARP. When the elected speaker moves (pod restart, node drain, MetalLB controller re-election), the IP "moves" to a different node MAC. The UDM sees the same IP claimed by multiple MAC addresses over time and flags it as a conflict — even though it's working as designed.
- **The clean fix = MetalLB BGP mode (M18).** In BGP mode, each speaker advertises the IP as a /32 route to the UDM (as a BGP peer). There's no ARP claim, no MAC ownership, no "conflict" from the UDM's perspective — it's a learned route. The Technitium audit (M25 §2.4) noted UniFi Network ≥10 supports eBGP peering, so this is unblocked technically. Effort: M (UDM BGP config + MetalLB BGPPeer/BGPAdvertisement CRs + private ASN allocation + cutover).
- **Short-term workaround (stop the alerts without the BGP migration):** in the UDM UI under Settings → Networks → Default (or the LAN where these VIPs live), add an "Excluded IP" list for `.5` and `.71` so the UDM stops tracking them as DHCP clients. Or under Insights → IP Conflict Detection, add a per-IP suppression rule. Either is reversible if BGP migration happens later.
- **Effort:** S (workaround) / M (proper BGP migration). Merging with M18 since they share the resolution.
- **Sequencing decision 2026-05-27:** do the workaround NOW to silence alert noise; defer BGP until AFTER M30 zone migration completes — both touch UDM L3 and should be batched into one blast-radius window.

### ⏳ M35. Wire dns-aws public IP as 3rd DHCP DNS resolver
- **Source:** user ask 2026-05-23. Rationale: with `.5` (Technitium cluster VIP) primary + `.6` (dns-fallback VM) secondary, any combined outage of both the K8s cluster + the on-prem fallback + the AWS WG tunnel leaves clients with no DNS. Wiring dns-aws's public IP (currently `52.40.219.113`, the EIP of the dns-aws EC2 instance) as a 3rd DHCP DNS gives clients a path over the public internet even when the tunnel is down.
- **Already in place:** the `dns_server` SG on AWS allows port 53 TCP+UDP from the homelab WAN IPs (`66.215.210.75` + `47.159.189.5`), kept in sync with `wan1`/`wan2.wind.etherport.net` Route53 records by the dns-restrict-ip Lambda. So clients reaching `52.40.219.113:53` from the homelab WAN will succeed.
- **Fix:** for each tenant VLAN with DHCP DNS set to `.5/.6` today (Management, Servers, Clients, IoT, vSAN, Ceph, Unifi per M25 audit §1.6), add `52.40.219.113` as a 3rd entry. UDM UI per-network or via the `paultyng/unifi` TF provider if codifying. Skip Guest (already uses public DNS by design).
- **Effort:** S — UI clicks or one TF block per network.

### ✅ M37. Centralized log aggregation with Loki + Alloy
- **Done:** 2026-05-23 (commit `3ed67ae`). Single-binary Loki on 20Gi Ceph RBD PVC, 30d retention, internal ClusterIP at `loki.monitoring.svc:3100`. Alloy DaemonSet replaces Promtail — picks up k8s pod logs natively + exposes a RFC3164/5424 syslog UDP+TCP receiver on `:514` via a dedicated MetalLB LoadBalancer at **`10.10.201.73`**.
- Grafana datasource auto-provisioned via ConfigMap label `grafana_datasource: "1"`. Runbook at `docs/runbooks/loki-log-aggregation.md` covers query examples, syslog onboarding, retention/storage, S3 future migration.
- Unblocks **M33** (point UDM rsyslog at `.73`). Future work: alertmanager rule for Loki ingest backlog (TODO breadcrumb in runbook); S3 backend when log volume justifies it.

### ✅ M38. Tear down vpn-mumbai (ap-south-1) regional VPN
- **Done:** 2026-05-23 (commits `cb102f8` + this one). User confirmed no travel for the next few weeks; destroyed to avoid the per-region $30/mo idle cost. Workflow `terraform-regional-vpn.yml` action=destroy + workspace=default ran clean (instance `i-0325d902bf6edd464` → `terminated`). Removed peer block from `infra/ansible/playbooks/wireguard.yml` (`wg0_regional_peers`) and `platform/kubernetes/wireguard/03-deployment.yaml` (preserved as a comment block in both for resurrection). Deleted dangling Route53 record `vpn-travel.etherport.net. → 13.234.119.106` that the destroy missed (it's managed in the route53 module, not the regional-vpn module — capturing as L-tier debt below).
- **To resurrect:** dispatch `terraform-regional-vpn.yml` action=apply with `region=ap-south-1`, `region_short=mumbai`, `vpc_cidr=10.10.112.0/24`, `tunnel_ip=10.255.255.3` → re-add the peer blocks from the inline comments → re-add the Route53 A record. New AWS EIP will require new homelab WireGuard peer endpoint.

### ✅ M39. Lambda dns-restrict-ip revoke ignoring stale entries
- **Done:** 2026-05-23 (commit `cb102f8`). Bug discovered during H6 cleanup: after Lambda enabled on `allow_ssh` SG, new IPs were added cleanly but the 4 stale `/32`s (`47.34.215.233`, `47.159.189.230`, `146.70.238.13`, `86.98.93.115`) persisted across reconciliations. Root cause: AWS `revoke_security_group_ingress` treats a passed `Description` as part of the match key, so our `"Managed by dns-restrict-ip (22/tcp)"` description failed to match the existing rules' `"Allow SSH access from ..."` descriptions. Fix: split `_permissions()` to accept an optional description; `add_security_group_rules` passes our marker, `remove_security_group_rules` omits it. Apply dispatched; verified `sg-0079fee23ee54417a:22/tcp` now contains only the 2 Route53-derived entries.

### ✅ M40. PVE IPMI / ASRock Rack BMC observability
- **Done:** 2026-05-23 (commits `202b9b3` `43c07fe` `30d7f20` … `98ff141` — 7 iterations to wire everything end-to-end). **End state verified:** `ipmi_up{collector=bmc|chassis|dcmi|ipmi} 1` across all 4 collectors; TEMP_CPU sensor reads 71°C with `Upper Non-Critical: 82.000` and `Upper Critical: 90.000` (down from vendor defaults 98/99); rsyslog forwarding PVE host syslog (including ipmievd SEL events) to Loki under `{host="pve"}`. Bug parade fixed during the rollout: PrometheusRule mixed PromQL+LogQL (broke flux-system), Ansible argument-splitter chokes on `{% for %}` in shell literal (split into template+command), awk `$1==lbl` failed on label trailing whitespace, ipmievd custom unit `Type=forking` hung on missing pidfile (use packaged unit), prometheus-ipmi-exporter perm-denied on `/dev/ipmi0` (`User=root` in override), rsyslog default-inactive on PVE 8+ (install + enable), drop-in dir created after override file (reorder), SSH ban from rapid task connections (ControlMaster=auto). Hardware identified via DMI: ASRock Rack **B650D4U** (AMI MegaRAC firmware 6.04.0), AMD Ryzen 7000 series (AM5, DDR5 — 2 of 4 slots populated). SEL pull confirmed the 2026-05-02/05-03 incident pattern: TEMP_CPU repeatedly asserted `Upper Non-Critical` at 98°C (events `0x749`-`0x754`) and deasserted within 1-2s, but no alerting was wired because (a) thresholds were vendor defaults (98 warn / 99 crit — basically at thermal-throttle), (b) PEF was unarmed, (c) sensors had no Prometheus exporter.
- **Three things shipped:** (1) Ansible play `infra/ansible/playbooks/ipmi-monitoring.yml` (dispatch via `ansible-proxmox.yml` workflow) installs `prometheus-ipmi-exporter` + `ipmievd`, tightens thresholds (`TEMP_CPU` unc=82 crit=90; `FAN1-4` unc=12500 to catch pegged fans), configures rsyslog to forward ALL PVE syslog to Alloy `10.10.201.73:514` UDP. (2) Prometheus scrape job `pve-ipmi` → `10.10.200.41:9290` added in `01-external-scrape-config.yaml`. (3) `04-ipmi-alerts.yaml` PrometheusRule with `PveCpuTempHigh` (>80°C 5m), `PveCpuTempCritical` (>88°C 1m), `PveFanFailed` (<300 RPM), `PveFansPegged` (>12000 RPM 15m — directly catches the cooling-capacity-exhausted mode), `PveDimmTempHigh`, `PvePsuPowerLoss`, `IpmiExporterDown`.
- **NOT done here (deliberate):** BMC accounts (user explicit: remote, no recovery path — defer to M42). Fan curve / Smart Fan profile (lives behind AMI Web UI Settings → Fan Control, not exposed via standard IPMI or Redfish — user must set in UI). PEF / LAN alert destinations (cross-subnet PET trap delivery needs gateway MAC the BMC hasn't learned — relying on syslog instead).
- **Footgun caught during apply:** the first draft of `04-ipmi-alerts.yaml` mixed a LogQL rule into the PrometheusRule which failed admission and BLOCKED the entire `flux-system` kustomization until removed. Captured at the top of the file. LogQL rules need `loki-ruler` which we don't yet have.
- **Effort follow-up:** L4 (loki-ruler), L5 (BMC PEF with proper gateway MAC), M42 (BMC account hardening when user is onsite).

### ⏳ M42. UDM WireGuard cleanup (renumbered from archived M14)
- **Source:** carried forward via `docs/architecture/firewall-zones.md` cross-reference. Original archive ID was M14 but that's now reused for the s3-sync SSL probe item above. ID rotated to M42 to disambiguate.
- **Effort:** S. Walk the UDM WG peer list, drop stale entries (likely vpn-mumbai before M38 destroyed it — verify), confirm wg0_regional_peers in `infra/ansible/playbooks/wireguard.yml` matches.

### ✅ M46. Backup/transfer/sync workloads covered by AI advisor
- **Done:** 2026-05-24. Background-audit subagent identified 11 backup/transfer workloads + their gaps. Action shipped:
  - **Added `namespace` label** to existing alerts so advisor's `_build_context()` can pull pod logs + Loki window: `KopiaDown`, `VeleroDown` (in `comprehensive-alerts.yaml`); `RcloneGDriveSync*` (4 alerts in `rclone-gdrive/03-prometheus-rules.yaml`); `UnifiCertSync*` + `UnifiWildcardCertExpiring` (3 in `unifi-cert-sync/05-prometheusrule.yaml`).
  - **New `06-backup-alerts.yaml`** PrometheusRule with the previously-missing alerts: `S3SyncFailed/Stale`, `UnifiBackupFailed/Stale`, `CNPGBackupFailed/Stale`, `VeleroBackupFailed/Partial/LastBackupAgeHigh`.
  - **Velero ServiceMonitor enabled** in `clusters/wind/helm-releases/velero.yaml` so the velero-side metrics actually scrape (the rules were dormant before).
  - **Advisor context widened to 36h** for any alert with `component: backup` OR alertname containing backup/sync/rclone/velero/kopia/barman/cnpg. Backup runs are infrequent — the 5min default window missed the actual failure.
  - **Prompt extended** with explicit backup-workload awareness — Claude is now told (a) which namespaces hold which backup workloads, (b) NOT to propose restart_pods for in-flight Velero/Kopia/CNPG pods, (c) when restart IS safe (CrashLoopBackOff before any work started, hung process after network blip).
  - **service-status-report** TTL bumped 3600 → 90000 to match sibling CronJobs.
- **Still TODO** (L15): etcd snapshot timer on PVE CP nodes logs only to journald — never reaches Loki. Either ship journald → syslog → Alloy `:514`, or add a Prometheus textfile collector emitting `etcd_snapshot_last_run_timestamp`. Captured below.

### ✅ M45. Extend AI advisor context to cover AWS resources
- **Phases A + B + C all done 2026-05-24.**
- **Phase A** (UNVR + UNAS friendly relabel + runbook) — shipped.
- **Phase B** (advisor fetches CloudWatch Logs on demand for AWS-related alerts via boto3) — shipped + creds populated by user.
- **Phase C** (continuous CloudWatch → Loki ingest so dashboards span both clouds) — new `cloudwatch-to-loki` namespace with a 5-min CronJob; pure Python (~200 lines) + boto3 + urllib; watermarks per log group in a ConfigMap so we don't re-ingest. Reuses the same `ai-advisor-readonly` IAM user from Phase B (mirrored secret since k8s secrets are namespaced). Runbook at `docs/runbooks/cloudwatch-to-loki-enable.md`. Operator action: populate the new SOPS secret with same creds + commit; Flux deploys; first run produces `{job="cloudwatch", cloud="aws", log_group=..., service_name=<lambda-name>}` streams in Loki.
- **Source:** user ask 2026-05-24. Today the advisor's `_build_context()` only fetches K8s pod logs + Loki + K8s events for the alerted resource. AWS-side infra (Lambda functions ddns/dns-restrict-ip/email-forward/homeassistant-alexa; EC2 dns-aws + vpn-aws; ALB; Route53) logs to CloudWatch only — the advisor diagnoses these blind. Plus UNVR + UNAS syslog onboarding (see `docs/runbooks/syslog-onboard-device.md`).
- **Phase A (UNVR + UNAS — preparatory):** already shipped 2026-05-24. Alloy relabel rules include `^UNVR.*` → `unvr` and `^Sequoia.*` → `unas-sequoia`. User flips the syslog setting in each device's UI per the runbook; logs flow into Loki automatically, advisor's existing Loki-window fetch picks them up for free.
- **Phase B (CloudWatch Logs ingest into advisor):** ✅ code + TF + SOPS placeholder shipped 2026-05-24. New TF module `infra/terraform/aws/ai-advisor-iam` provisions IAM user `ai-advisor-readonly` with scoped `logs:GetLogEvents + logs:FilterLogEvents + logs:DescribeLogGroups + logs:DescribeLogStreams + logs:StartQuery + logs:GetQueryResults` policy (Resource-scoped to `/aws/lambda/*`, `/aws/ec2/*`, `CloudWatchAgent*` log groups). Controller code adds `_fetch_cloudwatch_logs()` + `_alert_is_aws()` heuristic + wires into `_build_context()` so AWS-targeted alerts get `ctx.cloudwatch.{aws_resource, window}` for the LLM. Prompt updated to mention the new field. Graceful degradation if creds missing. Runbook at `docs/runbooks/ai-advisor-phase-b-cloudwatch.md` for the 4-step enable. **Operator action**: dispatch `terraform-ai-advisor-iam.yml` apply → populate SOPS secret with the printed access key → commit.
- **Phase C (AWS log-stream centralization — bigger lift, optional):** for unified search/alerts across AWS + on-prem in Loki, deploy a CloudWatch Logs → Loki forwarder (either Lambda subscription filter pushing to `loki:3100/loki/api/v1/push` or a Kinesis Firehose). Out of scope for Phase B; only justified if you want Grafana dashboards spanning AWS logs.
- **Effort:** Phase B = S (a day). Phase C = M.

### ✅ M44. Bump CP VM memory 4 GB → 8 GB
- **Done:** 2026-05-24. NodeMemoryHighUtilization had been firing constantly on k8s-cp2 + k8s-cp3 (advisor saw 18 hits in first 24h, all noop). Root cause: kube-apiserver alone steady-states at ~3.5 GiB; CPs were sized at 4 GiB total. Bumped `control_plane_nodes.k8s-cp{1,2,3}.memory_mb` in `infra/terraform/proxmox/k8s-vms/main.tf` from 4096 to 8192. Apply rolls each CP sequentially; etcd quorum preserved (2-of-3 throughout). PVE has 96+ GB; +12 GB overhead trivial.

### 🟡 M41. Plex log centralization + AI-augmented alert remediation
- **Done partial:** 2026-05-23 (commits `77a9ee0` `30d7f20` `062b3b1`).
- **Phase 1 of the advisor SHIPPED but is OFF by default.** Controller pod is rolled with the new code, prompt ConfigMap, two SOPS-encrypted secret placeholders (anthropic-api-key, smtp-credentials), and `AI_ADVISOR_ENABLED=false`. To turn on: see `docs/runbooks/ai-advisor-phase1-enable.md`. Requires (a) creating a dedicated Anthropic API key, (b) populating the two SOPS secrets, (c) flipping the deployment env. All three need user action — Anthropic console isn't agent-accessible, and the existing SMTP creds can't be auto-mirrored cross-namespace without writing plaintext to disk (correctly blocked by the sandbox).
- **Plex sidecar:** Plex writes its real logs to `/config/Library/Application Support/Plex Media Server/Logs/*.log` not stdout, so the cluster-wide Alloy scraper had been seeing only the s6 init lines. Added `logtail` busybox sidecar to `platform/kubernetes/plex/02-deployment.yaml` that mounts the config PVC read-only and `tail -F`'s the log dir. Logs now query as `{namespace="plex", container="logtail"}`. **Immediate win:** centralized logs caught a real Plex config bug — `ERROR - Error parsing allowedNetworks entry ' 10.10.201.0 24': Invalid argument` repeating ~constantly. The space-separated entries look like Plex Web UI Library Settings → Network → "LAN Networks" was set with `; ` separators colliding with the env-var `ALLOWED_NETWORKS` setting. Tracked as L6 below.
- **Syslog labeling:** Alloy now promotes `__syslog_message_hostname` / `app_name` / `severity` / `facility` and `__syslog_connection_ip_address` to real Loki labels (`host`, `app`, `source_ip`). Required the `relabel_rules = loki.relabel.X.rules` pattern on the syslog source itself (not a downstream `forward_to` chain — first attempt got that wrong; fixed in `2839623`). Confirmed: `host` label values now include `UDM-Pro-Max`, `AMI9C6B006A1B39` (PVE BMC), `APBasement`/`APDeck`/`APDownstairs`/`APDriveway`/`APWorkroom`.
- **AI advisor spec:** `docs/planning/ai-alert-remediation-2026-05-23.md` — full design for extending the existing M8 auto-remediation webhook with a Claude API path that handles alerts falling through the rule-based dispatch. Three-mode safety model (advisory/propose/auto), hard guardrails enforced in code not prompt, ~$5/mo cost estimate. Phase 1 (advisory-only) is ready to build pending user decisions on Slack-vs-email sink + API key.
- **Open:** build Phase 1 of the advisor. ETA 1 week of implementation.

### 🟡 M47. UDM Network App modernization — API key + Integration API
- **Status 2026-05-26:** scoping runbook landed at `docs/runbooks/udm-network-app-modernization.md` (commit `de65e29`). Auth migration is ~half-day work; the URL migration to `/proxy/network/integration/v1/...` is partial-coverage (firewall groups have no Integration equivalent yet) so the recommended path is auth-only swap first, defer URL migration until UniFi Network 10.2+. Awaiting user to create the UDM API key (one-time console action).
- **Original entry below.**

### ⏳ M47-orig. UDM Network App modernization — API key + Integration API
- **Source:** 2026-05-26 audit while working Twilio Talk (#22). Found that `infra/ansible/playbooks/udm-firewall.yml` still uses the legacy username/password + `POST /api/auth/login` cookie auth flow against `/proxy/network/v2/api/...` and `/proxy/network/api/s/...`. UniFi Network Application ≥10.1.84 ships an official **Integration API** at `/proxy/network/integration/v1/...` with API-key auth (`X-API-Key` header), which is more durable + key-rotatable than the cookie dance.
- **Scope:**
  - User creates UDM API key in console → Control Plane → Admins → Create API Key. Stored in 1P as `unifi-udm-api` (API Credential category: `credential` = key value). Least-privilege scope; only widen if a playbook requires it.
  - Add `udm_api_key` to `infra/ansible/inventory/group_vars/all/secrets.sops.yml`.
  - Update `udm-firewall.yml` (+ any future UDM playbooks) to swap login flow → `headers: { X-API-Key: "{{ udm_api_key }}" }`.
  - Where Integration API covers the resource, migrate the endpoint (`/proxy/network/integration/v1/sites/{site}/...`); where it doesn't, keep `/proxy/network/v2/api/...` but with the new auth header (still supported).
  - Add `UNIFI_UDM_API_KEY` GH Actions secret for CI runs.
- **Effort:** ~half day. Mirror the auth-modernization pattern used elsewhere.
- **Source:** memory `reference_udm_zone_policy_api.md` for current state.

### ⏳ M48. UNAS Pro — bring under IaC via new per-device API key
- **Source:** 2026-05-26 user spotted the new "Create API Key" option in the UNAS app. Today UNAS config is fully UI-managed.
- **Scope:**
  - User creates API key in UNAS app → Settings → API. Stored in 1P as `unifi-unas-api`.
  - Add `unas_api_key` to SOPS secrets.
  - Net-new Ansible playbook `infra/ansible/playbooks/udm-unas.yml`. Start with a low-risk resource (e.g., admin user list or share permission audit), expand as patterns settle.
  - Use case: durability for whatever's currently UI-only (share configs, retention, accounts, SMB/NFS exports).
- **Effort:** ~1 day for first playbook; subsequent resources faster.
- **Note:** UNAS is a recent Ubiquiti product; API docs evolving. Pin Network App version in safety-check if endpoints stabilize per major release.

### ⏳ M49. UniFi Protect — bring under IaC via new per-device API key
- **Source:** 2026-05-26 (same trigger as M48). New per-device API key feature.
- **Scope:** mirror M48 but for Protect. 1P item `unifi-protect-api`. Playbook `udm-protect.yml`. Resources to manage as IaC: camera config (resolution, bitrate, motion zones), retention policies, user permissions, NVR-level alert rules. Start with a single resource type.
- **Effort:** ~1 day initial.

### ⏳ M50. Audit + gap-fill UDM/UNAS/Protect IaC coverage
- **Source:** 2026-05-26 outflow of #63 work. After M47-M49 land, walk through every UI page on UDM Network app, UNAS, and Protect; enumerate every setting NOT yet IaC-managed.
- **Scope:**
  - Output: a `docs/runbooks/udm-iac-coverage.md` table — UI page × management state × (durable / UI-only / needs-IaC).
  - Triage to critical-for-rebuild vs. nice-to-have.
  - Land the critical gaps as additional playbook resources.
- **Effort:** 1-3 days depending on triage scope.
- **Dependency:** M47 done first.

### ⏳ M51. UniFi Talk IaC — DEFERRED pending public API
- **Source:** 2026-05-26 research during Twilio Talk #22 work. Investigated whether UniFi Talk 3rd-party SIP provider config can be managed as IaC; conclusion = no public API exists today, and reverse-engineering the `/proxy/talk/...` endpoints is feasible (1-2 days) but undocumented (Ubiquiti can change them silently on any upgrade).
- **Decision:** wait for Ubiquiti to ship a public Talk API. Track via the open community feature request. Until then, the SIP provider config in [twilio-talk.md](../runbooks/twilio-talk.md) is the source-of-truth (UI-managed, documented).
- **Trigger to revisit:** Ubiquiti announces Talk API support.
- **Effort when unblocked:** ~1 day to write the playbook.

### ✅ M34. Disable site-wide UniFi auto-upgrade (DONE 2026-05-29, udm-firmware-policy.yml)
- H23 closed because the UDM itself has `mgmt.auto_upgrade: false`, but all 9 switches + 7 APs still have `safe_for_autoupgrade: true` and the site-wide policy upgrades them nightly at 03:00. A future firmware bug would auto-deploy to the fleet before you see it.
- **Live snapshot 2026-05-27** confirms: `mgmt.auto_upgrade = true` site-wide, and per-device `safe_for_autoupgrade`:
  - **UDM (Windroute):** `false` ✓ (won't auto-upgrade)
  - **All 7 APs** (access-road, basement, deck, downstairs, driveway, office, workroom): `true` ✗
  - **All 9 switches** (access-road, chapel, driveway, living-room, office, outdoor-junction, rack-10G, rack-PoE, workroom): `true` ✗
- **Fix:** flip `mgmt.auto_upgrade: false` site-wide (or per-device on non-UDM devices). Manual updates via Network UI on a planned cadence.
- **Effort:** Trivial.

---

## LOW

### ⏳ L1. Proxmox HA cluster expansion
- Source: `archive/outstanding-work-2026-05-16.md` L1. Blocked on adding a 2nd PVE node.

### 🟡 L2. Regional VPN destroy doesn't drop the per-region Route53 record
- **Status 2026-05-24:** module-side fix shipped, workspace-side migration pending.
- **Done:** `infra/terraform/modules/regional-vpn/main.tf` now accepts `dns_zone_id` + `dns_record_name` variables; when both are set (and `use_elastic_ip = true`), creates an `aws_route53_record.vpn_endpoint` resource that destroy-cleans automatically. Output `dns_record_fqdn` exposes the created FQDN.
- **Still TODO:** the live `infra/terraform/aws-regional-vpn/` workspace doesn't use the modules/regional-vpn module — it's a self-contained set of resources that uses `associate_public_ip_address = true` (no EIP, so IP changes on every instance reboot, defeating the DNS-record point). Migrate that workspace to either (a) use the module with `use_elastic_ip = true` + `dns_zone_id`/`dns_record_name`, or (b) duplicate the EIP + Route53 record resources inline. (a) is cleaner but is a one-shot state-migration exercise (destroy + re-apply, accepting brief outage on the next regional spin-up).
- **Original entry:**


- **Source:** observed during M38 (Mumbai destroy 2026-05-23). After `terraform-regional-vpn.yml` action=destroy ran clean, the `vpn-travel.etherport.net. → 13.234.119.106` A record was still present (deleted by hand after). The regional-vpn module manages the EC2/VPC/SG side but doesn't own the public DNS record — that lives in the `route53` module as a separate resource keyed on the EIP. So destroy leaves a dangling record pointing at a freed-up Elastic IP.
- **Risk:** the next AWS customer to grab that EIP would receive traffic addressed to `vpn-travel.etherport.net` until the record's 300s TTL expires. Low real-world impact for a WireGuard endpoint (handshake fails without the right key) but still a leak.
- **Fix options:** (a) move the Route53 record into the regional-vpn module so the per-region apply/destroy owns it end-to-end; (b) wire a `data` reference + `null_resource` `destroy_provisioner` in the regional-vpn module to call `aws route53 change-resource-record-sets DELETE` on teardown; (c) accept it as a manual step in the resurrection runbook. (a) is cleanest.
- **Effort:** S.

### ⏳ L3. EIP → FQDN conversion debt (hardcoded ephemeral IP audit follow-up)
- **Source:** `docs/planning/hardcoded-ephemeral-ip-audit-2026-05-23.md`. Several places still hardcode AWS Elastic IPs that *could* rotate if recreated: `vpn-use1` endpoint `35.169.37.16` in `platform/kubernetes/wireguard/03-deployment.yaml`, dns-aws `52.40.219.113` in M35 plan, etc. Convert each to a Route53 FQDN + DNS lookup at peer/config render time so an EIP swap doesn't require a code change.
- **Effort:** S per site, M overall.

### ✅ L4. Enable loki-ruler for LogQL alerting
- **Done:** 2026-05-24. `clusters/wind/helm-releases/loki.yaml` now has a `loki.ruler` block (alertmanager_url pointed at kube-prometheus-stack's AM service) + `sidecar.rules.enabled: true` that watches ConfigMaps labeled `loki_rule: "1"` and writes them into the ruler's rules dir. First two rules shipped in `platform/kubernetes/monitoring/05-loki-rules-ipmi.yaml`: PveIpmiSelAssertion (counts ipmievd "Asserted" lines in 5m) + UdmSyslogCritical (sustained err/crit severity for 5m). Pattern matches the existing Grafana dashboards sidecar (label-discovery). Add new rule groups by appending to the ConfigMap or creating sibling ConfigMaps with the same label.

### ⏳ L5. PVE BMC PEF / LAN alert destinations (cross-subnet PET trap)
- **Source:** M40 deliberately deferred. BMC sits on VLAN 200 (10.10.200.21); Alloy/Loki on VLAN 201 (10.10.201.73). For BMC PET traps to reach Alloy, the BMC needs to learn the gateway MAC for 10.10.200.1 — `ipmitool lan print 1` shows `Default Gateway MAC: 00:00:00:00:00:00` currently. Either populate the gateway MAC statically (one-shot ARP lookup + `ipmitool lan set 1 defgw mac <mac>`) or have the BMC do it via gratuitous ARP. Then enable PEF policy 1 with action="send to LAN destination 1" pointed at 10.10.201.73. Today we rely on BMC remote-syslog → Alloy which covers the same alerts.
- **Effort:** S.

### ⏳ L8. Delete stale `platform/kubernetes/monitoring/values.yaml`
- **Source:** consistency review 2026-05-24. The file is the legacy chart-values that was replaced by inline values inside `clusters/wind/helm-releases/monitoring.yaml`. It's not referenced from any `kustomization.yaml`, so Flux doesn't apply it. Source of confusion (e.g. the original H5 entry pointed at the wrong file). Safe to delete; commits since the migration use the HelmRelease inline values exclusively.
- **Effort:** Trivial.

### ⏳ L15. Ship etcd snapshot timer logs to Loki
- **Source:** M46 backup audit 2026-05-24. The Ansible-managed etcd snapshot systemd timer on each PVE control-plane node writes only to journald — never reaches Loki. Snapshots themselves are captured by Velero's `kube-system-daily` FS backup, but timer-side failures (disk full, snapshotter crash) are invisible.
- **Fix options:**
  - (a) Install `systemd-journal-upload` or rsyslog forwarder on the CP nodes pointing at `10.10.201.73:514` (existing Alloy syslog receiver). Same pattern as the PVE ipmi-monitoring playbook's rsyslog forwarder. Adds ~10 lines to `etcd-backup.yml` playbook.
  - (b) Add a Prometheus textfile collector emitting `etcd_snapshot_last_run_timestamp` after each snapshot; add a staleness alert. More aligned with how other backup workloads alert.
- **Effort:** S either way.

### ⏳ L14. AI advisor public approval URL — needs auth gate before advertise
- **Source:** Phase 2 wireup 2026-05-24. The `approve.etherport.net` Traefik IngressRoute is deployed but unadvertised (email links default to the Tailscale URL). HMAC-token-only auth on a public endpoint is too thin — anyone with email access can approve. Before flipping `APPROVAL_BASE_URL` to the public URL, add a zero-trust gate:
  - Option A: **Cloudflare Access** policy gating `*.wind.etherport.net` — requires Google SSO + email-domain restriction. ~30min setup; needs Cloudflare-as-DNS for the domain (currently Route53). Doable but moves DNS authority.
  - Option B: **Tailscale Funnel** — exposes a TS service publicly via TS-managed gate. No DNS change; gate is TS auth. Requires Funnel feature on the tailnet.
  - Option C (current): Stay TS-only; treat public Ingress as future infra.
- **Effort:** M.

### ⏳ L13. Phase 3 (autonomous execute) opt-in alerts
- **Source:** code shipped 2026-05-24 (`AI_PHASE3_ENABLED` env, default OFF). Per the phased rollout plan in `docs/runbooks/ai-advisor-phase3-enable.md`: week 1 add `ai_remediation: "auto"` label to `NodeLocalDNSHighErrorRate` only; week 2 add `CoreDNSDown`; week 3 add `TechnitiumDNSDown` + `HomeAssistantDown`; expand 1/week as comfort builds. Never include CNPG / Ceph / kube-system alerts.
- **Effort:** Trivial per alert (one label addition). Spread across weeks for safety.

### ✅ L12. Dedicated `tag:cluster-ingress` Tailscale tag + ACL in IaC
- **Done:** 2026-05-24. `tag:cluster-ingress` added to `tagOwners` in the tailnet ACL (operator-owner only). `auto-remediation/remediation-approve` Ingress annotation flipped from `tag:subnet-router` → `tag:cluster-ingress`. Bonus: pulled the entire tailnet policy into IaC at `infra/tailscale/policy.hujson` with heavy inline comments + a README. GH Actions workflow `.github/workflows/tailscale-policy.yml` POSTs the file to `https://api.tailscale.com/api/v2/tailnet/-/acl` on every push to main (the older admin-console GitHub-pull flow is deprecated; API-push is the current pattern). One-time operator setup: generate Tailscale API key + add as `TAILSCALE_API_KEY` GH repo secret, then lock the admin-console policy editor so the web UI becomes view-only. Tailnet ID `TwxNUjPekr11CNTRL` (display: `sparked-diamond.github`).

### ✅ L11. gh-runner .git permission failure on TF apply jobs (durable fix)
- **Done:** 2026-05-24 in `infra/ansible/playbooks/gh-runner.yml`. Symptom (M44 apply, run 26366496970): `insufficient permission for adding an object to repository database .git/objects` + `fatal: unpack-objects failed`. Root cause: some prior workflow step (likely a `container:`-based action) wrote files into the work dir as root; subsequent runs as the `ubuntu` runner user can't overwrite them.
- **Durable fix:** the gh-runner playbook now drops a `job-started.sh` hook at `{{ runner_home }}/hooks/job-started.sh` and points `ACTIONS_RUNNER_HOOK_JOB_STARTED` at it via the runner's `.env` file. The hook runs at every job start (before `actions/checkout`) and does a `chown -R {{ runner_user }}:{{ runner_user }} _work` so stale ownership self-heals on every run. Passwordless sudo for `/usr/bin/chown` granted to the runner user via `/etc/sudoers.d/runner-chown` (scoped to that one binary, validated with visudo). Also runs a one-off `chown -R` during the play so the next workflow can start immediately.
- **To apply:** dispatch `ansible-proxmox.yml`? No — `gh-runner.yml` doesn't live in the proxmox workflow list. Run from operator's laptop with the standard env: `GH_TOKEN=$(op item get p4k7sihbwzls55lvt6qlf23fcu --fields token --reveal) ansible-playbook -i infra/ansible/inventory/wind/ infra/ansible/playbooks/gh-runner.yml`.

### ⏳ L9. Delete legacy traefik files
- **Source:** consistency review 2026-05-24. `platform/kubernetes/traefik/{pvc-traefik-ceph.yaml,traefik-acme-fix.yaml}` are explicitly labeled "Legacy. Safe to remove." in the traefik README but still on disk. Drop them.
- **Effort:** Trivial.

### ⏳ L7. Clean up debug Jobs in `backups` namespace
- **Source:** observed during M40 tidy 2026-05-23. Six failed pods from
  `unifi-backup-test`, `unifi-backup-test2`, `unifi-backup-test3` Jobs
  remain in the `backups` namespace (created 3.5h ago during M31
  debugging before the playbook landed). All have `status=Error`,
  contributing nothing — `kubectl get pods -A --field-selector
  status.phase!=Running,Succeeded` returns them as the only
  unhealthy pods cluster-wide. Cluster is otherwise green.
- **Fix:** `kubectl delete job/unifi-backup-test{,2,3} -n backups`
  (one-liner). Or wait for K8s' default Job TTL to expire.
- **Effort:** Trivial.

### ⏳ L6. Plex `ALLOWED_NETWORKS` parse error
- **Source:** surfaced 2026-05-23 by the new Plex logtail sidecar (M41). Plex repeatedly logs `ERROR - Error parsing allowedNetworks entry ' 10.10.201.0 24': Invalid argument`. The space-separated CIDR fragments suggest Plex is reading from its Web UI "LAN Networks" setting where the slash got stripped — likely an old config from before the env-var was set. The `ALLOWED_NETWORKS` env in `02-deployment.yaml` is correct (`10.10.201.0/24,...`); need to clear the Web UI value or re-sync. Library Settings → Network → LAN Networks → check/clear the value.
- **Effort:** Trivial (one UI click).

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
| H26 | Etcd backup automation + DR drill schedule | 2026-05-22 |
| H27 | Ceph msgr2 v2 re-enable | 2026-05-22 |
| H28 | Containerized ansible CI | 2026-05-22 |
| H5 | Prometheus + Alertmanager replicas=2 podAntiAffinity | 2026-05-22 |
| H6 | Hardcoded WAN IPs in AWS security groups → Lambda-managed | 2026-05-23 |
| H8 | Archive completed proxmox-sdn-implementation doc | 2026-05-22 |
| M2 | cert-manager wildcard runbook | 2026-05-21 |
| M4 | Image pinning + Renovate policy doc | 2026-05-21 |
| M8 | Auto-remediation webhook wired into alertmanager + COVERAGE.md | 2026-05-22 |
| M9 | Etcd backup automation + DR drill schedule | 2026-05-22 |
| M19 | MetalLB advertising technitium aggregator .201.5 | 2026-05-22 |
| M20 | safety-check single-ping flake tolerance over WG | 2026-05-22 |
| M21 | WG K8s pod preStop / VRRP failover | 2026-05-22 |
| M22 | Consolidated Grafana service-status dashboard | 2026-05-22 |
| M23 | Daily service-status email digest | 2026-05-22 |
| M24 | Modernize s3-sync daily-report HTML | 2026-05-22 |
| M26 | Grafana sidecar admin password rotation | 2026-05-22 |
| M27 | service-status inventory drift-check in CI | 2026-05-22 |
| M28 | Bake homelab automation pubkey into AWS VM user_data | 2026-05-22 |
| M29 | kube-proxy metrics scrape | 2026-05-22 |
| M13 | Delete /data/udm-le.removed-* + cert mgmt for all 3 UniFi-OS devices | 2026-05-23 |
| M25 | UDM / UniFi config audit (3-part) | 2026-05-23 |
| M31 | Automated UDM backup to S3 (infra.wind.etherport.net) | 2026-05-23 |
| M33 | UDM rsyslog → Alloy syslog receiver | 2026-05-23 |
| M36 | Document UDM MetalLB IP-conflict noise (BGP migration M18 unblocks) | 2026-05-23 |
| M37 | Loki + Alloy centralized log aggregation | 2026-05-23 |
| M38 | Tear down vpn-mumbai (ap-south-1) regional VPN | 2026-05-23 |
| M39 | Lambda dns-restrict-ip revoke description-mismatch fix | 2026-05-23 |
| M40 | PVE IPMI / ASRock Rack BMC observability (ipmi_exporter + ipmievd + thresholds) | 2026-05-23 |
| M44 | Bump CP VM memory 4 → 8 GB | 2026-05-24 |
| M46 | Backup/transfer alerts + advisor context coverage | 2026-05-24 |
| L4  | Enable loki-ruler (LogQL alerts) | 2026-05-24 |
| L11 | gh-runner .git permission durable fix | 2026-05-24 |
| L12 | tag:cluster-ingress + ACL in IaC + GH-Actions push | 2026-05-24 |
| C1 | CNPG Barman ScheduledBackup + Cluster manifest | 2026-05-22 |
| C3 | Encrypt Ceph key in plaintext inventory | 2026-05-22 |

---

## Process

- This file is the canonical work tracker. When an item completes, flip the glyph to ✅ and add a one-line `**Done:**` note with the date. Don't delete — preserve history.
- When the file gets too long (>500 lines or once per ~quarter), spin off a new dated successor and link forward like this one does.
- Items not yet captured here should be added with the next free ID in their tier — don't re-use deprecated IDs.
- TaskCreate IDs (`#NN`) are session-scoped and ephemeral; this file is the durable record. Reference TaskCreate IDs only to help cross-check while a session is active.
