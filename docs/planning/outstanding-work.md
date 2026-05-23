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
- **Done:** 2026-05-22 (commit `0851d26`). Prometheus + Alertmanager both bumped to `replicas=2` with podAntiAffinity in `kube-prometheus-stack-values.yaml`. cert-manager + cert-manager-cainjector + cert-manager-webhook were already 2/2 per kubectl (no change needed). Traefik was already 2/2. Grafana stays at 1 (RWO PVC + sticky session — HA needs external DB).

### 🟡 H6. Hardcoded WAN IPs in AWS security groups
- **Status 2026-05-23:** DNS-side done; SSH-side still hardcoded pending user input.
- **Done (commit `d0f3a36`):** the 4 hardcoded `dns_(udp|tcp)_homelab[12]` ingress rules on `aws_security_group.dns_server` have been transferred from Terraform to the `dns-restrict-ip` Lambda. The Lambda was already keeping these in sync with `wan1`/`wan2.wind.etherport.net` Route53 records via boto3; the TF side was a redundant declaration that would have fought the Lambda on any WAN-IP change. Used `removed` blocks with `destroy = false` so TF forgets ownership without deleting the rules in AWS. Verified by `terraform apply` showing `0 added, 0 changed, 0 destroyed`.
- **⏳ Still hardcoded:** `aws_security_group.allow_ssh` port 22 from `47.34.215.233/32` (commented "remote location"). To migrate this, need to decide: is this a static second residence IP (keep hardcoded with a clearer comment), or is it DDNS-tracked somewhere (add Route53 record + extend Lambda to also manage SG/port/protocol tuples beyond the dns_server SG)? **Awaiting your input** before further IaC changes.

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

### 🟡 M30. UDM zone architecture — reconcile doc with live + future-state design
- **Status 2026-05-23:** option (b) shipped. Option (a) tracked as the migration plan in the new future-state doc, awaiting user kickoff.
- **Option (b) done** (commit `f5693c3`): rewrote `docs/architecture/firewall-zones.md` to match the live single-custom-zone (IoT) reality. Removed 317 lines of aspirational multi-zone description; added a "Current state vs aspirational state" callout pointing at the future-state doc.
- **Future-state doc** (new — `docs/planning/firewall-zones-future-state.md`): proposes a 4-zone end-state (Trusted/Infrastructure/IoT/Security), inter-zone allow/deny matrix, named allow rules, **5-phase migration plan** with per-phase rollback procedures, and a decision checklist. Calls out M31 (UDM backup) as a hard prerequisite (now ✅), so Phase 1 (pilot Unifi/212 → Infrastructure zone) is unblocked.
- **Open questions for you** (§7 of future-state doc): (1) SimpliSafe WAN dependence; (2) non-K8s sync jobs Clients→Servers that would silently break; (3) Default/199 disposition; (4) WireGuard WAN1 (UDM-side VPN pool) — re-enable or delete; (5) long-term L3-switch ACL management strategy. Phase 2 risk is unbounded until §5 is resolved.

### ✅ M31. Automated UDM backup to S3 (P0 from M25 audit)
- **Done:** 2026-05-23. New CronJob `unifi-backup` in `backups` ns, fires daily 04:00 PT. Three targets per run:
  - **`udm-controller-db`** — newest `.unf` from `/data/unifi/data/backup/autobackup/` (UDM writes one daily at 07:00 UTC, ~8.5MB).
  - **`udm-core-config`** — tar+gz of `/data/unifi-core/config/` (firewall, fabric, firmware, cloud YAMLs ~21KB).
  - **`protect-core-config`** — tar+gz of Protect's `/data/unifi-core/config/`.
- Lands at `s3://infra.wind.etherport.net/{prefix}/{name}-{date}.{ext}`. New `infra.wind.etherport.net` general-purpose bucket created via TF (`4101a49`); IAM policy `s3-backup-kubernetes-policy` extended to v14 to allow PutObject. Lifecycle: 90d expiry under `unifi/` + 30d noncurrent-version cleanup.
- Reuses `unifi-cert-sync-ssh` SSH key (copied to a new SOPS-encrypted secret in `backups` ns). Status + bytes metrics pushed to pushgateway under `unifi_backup_*`.
- Verified end-to-end: first manual fire uploaded all 3 objects cleanly.

