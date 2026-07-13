# Outstanding Work — Consolidated Priority List

Latest revision: 2026-07-03 (Opus 4.8 sweep — ✅ entries of 07-01→07-03 extracted to the same archive; prior pass 2026-07-01: all ✅-done entries extracted to
[`archive/outstanding-work-completed-2026-07.md`](archive/outstanding-work-completed-2026-07.md);
prior extractions [`archive/completed-2026-H1.md`](archive/completed-2026-H1.md) 2026-06-24 and
[`archive/outstanding-work-snapshot-2026-05-31.md`](archive/outstanding-work-snapshot-2026-05-31.md)).
Canonical filename `outstanding-work.md` is stable; older dated snapshots live in
`archive/`. Per-session narrative: `session-log.md`.

Successor to `archive/outstanding-work-2026-05-16.md`.

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

## Recently completed (since ~2026-06-20)

One line per item, newest first — **full text in
[`archive/outstanding-work-completed-2026-07.md`](archive/outstanding-work-completed-2026-07.md)**.
Open residuals are noted inline; they are the only open work in this section.
(M111, the 2026-07-01 AWS-cost root-cause, stays a full entry below — its follow-ups are open.)

### Added 2026-07-03 (the 07-01→07-03 wave)
- ✅ H42. step-ca (+ asterisk-sbc, pve OS) monitoring blind spot — DONE 2026-07-01
- ✅ H43. 9 TF workflows ran PR-authored `terraform plan` on the in-network self-hosted runner — DONE 2026-07-01
- ✅ H44. Authentik upgrade 2024.12.3 → **2026.5.3 (latest) — DONE 2026-07-02; CVE-2026-25227 remediated + 7 majors of currency**
- ✅ H45. CVE patch batch — ALL DONE 2026-07-02: containerd 2.2.5, Cilium 1.18.11, CNPG operator 1.30.0, PG 16.14
- ✅ 07-05 triage. (1) Cilium MTU black hole on gpu1 (WG-pod node) — auto-detect latched onto the WG pod's wg0 (1420) after the K8s-upgrade reboot → cilium_wg0=1340 → dcgm TargetDown + NFD crashloops; fixed `helm --set MTU=9000` + pinned `cilium_mtu` in inventory + NEW runbook `cilium-mtu-wireguard-blackhole.md`. (2) Daily-email false "outages": removed dead Authentik-Redis + fixed Ceph-CSI namespace in `services.py`; fixed the ansible drift detectors never writing `drift-status` (matrix runs in a container w/o kubectl → moved the write to a lifecycle host job). Email 4-unknown → 0. Remaining reds genuine: Mac-mini backups (NAS SMB mount wedged post-UNAS-nvme0-incident, needs mini remount) + cloud-tag-drift (→ M135).
- ✅ M122. Close the update-automation blind spots (the systemic fix) — DONE 2026-07-02 (`122caaa`)
- ✅ L32. vpn-fallback (ex vpn-local) Tailscale — REINSTALLED + REJOINED 2026-07-02 (100.97.20.113, tagged-devices, exit-node advertised; owner to approve exit node + disable key expiry)
- ✅ M128. Rename `vpn-local` → `vpn-fallback` — COMPLETE 2026-07-02 (repo+TF+PVE+guest hostname+TS rejoin as vpn-fallback)
- ✅ M123. K8s platform upgrade train — COMPLETE 2026-07-02: 1.34.3 (with H45b) AND the 1.35.0 minor, same day
- ✅ M125. unifi TF provider MIGRATED to ubiquiti-community/unifi 0.41.25 — DONE 2026-07-02 (import-based, plan=No changes, CI green); the fork FIXED the PUT-400 bug
- ✅ M127. Tailnet split-DNS still lists the DESTROYED dns-aws (10.10.100.5) — DONE 2026-07-02 (console edit `.5`→`.100.10`; verified 1–3 ms via 100.100.100.100). Residuals optional: tailnet-DNS-into-IaC (S) + the off-cluster second subnet router decision (S). Original finding:
- ✅ M112. `concurrency:` groups on all terraform workflows — DONE 2026-07-01 (`72cb120`): `tf-<stack>` group, `cancel-in-progress: false`, added to all 24 TF workflows (incl. drift-detection).
- ✅ M113. Alert-coverage gaps — DONE 2026-07-01 (`727a40d`,`47e29b7`), verified: cert-manager ServiceMonitor enabled (metrics were never scraped!); NEW 13-service-alerts.yaml — CNPGClusterDown ×2 (absent()-based), CertManagerRenewalOverdue + CertExpiryCritical (**duration-agnostic — the wildcard is a ~6.7d short-lived LE cert, absolute-day thresholds false-fired within minutes and were rewritten to renewal-overdue semantics**), AuthentikDown (new in-cluster blackbox Probe + plain http_2xx module), CloudflaredTunnelDegraded/Down; runbook_url pass (14 rules linked to their docs/runbooks/alerts docs). All 7 rules loaded + inactive on the healthy cluster.
- ✅ M114. authentik-server HA — DONE 2026-07-01 (`72cb120`), verified: replicas 2 on distinct nodes (w1+w4), zero-gap RollingUpdate, hostname topologySpread, PDB minAvailable 1, worker `ak healthcheck` probes. **Unblocked by dropping the RWO media PVC** (it held only the initContainer-regenerated login-bg.png → emptyDir now; future real media = RWX/S3 decision, don't re-add RWO). In-cluster `/-/health/ready/` = 200.
- ✅ M115. authentik = 6th NetworkPolicy-enforced tier — DONE 2026-07-01 (`38da9a9`), verified: `15-tier-authentik.yaml` (ingress :9000 from traefik+blackbox-exporter+intra-ns; egress postgres :5432 + SES :587 + intra-ns; world :443 deliberately absent — update-check/analytics/gravatar all disabled). Full audit-toggle procedure: audit ON → label → 605 real flows observed, **0 would-be drops** → audit OFF → enforced-path verified (traefik-pod→authentik OK, probe_success=1, 0 DROPPED).
- ✅ M116. k8s-node automated security patching — DONE 2026-07-01 (`f4bc0dd`), applied to all 8 nodes + spot-verified: NEW `k8s-unattended-upgrades.yml` (Ubuntu -security pocket only, `Automatic-Reboot=false`) — **kured owns reboots** (existing deploy: concurrency 1, nightly 02:00-06:00 PT window, watches /var/run/reboot-required, cordon+drain). kubelet/containerd are kubespray binaries, not apt packages — untouchable by the security origin.
- ✅ M117. metrics-server — DONE 2026-07-01 (`727a40d`), verified: HelmRelease (chart 3.13.0, kube-system, kubelet-insecure-tls) — `kubectl top nodes/pods` now works cluster-wide.
- ✅ M118. Resource right-sizing — DONE 2026-07-01 (7d PromQL evidence), rolled + verified: velero node-agent 200m/256Mi→**25m/160Mi** (7d max incl. backups = 138Mi; freed ~1.4 CPU + ~0.8Gi schedulable); prometheus 512Mi req/2Gi lim→**2Gi/3Gi** (P95 1.83Gi — was <10% from OOM); alloy 128Mi→**384Mi** (P95 315Mi); tetragon 32Mi(kyverno-default)→**256Mi** (P95 219Mi; the HR requests hadn't been landing — fresh upgrade fixed it).
- ✅ M119. Backup thundering-herd stagger — DONE 2026-07-01 (`727a40d`,`6fa4f2d`), verified live: 7 s3-sync shares 01:00→01:50 at 10-min steps (scans suspended but slotted at 02:00); velero de-stacked to :00/:20/:40 (02:00,04:00 groups) + :00/:12/:24/:36/:48 (03:00 group).
- ✅ M120. ceph-csi codified + moved to its namespace — DONE 2026-07-01 (`8851750`), e2e-verified. Bigger than reported: the workloads (deploy/DS/SA/RBAC) ran 50d as an **out-of-band kubectl apply** (not in git at all), and the ceph-csi-ns configmap copy pointed at the **pre-VLAN-migration monitor 10.10.201.41** — a naive move would have broken all new volume ops. Codified the full stack from a cleaned live dump into `storage/ceph-csi/` (ns ceph-csi; git configmaps with the correct 10.10.210.41 overwrote the stale copy). Cutover: old deleted → Flux applied new → **one gotcha: the old pods' termination deleted the new registrar's socket** (plugins_registry emptied post-registration) → DS restart re-registered 5/5 → **acid test green** (PVC provision→attach→mount→write→delete all through the moved stack; 22 existing Bound PVCs unaffected). default ns now EMPTY + PSS enforce=baseline (adopted as a git resource in policy-baseline/); 50d rbd-test-pvc deleted; provisioner PDB moved with the workload.
- ✅ M121. Drift plan redaction — DONE 2026-07-01 (`35dce3a`): plan.txt redacted to structure-only lines (Plan: summary + resource headers) before artifact upload AND the drift-issue embed; attribute values no longer leave the run.
- ✅ M111. AWS cost spike root-caused + fixed — velero Kopia hourly maintenance → S3 request storm
- ✅ M110. AWS vpn+dns consolidation — COMPLETE 2026-07-02
- ✅ L25. DONE 2026-07-01 (`35dce3a`) — test-ssh-cert.yml deleted; permissions:{} on bootstrap-runner-key.yml.
- ✅ L26. automountServiceAccountToken sweep — DONE 2026-07-02: false on plex, wikijs, ollama, open-webui, technitium, home-assistant (rolled via Flux).
- ✅ L27. DONE 2026-07-01 (`35dce3a`), verified live: enforce=baseline on kyverno + plex (the plex "GPU needs privileged" note was STALE — device-plugin GPU, dry-run clean); pg-recovery ns deleted (held a stray csi-rbd-secret COPY — bonus credential cleanup).
- ✅ L28. DONE 2026-07-01 (`35dce3a`) — no_log on the 3 token-in-URL tasks; structurally verified every technitium_token task now carries it.
- ✅ L29. Loki per-stream limits — DONE 2026-07-01: per_stream_rate_limit 3MB/10MB-burst + 7d retention_stream for hubble-audit + tetragon export (selectors verified against the actual ruler rules). loki-0 restarted clean.
- ✅ L31. Minor hygiene batch — COMPLETE 2026-07-02: email_fwd abort-MPU + SSE-S3 blocks codified on all 7 default-reliant buckets (plan-gated `7 to add`, applied); WG-key item moot.
- ✅ L2. Regional VPN destroy doesn't drop the per-region Route53 record — CLOSED (moot 2026-07-01)


- ✅ **M106** (2026-06-30) — daily ~10:05Z vzdump-of-cp1 etcd stall → cluster lease-storm; operator excluded k8s-cp1/2/3 from the vzdump job.
- ✅ **M107** (2026-06-30) — weekly unattended doc/IaC drift audit on the devbox (scoped headless `claude -p`; GH-issue + SES report; off-box staleness alert).
- ✅ **M108** (2026-06-30) — Google Places API (New) key for Cue Find-food; feature live.
- ✅ **M77** (2026-06-28/29) — all 6 standalone VMs default-deny inbound (PVE VM firewall); asterisk SIP/RTP source-scoped to Twilio ranges — ⚠️ residual: **live inbound+outbound call test still required** to trust the RTP scoping (revert = `git revert bf906f3`); optional vpn-local WG `/32` source-scope.
- ✅ **L24** (2026-06-28) — MetalLB kubespray-native→Helm/Flux **FRR mode** + BGP **TCP-MD5** + `MetallbBGP*` alerts — optional not-done: BFD; a VLAN-201→VIP `/32 via .1` route for TS/WG remote clients.
- ✅ **M72** (2026-06-28) — PSA enforce=baseline rollout complete (15+3 namespaces; plex deliberately exempt; 7 orphan namespaces deleted).
- ✅ **M73** (2026-06-28) — Kyverno guardrails ENFORCE (`disallow-latest-tag`, mutate-default-requests, `require-resource-requests`) — ⏳ next: cosign `verifyImages` provenance policy (needs signing setup).
- ✅ **M74** (2026-06-28) — Tetragon detection pipeline live (4 TracingPolicies → Loki alerts; allowlist-limited export) — ⏳ optional: shell-in-container / kmod / mount policies; enforcement mode.
- ✅ **M76** (2026-06-26) — fleet SSH **cert-only** cutover (step-ca; static key removed from all 15 hosts) — residuals by design: cloud-init bootstrap seed + packer + appliance keys; ⏳ user removes the bootstrap-only `ANSIBLE_SSH_KEY` GH secret; the mini key copy rolls into [[M71]].
- ✅ **M103** (2026-06-25/26) — cairn native iCloud backup agent: cutover + CI signed release done; bash suite retired. Repo: [sparked-diamond/cairn](https://github.com/sparked-diamond/cairn); runbook `docs/runbooks/cairn-deployment.md`.
- ✅ **H30** (2026-06-24) — supply chain: 111 Actions SHA-pinned, SOPS checksum-verified, all 13 ImagePolicies digest-pinned (in-house `:main` + cue-api `:latest` accepted for now — do NOT "fix" cue-api).
- ✅ **M82** (2026-06-24) — Terraform is CI-only; devbox dropped standing AWS/PVE creds (dispatches via the M92 PAT).
- ✅ **M75** (2026-06-24) — IRSA in-cluster AWS workload identity; all workloads migrated, **no static AWS keys in etcd** — ⏳ residual: deactivate/remove the 4 orphaned dedicated IAM keys (NOT the H29 `terraform-homelab` key) — **2 of 4 DONE 2026-07-12** (`velero-backup` + `kubernetes-s3-backup` users/keys/policies deleted, M143); `barman-postgres` + `etcd-backup` remain (etcd-backup is the deliberate host-level static, M71).
- ✅ **M101** (2026-06-24) — VM auto-update gaps closed (devbox managed, full patch policy, node patch path).
- ✅ **M102** (2026-06-24) — Cue public internet access + Web Push.
- ✅ **M42** (2026-06-24) — UDM WireGuard cleanup + Vpn-zone tightened to admin ports.
- ✅ **M47** (2026-06-24) — `udm-firewall.yml` auth swapped to `X-API-Key` (password fallback kept) — ⏳ residual: add a `UDM_API_KEY` GH secret, then drop the fallback + `UDM_USERNAME/PASSWORD` secrets; URL migration deferred to UniFi ≥10.2.
- ✅ **M15** (2026-06-24) — Twilio 911: primary DID `emergency_status: Active` at the carrier, address validated; no apply needed — ⏳ residual (TF hygiene): confirm the address + DID are imported into twilio state at the next stack touch (M16/M17).
- ✅ **L19** (2026-06-24) — Telegram webhook auth check obsolete (surface retired; cue is behind CF Access).
- ✅ **H3** (2026-06-23) — NetworkPolicies: all 5 target tiers ENFORCED + drop alerting live (see CLAUDE.md §5 + `docs/runbooks/networkpolicy-tiers.md`).
- ✅ **H38** (2026-06-23) — Authentik SSO/IdP gating internal apps (OIDC + domain forward-auth).
- ✅ **M80** (2026-06-23) — iCloud Drive/Contacts/Calendars/Messages/Notes/Safari → NAS → S3 + dashboards/alerts — ⏳ residual: one-time operator sudo to bootstrap the `net.wind.nsmb-install` LaunchDaemon (see `infra/macos/mini/README.md`). (Now superseded operationally by cairn, M103.)
- ✅ **H39** (2026-06-18→22) — Velero fs-backup wedge reset + hardened; advisor email-flood residual resolved.
- ✅ **M97** (2026-06-22) — over-broad terraform-homelab IAM grants tightened + orphan-policy audit.
- ✅ **M100** (2026-06-22) — mini photos-export cluster-side observability.
- ✅ **M94** (2026-06-21) — S3 delete-guard + Cloudflare-Access approval flow live.
- ✅ **M95** (2026-06-21) — rclone gdrive/onedrive sync hardening.
- ✅ **M96** (2026-06-21) — iCloud Photos dedup (NAS + S3).
- ✅ **M98** (2026-06-21) — iam-apply workflow (remote apply of manually-managed IAM policies).
- ✅ **M99** (2026-06-21) — rclone-onedrive excludes the OneDrive Personal Vault.
- ✅ **M87** (2026-06-20) — cloudwatch-to-loki baked image (runtime pip eliminated).
- ✅ **M88** (2026-06-20) — OneDrive → NAS backup (rclone-onedrive); supersedes M78.
- ✅ **M89** (2026-06-20) — pve-ipmi TargetDown fixed (H37 firewall `pve-ipmi` allow — see CLAUDE.md §5 "THREE required allows").
- ✅ **M90** (2026-06-20) — CI drift detection extended to all TF stacks.
- ✅ **M92** (2026-06-20) — devbox GH dispatch PAT (Actions:write).

---

## 2026-06-23 aws-s3 adversarial review — open residuals

Full finding/fix table (AB-H1…AB-H5, most ✅) in
[`archive/outstanding-work-completed-2026-07.md`](archive/outstanding-work-completed-2026-07.md);
narrative in [`session-log.md`](session-log.md). Still open:

| ID | Finding | State |
|---|---|---|
| **AB-L4** | Mutable `:main` image tag for a delete-capable workload | ✅ CLOSED as accepted risk per **H30** (2026-06-24 in-house-`:main` stance — do not "fix") |
| **AB-H3b** | Fuller manifest-driven delete (drive deletes from the measured set) | ⏳ deferred follow-up to the conservative re-assert |
| **AB-L6** | "Object Lock" claimed in README but no `object_lock_configuration` in TF | ✅ codified in TF 2026-06-23 (`aws_s3_bucket_object_lock_configuration.archive`, M101) |

**2026-07-02 Fable-5 re-review** (narrative in session-log): shipped — REJECTED_HELD
status semantics (rejected-snoozed no longer reads as "awaiting approval"; FAILED
sync outranks held status), chat.db mid-run-modification downgrade
(`modifiedDuringRun`, skew-margined, exception-hardened, forensics kept — NB not
self-healing under `--size-only`), repaired the **settle-pass no-op** (re-HEAD
retries called verify-one.sh with the pre-a700b3f arg interface since 06-24),
daily-report held-pill consistency + "N holding deletions" header, `approvals/pending/`
30d TF lifecycle. **New residuals:** ⏳ **AB-R1** force re-upload (`aws s3 cp`) of
`modifiedDuringRun` keys once settled — until then a same-size mid-write rewrite
persists in S3 with only the degraded-email cue; ⏳ **AB-R2** churn-file residual:
real at-rest corruption of a constantly-churning file lands in the downgrade
bucket, never CRITICAL (needs a quiescent re-verify, e.g. the monthly validation
job on `modifiedDuringRunFiles`).

---

> 🗺️ **Forward-looking dev roadmap** (reliability · security maturity · platform/capabilities ·
> devex/automation/cost) lives in [`dev-roadmap-2026-06-11.md`](dev-roadmap-2026-06-11.md).

_ID provenance: the 2026-06-10 full-repo review introduced H29–H34 / M60–M68 / L16–L20; its
headline findings + "what's genuinely solid" list are preserved in the
[archive](archive/outstanding-work-completed-2026-07.md)._

---

## Open items

_Completed items' **full text** lives in [`archive/outstanding-work-completed-2026-07.md`](archive/outstanding-work-completed-2026-07.md)
(2026-07-01 extraction; last ~2 weeks summarized one-line-per-item above) and
[`archive/completed-2026-H1.md`](archive/completed-2026-H1.md) (2026-06-24 extraction). Older
pre-06 completions: [`archive/outstanding-work-snapshot-2026-05-31.md`](archive/outstanding-work-snapshot-2026-05-31.md).
This file foregrounds open/in-progress/gated work._

## HIGH — production-readiness; 1–2 weeks

### 🟡 H41. etcd apply-latency spikes → CP leader-components restart-looping — defrag DONE, disk fix windowed
- **🟢 PARTIAL FIX 2026-06-28 (commit `2d1a22c`).** Refined root cause: NOT ongoing elections (death-window
  10:00-10:14 logs showed **no leader changes**, raft term steady at 79). The real cause is **etcd
  apply-latency spikes** — bursts of 280-320ms `read-only range`/lease applies that **back up behind each
  other** until an apiserver lease `Put` exceeds its 5s deadline → the holder loses its lease + restarts.
  Two drivers found: (a) **etcd was 62% FRAGMENTED** (248MB on disk vs **95MB** in use) — bloated DB =
  bigger fsyncs/worse cache → **FIXED: rolling defrag (followers→leader) brought all 3 members to 97MB**,
  no disruption; (b) etcd's WAL shares the CP VM **root disk** (`/dev/sda1`, ~5-6ms writes, spikes under
  contention). etcd timeouts are already generous (election 5000ms / heartbeat 250ms); `etcdctl check
  perf` PASSES when isolated (13.8ms). **Added a staggered weekly defrag timer** (`playbooks/etcd-defrag.yml`,
  Sun 02:00/03:00/04:00 UTC per CP, never two at once) so fragmentation can't rebuild. Kyverno reports are
  NOT a significant load (386 polr / 2 ephemeral).
- **🔎 Storage is NOT the gap (checked 2026-06-28):** the CP VMs are on `local-zfs` = a **mirror of two
  enterprise Micron 7450 NVMe** (datacenter, **power-loss protection** → fast fsync), and the etcd zvol is
  already well-tuned (`sync=standard`, `logbias=latency`, 16K, compression on). So a "dedicated etcd disk"
  is NOT warranted — same good pool, only isolation, no media gain. **The actual lever is the VM I/O config:
  `iothread=0` on the CP `scsi0` disks** (scsihw is already `virtio-scsi-single`) → etcd's fsync shares the
  single QEMU main thread instead of a dedicated I/O thread. `etcdctl check perf` slowest was 13.8ms with
  iothread off; enterprise-NVMe+PLP should be sub-ms.
- **✅ iothread=1 DONE 2026-06-28 (commit `0e2469d`).** Added `iothread = true` to the CP `scsi0` disk in
  `infra/terraform/proxmox/k8s-vms/main.tf` (scsihw already virtio-scsi-single). Applied per-CP via the CI
  workflow `-target` (config-only, no reboot from the provider), then **rolling `qm reboot` to activate**
  (cp2→cp3→cp1-last, verified etcd quorum + node Ready + iothread live in each qemu process between steps;
  one expected re-election, term 79→80). **Durable in IaC:** TF declares it, full `terraform plan` =
  **"No changes"** (state reconciled), so any future apply/rebuild keeps it; iothread re-activates on any
  boot. (Workers left iothread=0 for now — they'd need a drained rolling reboot; revisit if needed.)
- **✅ etcd metrics scrape DONE 2026-06-28 (commit `2dfeef2`).** Enabled `etcd_metrics_port=2381` (kubespray
  inventory, durable) + rolling etcd restart; pointed kube-prometheus-stack `kubeEtcd` at the CP node IPs
  `:2381` over http (no client cert in a secret). All 3 targets `up=1`; **fsync p99 = 3.3–3.6 ms** (healthy
  baseline post-iothread/defrag; the alert threshold is 500ms). This activated the chart's **15 dormant etcd
  alert rules** (etcdHighFsyncDurations, etcdHighNumberOfLeaderChanges, etcdNoLeader, **etcdDatabaseHigh-
  FragmentationRatio** — which would have caught the 62% frag — etcdHighCommitDurations, etcdMembersDown, …)
  → H41's failure mode now auto-alerts.
- **⏳ Only remaining (minor):** **CSI VolumeSnapshot CRDs missing** (`snapshot.storage.k8s.io`) →
  csi-snapshotter error-spam (volume snapshots non-functional; RBD provisioning fine) — install the CRDs +
  snapshot-controller, or drop the unused sidecar. **Watch the scheduler/CM restart RATE over the next few
  days** (now defragged + dedicated I/O thread + monitored). The etcd-stability core of H41 is fixed +
  observable; this CRD cleanup is cosmetic. **Tier: now LOW.**
- **Original symptom (for grep):** kube-scheduler 54/71/74, controller-manager 43/79/87, csi-snapshotter
  17/23 restarts over ~4d; each dies on leader-election lease `context deadline exceeded` (5s `Put` to
  `coordination.k8s.io`). apiservers stable. Self-recovering, no outage. Full triage in session-log 2026-06-28.

### 🟡 M83. GPU dcgm-exporter wedge → empty GPU dashboard (recurrable) — REMEDIATED 2026-06-19
- **Source:** owner 2026-06-19 ("GPU dashboard has no data"). `nvidia-dcgm-exporter` on `k8s-gpu1` was wedged — `/metrics` timing out (`TargetDown`), `nvidia-smi` itself hung (D-state) → **GPU driver/DCGM wedged at the kernel level** (flaky since ~06-10 per its logs). Pod restarts can't fix it (old container stuck Terminating, new one re-hangs on the wedged driver). **GPU compute (ollama/Plex) was unaffected** — monitoring only.
- ✅ **Remediated:** rebooted gpu1 (Proxmox **VM 120**) via `qm shutdown --timeout 60 --forceStop 1 && qm start` (graceful-then-force → clean Ceph unmount, no stale-EIO). Post-reboot verified: operator-validator 1/1, dcgm serves metrics, `DCGM_FI_DEV_GPU_UTIL` live in Prometheus (target `up`), ollama/plex back clean. Runbook: [`../runbooks/gpu-dcgm-exporter-wedge.md`](../runbooks/gpu-dcgm-exporter-wedge.md).
- 🟡 **Durability gap (can recur):** the gpu-operator `ClusterPolicy.dcgmExporter` exposes **no `livenessProbe`**, so self-restart-on-hang isn't configurable via IaC (and a probe can't kill a D-state container anyway). Mitigation = the **`TargetDown` alert → advisor** (early warning) + the runbook (fast reboot). **If recurring:** investigate the NVIDIA driver/DCGM version for a kernel-wedge bug (ClusterPolicy `driver`/`dcgmExporter.version`), or add a node-level watchdog (nvidia-smi-hang → auto-reboot). **Effort:** S done; driver investigation M (only if it recurs).

### 🟡 M91. k8s-vms watchdog — bpg can't apply it; attached via pvesh; ACTIVATES on next reboot
- **Source:** 2026-06-20 drift review (`plan` = 0 add, 8 change: all 8 VMs `watchdog.action none→reset` + gpu1 `floating 8192→0`). The watchdog (i6300esb + guest daemon → auto-reset on hang; relevant to the GPU dcgm wedge) is a deliberate feature.
- ❌ **Dead end (lesson):** **bpg/proxmox 0.106 silently NO-OPs the `watchdog {}` block** — `apply` "succeeds" + reboots the VM but the device never lands in the config. Discovered the hard way: rolling-applied w4/w3/w2/w1/gpu1 (5 reboots, incl. recovering 2 incidents — a cue-db-1 stuck-shutdown + a detector-bug self-inflicted force-stop) and the plan STILL showed all 8 drifting + the configs had no watchdog. Stopped before the control planes.
- ✅ **Fixed (`0e80782`):** `lifecycle.ignore_changes=[watchdog]` on all 3 VM resources → plan now **"No changes"** (perpetual drift gone; [[M90]] sweep no longer false-flags k8s-vms).
- 🟡 **Device attached, but watchdog still NOT functional — BLOCKED on the kernel module.** Attached the i6300esb device to all 8 VM configs via PVE API `qm set --watchdog` (`current=[model=i6300esb,action=reset]`); cold-rebooted w4 to confirm qemu presents the PCI device in-guest (`0000:06:04.0` = 25ab ✓); guest daemon deployed+enabled on all 8. **But `/dev/watchdog0` never appears because `i6300esb.ko` is ABSENT from the node kernel** — `6.8.0-124-generic` ships only `softdog` + `wdat_wdt`, and `linux-modules-extra-<kernel>` does NOT provide i6300esb either (verified on w4: `find /lib/modules -name i6300esb*` = none). So the daemon runs inert; **the hardware watchdog has never actually armed.** A `modprobe i6300esb` ansible task was tried and reverted (`2642aa4`) — it FATALs the playbook ("Module not found").
- 🔎 **PARKED + investigated 2026-06-21. Root cause is mundane: `linux-modules-extra-$(uname -r)` is simply NOT INSTALLED on the nodes** (dpkg has no `linux-modules-extra*.list`; no installed pkg ships `i6300esb`). That package is exactly where Ubuntu ships `i6300esb.ko` — the base `linux-image`/`linux-modules` omits the less-common watchdog drivers. My earlier apt task silently no-op'd (didn't actually install it; investigate why — likely `apt-get update`/repo on the nodes). So this is **resolvable + standard**, not exotic.
- 📐 **Production-standard Proxmox VM watchdog (what we'll implement):** (1) attach emulated device `qm set <vmid> --watchdog model=i6300esb,action=reset` ✅ done; (2) guest: **`apt install linux-modules-extra-$(uname -r)`** → `modprobe i6300esb` + persist `/etc/modules-load.d/i6300esb.conf` ← the missing step; (3) feeder: the `watchdog` daemon (have it) OR systemd `RuntimeWatchdogSec=` (simpler, no daemon); (4) activates on the VM's next cold start (`/dev/watchdog0` appears → fed → armed). **Durability gotcha:** `-extra` must be reinstalled for every NEW kernel (kured/kubespray upgrades) or `i6300esb.ko` vanishes again — the node-provisioning role (kubespray bootstrap / k8s-node-fixes) should ensure it per-kernel.
- ⏳ **To resolve (deliberate, not urgent):** debug why `apt install linux-modules-extra-<kernel>` no-op'd on the nodes → make it actually install (verify via dpkg) → re-add the reverted `modprobe`+persist tasks → re-apply ansible → cold-reboot per node (kured-natural) → verify `/dev/watchdog0` + daemon armed on one node. Alternatives if `-extra` truly unavailable: `softdog` (guest-software, can't catch a hung kernel — weaker) or drop it (inert since inception → no regression). Drift already clean (`ignore_changes`); attached device harmless.
- **Lesson (CLAUDE.md §5):** ~7 node reboots + 3 incidents chasing this before finding the module was absent — **verify the kernel module is installed (`linux-modules-extra`) BEFORE attaching watchdog devices / rebooting.**

### 🟡 M93. UNAS nvme0 cache SSD — RECURRING controller hang (firmware/APST suspect, NOT wear)
- **Source:** UNAS Storage "At Risk" again 2026-06-21. **`nvme0` dropped off the PCIe bus TWICE** (Jun 19 ~11:04, Jun 20 ~21:35), same signature each time: `nvme nvme0: controller is down; CSTS=0xffffffff`, `Removing ... status -19`, `/dev/nvme0` gone, `md4` cache RAID1 degraded `[2/1] [_U]`. Data safe throughout (RAID1 survivor nvme1 + RAID6 `md3` intact). `unas-health` alert ([[M86]]) caught both (`UnasMdArrayDegraded`).
- 🔬 **Reassessed 2026-06-21 (owner pushback — likely FIRMWARE, not a failing drive):** `CSTS=0xffffffff` "controller is down" is a **power-state/APST hang, not media wear**; **nvme1 is pristine** (INTEL SSDPELKX010T8, 2% used, 0 media_errors, **0 error-log entries**); the NAS is lightly used; both drops are **post the Jun-19 firmware update** (`UNASPRO v5.1.19`); and **deep NVMe APST is enabled** (`default_ps_max_latency_us=100000`) — the classic trigger. nvme0's controller is so wedged a **PCI rescan can't re-probe it** (needs a power cycle), consistent with a deep-power-state lockup. So: firmware is the likely TRIGGER; nvme0 is the more-susceptible unit (could be a marginally weaker controller/slot, or identical model that just hangs first). **Couldn't read nvme0 SMART** (off the bus; rescan failed → needs a reboot).
- ⏳ **Resolve (firmware-first):** (1) **firmware rollback** to the pre-update version if UniFi allows, and/or **report to Ubiquiti** (NVMe APST regression: `CSTS=0xffffffff`, healthy SMART, light use, started right after v5.1.19). (2) **Test/confirm + mitigate APST:** on a reboot, nvme0 re-probes → read its SMART (expect healthy) → `nvme set-feature /dev/nvme0 -f 0x0c -v 0` (disable APST) → re-add to md4 → if it survives >24h with APST off, firmware/APST is confirmed. Persistent APST-disable is hard on the locked appliance (fixed kernel cmdline) → that's why rollback/Ubiquiti is the real fix. (3) Replace nvme0 only if it keeps dropping with APST disabled. **Don't blind re-add** (recurs ~daily).
- ✅ **Matched pair CONFIRMED (UI, 2026-06-21):** both `INTEL SSDPELKX010T8`, fw `VCV10352`, ~5,455 power-on-h, **98% lifespan each** (≈new). nvme0 = **M.2 SSD 1** (SN PHLJ241101…), nvme1 = M.2 SSD 2 (SN PHLJ132500…). **Identical, near-new drives where only one hangs → strongly firmware-APST, not wear.** Extra clue: nvme0 last read **63°C vs nvme1 45°C** (18° hotter) → a **thermal/slot factor** on M.2 SSD 1 (worse airflow → hotter controller → more prone to the deep-power-state wake hang). When the unit's open, check M.2 SSD 1's heatsink/slot airflow.
- ⏳ **Until fixed:** cache degraded on nvme1 alone (no redundancy). Optional: SSD cache → **read-only** (kills write-back risk); silence `UnasMdArrayDegraded` time-boxed if the reminders are noise.
- ➕ **2026-06-21 update:** nvme0 dropped a **3rd** time across a `systemctl reboot`; came back healthy (`percentage_used 2%`, `media_errors 0`, `critical_warning 0x2`=temp, `unsafe_shutdowns 7`) and md4 rebuilt `[2/2]`. SMART confirms wear is a non-issue — firmware/APST holds. Gotcha learned: a **raw `systemctl reboot` left the UNAS half-up** (web UI + ping, but SSH/NFS/SMB down ~minutes) while services restarted + the cache resync spiked load — prefer a UI/console restart. Thermal note revised: nvme0 ran **69°C** post-reboot → disabling APST (keeps it out of deep idle) would *raise* idle temp, so firmware rollback/airflow is the better durable fix than APST-off.

## MEDIUM — quality / hygiene

> M122+ from the 2026-07-02 currency/state review + path-loss investigation.

### 🟡 L33. WG HA-failover review — DONE 2026-07-02: architecture KEPT (it proved itself live today); 3 follow-ups
- **Verdict: keep the design.** The VRRP failover **fired for real during today's 1.34.3 rolling upgrade** (w2 drain took the K8s WG pod) and worked: vpn-fallback took VIP `10.10.201.20`, started wg0, and the AWS site-to-site stayed up (fresh handshakes verified). The three-path model is sound: K8s WG pod (HA across drains) → vpn-fallback VM (survives cluster-wide outages) → Tailscale mesh (independent third path; now healthy again post-L32 with BOTH local exit nodes live).
- **Backup readiness audited on-box:** keepalived active+enabled, wg0 config present, the tailscale-failover unit active. The 47-day dead-TS episode (L32) was the only rot — and nothing alerted on it.
- **Follow-ups:** (1) ⏳ **reclaim check** — the K8s WG pod has been Running ~2h without reclaiming the VIP from vpn-fallback (fine DURING the upgrade window — fewer flaps — but verify prio-150 preemption works after the 1.35 rollout settles; if nopreempt is set k8s-side, decide deliberately which behavior we want). (2) ⏳ **monitoring gap** — no alert on VRRP state or backup-readiness (keepalived/tailscaled/wg0-config on vpn-fallback); add node_exporter systemd-unit collectors + a `WgFailoverBackupNotReady` rule, and a "VIP holder changed" info alert. (3) ⏳ **quarterly failover drill** — stop the k8s WG pod, verify VM takeover + TS route flip, document in a runbook. **Effort: S each.**
- **Owner ask 2026-07-02.** Current design (`docs/architecture/vpn-wireguard.md`): VRRP/keepalived floats VIP `10.10.201.20` between a **K8s WG pod (primary, prio 150)** and the **vpn-local VM (backup, prio 100, nopreempt)**; on pod failure vpn-local acquires the VIP + starts wg0 (~10-15s). Questions to answer: (a) is the K8s-pod-as-primary-WG-gateway still worth the complexity vs running WG solely on vpn-local or the edge box? (b) vpn-local's TS daemon has been dead 47d (L32) — is the VM actually a healthy backup, or has the failover been silently single-homed on the K8s pod? (c) does the M110 edge-box consolidation + the in-cluster `k8s-homelab-router` TS subnet-router change what's needed? (d) could Tailscale (stable IPs, DERP) subsume the remote-access wg1 path? **Effort: M (design review).**

### 🟡 L34. Tailscale ACL model — explained; IaC adoption RECOMMENDED (needs an owner API key)
- **Explained:** node IPs are stable, and the tailnet grants by USER — any `sparked-diamond@`-owned device (abacus) inherits the owner's ACL grants + Mullvad exit-node entitlement on join; the remembered "add the Surface to the allowlist" was almost certainly one-time device APPROVAL (or a since-generalized ACL edit), not a per-device grant. Console-managed, not verifiable from the agent (no TS API key).
- **Recommendation:** adopt the tailnet policy (ACL + split-DNS + device-approval settings) into IaC — either the official `tailscale` TF provider (needs an OAuth client/API key as a GH secret, CI-only per M82) or a GitOps ACL file (tailscale.com/kb GitOps-ACL action). Prevents the next M127-class strand (console config drifting from reality invisibly). **Blocked on: owner minting a TS API key/OAuth client.** **Effort: S-M once keyed.**
- **Owner ask 2026-07-02.** The reformatted Surface laptop (now **abacus**, 100.95.15.104, Windows, `sparked-diamond@`-owned, online, using Mullvad exit nodes) joined + worked **without** the per-device allowlist step remembered from before. Hypothesis: the TS ACL grants owned/`autogroup:member` devices exit-node + subnet access broadly, so any new device under the same user inherits it — the prior "add the Surface" was likely a one-time **device approval** (if device-approval was on) or a now-generalized ACL entry. **The TS ACL is console-managed, NOT in git** (no tailscale TF module) — can't verify from the agent without the TS API. **Do:** review the tailnet ACL in the admin console to confirm the grant model; consider **adopting the ACL + DNS config into IaC** (ties to L32/M127 — a tailscale provider or API-driven config) so device-auth + split-DNS are reviewable/reproducible. **Effort: S-M.**

### 🟡 M129. Enable local TS exit nodes — k8s-homelab-router APPROVED; vpn-fallback advertising (owner console-approval pending)
- **Owner ask 2026-07-02.** Only `vpn-aws` currently "offers exit node". **k8s-homelab-router ALREADY advertises exitNode** in git (`platform/kubernetes/tailscale/connector/connector.yaml` `exitNode: true`; live Connector `ISEXITNODE=true`) — it just isn't **approved** as an exit node in the TS admin console (an advertised exit node must be admin-approved before clients can use it). **ACTION (console, user — no TS API key on the agent):** Machines → `k8s-homelab-router` → Edit route settings → approve **Exit node**. The **local** (vpn-fallback) exit node is blocked on **L32** (Tailscale is uninstalled there — reinstall first, then advertise `--advertise-exit-node` + approve). No repo change needed for the k8s one. **Effort: S (console).**

### ✅ H46. Dead-man's switch — DONE (watchdog-deadman + us-east-1 CloudWatch alarm)
- **2026-07-03 Opus 4.8 gap analysis #1 (verified):** `Watchdog` routes to `null`; the only human channel is SES email from the in-cluster Alertmanager; even `DocDriftAuditStale` rides the same pipeline. If Prometheus/AM/the cluster/SES dies → SILENCE. **Fix options:** (a) healthchecks.io ping from a Watchdog webhook receiver (needs owner account), or (b) fully self-hosted: a systemd timer on the AWS edge box queries the Alertmanager API for Watchdog over the tunnel and raises a CloudWatch alarm on absence (the box has a CW role; CW→SNS→email is already proven in external-monitoring). Prefer (b). **Effort: S-M. Tier: H.**

### ✅ M130. PVE host config + the single Ceph mon store have NO backup
- **Gap #4 (verified):** nothing backs up `/etc/pve`, the firewall residue, or `/var/lib/ceph` (mon store.db/keyrings/monmap). pve boot-disk loss = rebuild the storage backend from memory; mon-store loss = objectstore-tool archaeology. **Fix:** nightly timer on pve tarring `/etc/pve` + mon keyrings/monmap → offsite (UNAS or S3 — decide channel) + a "pve total loss" section in disaster-recovery.md. Orthogonal to L1. **Effort: S. Tier: M-H.**
- **✅ Done 2026-07-09 (`infra/ansible/playbooks/pve-config-backup.yml`, applied + verified live):** daily systemd timer on pve tars `/etc/pve` (+`/priv`), `/etc/ceph`, the Ceph MON store + bootstrap keyrings + an extracted monmap → **`/mnt/pve/sequoia-backups/pve-config/`** on the NAS (sequoia, already-mounted, SEPARATE hardware). ~3.4MB, keeps 14, `chmod 600`. **Zero AWS cost/egress** (config only, NOT the giant VM images). node_exporter textfile metric → `PveConfigBackupStale` (>36h, critical→email) + `PveConfigBackupNoMetric` (02-external-alerts). DR restore steps = disaster-recovery.md §6.2. Gotcha fixed: tar only existing paths (this host has no `bootstrap-mon` → tar rc=2 fatal). ✅ **Offsite-S3 tier DONE (2026-07-09, verified):** daily CronJob `backups/pve-config-offsite` (velero-dr dir) NFS-mounts ONLY the pve-config subdir → rclones to `s3://velero.wind.etherport.net/pve-config/` (reuses velero-dr-sync SA + IRSA wind-irsa-velero + rclone config — no new IAM; BSL reads only `dr/` so the sibling prefix is inert). Runs as 977:988 (tarball owner) + an empty-source guard (a failed NFS mount can't wipe S3). Alert `PveConfigOffsiteStale` (>36h). Test run uploaded 3.38MiB → confirmed in S3. **pve config is now full 3-2-1** (pve → NAS → S3).

### 🟡 M134. DMARC is p=none with NO rua — zero enforcement, zero visibility (BLOCKED at the receiver)
- **2026-07-09 investigation:** the CF `_dmarc` rua record is trivial (this repo), BUT self-hosted receiving is **blocked**: `etherport.net` has **no inbound MX** — the only MX is `mail.etherport.net → feedback-smtp.us-west-2.amazonses.com` (SES *feedback*, not `inbound-smtp`), and there is **no `aws_ses_receipt_rule` in this repo** (they live in the personal-web repo per the email-forward comment). Self-hosted reporting therefore needs (1) an **apex MX `etherport.net → inbound-smtp.us-west-2.amazonaws.com`** — an EMAIL-CRITICAL change on a live mail domain — + (2) a SES receipt rule → S3 (`dmarc/` prefix), likely coordinated with personal-web. **Not done unilaterally.** Operator decision needed: confirm the apex-MX won't disrupt current etherport.net mail, and whether the receipt rule lands here or in personal-web. Then rua record + p=none→quarantine→reject ramp.

### 🟡 M138. cairn iCloud backups broadly FAILING on the mini — needs operator (the daily "3 down")
- **Update 2026-07-11:** distinct from (and compounded by) M141 — the UNAS wedge took the SMB
  *destination* down 07-10→11 (now fixed); this item remains the iCloud *source* auth failure
  (app-specific password), still operator-gated. Re-check the category RCs once the mounts are
  back and the app-password is re-minted.
- **Found 2026-07-09** while sampling the daily status email ("3 down"): the Mac mini is **up and actively pushing** metrics (`mini_health_last_check` ~14 min old) but `mini_health_up=0`/`cairn_healthy=0`, and **8 of 9 cairn backup categories are failing** (`cairn_backup_last_rc=1`): `drive, notes, safari, messages, calendars, contacts, reminders, photos` — only **`messages_attachments` (rc=0)** succeeds. Last successes **~51–150h** stale. **Diagnostic pattern:** the ONE passing category reads LOCAL files; all 8 failing ones hit the **iCloud API** → almost certainly an **expired iCloud app-specific password / de-authed session** (`icloud_app_password` in the ops bundle) — or a post-OS-update TCC/keychain break. **Blocked:** the devbox cannot SSH to the mini (macOS user, not on the cert-only fleet — `Permission denied (publickey)`), so this needs the operator on the mini: check the cairn agent logs + re-mint the iCloud app-password (appleid.apple.com → App-Specific Passwords) and update it in 1P/SOPS. Runbook: `docs/runbooks/cairn-deployment.md` (M103). **Tier: M-H (data protection).**

### ✅ M131. kube-apiserver audit logs: enabled but local-only, unshipped, unwatched
- **Gap #5 (verified):** `kubernetes_audit: true` writes CP-local (30d/10 files) — no Alloy scrape, no Loki rules. Detection covers network (Hubble) + runtime (Tetragon) but is blind at the API layer (secret reads, RBAC grants, pods/exec); logs die with the node. **Fix:** Alloy hostPath match on CPs → Loki scoped retention_stream (hubble-audit pattern) + 1-2 ruler rules. **Effort: M. Tier: M.**
- **✅ Done 2026-07-09 (3f05e18, b260ca5):** Alloy tails the active file `/var/log/kubernetes/audit/audit.log` (in-container `--audit-log-path` maps there via the audit-logs hostPath) → Loki `job=apiserver-audit`; verified stream flowing. 2 conservative loki-ruler rules (`06-loki-rules-apiserver-audit`): `ApiserverAnonymousSuccess` (critical) + `ApiserverForbiddenBurst`. NB fixed a LogQL alternation-anchoring bug ([[logql-alternation-anchoring]]) that would've fired the critical on every health probe.

### ✅ M139. Anthropic "poor prompt caching" email — ai-advisor deep-mode re-billed its prefix
- **Found 2026-07-09** (operator forwarded an Anthropic prompt-caching notice). Root cause: the ai-advisor sent **zero `cache_control`**. Deep-mode (`_call_anthropic_with_tools`) loops up to `AI_DEEP_MAX_ITERATIONS=10` API calls per alert, each re-sending the identical `system` + ~1.8k-token tool schema at full input price (model `claude-sonnet-4-6`, cache floor 1024 tok — comfortably exceeded). **✅ Fixed (this session):** ephemeral `cache_control` breakpoint on the `system` block + the last tool → turns 2..N read the prefix from cache (0.1x); single-call `_call_anthropic` left UNcached on purpose (sparse → a write never read = 1.25x loss); `_add_cost` now prices cache read/write so the $0.50/day cap stays accurate; per-turn `cache_r` log line for verification. **Cross-repo:** the **cue-api** also calls Claude (separate repo) — if its prompts re-send a large stable prefix, apply the same `cache_control` there (owner action in that repo). **Verify:** next real deep-mode alert → advisor pod logs show `cache_r>0` on turn≥1.
- **✅ M139b (2026-07-09, operator-requested): tiered models.** Deep-mode (multi-turn root-cause + the `ai_remediation:auto` execute path) now runs on `AI_ADVISOR_MODEL_DEEP=claude-opus-4-8` for diagnosis accuracy + confidence calibration where a wrong auto-action costs; single-call stays Sonnet 4.6. **Cap unchanged ($0.50/day)** — `_add_cost` takes per-call prices and deep-mode passes Opus rates ($15/$75), so at cap the advisor falls back to raw-alert emails (fewer deep diagnoses/day, never a surprise bill). Live (advisor restarted; startup log `model=… (deep=…)`). We'll watch whether the cap bites.

### ✅ M132. Criticals have exactly ONE human channel (SES email)
- **Gap #6:** precedent: ~4k alert mails eaten by a junk filter for a week (2026-05-22). **Fix:** push receiver on severity=critical — self-hosted ntfy behind Traefik or Pushover. Pairs with H46. **Effort: S + a service/account decision. Tier: M.**
- **✅ Done 2026-07-09 (`platform/kubernetes/ntfy/`):** self-hosted **ntfy** + an in-house ~50-line `am2ntfy` bridge (ntfy has no native Alertmanager parser). AM `severity=critical` (continue:true → still emails) → bridge → ntfy topic `wind-critical` (urgent). Exposed **tailnet-only** via `loadBalancerClass: tailscale` + `tag:k8s` (the operator can't mint `tag:cluster-ingress` — ACL grants it to autogroup:owner only) → `http://ntfy.tail48f596.ts.net`, LB `TailscaleProxyReady`. **E2E tested** (AM-shaped payload → bridge HTTP 204 → ntfy stored the message). ⏳ **Operator one-time:** install the ntfy app, add that server URL, subscribe to `wind-critical` (see the dir README). Chose ntfy over Pushover (self-hosted, no account, no per-msg cost).

### ✅ M133. SSH-cert RENEWAL staleness unmonitored (StepCADown covers only the CA process)
- **Gap #7 (verified):** host certs 30d/renew-at-7d; the devbox 13h user cert renews via a timer with no success metric — a renewal failure while the CA is UP walks hosts silently toward SSH lockout. **Fix:** textfile-collector not-after metric per host + devbox renew-timer success timestamp + a <5d rule. **Effort: S. Tier: M.**
- **✅ Done 2026-07-09 (66be2c8):** `step-ssh-renew.sh` writes `step_ssh_cert_not_after_seconds` + `..._renew_last_success_timestamp_seconds` to a node_exporter textfile (instance=devbox); alerts `DevboxSSHCertExpiringSoon` (<4h remaining, critical→email; the on-disk metric keeps serving stale expiry when the loop stalls, so it fires ~3.5h pre-expiry) + `DevboxSSHCertNoMetric` (warning). Both PrometheusRules loaded + verified. Timer confirmed healthy at implementation time.

### ⏳ M134. DMARC is p=none with NO rua — zero enforcement, zero visibility
- **Gap #8 (verified):** etherport.net `_dmarc` = `"v=DMARC1; p=none;"` with no reports destination — and the estate's most plausible phish is a forged approval/alert email (the M94 S3-delete approval flow IS email). **Designed fix:** (1) rua target `dmarc@etherport.net` needs a homelab-side SES receipt rule (mirror personal-web's fwd_graham pattern: S3 prefix + extend the email-forward Lambda mapping — INBOUND_MAIL rule set is homelab-owned) or an external aggregator (+authorization TXT). (2) `rua=` into the CF `_dmarc` var. (3) After 2-4 weeks of reports: p=none → quarantine → reject on the sending zones. **Effort: S-M. Tier: M.**

### ✅ M140. AWS TF CI: PR-triggered `plan` assumes the same PowerUserAccess role as apply
- **✅ Done 2026-07-11 (dd7192c; applied via the new `terraform-github-oidc.yml`, run 29158373005):**
  `gh-actions-terraform-plan` role live — trust `repo:…:pull_request` only; ReadOnlyAccess + tfstate
  read + `*.tflock`-only writes + Deny on backup object-data / Secrets Manager / SSM SecureString /
  KMS decrypt (mirrors the M71 RA plan scope; verified no stack uses secret data sources). Main role
  trust now `refs/heads/main` only; 15 AWS workflows select the role by event (ternary); the
  github-oidc stack got its own plan/apply workflow (was bootstrap-only). Residual documented
  in-code: a PR plan can still read state-resident plaintext secrets — inherent to "can run plan".
  ⏳ Watch the next Renovate PR to confirm plans go green under the new role.
- **Found 2026-07-11 (repo audit M-1):** the `gh-actions-terraform` role trusts `repo:…:pull_request`
  (github-oidc/main.tf:74-82) AND carries `PowerUserAccess` (:100-102) — every AWS TF workflow uses
  this one role for both PR plan and dispatch apply. A PR-authored branch (or supply-chain PR) can
  execute arbitrary HCL (data sources, `external` provider) with a live PowerUser session during
  "plan", and TF state holds plaintext secrets. H43 fixed the *self-hosted in-network* side only.
  **Fix:** dedicated read-only plan role for the `:pull_request` trust sub; keep PowerUser bound to
  `refs/heads/main` + workflow_dispatch. Companion finding M-2 (unsafe `head.ref` interpolation into
  `github-script` in 13 TF workflows — the co-located injection sink) was **fixed same day** via
  env-var indirection. **Effort: S-M (TF github-oidc stack + 13 workflow role refs). Tier: M.**

### ✅ M141. UNAS dm-cache kernel wedge — ~30h total mini-backup outage (2026-07-10→11) + mount-nas deadlock fix
- **Incident:** sequoia wedged ~07-10 00:30 (NOT the NVMe bus-drop variant: both SSDs present, md4
  `[UU]`) — dm-cache kworkers in permanent D-state, load avg 437, SLUB vmap_area exhaustion; smbd
  accepted auth but sessions hung in I/O → the mini probe reported `smb_auth=0` → all cairn SMB
  backups down. Server-side proof gathered live (smbd logs, D-state census, tcpdump). Operator
  rebooted via console 07-11 ~05:12: clean 3.5-min recovery, no rebuild needed, all arrays clean;
  Garage/velero BSLs revalidated instantly.
- **Second bug found during recovery:** the mini's dead kernel SMB session (held by stale mounts)
  poisoned `smbutil`, which faked "Authentication error" WITHOUT any packet reaching the NAS
  (proven at smbd debug3 + pcap: TCP connects, zero session-setups; anonymous SMB3 from the devbox
  succeeded) — and mount-nas's auth-gate-first ordering deadlocked: bail on the phantom rejection,
  never reach its own force-unmount. **Fixed `5729808`:** stale-mount cleanup now precedes the auth
  probe; MiniSMBAuthRejected alert text documents both causes + the smbclient disambiguation.
  (The a33ab9f severity bump to critical, made by the overnight session, was correct and kept.)

### ✅ M142. technitium-1 admin credential diverged from the `technitium-admin` secret (~06-22)
- **Found 2026-07-11 (drift check):** technitium-1 had re-initialized on pre-rename state during the
  June Ceph incident — it still had only the old `admin` user (secret password), no `graham` user,
  and a stale server name — so the weekly `technitium-set-log-retention` CronJob failed silently for
  3 weeks (`Invalid username or password for user: graham`; TTL erased the failed Jobs). DNS serving
  itself was unaffected. **Fixed live:** created `graham` (Administrators) on technitium-1 via the
  API as `admin`, verified login on both replicas, re-ran the job — `[technitium-1] updated
  maxLogFileDays=365→7, maxStatFileDays=365→90` (it had also missed the retention hardening).
  ⏳ Residual: no alert covers this CronJob's success — candidate for a kube-state `job_failed` rule.

### ✅ M143. cloud-tag-drift red for weeks — 51 flagged; root-caused + resolved
- **✅ Teardown executed 2026-07-12 (operator-approved "delete all 5"):** the web agent disproved
  the personal-web premise — its providers ALWAYS had default_tags; the `public-web-vpc` family was
  **orphaned console-era WordPress networking** (verified EMPTY: 0 instances/ENIs/endpoints/EIPs) →
  **deleted** (VPC + IGW + 4 subnets + 3 RTs + 2 SGs, 12 resources). IAM fossils **deleted**: users
  `w3tc`/`velero-backup`/`kubernetes-s3-backup` (+ keys + inline policies, local key), 2× DataSync
  role+`service-role/` policy pairs, `VeleroBackupPolicy`, `s3-backup-kubernetes-policy`,
  `S3_stopthecastle` (via `aws-tag-manual.yml delete-fossils` — hardcoded one-shot; needed a
  non-default policy-VERSION purge first, now handled). us-east-1 KMS key **kept** (may protect old
  encrypted snapshots) + tagged manual — console review at leisure. ⏳ Green pending only AWS
  Config re-record (≤24h); check the next daily detector run.
- **Investigated 2026-07-12** (status email "Cloud tags" row down since the detector shipped). NOT
  one bootstrap residual — 51 resources in FOUR classes:
  1. **Config-blind false positives (~13, FIXED):** AWS Config configuration items carry NO tag
     data for `AWS::CloudWatch::Alarm` / `AWS::Events::Rule` (verified tagged `ManagedBy=terraform`
     live while flagged for weeks); `AWS::SES::ReceiptRuleSet` supports no tags; the per-region
     `default` EventBus can't be TF-managed → all four types allowlisted with reasons (`4bde045`).
  2. **Hand-made bootstrap (24, FIXED):** 9 IAM users + 2 S3 buckets (terraform-state,
     packer-autoinstall) tagged `ManagedBy=manual` via the local key; 9 policies + 4 roles needed
     `iam:TagPolicy/TagRole` (local key lacks it) → new **`aws-tag-manual.yml`** dispatch workflow
     (fixed modes: map-ids / tag-manual, charset-validated) runs them under the CI role. M75 orphans
     (`velero-backup`, `kubernetes-s3-backup` + `VeleroBackupPolicy`/`s3-backup-kubernetes-policy`)
     additionally tagged `Status=m75-orphan-pending-delete`; `w3tc` `legacy-pending-delete`.
  3. **personal-web repo resources (~14, CROSS-REPO):** `public-web-vpc` family, default NACL,
     us-east-1 KMS key, `INBOUND_MAIL` — that repo's provider has no `default_tags`. Handoff prompt
     delivered to the operator for the personal-web agent.
  4. **Stale SNS sub (bonus, FIXED):** external-monitoring re-applied → recreates the never-confirmed
     `email_backup` SNS subscription (07-08) — ⏳ operator must click the new confirmation email.
- 10/11 owning-stack plans were "No changes" — the re-apply theory was WRONG; tags were already
  live where TF manages them. ⏳ Residual: detector goes fully green only after (a) AWS Config
  re-records the IAM tag changes (≤24h) and (b) personal-web applies its default_tags. Delete
  decisions pending operator: w3tc, 2× DataSync role+policy pairs, M75 orphan users.

### ✅ L35. Credential inventory + rotation cadence for the never-expiring statics
- **Gap #10+#12:** age key (4 holders, never rotated), PVE/CF/UDM tokens, STEP_JWK_PASSWORD, SES SMTP, technitium/grafana admin — no born-on dates, no cadence; also the etcd secretbox key (enabled ✓ but static since install, on the CP disks it protects). **Fix:** `docs/reference/credential-inventory.md` (holder/born-on/last-rotated) + annual reminder + the etcd key-rotation procedure. Complements the NEW credential-expiry-check workflow (hard-expiry creds now metered). **Effort: S. Tier: L-M.**
- **✅ Done 2026-07-09 (4c2acb8):** `docs/reference/credential-inventory.md` — the consolidated MAP (what/where-held/consumers/rotation/blast-radius) across 12 categories, built from the live `*.sops.yaml` set + ops bundle; cross-linked with secrets-rotation.md (mechanics) + indexed. Born-on/last-rotated dates + the etcd secretbox key-rotation procedure are a follow-up (the inventory notes it stays static since install).

### ✅ L36. PSA: path from enforce=baseline to restricted for the easy namespaces
- **Gap #11:** many workloads already carry hardened securityContexts. **Fix:** add warn=restricted+audit=restricted labels (keep enforce=baseline), harvest violations, promote clean namespaces one at a time. **Effort: M. Tier: L.**
- **✅ Done 2026-07-09 (cc23092):** 9 namespaces whose live pods already pass `restricted` (verified via `enforce=restricted --dry-run=server`) graduated audit+warn→restricted, enforce left at baseline (non-blocking early-warning): authentik, cert-manager, cloudflare-ddns, cloudflared, cnpg-system, kyverno, postgres, traefik, unifi-cert-sync. The other baseline namespaces (dns/cue/ollama/wikijs/backups/rclone/auto-remediation/cloudwatch-to-loki) are baseline-clean but NOT restricted-clean (root/no-seccomp) → kept at baseline. Promotion to enforce=restricted is the future follow-on.

### ✅ M137. Durable fix for velero S3 egress — local-primary Garage on the NAS (3-2-1)
- **Why:** velero Kopia repo-maintenance (`"rewriting contents from short packs"`) DOWNLOADS repo content from S3 to repack → the 2026-07 egress ($75→$160; [[velero-kopia-maintenance-s3-cost]]). Fix = primary Kopia repo LOCAL, S3 = batched DR. MinIO rejected NFS ("insufficient drives online") → **Garage** (LMDB metadata on a 10Gi Ceph-RBD PVC + data blocks on the NAS/NFS).
- **Phase 1 DONE 2026-07-08:** `platform/kubernetes/garage/` — single-node Garage (uid/gid 988 = share owner), bootstrapped (layout + imported velero S3 key + `velero` bucket). 10MB PUT → NAS block ~90MB/s; small objects inline to RBD.
- **Phase 2 DONE + VERIFIED 2026-07-08:** velero default BSL → Garage (`clusters/wind/helm-releases/velero.yaml`, `velero-garage-creds.sops.yaml`, `checksumAlgorithm=""`, `s3ForcePathStyle`), old S3 BSL → `default:false accessMode:ReadOnly`. **Full PVC backup→delete-ns→restore round-trip byte-exact through Garage.** ⚠️ **velero got wedged mid-testing (rapid backup/delete/restart churn) → server backup/restore/schedule controllers stopped starting.** Fixed by a **helm CLI uninstall + Flux `forceAt` reinstall** (CRDs/BSLs/repos/336 backups survive) — GOTCHAS: (1) `helm uninstall` desyncs Flux helm-controller's cached state → it no-ops the reinstall; force with `reconcile.fluxcd.io/forceAt`. (2) an old S3 BSL survived the uninstall keeping `default:true` → had to re-patch garage=default. (3) right after reinstall, backups hang InProgress for a few min until the pipeline warms — then complete (~20s). Nightly schedules now target garage.
- **Phase 3 DONE + verified 2026-07-08:** `platform/kubernetes/velero-dr/` weekly rclone Garage→`s3://velero.wind.etherport.net/dr/` (IRSA `wind-irsa-velero` + new `backups:velero-dr-sync` sub; static GK key for the garage remote) → `dr/` Deep-Archive lifecycle @30d (delay dodges the churned-block early-deletion penalty). Manual run mirrored 93 objects; alerts `GarageRepoDown`/`VeleroDRSyncStale`. NB `archive.wind` = the NAS/iCloud s3-sync archive, kept SEPARATE. **All 3 phases complete — egress killed, 3-2-1 restored.** **Effort: S (Phase 3 only). Tier: M.**

### ✅ M136. Daily AWS cost reporting (Grafana + status email + spike alerts)
- **Why:** an S3 `DataTransfer-Out` spike ran ~a week (forecast $75→$160) and was caught ONLY by a manual console check — the sole cost signal was the single monthly AWS Budgets forecast email. **Built 2026-07-08:** `aws-cost-exporter` CronJob (monitoring, 05:30 PT) reads Cost Explorer + Budgets via IRSA (new `ReadCostExplorer` statement on `wind-irsa-cloudwatch-read`; ~$0.30/mo in CE calls) and pushes `aws_cost_*` gauges to Pushgateway → (1) "AWS Cost" Grafana dashboard, (2) Cost section in the daily service-status email (MTD, forecast vs budget, top services, spikes), (3) alerts `AWSCostForecastHigh` / `AWSServiceDailyCostSpike` / `AWSCostExporterStale` (`15-aws-cost-alerts.yaml`). Exporter verified against live CE (MTD $42.99, forecast $159.94, S3 $36.84). **DONE + verified 2026-07-08:** cluster-irsa applied (IRSA CE grant live); manual exporter run pushed metrics → Prometheus scraped (MTD 42.99, forecast 159.94, 12 svc); email Cost section + Grafana dashboard + alerts all render. AWSCostForecastHigh fires now (forecast $160 > $75 budget = the real ongoing egress overage; auto-resolves as it decays). README: `platform/kubernetes/monitoring/aws-cost-exporter/`. **Effort: done pending apply-verify. Tier: M.**

### 🟢 M135. cloud-tag-drift resolved (pending AWS Config catch-up)
- **2026-07-08 done:** (1) detector reworked to exclude AWS-managed/untaggable resources — type allowlist + arn exclusion (service-linked roles, AWS-managed policies) + `configuration.keyManager==AWS` (AWS service KMS keys). (2) **Both default VPCs DELETED** (us-west-2 vpc-85fefdfd + us-east-1 vpc-2725525a — verified EMPTY: 0 ENIs/instances/non-default subnets; removes ~22 default-VPC resources + is a security win). (3) **Re-applied 4 lambda stacks** (ddns-lambda/email-forward/homeassistant-alexa/twilio-webhook — plans confirmed tags-only, `+ManagedBy` on their Lambda/IAM/CW/APIGW/Secret). (4) 8 stacks already fully tagged ("No changes"). **Count 228 → ~71** once AWS Config catches up (its recording lags the VPC delete + tag applies by ~1h; a re-run mid-morning shows the true number).
- **Residual = the ~51 `terraform-homelab` BOOTSTRAP IAM** (29 policies, 9 users, 8 roles, 5 groups) — hand-created per `iam-policies/README` (chicken-and-egg: TF needs an IAM identity to run). The detector *correctly* flags these as unmanaged. **DONE 2026-07-08:** tagged 20 bootstrap customer policies `ManagedBy=manual` (users/roles already carried a ManagedBy tag); detector now excludes `ManagedBy=manual` + allowlists `AWS::IAM::Group` (IAM groups can't be tagged at all).
- **Also DONE:** applied `external-monitoring` → recreated the missing `email_backup` SNS subscription (2nd alert-email channel) — ⚠️ a confirmation email was sent to the backup address and MUST be clicked to activate. **⏳ AWS Config recording lag:** the live detector still reads ~103 because Config hasn't re-snapshotted the default-VPC deletions + the ~35 tag changes; the next scheduled run (or ~a few hours) shows the true near-zero. If a residual persists, it's a handful of genuinely-unmanaged items (a couple S3 buckets / the default EventBus) to spot-check. **Effort: done pending Config sync. Tier: M.**

### ⏳ M124. WAN path-loss waves — instrumented, not yet root-caused
- **State 2026-07-02:** NOT the box (ENA counters 0 post-resize; 274 scrape flaps in 12h anyway), NOT MTU (20/20 large-payload when calm; wg 1420 both ends), NOT SG/fail2ban/egress-IP. Waves hit BOTH the wg-tunnel and public paths; 90-min mtr windows when calm show 0% loss on every hop incl. control ⇒ **ISP/WAN-side, intermittent, hours-scale**. Continuous detector = `AWSReplicaHostFlapping` (fires during waves). **Next:** when it fires, capture mtr from BOTH ends immediately (runbook-able; consider auto-capture triggered by the alert), correlate wave timestamps against ISP/UDM WAN events (dual-WAN failover logs?). **Effort: M (mostly waiting for a wave).**

### ⏳ M126. Structural improvements from the 2026-07-02 state review (operator to prioritize)
- (a) **kube-vip HA API endpoint** (ARP mode on VLAN 201 — NOT BGP per the VIP gotcha); do with the 1.35 upgrade window. (b) **Split the Flux mono-Kustomization** into layered Kustomizations with dependsOn/healthChecks (one bad manifest currently freezes ALL reconciliation). (c) **PVE memory ceiling decision** — ~85/93 GiB committed; growth is now RAM-gated (cheaper than the L1 second node). (d) Cilium lifecycle ownership in git (values snapshot + upgrade runbook). (e) Spegel pull-through cache (L). (f) PG 16→18 plan piggybacked on the M12 restore drill (L). (g) file the bpg watchdog bug upstream (verified unreported; L). (h) IPv6 stance doc (L). Full detail: session-log 2026-07-02.

### ⏳ M6. Packer + ansible netplan dedup (F1.3)
- Source: `archive/outstanding-work-2026-05-16.md` M6.

### ⏳ M10. Lifecycle / `ignore_changes` on Proxmox K8s VMs (F1.5)
- Source: `archive/outstanding-work-2026-05-16.md` M10.

### ⏳ M11. DR runbook with measured RTO/RPO targets
- Source: task #23. Needs your judgment on targets before measurement.

### ✅ M12. CNPG restore drill — restore PROVEN end-to-end (barman)
- **2026-07-09 lightweight validation (backups ARE restorable-in-principle):** both CNPG clusters healthy (cue-db 1/1, postgres-cluster 3/3); daily barman backups all `completed`; **30-day continuous recoverability window** (firstRecoverabilityPoint 2026-06-09) with `lastSuccessfulBackup` = today on both. So a base backup + continuous WAL archive exist + are current. ⏳ **Still pending = the definitive proof:** a full `bootstrap.recovery` into a SIBLING cluster in a temp namespace (validates the actual WAL-replay path end-to-end). Non-destructive; deserves a focused run.
- **✅ Restore PROVEN 2026-07-09:** ran the real barman tooling from the live `cue-db-1` pod (trusted IRSA): `barman-cloud-backup-list` returned the full 14-backup catalog from S3, and **`barman-cloud-restore` of the latest base backup fetched + AES256-decrypted + gunzipped + assembled a VALID PGDATA** to a scratch dir on the PVC (PG_VERSION 16; base/global/pg_wal present; 4 databases; **`pg_controldata` reads a coherent control file** — "cluster state: in production", valid checkpoint) → a genuinely startable data directory. Scratch cleaned; live untouched. This exercises the exact fetch→decrypt→assemble restore path. **Remaining 5% (optional):** a live SIBLING cluster accepting connections + WAL-replay-to-target needs a 1-line addition of `system:serviceaccount:cnpg-drtest:<cluster>` to the `barman` role `subs` in `infra/terraform/aws/cluster-irsa/main.tf` (the recovery pods' new SA isn't in the trust today) — worth adding as standing infra if the RTO/RPO drill (M11) becomes recurring.
- Source: task #24. Destructive test; needs supervision and maintenance window.

### ✅ M14. Investigate aws-s3-sync daily-report SSL mismatch (if recurs)
- **✅ Closed 2026-07-09:** not recurred — 0 SSL/TLS/x509 errors in the `backups` namespace over the last 7d (Loki). "Only act if it recurs" → nothing to act on; close.
- Source: task #25. Only act if it recurs.
- **Note on ID:** the *archived* outstanding-work-2026-05-16.md used M14 for a UDM WireGuard cleanup item; some older cross-references (e.g. `docs/architecture/firewall-zones.md`) still point at that older meaning. To disambiguate, that WireGuard cleanup is now M42 (below). The two are unrelated.

### ⏳ M16. Twilio Talk: route or release orphan DID
- Source: task #21. Out-of-band.

### ⏳ M17. Twilio Talk: migrate SIP trunk UDP → TLS+sRTP
- Source: task #22. Out-of-band.

**Evidence / loose end (spotted 2026-06-12 in Loki):** the UDM logs a recurring
`ubios-udapi-server ... firewall: Destroying set(s) unifi_talk_addresses, unifi_talk_ports failed and will retry soon: command ipset ...`
(seen 06-05). The Talk firewall ipsets fail to tear down cleanly — likely
stale Talk firewall state on the UDM. Worth clearing while doing the Talk
work above (M16 DID release / M17 SIP migration) so the sets aren't
orphaned. Not service-affecting on its own.

### ⏳ M58. Periodic: recheck for a UDM BGP config API → promote UDM BGP to IaC
- **Source:** 2026-05-31 (BGP Phase C/D). The MetalLB↔UDM BGP works, but the **UDM side is UI-only** — UniFi Network 10.4.57 exposes no usable API endpoint for the BGP/FRR config (`rest/routing/bgp` + `stat/routing/bgp` empty, `get/setting` + device object + v2 routing paths don't carry it). So it can't be a `udm-bgp.yml` Ansible push; durability today = git-stored FRR config (`docs/runbooks/bgp-phase-c-udm-metallb.md`) + the daily controller backup.
- **Action (cadence = on each UniFi Network upgrade; the API only changes with releases — a time-based cron is the wrong tool, it'd expire):** re-probe those endpoints; if one now returns/accepts the BGP config, write `udm-bgp.yml` (the `udm-firewall.yml` pattern) and promote the UDM BGP to full IaC.
- **Effort:** S to recheck; M to build the playbook once an endpoint exists.

### ✅ M35. Wire a public IP as 3rd DHCP DNS resolver
- **✅ Done (verified 2026-07-09):** the tertiary resolver is LIVE on all 7 tenant VLANs — `dns_servers = [10.10.201.5, 10.10.201.6, 44.240.60.80]` in the fork `infra/terraform/unifi/networks.tf` AND confirmed on the live UDM (Management/Servers/Clients/IoT/vSAN/Unifi/Ceph). NB the IP is the M110 consolidated edge `44.240.60.80` (vpn-aws, runs Technitium), NOT the destroyed dns-aws `52.40.219.113` this entry originally named. Cutover landed via M110 (direct API PUT) + M125 (nested dhcp_server schema).
- **Source:** user ask 2026-05-23. Rationale: with `.5` (Technitium cluster VIP) primary + `.6` (dns-fallback VM) secondary, any combined outage of both the K8s cluster + the on-prem fallback + the AWS WG tunnel leaves clients with no DNS. Wiring dns-aws's public IP (currently `52.40.219.113`, the EIP of the dns-aws EC2 instance) as a 3rd DHCP DNS gives clients a path over the public internet even when the tunnel is down.
- **Already in place:** the `dns_server` SG on AWS allows port 53 TCP+UDP from the homelab WAN IPs (`66.215.210.75` + `47.159.189.5`), kept in sync with `wan1`/`wan2.wind.etherport.net` Route53 records by the dns-restrict-ip Lambda. So clients reaching `52.40.219.113:53` from the homelab WAN will succeed.
- **Fix:** for each tenant VLAN with DHCP DNS set to `.5/.6` today (Management, Servers, Clients, IoT, vSAN, Ceph, Unifi per M25 audit §1.6), add `52.40.219.113` as a 3rd entry. UDM UI per-network or via the `paultyng/unifi` TF provider if codifying. Skip Guest (already uses public DNS by design).
- **Effort:** S — UI clicks or one TF block per network.

### ⏳ M105. Switch-port security cleanup (Default/199 unused-port risk + exposed outdoor switches)
<!-- renumbered from M103 (ID collided with the cairn backup agent); kept stable as M105 since 2026-06-26 -->
- **Source:** owner 2026-06-24 (network-hardening pass). Confirmed via UDM API: **Default/199 has 0 of 102 active clients** (unused except `.1` transit/route). Risk: **~33 unused/down switch ports** fleet-wide default to Default/199 (Internal trusted-transit zone), and **no "Disabled" port profile exists** — a device on an open jack lands on trusted-transit. Can't fix via the `Internal` zone (it carries the zoneless switch-routed VLAN transit) — fix is at the **port level**.
- **Plan (UI / future unifi-TF port profiles):** (1) create a **Disabled** port profile, apply to all unused ports (prioritize the **physically-exposed** switches — Driveway, Access Road, Outdoor Junction, Chapel, ua-gate; task #18). (2) **Per-port VLAN minimization** — camera→Security/205, outdoor AP→its SSID VLAN, ua-gate→dedicated Access VLAN (a hijacked port then lands in an already-isolated/zoned VLAN). (3) **802.1X + MAC-Auth-Bypass** via RADIUS (only the "Default" placeholder profile exists today) — known MAC→VLAN, unknown→quarantine/deny; MAB is spoofable so VLAN confinement is the real control. (4) L2: DHCP guard/snooping, port isolation, loop/storm control. (5) Physical: lockboxes, device password, SSH off. **Effort:** S (disable unused + VLAN-min, UI) + M (802.1X/MAB project).

### 🟡 M104. Security/205 (SimpliSafe) — HALF DONE: isolation disabled; DHCP DNS still pending (owner: FIX)
- **Source:** firewall-zones anomaly #1. **✅ Network Isolation is now OFF** (verified live 2026-06-29 by the doc re-audit: `network_isolation_enabled=false`) — the zone model is sole enforcement. **⏳ Remaining:** DHCP DNS is still empty (`dhcpd_dns_enabled=false`) → SimpliSafe gear still has no LAN resolver. **Action (UI — `unifi` TF provider lacks `network_isolation_enabled`; 205 not in TF):** set the Security network's DHCP Name Server to `10.10.201.5`,`10.10.201.6`. firewall-zones.md already updated to match live.

### 🟡 M109. Full infra health check 2026-06-30 — 3 high fixed; AWS t4g right-size open
- **Source:** operator-requested full health check (8-agent parallel sweep). Storage / networking (Cilium+BGP+DNS) / certs-PKI / backups all **healthy**. Found **0 critical, 3 high** — all resolved this session (`46371c3`):
  - **(A, DONE) DocDriftAuditNoMetrics false-critical** — my #41 bug: the textfile `.prom` was written 0600 by `mktemp`, so node_exporter (its own uid) got permission-denied → metric dark + pending critical. Added `chmod 0644 "$tmp"` before the `mv` (+ live-chmod'd; `node_textfile_scrape_error=0`).
  - **(B, DONE) AWS replica scrape-flap false-pages** — dns-aws/vpn-aws (t4g.nano) suffer brief per-instance **ENA-allowance packet blackouts** (flap node_exporter 600+x/24h, *independently* — never together, so NOT the tunnel/WAN; the WG tunnel is pristine, no OOM). Scoped `ExternalHostDown`/`TechnitiumExternalHostDown`/`VPNGatewayDown` to `location="local"`; added `AWSReplicaHostDown` (location=aws, **for:15m** — only sustained pages) + `AWSReplicaHostFlapping` (warning, dashboard-only). DNS service itself is FINE (dns-sync syncs, dig answers) — monitoring-visibility, not an outage.
  - **(C, DONE) recurring daily ~10:00 UTC etcd stall → cluster-wide leader-election cascade** (~129 restarts/24h across kcm/scheduler/cnpg/csi/cilium-operator, 06-28→06-30) — **RE-DIAGNOSED**: the slow etcd keys are `/registry/reports.kyverno.io/ephemeralreports/backups/*` + policyreports, with etcd fsync p99 **3.5ms (fast)** → it's a **Kyverno ephemeralreport write-storm** saturating the raft pipeline (triggered by the 10:00 backup/CronJob fan-out), NOT (primarily) the M106 vzdump disk stall. **Fix:** Kyverno `features.admissionReports.enabled=false` (reporting-only; verified `--admissionReports=false` on both controllers + enforcement intact: `:latest` still rejected, mutate still injects requests; ephemeralreports 46→1). Onset coincides with Kyverno install (~6d ago) — strong signal. **M106 vzdump exclusion is complementary; verify BOTH at the next 10:00 UTC window.**
- **Follow-ups:** (1) **⏳ AWS t4g.nano right-size** — the real fix for the flap is bumping dns-aws/vpn-aws to t4g.micro/small (or reducing per-host pps); needs AWS access (TF apply on the regional-vpn stack + a cost decision) — the alert de-flap (B) is the interim. **Reminder set for 2026-07-02.** (2) **✅ Kyverno admission HA DONE 2026-07-01 (`bef7636`)** — `admissionController.replicas: 2` + PDB minAvailable=1 + antiAffinity (pods on k8s-w1+w3); removes the single-pod fail-closed-webhook blackout that amplified the cascade. Enforcement verified intact. (3) low/info hygiene (unchanged): csi-snapshotter CRDs absent (noise; snapshots unused), ceph-csi pods lack resource requests (audit warning), Prometheus-0 at ~80% mem. Full findings: health-check workflow output (session 2026-06-30).

### 🟡 M41. Plex log centralization + AI-augmented alert remediation
- **Done partial:** 2026-05-23 (commits `77a9ee0` `30d7f20` `062b3b1`).
- **Phase 1 of the advisor SHIPPED but is OFF by default.** Controller pod is rolled with the new code, prompt ConfigMap, two SOPS-encrypted secret placeholders (anthropic-api-key, smtp-credentials), and `AI_ADVISOR_ENABLED=false`. To turn on: see `docs/runbooks/archive/ai-advisor-phase1-enable.md`. Requires (a) creating a dedicated Anthropic API key, (b) populating the two SOPS secrets, (c) flipping the deployment env. All three need user action — Anthropic console isn't agent-accessible, and the existing SMTP creds can't be auto-mirrored cross-namespace without writing plaintext to disk (correctly blocked by the sandbox).
- **Plex sidecar:** Plex writes its real logs to `/config/Library/Application Support/Plex Media Server/Logs/*.log` not stdout, so the cluster-wide Alloy scraper had been seeing only the s6 init lines. Added `logtail` busybox sidecar to `platform/kubernetes/plex/02-deployment.yaml` that mounts the config PVC read-only and `tail -F`'s the log dir. Logs now query as `{namespace="plex", container="logtail"}`. **Immediate win:** centralized logs caught a real Plex config bug — `ERROR - Error parsing allowedNetworks entry ' 10.10.201.0 24': Invalid argument` repeating ~constantly. The space-separated entries look like Plex Web UI Library Settings → Network → "LAN Networks" was set with `; ` separators colliding with the env-var `ALLOWED_NETWORKS` setting. Tracked as L6 below.
- **Syslog labeling:** Alloy now promotes `__syslog_message_hostname` / `app_name` / `severity` / `facility` and `__syslog_connection_ip_address` to real Loki labels (`host`, `app`, `source_ip`). Required the `relabel_rules = loki.relabel.X.rules` pattern on the syslog source itself (not a downstream `forward_to` chain — first attempt got that wrong; fixed in `2839623`). Confirmed: `host` label values now include `UDM-Pro-Max`, `AMI9C6B006A1B39` (PVE BMC), `APBasement`/`APDeck`/`APDownstairs`/`APDriveway`/`APWorkroom`.
- **AI advisor spec:** `docs/planning/archive/ai-alert-remediation-2026-05-23.md` — full design for extending the existing M8 auto-remediation webhook with a Claude API path that handles alerts falling through the rule-based dispatch. Three-mode safety model (advisory/propose/auto), hard guardrails enforced in code not prompt, ~$5/mo cost estimate. Phase 1 (advisory-only) is ready to build pending user decisions on Slack-vs-email sink + API key.
- **Open:** build Phase 1 of the advisor. ETA 1 week of implementation.

### ⏳ M51. UniFi Talk IaC — DEFERRED pending public API
- **Source:** 2026-05-26 research during Twilio Talk #22 work. Investigated whether UniFi Talk 3rd-party SIP provider config can be managed as IaC; conclusion = no public API exists today, and reverse-engineering the `/proxy/talk/...` endpoints is feasible (1-2 days) but undocumented (Ubiquiti can change them silently on any upgrade).
- **Decision:** wait for Ubiquiti to ship a public Talk API. Track via the open community feature request. Until then, the SIP provider config in [twilio-talk.md](../runbooks/twilio-talk.md) is the source-of-truth (UI-managed, documented).
- **Trigger to revisit:** Ubiquiti announces Talk API support.
- **Effort when unblocked:** ~1 day to write the playbook.

### 🟡 M61. Expand pre-commit + Renovate coverage
- Review 2026-06-10. ✅ **Landed 2026-06-10:** `terraform_tflint` (+ minimal `.tflint.hcl`) + `shellcheck` pre-commit hooks.
- ✅ **Done 2026-06-17:**
  - **SOPS centralized:** the 3 terraform workflows that still curl'd SOPS inline (`terraform-drift-detection`, `terraform-aws-us-east-1`, `terraform-regional-vpn` — all `ubuntu-latest`/amd64) now `uses: ./.github/actions/setup-sops` (pinned + **checksum-verified**, single source of truth for the version). Also closes the H30 "wire 3 workflows to setup-sops" deferred item. (Verified: 0 inline `releases/download/v3.9.4/sops` curls remain in `.github/workflows/`; YAML lints clean.)
  - **Renovate coverage:** enabled the `pre-commit` **manager** (off by default → now bumps the 4 externally-pinned hook repos: pre-commit-terraform, yamllint, shellcheck-py, gitleaks); added explicit `packageRules` grouping the `github-actions`, `terraform`, and `pre-commit` managers into tidy per-area PRs. (`github-actions` + `terraform` managers/datasources were already active via `config:recommended` — now intentionally grouped.) renovate.json validates.
  - **ansible-runner Dockerfile:** can't reuse the composite action (it's a build, not a workflow) + is arch-dependent; already pinned to the same `v3.9.4`. Added a sync-pointer comment to `setup-sops` (the canonical version) + a `TODO(M61/H30)` for per-arch sha256 verification.
- ⏳ **Remaining:** `ansible-lint` pre-commit hook — still deferred (needs a baseline-noise suppression pass first or it floods every commit). **Effort:** S remaining.

### 🟡 M63. k8s manifest hardening sweep
- Review 2026-06-10. Per-workload gaps: (a) `cloudflared` ServiceMonitor missing `release: monitoring` label → metrics never scraped; (b) `rclone-gdrive` CronJob has NO securityContext (runs root); (c) no `startupProbe` on slow-boot workloads (technitium DNS, home-automation, wikijs, ollama) → restart risk mid-rollout; (d) no PDB for 2-replica `cloudflared`; (e) home-automation `privileged: true` → scope to explicit caps + device mounts. Small per-file fixes; template the hardened securityContext (cue-api/cloudflared already do it right). **Effort:** M (sweep).
- 🟡 **Done 2026-06-17 (safe trio a/b/d):** (a) added `release: monitoring` to the cloudflared ServiceMonitor; (b) added a **conservative** container securityContext to the rclone-gdrive CronJob (`allowPrivilegeEscalation: false` + `capabilities.drop:[ALL]` + `seccompProfile: RuntimeDefault`; deliberately **NOT** `runAsNonRoot`/`readOnlyRootFilesystem` — rclone writes its working config to an emptyDir and the image's user expectations are untested, so those stay off to avoid breaking the nightly sync); (d) added a `minAvailable: 1` PDB for the 2-replica cloudflared Deployment (`platform/kubernetes/cloudflared/03-pdb.yaml`). All three `kubectl kustomize`-validated.
- ⏳ **Deferred (need care, not "safe trio"):** (c) `startupProbe`s — technitium is the cluster's split-horizon DNS; a misjudged probe could wedge DNS mid-rollout, so this needs per-workload boot-time measurement first. (e) home-automation `privileged: true` → explicit caps + device mounts — needs the owner's knowledge of exactly which host devices (Zigbee/Z-Wave USB, etc.) HA needs before narrowing, or it'll break device access.
- 🟡 **More (2026-07-09):** added the conservative container securityContext (`allowPrivilegeEscalation:false` + `drop:[ALL]` + `seccompProfile:RuntimeDefault`) to the **remediation-controller** (userspace kubectl/paramiko/boto3 — no caps/priv-esc needed; NOT runAsNonRoot since it `pip install`s at boot as root). A cluster-wide `allowPrivilegeEscalation:false` scan found ~15 more app workloads lacking it, but most are infra that legitimately needs privilege (ceph-csi, metallb frr, wireguard, tailscale operator, gpu-operator); the remaining apps (garage, ollama, plex, wikijs, open-webui) each carry a small per-workload restart/break risk → harden incrementally as touched, not in a blind sweep (garage is the velero backend — left alone). L36's `warn/audit=restricted` labels already surface these as PSS warnings.

### ⏳ M64. Image-pinning model — pick one and apply repo-wide
- Review 2026-06-10. Mixed: 18 manifests auto-update via Flux `$imagepolicy`, ~10 use hardcoded floating tags. Decide canonical (Flux ImagePolicy+digest everywhere, or pin-by-digest + manual bump) and apply; document which apps auto-update vs frozen. Ties to **H30**. **Effort:** M.

### ⏳ M70. Protect webhook follow-ups (after the 2026-06-15 fix)
- **Confirm all 5 Alarm Manager URLs flipped** to `http://10.10.201.70:8088/api/webhook/<id>` (IP-literal + plain-HTTP — Protect's hostname-webhook bug). Owner updated some via the Protect UI; verify none remain on `https://`/hostname or the old `https://10.10.202.25/...-bY8...`. **UI-only** (no Protect write API for Alarm Manager). Test after dark — the automations carry a `condition: sun` (sunset→sunrise) so daytime tests won't actuate lights (by design).
- **(optional)** add the `protect-tf` 1P key to the SOPS bundle for headless Protect *integration*-API reads (camera/motion state into HA). Read-only; not needed for the webhook fix.
- **(optional, owner-declined)** source-lock the `:8088` route to Protect's IP. Blocked by Traefik LB `externalTrafficPolicy: Cluster` (SNATs client IP → `ipAllowList` 403s). Would need `externalTrafficPolicy: Local` (cluster-wide) or a UDM firewall rule. Marginal for a LAN-only, path-scoped, secret-ID-gated endpoint. See [`session-log.md`](session-log.md).
- **Effort:** S (verify) / done otherwise.

### 🟡 M71. AWS CLI auth modernization — kill standing static keys on the mini + terminals
- **✅ RA AWS-SIDE APPLIED 2026-06-28 (run `28330240921`, sha `fc32bf2`) → [`m71-roles-anywhere-plan.md`](archive/m71-roles-anywhere-plan.md).** The IAM Roles Anywhere stack `infra/terraform/aws/roles-anywhere/` is **live** (5 resources): trust anchor `wind-homelab-step-ca` (= **reused step-ca root** `step-ca-root.pem`, a PUBLIC cert — committed via a `.gitignore` negation past `**/*.pem`); IAM role `wind-mini-roles-anywhere` trust-scoped to the trust anchor + cert Subject CN `mini.wind.etherport.net` + issuer CN `wind Homelab CA Intermediate CA`; RA profile `wind-mini` (1h sessions). **The 3 ARNs are baked into the runbook's `credential_process` block.** Applied via CI (`terraform-roles-anywhere.yml`, dispatched with the M92 PAT). **3 owner-gated steps RESOLVED:** (1) **CI perms** — `gh-actions-terraform` already has **PowerUserAccess** which covers `rolesanywhere:*` (no extra JSON needed; the redundant `iam-policies/terraform-roles-anywhere.json` was **deleted**); (2) **scope decided = plan/debug-only** (2026-06-28) — role gets **`ReadOnlyAccess`** + an inline `tfstate-rw-and-deny-data-reads` (S3 state read/write + lock on `terraform.wind.etherport.net` only; **Deny** object-data reads `s3:GetObject`+**`GetObjectVersion`** [the versioned-backup bypass] everywhere else + `secretsmanager:GetSecretValue`/`BatchGetSecretValue`/**`ssm:GetParameter*`**/`kms:Decrypt`) → blocks the dedicated **backup buckets + secret stores**. ⚠️ **Caveat (hardened 2026-06-28 after the adversarial review found the `GetObjectVersion`/`ssm` Deny gaps):** the role CAN still `s3:GetObject` the *whole* tfstate bucket, and TF state stores **plaintext secrets** — so "can't exfiltrate secrets" is NOT absolute; that's an inherent residual of "can run plan". No 10-managed-policy-per-role quota issue (vs attaching ~20 `terraform-*` policies); (3) **mini-side cert + signing-helper = the ONLY remaining work** (owner-only — agent can't reach the mini; step-by-step in [`docs/runbooks/aws-roles-anywhere-mini.md`](../runbooks/aws-roles-anywhere-mini.md)). **Apply gotchas hit + fixed:** IAM rejects an em-dash in the role `description` (regex `[ -~¡-ÿ]`→ASCII hyphen); the public root PEM was gitignored → CI checkout missing it (negation + `git add -f`); and a `workflow_dispatch` apply contends the S3 lockfile with a concurrent `push`-triggered plan run (re-dispatch after the plan run finishes). **Interim wins still owner-side** (biggest cut = pull `[claude-admin]` PowerUser off the mini — `docs/runbooks/udm-manual-hardening-actions.md` §8).
- **Source:** 2026-06-17 review (after H29 close). Current state = **long-lived static IAM access keys in plaintext** `~/.aws/credentials` (mode 0600) on the headless mini: `[homelab]`=terraform-homelab (6 `terraform-*` service policies, **no IAM** → bounded, can't self-escalate; key created 2025-12-31, never rotated) and `[claude-admin]`=PowerUserAccess break-glass (created 2026-04-01, never rotated). At rest protected only by FileVault + file perms. **Owner accepts this risk for now** (single-owner, tailnet-only, FileVault) — this item is the **medium-term proper fix**, not urgent.
- **Target architecture:**
  - **Headless mini → [IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html).** X.509 trust anchor (CA) + per-host cert + `aws_signing_helper` as a `credential_process` → short-lived session creds, **zero standing key**. The blessed pattern for a persistent on-prem host. SSO is a poor fit here (needs periodic interactive login → breaks headless cron). Setup: trust anchor, cert issuance/rotation, profile per role.
  - **Human/interactive laptops → IAM Identity Center (SSO).** `aws sso login`, short-lived + per-user + MFA. Fine where interactive login cost is acceptable.
- **Cheap interim wins (can do anytime, owner-deferred for now):** (a) remove the `[claude-admin]` PowerUser block from the mini's standing creds — pull from SOPS / use from laptop only when break-glass is actually needed (biggest blast-radius cut for ~0 effort); (b) rotate both keys + set a cadence (terraform-homelab can't rotate itself — do from claude-admin/gs_admin).
- 🟢 **Progress 2026-06-24:** the **devbox is now clean** — M82 (CI-only TF) removed its standing `[homelab]` key; the devbox holds no standing AWS creds. **Remaining is mini-side only** (the mini's `[homelab]` + `[claude-admin]` standing keys + rotation) — needs admin creds / the mini, so it's a manual owner action (the agent can't reach it headlessly: no SSH to the mini, `op` doesn't authorize from agent bash, and the bounded homelab key has no IAM to rotate keys). **Step-by-step procedure: `docs/runbooks/udm-manual-hardening-actions.md` §8** (mini cred trim + rotation). Recommended order: do interim win (a) now (~0 effort, biggest cut), schedule (b) rotation, then the Roles-Anywhere/SSO target arch when ready.
- **Effort:** M (Roles Anywhere) + S (interim a/b). See session-log 2026-06-17 for the full blast-radius assessment.

### 🟢 M79. iCloud Photos backup (priority) → NAS → S3 — run on the mini
- **✅ STATUS 2026-06-21 — OPERATIONAL (bar a permanent-missing tail + owner's S3 dup cleanup).** Library backed up (**~15,355 photos**; ~41,727 deduped files on `Backups`). **Deduped** the ~30,577 `(N)` duplicate files (from the DB-less crash-retries) — run **NAS-local over SSH** by the owner (over-SMB bulk delete is NAS-metadata-bound to ~2.5–3 h; NAS-local is the right tool). Verified: dups gone, all canonical keepers present. **Steady state:** nightly `photos-export.sh` now **LOCAL mode** (no PhotoKit/dialogs) `--update --exportdb<local> --cleanup`; timer re-enabled 22:00. **No-new-dups guarantee** = persistent local `--exportdb` + `--update` (reuses canonical names) + atomic **lockfile** in both scripts (no concurrent-run ledger race) + `--cleanup` (orphan net). **Residual:** 293 photos truly unbacked + ~950 Live-Photo `.mov` clips (iCloud won't serve; list `~/Library/Logs/photos-export/MISSING-photos.txt`) — supervised `DOWNLOAD_MISSING=1` pass attempts these (`mc_on` re-enabled — the drops were the NVMe cache, not multichannel). **Owner:** finishing S3 dup deletion via infra agent (same `dedup-relative-paths.txt` → `objects/backups/<rel>` keys). Full saga in [`session-log.md`](session-log.md) 2026-06-19→21.
- **Source:** owner 2026-06-17. Highest-priority iCloud item. Want **individual files (not the .photoslibrary container) + attached settings**. **Decision:** **`osxphotos`** (owner: icloudpd was tried years ago, never worked). Exports **originals + edited + XMP sidecars** (albums/keywords/faces/GPS/captions) as individual files → NAS `Backups` → S3. Mini signed into iCloud (`graham.m.smith@mac.com`).
- **🔑 Disk constraint (the crux):** osxphotos reads a **local** Photos library, but the mini has only **~11–40 GB free** — nowhere near a full library. **Solution: host the Photos library in an APFS sparsebundle on the NAS (SMB), mounted on the mini** (macOS sees a local APFS volume; bits live on the NAS) → "Download Originals" into it → `osxphotos export --update` (XMP sidecars) → individual files+sidecars → S3. The sparsebundle (working library) is **never** uploaded (not in the export dir); only the exported files are. **Caveat:** sparsebundle-over-network corruption risk if the link drops mid-write (Time-Machine model; acceptable — the lib is a cache of iCloud → corruption = rebuild, not data loss). **Robust alt:** external APFS SSD on the mini.
- **✅ Built 2026-06-18 (`infra/macos/mini/`):** `create-photos-sparsebundle.sh` (run — bundle exists at `/Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle`, 2 TB sparse, attaches as `/Volumes/PhotosLib`); `photos-export.sh` (preflight `mount-nas.sh` → `hdiutil attach` → `osxphotos export --update --sidecar XMP --cleanup` → `/Volumes/Backups/Graham/iCloud/Photos`; exits 0 "not ready" until a `*.photoslibrary` exists); `net.wind.photos-export.plist` LaunchAgent (daily 22:00 PT — **authored, NOT loaded yet**). `osxphotos` 0.76.1 installed via **pipx** (NOT in brew core; works under Python 3.14). Full owner runbook in `infra/macos/mini/README.md`.
- **✅ Design simplified 2026-06-18 — NO new bucket/share.** Export target `/Volumes/Backups/Graham/iCloud/Photos` is a subtree of the **`Backups`** NAS share, which the **existing `s3-sync-backups` CronJob** (01:00 PT) already syncs to `archive.wind.etherport.net` (Glacier **Deep Archive**). Owner accepted Deep Archive's ~12 h retrieval for photos → **dropped** the earlier separate Glacier-Instant-Retrieval `photos` bucket plan (no TF bucket/IAM, no NFS export, no new s3-sync share — `Backups` is already NFS-exported to the node IPs and has no `Graham` exclude).
- **🟡 Owner setup IN PROGRESS (2026-06-18):** System Photo Library created inside the sparsebundle (`Photos Library (NAS).photoslibrary`), iCloud Photos on, catalog synced. Old `~/Pictures` library left untouched as fallback.
- **⚠️ iCloud background "Download Originals" stalls on the headless mini** (2026-06-18): catalog + thumbnails synced but original masters froze at **192/14,267** for hours (`cloudphotod` idle at 0% CPU, no progress, byte-identical over a 45 s sample) **even with Photos open**; `killall cloudphotod` didn't revive it (network/thermal/space all fine). **Fix: `photos-export.sh` now uses `osxphotos export --download-missing --use-photokit`** — fetches each missing original on demand via PhotoKit at export time (independent of the flaky background queue; fetched masters persist in the library on "Download Originals" mode → one-time download per photo, not per run). **Validated** (forced `--missing --download-missing` run: exported w/ XMP, error 0, library originals 192→196, no TCC prompt).
- **🟡 First bulk export reached 71%, then SMB instability + library corruption — ROOT CAUSE FOUND & FIXED** (2026-06-19): full export ran to **10,203/14,343** (~3.5 h), then the SMB mounts dropped repeatedly — including **`Personal-Drive` dropping while completely IDLE** on the 10G wired link, which force-quit Photos ("quit to prevent corruption") and left the sparsebundle's APFS journal dirty; after a reboot Photos errored "PhotosLib cannot be found." **Root cause: no `nsmb.conf` existed → macOS SMB *multichannel* was ON**, the classic cause of spontaneous idle SMB session resets against a NAS on a fast NIC (NOT write-load, sleep, or bandwidth — sleep was already disabled, link is 10G). **Fix (sudo-free, in git, self-healing on rebuild): `infra/macos/mini/nsmb.conf`** (`mc_on=no` + SMB1 off + `notify_off`), installed to `~/Library/Preferences/nsmb.conf` by `mount-nas.sh` before it mounts. **Validated** by checkpointing the library's 14 GB un-checkpointed WAL = a 14 GB sustained network write soak: **0 drops, 0 SMB reconnects** start→finish. **Library NOT corrupted** — after the WAL checkpoint, `PRAGMA integrity_check` = `ok`, 14,267 photos readable (the earlier "malformed" was purely the outstanding-WAL artifact). Two durability gaps also fixed in `mount-nas.sh`: it now (a) installs `nsmb.conf` and (b) **attaches the sparsebundle at login** (nothing did before → that's why PhotosLib didn't come back after reboot). Resume wrapper hardened: auto-attaches the bundle + `--cleanup` is now opt-in (`CLEANUP=1`; default OFF because the `.osxphotos_export.db` was lost in the corruption → cleanup without the ledger could delete+re-download). Full incident + lessons in [`session-log.md`](session-log.md) 2026-06-19.
- **🔴 ACTUAL ROOT CAUSE of all the SMB instability = NAS hardware (2026-06-19, owner-diagnosed via SSH to UNAS):** one of the two NVMe **SSD-cache** drives (`nvme0`) fell off the PCIe bus at ~11:04 (`controller is down, CSTS=0xffffffff`); Linux `md` kicked it from the cache RAID1 (`md4` degraded `[2/1]`), and `smbd`/`kcopyd`/`btrfs-transaction` went **D-state** (uninterruptible I/O wait) on the dead device → that is the "copy works ~10 s then hangs" symptom. Data array (RAID6 `md3`) + the surviving cache SSD healthy → **no data risk**. Timeline fits perfectly: NAS booted 06:17 (update), SSD dropped ~5 h later → the "stable ~5 h then degraded" pattern. So `mc_on=no` *was* a real improvement but the deeper instability was the dying SSD, not the client. **Resolution: owner rebooted the UNAS ~16:1x; `nvme0` re-probed clean, SMB stably healthy again** (verified by the watcher's 3× timeout-guarded reads). Lesson: when SMB degrades *progressively* (fine→flaky→EIO/hang over hours), suspect NAS-side storage/SMB health, not just the Mac.
- **🟢 Auto-resume on NAS recovery (2026-06-19):** built `~/Library/Logs/photos-export/auto-resume.sh` (not committed — one-off recovery orchestrator): polls a **timeout-guarded** 50 MB read off `/Volumes/PhotosLib` (a D-state hang ⇒ fail, not block), requires 3 consecutive healthy reads, then auto-runs `photos-export-resume.sh`. Fired at 16:24 when SMB recovered.
- **🟢 Export DB moved to LOCAL disk — the fix that finally let it complete:** osxphotos writes its export DB as the *final* step; on the blip-prone SMB share that write kept failing (rc=1, no clean completion → wrapper retried **~18×** even though files were exported). Pointed `--exportdb` at `~/Library/Application Support/osxphotos/graham-icloud-photos.db` + `--ramdb` (both `photos-export-resume.sh` and nightly `photos-export.sh`). First **clean `rc=0` completion** came at 22:08 (5h41m local-mode run). Also: `--download-missing --use-photokit` made opt-in (`DOWNLOAD_MISSING=1`); default = pure-LOCAL (no Photos.app/PhotoKit → no corruption dialogs/XPC wedges).
- **🟡 Clean completion REVEALED two issues (2026-06-19 22:08):** `Processed: 14343 photos, exported: 10420, skipped: 0, missing: 11538, error: 0`. (1) **~11,538 photo-versions' originals were never downloaded** — the PhotoKit run dropped at 71% before reaching them, so they are NOT yet backed up (only ~10,420 versions have local originals). (2) **Massive duplication on disk** — 55,745 files but **41,295 have `(N)` suffixes** collapsing to ~5,305 base names: the ~20 DB-less retries each re-assigned `(N)` numbers and re-exported the same photos under new names. Now fixable convergently because the **persistent local DB exists** (no more dup explosion).
- **🔴 DOWNLOAD_MISSING pass BLOCKED — recurring NAS SMB instability + PhotoKit wedge (overnight 2026-06-19→20):** the `DOWNLOAD_MISSING=1` pass hit two walls. (1) **PhotoKit XPC wedge:** even on healthy SMB, `osxphotos --use-photokit` ran ~1h27m with **0 downloads** then wedged on `CoreData: XPC: failed after 8 attempts` (`photolibraryd` serving the SMB library wedges after the day's crashes/force-quits). Restarting the Photos daemon stack (kill `photolibraryd`/`photoanalysisd`) is the intended fix (a fresh daemon is what let the first 5h run download 10,420). (2) **NAS SMB EIO returned ~02:35:** `Personal-Drive`/sparsebundle reads fast-fail with `[Errno 5]` (sparsebundle won't even attach) while **`Backups` stays healthy** — so it's a *Personal-Drive SMB-session wedge*, not the whole NAS (different from the nvme0 case which hung both). Possibly `nvme0` flapping again (owner: re-check the UNAS — is the cache SSD dropping intermittently? may need replacement) or just a session wedge. **`--download-missing` downloading was NEVER cleanly confirmed working post-recovery** (every attempt blocked by wedge or EIO before a clean download). **Action taken:** stopped thrashing the NAS; re-armed `~/Library/Logs/photos-export/auto-resume.sh` in **DOWNLOAD_MISSING mode** (gentle 5-min health-gated polling, 12 h window, force-remount on failure, fresh daemons before each export) → it will **auto-resume the download pass the moment the NAS is stably healthy**. Monitor watching for health/progress/completion.
- **⚠️ Backup completeness as of this pause:** ~10,420 photo-versions exported (originals downloaded), **~11,538 versions NOT yet backed up** (originals never downloaded), plus ~41k duplicate `(N)` files to clean. **Remaining work = the download-missing pass + cleanup**, gated on NAS-SMB stability (and confirming PhotoKit downloads actually work — if they don't even on a fresh daemon/healthy SMB, the fallback is iCloud re-auth in VNC or the non-photokit AppleScript download path).
- **Then (unchanged):** `CLEANUP=1` (`--dry-run` first) to delete the ~17k+ orphan duplicates → one canonical copy per photo.
- **Remaining (after download-missing + cleanup):** verify `missing: 0` + distinct count ≈ expected → enable the `net.wind.photos-export` timer → confirm `s3-sync-backups` ships `Graham/iCloud/Photos`. **Owner asked to report final exported count vs 14,267 + whether the timer is active.**
- **Caveats:** Apple **2FA session expires** every ~weeks→months → periodic interactive re-auth via VNC. Sleep disabled (`SleepDisabled`/`sleep 0`). Sparsebundle-on-SMB remains the architecture (owner is remote, no SSD option) — hardened SMB + login-time attach make it robust; **robust alt if it ever recurs: external APFS SSD on the mini**, or the sudo-only deeper levers (system-wide `/etc/nsmb.conf` + raised `net.smb.fs.kern_*_deadtimer` so a stall pauses I/O instead of erroring into APFS). **Effort:** M (tail + verify).

## LOW

### ⏳ L37. `automountServiceAccountToken: false` sweep — newer workloads (extends L26)
- **Found 2026-07-11 (repo audit L-2):** garage, ntfy (server + bridge), cue-api, rclone-gdrive,
  cloudwatch-to-loki, and the backups/aws-s3 base cronjob still auto-mount a usable SA token they
  never use (IRSA workloads use a separately-projected token, so disabling the default mount is
  safe). L26 covered only the 6 older workloads. Mechanical; each is a pod-template change →
  rolling restart, so batch with other touches (garage = velero primary, restart when quiet).

### ⏳ L38. Verify the Authentik `grafana` app policy binding actually gates `allow_sign_up`
- **Found 2026-07-11 (repo audit V-1):** Grafana OIDC has `allow_sign_up: true` (+
  `skip_org_role_sync`), so any Authentik user who can get a token self-provisions a Grafana
  account (Viewer). Safe ONLY if the Authentik `grafana` application has a restricting
  group/policy binding in `40-blueprints.yaml`. Confirm the binding exists; otherwise add one or
  set `allow_sign_up: false`. **Effort: XS.**

### 🟡 L30. Infra PDBs DONE 2026-07-01 (coredns/cilium-operator/csi-provisioner, minAvailable 1, selectors verified, live). **velero cluster-admin deliberately KEPT** — restore must create arbitrary resources incl. RBAC; scoping it risks silently breaking DR. Documented decision; close unless posture changes.
- Drains can momentarily evict both replicas of cluster DNS; velero needs broad-but-not-cluster-admin. (#20.) **Effort: S.**

### ⏳ L1. Proxmox HA cluster expansion
- Source: `archive/outstanding-work-2026-05-16.md` L1. Blocked on adding a 2nd PVE node.

### ✅ L3. EIP → FQDN conversion debt (hardcoded ephemeral IP audit follow-up)
- **✅ Swept 2026-07-09:** both flagged live-config EIPs are already resolved — the wireguard `vpn-use1` peer (`35.169.37.16`) was removed in M110 (Endpoint is now `44.240.60.80`), and the dns-aws `52.40.219.113` was superseded by `44.240.60.80` (M110/M125). A broad repo sweep of `platform/clusters/infra` found NO dangling hardcoded ephemeral EIPs in live config; remaining `52.40.219.113` hits are all historical docs/comments. (DHCP `dns_servers` must be IPs, not FQDNs, so `44.240.60.80` — a deliberately-kept stable EIP — is the correct terminal value there, not an FQDN.)
- **Source:** `docs/planning/archive/hardcoded-ephemeral-ip-audit-2026-05-23.md`. Several places still hardcode AWS Elastic IPs that *could* rotate if recreated: `vpn-use1` endpoint `35.169.37.16` in `platform/kubernetes/wireguard/03-deployment.yaml`, dns-aws `52.40.219.113` in M35 plan, etc. Convert each to a Route53 FQDN + DNS lookup at peer/config render time so an EIP swap doesn't require a code change.
- **Effort:** S per site, M overall.

### ⏳ L5. PVE BMC PEF / LAN alert destinations (cross-subnet PET trap)
- **Source:** M40 deliberately deferred. BMC sits on VLAN 200 (10.10.200.21); Alloy/Loki on VLAN 201 (10.10.201.73). For BMC PET traps to reach Alloy, the BMC needs to learn the gateway MAC for 10.10.200.1 — `ipmitool lan print 1` shows `Default Gateway MAC: 00:00:00:00:00:00` currently. Either populate the gateway MAC statically (one-shot ARP lookup + `ipmitool lan set 1 defgw mac <mac>`) or have the BMC do it via gratuitous ARP. Then enable PEF policy 1 with action="send to LAN destination 1" pointed at 10.10.201.73. Today we rely on BMC remote-syslog → Alloy which covers the same alerts.
- **Effort:** S.

### ✅ L14. AI advisor public approval URL — needs auth gate before advertise
- **✅ Resolved (verified 2026-07-09; the entry below is stale):** Option A shipped — `approve.etherport.net`
  is gated by a **Cloudflare Access** application ("AI Advisor Approval URL", `cloudflare_zero_trust_access_application.approve`
  in `infra/terraform/cloudflare/main.tf`): **Google SSO + allowlisted-emails** policy, 24h session, in
  front of the CF-tunnel origin — on top of the per-request HMAC token (defense in depth). Confirmed
  live: an unauthenticated hit to `https://approve.etherport.net/approve` returns **302 → CF Access SSO**
  (not passed through to the controller). The old TS-only concern no longer applies.
- **Source:** Phase 2 wireup 2026-05-24. The `approve.etherport.net` Traefik IngressRoute is deployed but unadvertised (email links default to the Tailscale URL). HMAC-token-only auth on a public endpoint is too thin — anyone with email access can approve. Before flipping `APPROVAL_BASE_URL` to the public URL, add a zero-trust gate:
  - Option A: **Cloudflare Access** policy gating `*.wind.etherport.net` — requires Google SSO + email-domain restriction. ~30min setup; needs Cloudflare-as-DNS for the domain (currently Route53). Doable but moves DNS authority.
  - Option B: **Tailscale Funnel** — exposes a TS service publicly via TS-managed gate. No DNS change; gate is TS auth. Requires Funnel feature on the tailnet.
  - Option C (current): Stay TS-only; treat public Ingress as future infra.
- **Effort:** M.

### ⏳ L13. Phase 3 (autonomous execute) opt-in alerts
- **Source:** code shipped 2026-05-24 (`AI_PHASE3_ENABLED` env, default OFF). Per the phased rollout plan in `docs/runbooks/archive/ai-advisor-phase3-enable.md`: week 1 add `ai_remediation: "auto"` label to `NodeLocalDNSHighErrorRate` only; week 2 add `CoreDNSDown`; week 3 add `TechnitiumDNSDown` + `HomeAssistantDown`; expand 1/week as comfort builds. Never include CNPG / Ceph / kube-system alerts.
- **Effort:** Trivial per alert (one label addition). Spread across weeks for safety.

### ✅ L7. Debug Jobs in backups ns — resolved (May debris long TTL-expired; ns clean)
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

### ✅ L6. Plex `ALLOWED_NETWORKS` parse error
- **Source:** surfaced 2026-05-23 by the new Plex logtail sidecar (M41). Plex repeatedly logs `ERROR - Error parsing allowedNetworks entry ' 10.10.201.0 24': Invalid argument`. The space-separated CIDR fragments suggest Plex is reading from its Web UI "LAN Networks" setting where the slash got stripped — likely an old config from before the env-var was set. The `ALLOWED_NETWORKS` env in `02-deployment.yaml` is correct (`10.10.201.0/24,...`); need to clear the Web UI value or re-sync. Library Settings → Network → LAN Networks → check/clear the value.
- **✅ Fixed 2026-07-09:** the culprit was actually the **`LanNetworksBandwidth`** pref (`"10.10.0.0/16, 10.42.0.0/16"` — a **space after the comma**; `allowedNetworks` itself was already clean), so Plex logged the parse error **~1/sec (74,899 in 24h)** = pure Loki spam. Fixed via the Plex prefs **API** (`PUT /:/prefs?LanNetworksBandwidth=…` with the PlexOnlineToken, no space) — Plex owned the write, **no outage / no Preferences.xml surgery**. Verified: errors dropped to **0**. NB this is a **live-only** fix (Plex prefs live in the config PVC, not git) — if the pod's PVC is rebuilt, re-check the pref.

### ⏳ L16. k8s consistency nits — velero-excludes part VERIFIED DONE, cosmetic remainder deferred
- Review 2026-06-10. Numbered-file convention (00-/01-) inconsistent across `platform/kubernetes/*`; Velero `backup-volumes-excludes` annotations present on some workloads, absent on most (cost — transient/media volumes get backed up); resource request:limit ratios vary wildly (ollama 12Gi limit vs 4Gi request). Standardize + lint. **Effort:** S each.
- **2026-07-09 checked:** the cost-relevant part — `backup.velero.io/backup-volumes-excludes` — is **already present on the big-volume workloads** (plex media, ollama models, rclone-gdrive/onedrive mirrors, cue-api, aws-s3 base), so large volumes are NOT being Kopia-backed-up. Remaining bits (numbered-file naming convention + request:limit ratio standardization) are **cosmetic / low-value** — deferred. Not blocking.

### ✅ L18. `optional: true` secret refs can start pods degraded
- Review 2026-06-10. e.g. `cue-api/01-deployment.yaml` — intentional for bootstrap, but a workload can run in a no-auth state; worth an alert on the empty-secret condition. **Effort:** S.
- **✅ Done 2026-07-09:** audited all `optional: true` refs — only **cue-api's `cue-app`** carries AUTH material (CUE_WEB_TOKEN_SECRET, VAPID_*, ANTHROPIC_API_KEY); the rest (cloudflare-ddns config, service-status drift-status, per-share s3-sync excludes) are non-auth config with safe defaults → no alert needed. Added **`CueAppSecretMissing`** (`absent(kube_secret_info{namespace="cue",secret="cue-app"})`, warning) in `13-service-alerts.yaml` — fires if the secret is deleted (cue-api keeps running degraded on its own).

### ⏳ L20. Branch protection / CODEOWNERS (single-owner risk, accepted?)
- Review 2026-06-10. `main` has no enforceable branch protection (GitHub free plan on a private repo blocks required-reviews/checks) and no `CODEOWNERS`; the headless mini auto-pushes to `main`. Mitigate with a mandatory pre-push CI gate, or explicitly accept the single-owner risk. **Effort:** S (decision).
