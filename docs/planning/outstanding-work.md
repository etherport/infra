# Outstanding Work — Consolidated Priority List

Latest revision: 2026-07-01 (doc-consolidation pass: all ✅-done entries extracted to
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
- ✅ **M75** (2026-06-24) — IRSA in-cluster AWS workload identity; all workloads migrated, **no static AWS keys in etcd** — ⏳ residual: deactivate/remove the 4 orphaned dedicated IAM keys via their TF stacks (NOT the H29 `terraform-homelab` key).
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

### ✅ H42. step-ca (+ asterisk-sbc, pve OS) monitoring blind spot — DONE 2026-07-01
- **✅ Fixed (`6c458f6`), e2e-verified:** node_exporter deployed to step-ca + asterisk-sbc (base.yml CI apply — never ran there) and to the pve HOST via the NEW standalone `node-exporter.yml` (full base.yml is a hypervisor hazard: its unattended-upgrades Automatic-Reboot would reboot every VM). NEW `pve-nodeexp` firewall group (:9100 from Servers VLAN) — **the PVE host firewall now has FOUR required allows** (CLAUDE.md updated). 3 new scrape targets + relabels; blackbox Probe on step-ca `:8443/health`; `StepCADown` critical alert (blast-radius + break-glass in the annotation). Verified: all 3 targets `up=1`, `probe_success{step-ca}=1`.
- **Source:** 2026-07-01 Fable-5 infra review (#1). `base.yml` installs node_exporter on step-ca/asterisk-sbc/pve, but `01-external-scrape-config.yaml` scrapes neither; **0 of 82 alert rules mention step-ca**; no blackbox probe on `https://10.10.201.46:8443`. Since M76 the whole fleet is cert-only SSH — a wedged step-ca silently breaks cert renewal and the devbox/CI lose fleet access at the next ≤13h expiry, unpaged (break-glass = PVE console/IPMI, but you'd find out the hard way).
- **Fix:** add the 3 targets to `external-nodes`, a blackbox probe on the step-ca endpoint, and a `StepCADown` (+ cert-renew-staleness) alert. **Effort: S.**

### ✅ H43. 9 TF workflows ran PR-authored `terraform plan` on the in-network self-hosted runner — DONE 2026-07-01
- **✅ Fixed (`72cb120`):** removed the `pull_request` trigger from all 9 self-hosted-runner workflows (cloudflare, google, twilio, twilio-webhook, unifi, proxmox ×4). Plans still run on push-to-main (the 5 stacks that had it), workflow_dispatch, and the daily drift-detection sweep (all 9). Renovate PRs no longer execute code on the lifecycle runner.
- **Source:** 2026-07-01 Fable-5 infra review (#2). `terraform-{google,twilio,twilio-webhook,cloudflare,proxmox-firewall,proxmox-sdn,proxmox-standalone-vms,proxmox-k8s-vms,unifi}.yml` trigger on `pull_request` and run on `[self-hosted, lifecycle]`. `plan` executes PR-authored code (`data "external"`, module/provider fetch) = code-exec on a persistent in-homelab runner whose env scope holds PVE/CF/UDM secrets — PR-reachable, worse than the accepted dispatch-only L20 posture. Renovate PRs traverse this path constantly.
- **Fix:** move PR plans to `ubuntu-latest` where the stack allows (regional-vpn/dns-restrict-ip already do), or drop the `pull_request` trigger on self-hosted stacks (keep push+dispatch). **Effort: M.**

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

### ⏳ H44. Authentik 2024.12.3 — UNPATCHED CRITICAL RCE + forward-auth bypass; 8-hop upgrade program
- **2026-07-02 currency review:** running 2024.12.3 (~18 months, 7 majors behind; out of support). **CVE-2026-25227 (Critical, authenticated RCE via the policy-test endpoint) explicitly covers 2024.12.x with NO fixed build**, + GHSA-fj56-5763-j8pp (**Traefik forward-auth bypass via malformed session cookie — the exact H38 pattern gating every admin UI**) + ~13 more High/Critical since. Version-skipping unsupported → **8 sequential hops** (→2025.2→2025.4→…→2026.5.3), each with a velero restore point + blueprint/outpost/OIDC re-validation + the M115 netpol tier check. Fold the Redis 7.4→8 bump in (7.4 security-support ends 2026-11-30). **Biggest single risk in the estate. Effort: L. Owner: agent + operator windows.**

### 🟡 H45. CVE patch batch: containerd 2.2.1→2.2.5, ✅Cilium 1.18.11, ✅CNPG operator 1.24.1→1.30.0 + ⏳PG 16.4→16.14
- **✅ H45a Cilium DONE 2026-07-02 (`a5784c7`):** 1.18.6→**1.18.11** (CVE-2026-49445) via `helm upgrade` from the devbox (helm v3.19 installed → CLAUDE.md §4). ⚠️ `--reuse-values` threw a hubble.relay.logOptions nil-pointer template error → used `--reset-then-reuse-values`, which **re-enabled `policyAuditMode=true`** (helm values had drifted from the live ConfigMap hand-patches) — would have SILENTLY UN-ENFORCED all 6 netpol tiers. Caught + fixed with `--set policyAuditMode=false` + `rollout restart ds/cilium`. Verified: enforce mode, WG encryption, BGP 8/8, 0 drops. `cilium_version: 1.18.11` in kubespray inventory + live-values snapshot `docs/reference/snapshots/cilium-helm-values.yaml`.
- **✅ H45c CNPG OPERATOR DONE 2026-07-02:** laddered 1.24.1→1.25.1→1.26.1→1.27.1→1.28.1→1.29.1→**1.30.0** (sequential-minor per CNPG's documented no-skip policy; chart 0.22.1→0.29.0). Each hop verified operator-image + both clusters healthy + `ContinuousArchiving=True`. The **Critical 9.4 (fixed ≥1.28.3) is resolved.** cue-db single-instance restarts briefly per hop (multi-attach detach-lag ~4-6 min, self-clears); postgres-cluster HA-rolls with no downtime. Commits `e7e369f` + siblings.
- **⏳ H45d PG data-plane bump 16.4→16.14 — HELD, operator-gated:** cue-db depends on **pgvector** bundled in the operand image; CNPG changed extension bundling around 1.30 (minimal vs -standard images / image-volume extension mechanism), so a naive tag bump could drop pgvector and break cue-api. Needs the correct 16.14 image tag confirmed to ship pgvector before applying (postgres-cluster has no such dependency and can go first). See the operator question 2026-07-02.
- **⏳ H45b containerd 2.2.1→2.2.5 — PENDING (needs a node-reboot window):** exposed to the 2026-06-18 coordinated release (**3 Criticals** incl. image-LABEL→host-root exec; digest-pinning mitigates, not eliminates). containerd is a **kubespray binary** (`/usr/local/bin/containerd`), not apt → override `containerd_version` + rolling `upgrade-cluster --tags=containerd` (⚠️ **cni-dir-owner landmine: kubespray.sh only**, never a raw run) + per-node reboots. Best folded into the **M123** K8s upgrade window. **Effort: M. Tier: H.**

### ✅ M122. Close the update-automation blind spots (the systemic fix) — DONE 2026-07-02 (`122caaa`)
- Enabled renovate's **`flux` manager** on `clusters/wind/helm-releases/**` (was watching only gotk-components → the `version:` fields were invisible to renovate); patch+minor grouped weekly, majors as individual hand-review PRs (`prPriority:-1`). **Exact-pinned all 17 HelmReleases** to their deployed versions (the ranges silently FROZE majors — `alloy` sat on a `0.x` cap that 1.x never matched, so it was ~10 chart minors behind; kps `80.x`, cnpg on an EOL line, etc.). Upgrades now happen by merging PRs, never by silent drift/freeze.
- **CORRECTION (charter C3) vs the 2026-07-02 currency review:** the Grafana chart repo is **NOT dead** — the original `grafana.github.io/helm-charts` still serves alloy 1.10.0 / loki 7.0.0; the `grafana-community` repo carries a **diverged** loki 18.x lineage. The alloy staleness root cause was the **range cap**, not the repo URL. URL unchanged. **Remaining (⏳ L):** raw-manifest image coverage (authentik/redis/ceph-csi sidecars) not yet wired into renovate.

### ⏳ M123. K8s platform upgrade train (1.34 EOL 2026-10-27)
- Patch to 1.34.3 (kubespray v2.30 ceiling), then submodule→v2.31 + upgrade-cluster to 1.35.x before October; etcd/CoreDNS/containerd ride along. Pre/post checklist = the M75 issuer/api-audiences check, multus DS restart, cni-dir owner, per-kernel modules. Quarterly cadence thereafter. **Effort: M.**

### ⏳ M124. WAN path-loss waves — instrumented, not yet root-caused
- **State 2026-07-02:** NOT the box (ENA counters 0 post-resize; 274 scrape flaps in 12h anyway), NOT MTU (20/20 large-payload when calm; wg 1420 both ends), NOT SG/fail2ban/egress-IP. Waves hit BOTH the wg-tunnel and public paths; 90-min mtr windows when calm show 0% loss on every hop incl. control ⇒ **ISP/WAN-side, intermittent, hours-scale**. Continuous detector = `AWSReplicaHostFlapping` (fires during waves). **Next:** when it fires, capture mtr from BOTH ends immediately (runbook-able; consider auto-capture triggered by the alert), correlate wave timestamps against ISP/UDM WAN events (dual-WAN failover logs?). **Effort: M (mostly waiting for a wave).**

### ⏳ M125. Migrate unifi TF provider to the ubiquiti-community fork
- paultyng/unifi archived 2026-04-30; it now deterministically 400s PUT networkconf for 3 of 7 networks (bit the M110 dhcp_dns cutover — worked around via direct UDM API + ignore_changes). Fork is drop-in. Swap `source`, re-init, verify plan `0/0/0`, then try removing the M110 ignore_changes. **Effort: S.**

### ⏳ M126. Structural improvements from the 2026-07-02 state review (operator to prioritize)
- (a) **kube-vip HA API endpoint** (ARP mode on VLAN 201 — NOT BGP per the VIP gotcha); do with the 1.35 upgrade window. (b) **Split the Flux mono-Kustomization** into layered Kustomizations with dependsOn/healthChecks (one bad manifest currently freezes ALL reconciliation). (c) **PVE memory ceiling decision** — ~85/93 GiB committed; growth is now RAM-gated (cheaper than the L1 second node). (d) Cilium lifecycle ownership in git (values snapshot + upgrade runbook). (e) Spegel pull-through cache (L). (f) PG 16→18 plan piggybacked on the M12 restore drill (L). (g) file the bpg watchdog bug upstream (verified unreported; L). (h) IPv6 stance doc (L). Full detail: session-log 2026-07-02.

### ✅ M127. Tailnet split-DNS still lists the DESTROYED dns-aws (10.10.100.5) — DONE 2026-07-02 (console edit `.5`→`.100.10`; verified 1–3 ms via 100.100.100.100). Residuals optional: tailnet-DNS-into-IaC (S) + the off-cluster second subnet router decision (S). Original finding:
- **Found 2026-07-02** diagnosing the owner's on-Tailscale failures reaching `cue.etherport.net`. The Tailscale admin console's split DNS for `etherport.net` forwards to **10.10.201.5, 10.10.201.6, 10.10.100.5** — but `.100.5` was destroyed by M110 (`68a8156`) on 07-01. Verified from the devbox: `.100.5` times out; the consolidated edge box **10.10.100.10 answers correctly over the tailnet** (NOERROR, Cloudflare IPs). Every on-TS `etherport.net` lookup now races a dead resolver → intermittent failures/slow first loads. The outage windows themselves line up with today's cluster maintenance (cilium H45a + restart waves took down the technitium pods, MetalLB BGP announcements, AND the in-cluster `ts-homelab-subnet-router` — the tailnet's only path to VLAN 201 — simultaneously; home-LAN DHCP DNS points at the same VIP first, so WiFi-no-TS degraded too).
- **Fix (console, 2 min):** Tailscale admin → DNS → split DNS `etherport.net`: replace `10.10.100.5` → `10.10.100.10`. Not terraform-managed (no tailscale module) — consider adopting the tailnet DNS config into IaC so the next resolver move can't strand it (S, optional).
- **Resilience note:** the subnet-router pod runs on the same cluster whose DNS it fronts — during cluster maintenance, on-TS users lose BOTH the resolvers and the route to them. Mitigation options: a second subnet router off-cluster (e.g. a standalone VM), or accept + schedule maintenance windows. **Effort: Trivial (console edit) + S (IaC/second-router decisions).**



> M112–M121 + L25–L31 below are from the **2026-07-01 Fable-5 infra review** (3 parallel read-only agents:
> K8s efficiency/hardening, AWS, CI/CD, ansible, observability, cost). Deduped against everything above.

### ✅ M112. `concurrency:` groups on all terraform workflows — DONE 2026-07-01 (`72cb120`): `tf-<stack>` group, `cancel-in-progress: false`, added to all 24 TF workflows (incl. drift-detection).
- 0 of 25 TF workflows have one — a dispatch apply + push-plan on the same stack race the S3 lock (bit twice on 2026-07-01: us-east-1 destroy vs push-plan; plus a stale `.tflock` from a killed 06-17 run silently failed that stack's plans for 2 weeks). **Fix:** `concurrency: {group: tf-<stack>, cancel-in-progress: false}` per workflow. **Effort: S.**

### ✅ M113. Alert-coverage gaps — DONE 2026-07-01 (`727a40d`,`47e29b7`), verified: cert-manager ServiceMonitor enabled (metrics were never scraped!); NEW 13-service-alerts.yaml — CNPGClusterDown ×2 (absent()-based), CertManagerRenewalOverdue + CertExpiryCritical (**duration-agnostic — the wildcard is a ~6.7d short-lived LE cert, absolute-day thresholds false-fired within minutes and were rewritten to renewal-overdue semantics**), AuthentikDown (new in-cluster blackbox Probe + plain http_2xx module), CloudflaredTunnelDegraded/Down; runbook_url pass (14 rules linked to their docs/runbooks/alerts docs). All 7 rules loaded + inactive on the healthy cluster.
- CNPG has only backup alerts — a dead `postgres-cluster`/`cue-db` never pages; no general `certmanager_certificate_expiration_timestamp` alert; authentik (gates all admin UIs) and cloudflared (all external ingress) have zero rules. Also **0 of 82 rules carry `runbook_url`** even though `docs/runbooks/alerts/` has per-alert docs named after the alerts — the advisor emails lose that context. **Fix:** ~4 new rules (metrics already scraped) + a mechanical annotation pass + a lint for new rules. **Effort: S.**

### ✅ M114. authentik-server HA — DONE 2026-07-01 (`72cb120`), verified: replicas 2 on distinct nodes (w1+w4), zero-gap RollingUpdate, hostname topologySpread, PDB minAvailable 1, worker `ak healthcheck` probes. **Unblocked by dropping the RWO media PVC** (it held only the initContainer-regenerated login-bg.png → emptyDir now; future real media = RWX/S3 decision, don't re-add RWO). In-cluster `/-/health/ready/` = 200.
- Same failure class as the just-fixed cue-api: every drain of its node takes down SSO (Grafana/wiki/Open WebUI + all forward-auth admin UIs). Server is stateless (shared HA postgres + redis) → safe at 2. **Fix:** replicas 2 + PDB minAvailable 1 + topologySpread (mirror `493868b`) + liveness/readiness on the worker. **Effort: S.**

### ✅ M115. authentik = 6th NetworkPolicy-enforced tier — DONE 2026-07-01 (`38da9a9`), verified: `15-tier-authentik.yaml` (ingress :9000 from traefik+blackbox-exporter+intra-ns; egress postgres :5432 + SES :587 + intra-ns; world :443 deliberately absent — update-check/analytics/gravatar all disabled). Full audit-toggle procedure: audit ON → label → 605 real flows observed, **0 would-be drops** → audit OFF → enforced-path verified (traefik-pod→authentik OK, probe_success=1, 0 DROPPED).
- The SSO IdP (crown-jewel credential system) sits allow-all while `cue,dns,monitoring,postgres,traefik` are enforced; it's already a postgres-tier client so half its flows are mapped. **Fix:** the documented audit-on→observe→enforce procedure (`docs/runbooks/networkpolicy-tiers.md`). **Effort: M.**

### ✅ M116. k8s-node automated security patching — DONE 2026-07-01 (`f4bc0dd`), applied to all 8 nodes + spot-verified: NEW `k8s-unattended-upgrades.yml` (Ubuntu -security pocket only, `Automatic-Reboot=false`) — **kured owns reboots** (existing deploy: concurrency 1, nightly 02:00-06:00 PT window, watches /var/run/reboot-required, cordon+drain). kubelet/containerd are kubespray binaries, not apt packages — untouchable by the security origin.
- `base.yml` is `hosts: all:!k8s_cluster` — nodes get no unattended-upgrades and none of the sshd baseline; the only patch path is the manual `k8s-node-patch.yml`. **Fix:** either a scheduled (monthly) dispatch of the rolling patch playbook, or a security-only unattended-upgrades profile on `k8s_cluster` with reboots left to kured. **Effort: M.**

### ✅ M117. metrics-server — DONE 2026-07-01 (`727a40d`), verified: HelmRelease (chart 3.13.0, kube-system, kubelet-insecure-tls) — `kubectl top nodes/pods` now works cluster-wide.
- Blocks HPA, incident triage when the monitoring ns itself is down, and utilization-aware tooling. **Fix:** metrics-server via kubespray flag or a small HelmRelease. **Effort: S.**

### ✅ M118. Resource right-sizing — DONE 2026-07-01 (7d PromQL evidence), rolled + verified: velero node-agent 200m/256Mi→**25m/160Mi** (7d max incl. backups = 138Mi; freed ~1.4 CPU + ~0.8Gi schedulable); prometheus 512Mi req/2Gi lim→**2Gi/3Gi** (P95 1.83Gi — was <10% from OOM); alloy 128Mi→**384Mi** (P95 315Mi); tetragon 32Mi(kyverno-default)→**256Mi** (P95 219Mi; the HR requests hadn't been landing — fresh upgrade fixed it).
- PromQL vs requests: 8× velero node-agent ~200m/200Mi each over-requested (~1.6 CPU + 1.6Gi reserved idle fleet-wide); prometheus runs ~1Gi ABOVE its 512Mi request, alloy ~175-217Mi over 128Mi/node, tetragon 50-155Mi over — under-requested pods burst into headroom the scheduler thinks is free and are first-evicted under pressure. **Fix:** lower node-agent, raise the three under-requesters to observed P95. **Effort: S.**

### ✅ M119. Backup thundering-herd stagger — DONE 2026-07-01 (`727a40d`,`6fa4f2d`), verified live: 7 s3-sync shares 01:00→01:50 at 10-min steps (scans suspended but slotted at 02:00); velero de-stacked to :00/:20/:40 (02:00,04:00 groups) + :00/:12/:24/:36/:48 (03:00 group).
- All six s3-sync CronJobs fire at `0 1 * * *` (simultaneous UNAS+WAN hammer + shared-lock contention); 5 velero Schedules at exactly `0 3 * * *` drive the fs-backup/CNPG spike — same fan-out pattern that fed the 10:00 UTC etcd cascade. **Fix:** stagger minutes (01:00/01:15/… and 03:00/03:20/…). **Effort: S.**

### ✅ M120. ceph-csi codified + moved to its namespace — DONE 2026-07-01 (`8851750`), e2e-verified. Bigger than reported: the workloads (deploy/DS/SA/RBAC) ran 50d as an **out-of-band kubectl apply** (not in git at all), and the ceph-csi-ns configmap copy pointed at the **pre-VLAN-migration monitor 10.10.201.41** — a naive move would have broken all new volume ops. Codified the full stack from a cleaned live dump into `storage/ceph-csi/` (ns ceph-csi; git configmaps with the correct 10.10.210.41 overwrote the stale copy). Cutover: old deleted → Flux applied new → **one gotcha: the old pods' termination deleted the new registrar's socket** (plugins_registry emptied post-registration) → DS restart re-registered 5/5 → **acid test green** (PVC provision→attach→mount→write→delete all through the moved stack; 22 existing Bound PVCs unaffected). default ns now EMPTY + PSS enforce=baseline (adopted as a git resource in policy-baseline/); 50d rbd-test-pvc deleted; provisioner PDB moved with the workload.
- The privileged CSI DS + provisioner run in `default`, which has no PSA label (anything landing there gets zero admission guardrails); the intended `ceph-csi` ns exists but is empty; `default/rbd-test-pvc` (1Gi) has lingered 50d. **Fix:** migrate CSI into `ceph-csi` (careful — storage path), or at minimum PSA-label `default`, delete the test PVC + decide the empty ns. **Effort: M (move) / S (label+PVC).**

### ✅ M121. Drift plan redaction — DONE 2026-07-01 (`35dce3a`): plan.txt redacted to structure-only lines (Plan: summary + resource headers) before artifact upload AND the drift-issue embed; attribute values no longer leave the run.
- Non-`sensitive` attributes render into plan text; artifacts are downloadable with repo read. **Fix:** stop uploading raw plans (step-summary tail suffices) or scrub. **Effort: S.**

### ⏳ M6. Packer + ansible netplan dedup (F1.3)
- Source: `archive/outstanding-work-2026-05-16.md` M6.

### ⏳ M10. Lifecycle / `ignore_changes` on Proxmox K8s VMs (F1.5)
- Source: `archive/outstanding-work-2026-05-16.md` M10.

### ⏳ M11. DR runbook with measured RTO/RPO targets
- Source: task #23. Needs your judgment on targets before measurement.

### ⏳ M12. CNPG restore drill Tier B (sibling cluster)
- Source: task #24. Destructive test; needs supervision and maintenance window.

### ⏳ M14. Investigate aws-s3-sync daily-report SSL mismatch (if recurs)
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

### ⏳ M35. Wire dns-aws public IP as 3rd DHCP DNS resolver
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

### ✅ M111. AWS cost spike root-caused + fixed — velero Kopia hourly maintenance → S3 request storm
- **Trigger:** cost alert ~$160 forecast (June ~$138 vs April ~$107). User suspected S3 storage-class transitions failing / archive bloat — **disproven**: the 10 TB `archive` bucket is legit (6 shares, `media/`=7 TB) and correctly in Deep Archive (~$10/mo); storage across all 15 buckets ≈ $17/mo; **0 noncurrent versions**.
- **Root cause:** the spike is S3 **REQUEST** cost. velero's Kopia repo-maintenance ran **HOURLY** (velero default; 11 `BackupRepository` CRs at `maintenanceFrequency: 1h0m0s`) — each run LISTs/GETs/rewrites the whole repo index in S3. ×11 repos ≈ 7,200 runs/mo ≈ **~$70/mo**. `velero` bucket born 2026-05-14 == the May spike month.
- **✅ Fixed (`e9f11d3`):** `defaultRepoMaintainFrequency: 24h` in the velero HelmRelease (verified server arg) + **live-patched the 11 CRs to `24h0m0s`** (velero owns them, not Flux) → ~24x fewer maintenance runs, effective immediately. Also added the missing `logs.grahamsmith.net` lifecycle (auto-expires ~116k dead ALB access-log objects; applied via `terraform-s3`, plan `1 add/0 destroy`).
- **Target ≈ $35/mo** (`aws-cost-teardown` workflow). **⏳ Remaining levers:** M110 consolidation (below) + us-east-1 decom (≈$9/mo). **⏳ USER-only** (CE/wafv2 denied to the scoped key): confirm the S3 `Requests-Tier1/2` line in Cost Explorer (Group-by Usage Type) + optionally grant `ce:GetCostAndUsage` + a Budget alert; console-check for a stray REGIONAL WAFv2 WebACL ($5/mo if orphaned). **⏳ Architectural follow-up (3-2-1):** move velero's PRIMARY BSL to LOCAL MinIO/Ceph RGW (zero-request frequent backups) + weekly BATCHED rclone → Deep Archive for DR. See session-log 2026-07-01.

### ✅ M110. AWS vpn+dns consolidation — COMPLETE 2026-07-02
- **End state (verified live):** ONE AWS box — `private-infra_edge` (t4g.small) + ONE EIP `44.240.60.80` serving WireGuard (wg0+wg1) + Tailscale + **Technitium DNS** (folded via `technitium.yml`; 47 records synced; answers internal names on the EIP + `.10`). The standalone dns instance + EIP `52.40.219.113` + its 3 CW alarms **destroyed** (plan-gated `5 to destroy`); us-east-1 + travel tooling already gone. UniFi `dhcp_dns` re-pointed on all 7 VLANs (4 via TF; **3 via direct UDM API PUT — the archived paultyng provider deterministically 400s on clients/vsan/ceph**, now `ignore_changes` + comment; stack back to `No changes`). dns SG (with the Lambda-managed :53 WAN allows) attached to the edge instance. All `.5`/dns-aws references cleaned (scrape, dns-sync, dns-tier netpol /32, inventory). Cert-SSH trust installed on the box (CI static-key branch remains until the M76-parity cutover — ⚠️ residual below).
- **⚠️ Residuals:** (1) flip the ansible-vm-fleet aws branch to cert auth + run `step-ca-remove-static-key` on the edge box (M76 parity); (2) SG redesign F1-F7 (delete `internal_aws_spokes` /19, port-scope the `-1` rules) still pending; (3) post-M110 doc sweep (the 🟡 flags planted in aws-infrastructure.md / PLATFORM-MANAGEMENT.md / disaster-recovery.md / instance-migration.md / operations-guide / UPDATE-PROCEDURES).

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

### ✅ L25. DONE 2026-07-01 (`35dce3a`) — test-ssh-cert.yml deleted; permissions:{} on bootstrap-runner-key.yml.
- The former still consumes `STEP_JWK_PASSWORD` on the self-hosted runner post-cutover; the two are the only workflows with no `permissions:` block. (2026-07-01 review #14.) **Effort: S.**

### ✅ L26. automountServiceAccountToken sweep — DONE 2026-07-02: false on plex, wikijs, ollama, open-webui, technitium, home-assistant (rolled via Flux).
- 243/255 pods automount a SA token; plex/wikijs/ollama/technitium/home-assistant etc. never call the API — a pod compromise hands each a valid cluster credential. (#15.) **Effort: M.**

### ✅ L27. DONE 2026-07-01 (`35dce3a`), verified live: enforce=baseline on kyverno + plex (the plex "GPU needs privileged" note was STALE — device-plugin GPU, dry-run clean); pg-recovery ns deleted (held a stray csi-rbd-secret COPY — bonus credential cleanup).
- Free hardening; velero/tetragon/home-automation legitimately can't (hostPath/privileged). (#16.) **Effort: S.**

### ✅ L28. DONE 2026-07-01 (`35dce3a`) — no_log on the 3 token-in-URL tasks; structurally verified every technitium_token task now carries it.
- They pass `?token={{ technitium_token }}` in the URL — the admin DNS token lands in ansible output on failure/`-v` (the user/password tasks nearby DO have `no_log`). (#18.) **Effort: S.**

### ✅ L29. Loki per-stream limits — DONE 2026-07-01: per_stream_rate_limit 3MB/10MB-burst + 7d retention_stream for hubble-audit + tetragon export (selectors verified against the actual ruler rules). loki-0 restarted clean.
- Global limits only today — a hubble-audit/tetragon runaway can eat the whole 10MB/s tenant budget; 30d retention applies uniformly to high-volume audit streams. (#19.) **Effort: S.**

### 🟡 L30. Infra PDBs DONE 2026-07-01 (coredns/cilium-operator/csi-provisioner, minAvailable 1, selectors verified, live). **velero cluster-admin deliberately KEPT** — restore must create arbitrary resources incl. RBAC; scoping it risks silently breaking DR. Documented decision; close unless posture changes.
- Drains can momentarily evict both replicas of cluster DNS; velero needs broad-but-not-cluster-admin. (#20.) **Effort: S.**

### ✅ L31. Minor hygiene batch — COMPLETE 2026-07-02: email_fwd abort-MPU + SSE-S3 blocks codified on all 7 default-reliant buckets (plan-gated `7 to add`, applied); WG-key item moot.
- `email_fwd` S3 bucket lacks the abort-incomplete-MPU rule every other bucket has; ~~WG private key passed as CLI `-var` in `terraform-regional-vpn.yml`~~ (moot — workflow deleted 2026-07-01); codify SSE blocks on the 7 buckets relying on AWS-default SSE-S3 (parity only). **Effort: S.**

### ⏳ L1. Proxmox HA cluster expansion
- Source: `archive/outstanding-work-2026-05-16.md` L1. Blocked on adding a 2nd PVE node.

### ✅ L2. Regional VPN destroy doesn't drop the per-region Route53 record — CLOSED (moot 2026-07-01)
- **Moot:** the entire travel-VPN tooling (`aws-regional-vpn/` stack + `modules/regional-vpn/` + workflow) was **deleted 2026-07-01** (M110 travel-tooling cleanup; both workspaces held 0 resources, S3 states removed). Nothing left to fix.
- **Status 2026-05-24 (historical):** module-side fix shipped, workspace-side migration pending.
- **Done:** `infra/terraform/modules/regional-vpn/main.tf` now accepts `dns_zone_id` + `dns_record_name` variables; when both are set (and `use_elastic_ip = true`), creates an `aws_route53_record.vpn_endpoint` resource that destroy-cleans automatically. Output `dns_record_fqdn` exposes the created FQDN.
- **Still TODO:** the live `infra/terraform/aws-regional-vpn/` workspace doesn't use the modules/regional-vpn module — it's a self-contained set of resources that uses `associate_public_ip_address = true` (no EIP, so IP changes on every instance reboot, defeating the DNS-record point). Migrate that workspace to either (a) use the module with `use_elastic_ip = true` + `dns_zone_id`/`dns_record_name`, or (b) duplicate the EIP + Route53 record resources inline. (a) is cleaner but is a one-shot state-migration exercise (destroy + re-apply, accepting brief outage on the next regional spin-up).
- **Original entry:**


- **Source:** observed during M38 (Mumbai destroy 2026-05-23). After `terraform-regional-vpn.yml` action=destroy ran clean, the `vpn-travel.etherport.net. → 13.234.119.106` A record was still present (deleted by hand after). The regional-vpn module manages the EC2/VPC/SG side but doesn't own the public DNS record — that lives in the `route53` module as a separate resource keyed on the EIP. So destroy leaves a dangling record pointing at a freed-up Elastic IP.
- **Risk:** the next AWS customer to grab that EIP would receive traffic addressed to `vpn-travel.etherport.net` until the record's 300s TTL expires. Low real-world impact for a WireGuard endpoint (handshake fails without the right key) but still a leak.
- **Fix options:** (a) move the Route53 record into the regional-vpn module so the per-region apply/destroy owns it end-to-end; (b) wire a `data` reference + `null_resource` `destroy_provisioner` in the regional-vpn module to call `aws route53 change-resource-record-sets DELETE` on teardown; (c) accept it as a manual step in the resurrection runbook. (a) is cleanest.
- **Effort:** S.

### ⏳ L3. EIP → FQDN conversion debt (hardcoded ephemeral IP audit follow-up)
- **Source:** `docs/planning/archive/hardcoded-ephemeral-ip-audit-2026-05-23.md`. Several places still hardcode AWS Elastic IPs that *could* rotate if recreated: `vpn-use1` endpoint `35.169.37.16` in `platform/kubernetes/wireguard/03-deployment.yaml`, dns-aws `52.40.219.113` in M35 plan, etc. Convert each to a Route53 FQDN + DNS lookup at peer/config render time so an EIP swap doesn't require a code change.
- **Effort:** S per site, M overall.

### ⏳ L5. PVE BMC PEF / LAN alert destinations (cross-subnet PET trap)
- **Source:** M40 deliberately deferred. BMC sits on VLAN 200 (10.10.200.21); Alloy/Loki on VLAN 201 (10.10.201.73). For BMC PET traps to reach Alloy, the BMC needs to learn the gateway MAC for 10.10.200.1 — `ipmitool lan print 1` shows `Default Gateway MAC: 00:00:00:00:00:00` currently. Either populate the gateway MAC statically (one-shot ARP lookup + `ipmitool lan set 1 defgw mac <mac>`) or have the BMC do it via gratuitous ARP. Then enable PEF policy 1 with action="send to LAN destination 1" pointed at 10.10.201.73. Today we rely on BMC remote-syslog → Alloy which covers the same alerts.
- **Effort:** S.

### ⏳ L14. AI advisor public approval URL — needs auth gate before advertise
- **Source:** Phase 2 wireup 2026-05-24. The `approve.etherport.net` Traefik IngressRoute is deployed but unadvertised (email links default to the Tailscale URL). HMAC-token-only auth on a public endpoint is too thin — anyone with email access can approve. Before flipping `APPROVAL_BASE_URL` to the public URL, add a zero-trust gate:
  - Option A: **Cloudflare Access** policy gating `*.wind.etherport.net` — requires Google SSO + email-domain restriction. ~30min setup; needs Cloudflare-as-DNS for the domain (currently Route53). Doable but moves DNS authority.
  - Option B: **Tailscale Funnel** — exposes a TS service publicly via TS-managed gate. No DNS change; gate is TS auth. Requires Funnel feature on the tailnet.
  - Option C (current): Stay TS-only; treat public Ingress as future infra.
- **Effort:** M.

### ⏳ L13. Phase 3 (autonomous execute) opt-in alerts
- **Source:** code shipped 2026-05-24 (`AI_PHASE3_ENABLED` env, default OFF). Per the phased rollout plan in `docs/runbooks/archive/ai-advisor-phase3-enable.md`: week 1 add `ai_remediation: "auto"` label to `NodeLocalDNSHighErrorRate` only; week 2 add `CoreDNSDown`; week 3 add `TechnitiumDNSDown` + `HomeAssistantDown`; expand 1/week as comfort builds. Never include CNPG / Ceph / kube-system alerts.
- **Effort:** Trivial per alert (one label addition). Spread across weeks for safety.

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

### ⏳ L16. k8s consistency nits
- Review 2026-06-10. Numbered-file convention (00-/01-) inconsistent across `platform/kubernetes/*`; Velero `backup-volumes-excludes` annotations present on some workloads, absent on most (cost — transient/media volumes get backed up); resource request:limit ratios vary wildly (ollama 12Gi limit vs 4Gi request). Standardize + lint. **Effort:** S each.

### ⏳ L18. `optional: true` secret refs can start pods degraded
- Review 2026-06-10. e.g. `cue-api/01-deployment.yaml` — intentional for bootstrap, but a workload can run in a no-auth state; worth an alert on the empty-secret condition. **Effort:** S.

### ⏳ L20. Branch protection / CODEOWNERS (single-owner risk, accepted?)
- Review 2026-06-10. `main` has no enforceable branch protection (GitHub free plan on a private repo blocks required-reviews/checks) and no `CODEOWNERS`; the headless mini auto-pushes to `main`. Mitigate with a mandatory pre-push CI gate, or explicitly accept the single-owner risk. **Effort:** S (decision).