### ⏳ M32. UDM firmware channel back to `release` (P0 from M25 audit, trivial)
- Live `mgmt.gateway_release_channel = beta`, almost certainly unintentional.
- **Fix:** UDM UI → System → Updates → Firmware Channel: `beta` → `release`. One click.

### 🟡 M33. UDM rsyslog destination empty — wire to Alloy syslog receiver (P0 from M25 audit)
- **Status 2026-05-23:** Receiver side shipped (M37 — Loki + Alloy); UDM-side config still pending.
- Alloy is deployed via `clusters/wind/helm-releases/alloy.yaml` with a syslog LoadBalancer Service at MetalLB IP **`10.10.201.73`**, listening on UDP/TCP **514** (RFC3164 + RFC5424). Logs flow into Loki.
- **Last step:** UDM UI → Settings → System → Remote Logging → set host `10.10.201.73` port `514` (UDP or TCP). OR via UDM API:
  ```
  curl -k -b $COOKIES -H "X-CSRF-Token: $TOKEN" -X PUT \
    https://10.10.200.1/proxy/network/api/s/default/set/setting/super_fabric_system_log \
    -d '{"key":"super_fabric_system_log","host":"10.10.201.73","port":514,"netconsole_enabled":false}'
  ```
- Once configured, query in Grafana via the new Loki datasource: `{job="syslog"} |~ "(?i)error|fail"`.
- **Effort:** Trivial (one UI click) once Flux applies M37.

### ⏳ M36. UDM "IP conflict" alerts for MetalLB VIPs (.5 + .71)
- **Source:** user report 2026-05-23. UDM repeatedly fires IP-conflict alerts for `10.10.201.5` (Technitium aggregator/cluster VIP) and `10.10.201.71` (technitium-0 LoadBalancer IP). Both are MetalLB-managed.
- **Why it happens:** MetalLB L2Advertisement mode picks ONE speaker pod per IP to send gratuitous ARP. When the elected speaker moves (pod restart, node drain, MetalLB controller re-election), the IP "moves" to a different node MAC. The UDM sees the same IP claimed by multiple MAC addresses over time and flags it as a conflict — even though it's working as designed.
- **The clean fix = MetalLB BGP mode (M18).** In BGP mode, each speaker advertises the IP as a /32 route to the UDM (as a BGP peer). There's no ARP claim, no MAC ownership, no "conflict" from the UDM's perspective — it's a learned route. The Technitium audit (M25 §2.4) noted UniFi Network ≥10 supports eBGP peering, so this is unblocked technically. Effort: M (UDM BGP config + MetalLB BGPPeer/BGPAdvertisement CRs + private ASN allocation + cutover).
- **Short-term workaround (stop the alerts without the BGP migration):** in the UDM UI under Settings → Networks → Default (or the LAN where these VIPs live), add an "Excluded IP" list for `.5` and `.71` so the UDM stops tracking them as DHCP clients. Or under Insights → IP Conflict Detection, add a per-IP suppression rule. Either is reversible if BGP migration happens later.
- **Effort:** S (workaround) / M (proper BGP migration). Merging with M18 since they share the resolution.

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
- **Done:** 2026-05-23 (commits `202b9b3` `43c07fe` `30d7f20`). Hardware identified via DMI: ASRock Rack **B650D4U** (AMI MegaRAC firmware 6.04.0), AMD Ryzen 7000 series (AM5, DDR5 — 2 of 4 slots populated). SEL pull confirmed the 2026-05-02/05-03 incident pattern: TEMP_CPU repeatedly asserted `Upper Non-Critical` at 98°C (events `0x749`-`0x754`) and deasserted within 1-2s, but no alerting was wired because (a) thresholds were vendor defaults (98 warn / 99 crit — basically at thermal-throttle), (b) PEF was unarmed, (c) sensors had no Prometheus exporter.
- **Three things shipped:** (1) Ansible play `infra/ansible/playbooks/ipmi-monitoring.yml` (dispatch via `ansible-proxmox.yml` workflow) installs `prometheus-ipmi-exporter` + `ipmievd`, tightens thresholds (`TEMP_CPU` unc=82 crit=90; `FAN1-4` unc=12500 to catch pegged fans), configures rsyslog to forward ALL PVE syslog to Alloy `10.10.201.73:514` UDP. (2) Prometheus scrape job `pve-ipmi` → `10.10.200.41:9290` added in `01-external-scrape-config.yaml`. (3) `04-ipmi-alerts.yaml` PrometheusRule with `PveCpuTempHigh` (>80°C 5m), `PveCpuTempCritical` (>88°C 1m), `PveFanFailed` (<300 RPM), `PveFansPegged` (>12000 RPM 15m — directly catches the cooling-capacity-exhausted mode), `PveDimmTempHigh`, `PvePsuPowerLoss`, `IpmiExporterDown`.
- **NOT done here (deliberate):** BMC accounts (user explicit: remote, no recovery path — defer to M42). Fan curve / Smart Fan profile (lives behind AMI Web UI Settings → Fan Control, not exposed via standard IPMI or Redfish — user must set in UI). PEF / LAN alert destinations (cross-subnet PET trap delivery needs gateway MAC the BMC hasn't learned — relying on syslog instead).
- **Footgun caught during apply:** the first draft of `04-ipmi-alerts.yaml` mixed a LogQL rule into the PrometheusRule which failed admission and BLOCKED the entire `flux-system` kustomization until removed. Captured at the top of the file. LogQL rules need `loki-ruler` which we don't yet have.
- **Effort follow-up:** L4 (loki-ruler), L5 (BMC PEF with proper gateway MAC), M42 (BMC account hardening when user is onsite).

### 🟡 M41. Plex log centralization + AI-augmented alert remediation spec
- **Done partial:** 2026-05-23 (commit `77a9ee0` `30d7f20`).
- **Plex sidecar:** Plex writes its real logs to `/config/Library/Application Support/Plex Media Server/Logs/*.log` not stdout, so the cluster-wide Alloy scraper had been seeing only the s6 init lines. Added `logtail` busybox sidecar to `platform/kubernetes/plex/02-deployment.yaml` that mounts the config PVC read-only and `tail -F`'s the log dir. Logs now query as `{namespace="plex", container="logtail"}`. **Immediate win:** centralized logs caught a real Plex config bug — `ERROR - Error parsing allowedNetworks entry ' 10.10.201.0 24': Invalid argument` repeating ~constantly. The space-separated entries look like Plex Web UI Library Settings → Network → "LAN Networks" was set with `; ` separators colliding with the env-var `ALLOWED_NETWORKS` setting. Tracked as L6 below.
- **Syslog labeling:** Alloy now promotes `__syslog_message_hostname` / `app_name` / `severity` / `facility` and `__syslog_connection_ip_address` to real Loki labels (`host`, `app`, `source_ip`). Required the `relabel_rules = loki.relabel.X.rules` pattern on the syslog source itself (not a downstream `forward_to` chain — first attempt got that wrong; fixed in `2839623`). Confirmed: `host` label values now include `UDM-Pro-Max`, `AMI9C6B006A1B39` (PVE BMC), `APBasement`/`APDeck`/`APDownstairs`/`APDriveway`/`APWorkroom`.
- **AI advisor spec:** `docs/planning/ai-alert-remediation-2026-05-23.md` — full design for extending the existing M8 auto-remediation webhook with a Claude API path that handles alerts falling through the rule-based dispatch. Three-mode safety model (advisory/propose/auto), hard guardrails enforced in code not prompt, ~$5/mo cost estimate. Phase 1 (advisory-only) is ready to build pending user decisions on Slack-vs-email sink + API key.
- **Open:** build Phase 1 of the advisor. ETA 1 week of implementation.

### ⏳ M34. Disable site-wide UniFi auto-upgrade (extends H23)
- H23 closed because the UDM itself has `mgmt.auto_upgrade: false`, but all 9 switches + 7 APs still have `safe_for_autoupgrade: true` and the site-wide policy upgrades them nightly at 03:00. A future firmware bug would auto-deploy to the fleet before you see it.
- **Fix:** flip `mgmt.auto_upgrade: false` site-wide (or per-device on non-UDM devices). Manual updates via Network UI on a planned cadence.
- **Effort:** Trivial.

---

## LOW

### ⏳ L1. Proxmox HA cluster expansion
- Source: `archive/outstanding-work-2026-05-16.md` L1. Blocked on adding a 2nd PVE node.

### ⏳ L2. Regional VPN destroy doesn't drop the per-region Route53 record
- **Source:** observed during M38 (Mumbai destroy 2026-05-23). After `terraform-regional-vpn.yml` action=destroy ran clean, the `vpn-travel.etherport.net. → 13.234.119.106` A record was still present (deleted by hand after). The regional-vpn module manages the EC2/VPC/SG side but doesn't own the public DNS record — that lives in the `route53` module as a separate resource keyed on the EIP. So destroy leaves a dangling record pointing at a freed-up Elastic IP.
- **Risk:** the next AWS customer to grab that EIP would receive traffic addressed to `vpn-travel.etherport.net` until the record's 300s TTL expires. Low real-world impact for a WireGuard endpoint (handshake fails without the right key) but still a leak.
- **Fix options:** (a) move the Route53 record into the regional-vpn module so the per-region apply/destroy owns it end-to-end; (b) wire a `data` reference + `null_resource` `destroy_provisioner` in the regional-vpn module to call `aws route53 change-resource-record-sets DELETE` on teardown; (c) accept it as a manual step in the resurrection runbook. (a) is cleanest.
- **Effort:** S.

### ⏳ L3. EIP → FQDN conversion debt (hardcoded ephemeral IP audit follow-up)
- **Source:** `docs/planning/hardcoded-ephemeral-ip-audit-2026-05-23.md`. Several places still hardcode AWS Elastic IPs that *could* rotate if recreated: `vpn-use1` endpoint `35.169.37.16` in `platform/kubernetes/wireguard/03-deployment.yaml`, dns-aws `52.40.219.113` in M35 plan, etc. Convert each to a Route53 FQDN + DNS lookup at peer/config render time so an EIP swap doesn't require a code change.
- **Effort:** S per site, M overall.

### ⏳ L4. Enable loki-ruler for LogQL alerting
- **Source:** M40 commit `43c07fe`. We want alerts of the form `{job="syslog"} |~ "(Temperature|Fan|PowerSupply).*(Critical|Asserted)"` as a belt-and-suspenders complement to the ipmi_exporter metric alerts. PrometheusRule rejects LogQL. The Loki helm chart has a `ruler` block that, when enabled, runs a separate ruler component reading rules from a ConfigMap and pushing alerts to Alertmanager. Wire it in `clusters/wind/helm-releases/loki.yaml` + add LokiRule resources alongside PrometheusRule.
- **Effort:** S (5-10 lines of values + one new resource type).

### ⏳ L5. PVE BMC PEF / LAN alert destinations (cross-subnet PET trap)
- **Source:** M40 deliberately deferred. BMC sits on VLAN 200 (10.10.200.21); Alloy/Loki on VLAN 201 (10.10.201.73). For BMC PET traps to reach Alloy, the BMC needs to learn the gateway MAC for 10.10.200.1 — `ipmitool lan print 1` shows `Default Gateway MAC: 00:00:00:00:00:00` currently. Either populate the gateway MAC statically (one-shot ARP lookup + `ipmitool lan set 1 defgw mac <mac>`) or have the BMC do it via gratuitous ARP. Then enable PEF policy 1 with action="send to LAN destination 1" pointed at 10.10.201.73. Today we rely on BMC remote-syslog → Alloy which covers the same alerts.
- **Effort:** S.

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
| H27 | Ceph msgr2 v2 re-enable | 2026-05-22 |
| H28 | Containerized ansible CI | 2026-05-22 |

---

## Process

- This file is the canonical work tracker. When an item completes, flip the glyph to ✅ and add a one-line `**Done:**` note with the date. Don't delete — preserve history.
- When the file gets too long (>500 lines or once per ~quarter), spin off a new dated successor and link forward like this one does.
- Items not yet captured here should be added with the next free ID in their tier — don't re-use deprecated IDs.
- TaskCreate IDs (`#NN`) are session-scoped and ephemeral; this file is the durable record. Reference TaskCreate IDs only to help cross-check while a session is active.
