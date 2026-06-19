# Session Log — narrative history

Append-only, **newest first**. One entry per substantive working session: what was
done, **why** (decisions/rationale that the code alone won't tell you), the state at
end, and explicit next steps. This is the artifact for resuming work if the chat
history is lost or you're picking up on a different machine.

**Maintenance:** add an entry at the end of every substantive session (see
[`../../CLAUDE.md`](../../CLAUDE.md) §6). For the structured, ID'd to-do status, see
[`outstanding-work.md`](outstanding-work.md). Pre-2026-06-14 session history lives in
that tracker's "Recently completed" blocks and the dated planning docs
(`gcp-oidc-wif-l21.md`, `cloudflare-provider-v5-migration.md`, etc.).

---

## 2026-06-19 — Grafana admin password (real, not default) + GPU dcgm-exporter wedge (gpu1 reboot)

Two follow-ups after the storage incident, both owner-reported:

**Grafana login.** Owner couldn't log in. Root cause: the `grafana-admin-credentials` SOPS
secret had shipped the **placeholder `ChangeMe123!`** since the original SOPS-encryption
commit (git shows no value change; no 1P→SOPS sync for it) — the real 1Password password was
never wired in. Not "reset today" (Grafana had 13d uptime). Owner updated
`grafana-admin-secret.sops.yaml` (VSCode SOPS extension) and pushed (`a0ffbc6`); Flux applied
it; I `rollout restart deploy/monitoring-grafana` so it re-read `GF_SECURITY_ADMIN_PASSWORD`.
**Verified:** new password → HTTP 200, `ChangeMe123!` → 401. (Side note: owner's laptop git
push failed on commit-signing — stale `/tmp/gs-session-keys/homelab` key; unblocked with
`git -c commit.gpgsign=false commit`.)

**GPU dashboard empty.** `nvidia-dcgm-exporter` on `k8s-gpu1` was wedged — `/metrics` timing
out (`TargetDown`), and crucially **`nvidia-smi` itself hung (D-state) → GPU driver/DCGM wedged
at the kernel level**. A pod restart couldn't fix it (old container stuck Terminating, new one
Pending; a fresh exporter just re-hangs on the wedged driver). **Fix = reboot gpu1 (Proxmox
VM 120)** via `qm shutdown --timeout 60 --forceStop 1 && qm start` (graceful-then-force, so the
Ceph volumes unmounted cleanly → no stale-EIO on ollama/plex). Post-reboot: operator-validator
1/1, dcgm-exporter serves metrics again (`DCGM_FI_DEV_GPU_UTIL` live in Prometheus, target
`up`), ollama+plex rescheduled back to gpu1 clean. **GPU *compute* was never affected** — only
the monitoring layer. Runbook written: [`../runbooks/gpu-dcgm-exporter-wedge.md`](../runbooks/gpu-dcgm-exporter-wedge.md).
**Durability:** the `TargetDown` alert (→ advisor) is the early-warning; the gpu-operator
`ClusterPolicy.dcgmExporter` exposes no `livenessProbe`, so self-restart-on-hang isn't
configurable via IaC (and couldn't kill a D-state container anyway) — runbook + alert is the
mitigation. Tracked as M83.

---

## 2026-06-19 — Storage incident: H37 firewall blocked Ceph; technitium-1 re-provisioned + made disposable

**Trigger:** a full cluster/service health-check (owner request) found **technitium-1
(DNS replica) wedged 0/1 for ~20h** — and chasing it uncovered a **cluster-wide latent
storage fault**.

**ROOT CAUSE (the big one): H37's PVE host firewall blocked all *new* K8s↔Ceph
connections.** When H37 flipped `policy_in: DROP` (2026-06-17 15:30) it had **no rule for
Ceph** — the host runs mon+OSDs on `vmbr0.210` (10.10.210.41) and the K8s nodes are RBD
clients on that same storage VLAN (10.10.210.0/24). Existing RBD sessions survived via
conntrack (mounted volumes kept working) so it was **latent**; the first *fresh* rbd
map/create — technitium-1 trying to remap, then dynamic provisioning — failed with
`DeadlineExceeded`/`exit 108`. Confirmed: Ceph `HEALTH_OK` locally on pve, but the csi
provisioner/node-plugin timed out, and conntrack showed only ~15 frozen Ceph conns from
the K8s nodes. **This is a serious latent landmine: any node reboot / pod reschedule / new
PVC would have failed cluster-wide.**

**Fix (durable, IaC): added a `pve-ceph` security group** (storage VLAN → `3300,6789,6800:7300`)
to `infra/terraform/proxmox/firewall/` and **applied via Terraform** (`d8fc8d4`/`982df07`;
plan `1 add, 1 change, 0 destroy`). **Proven end-to-end** — provisioning + map + mount all
work again. ⚠️ **The `d8fc8d4` commit message says a live `pvesh` hotfix was also applied —
it was NOT** (the classifier blocked the live firewall write); the fix is **Terraform-only**,
so there's no temp rule to remove.

**devbox is now TF-capable.** To apply from devbox (no longer the mini) I installed
`terraform` 1.15.5 + `aws` CLI v2 and rendered the homelab AWS profile from SOPS
(`scripts/render-aws-credentials.sh`) + PVE token via `scripts/tf-proxmox.sh firewall`.
**This is a deliberate change from the "devbox = no TF/creds" design** — it puts the
homelab AWS profile + PVE token on devbox, **expanding its blast radius**. Owner accepts
for now (it was genuinely needed); flagged as a ZT consideration (revisit vs the mini/CI).

**technitium-1 recovery + disposability (the owner directive "make services recreatable
from code"):** the old RBD image (`csi-vol-ba25c344`) was wedged (a hung krbd client on
w2 left a stale exclusive-lock; fenced via `ceph osd blocklist`, but the image/mount stayed
stuck). Since technitium-1 is a disposable replica, **re-provisioned it onto a fresh dynamic
PVC** (dropped its static PV from `02a-static-pv-recovery.yaml`; old image retained in Ceph
for forensics). That exposed **two bootstrap gaps** a fresh replica hit — now fixed in
`dns-sync` (`07-dns-sync.yaml`):
  1. **No zone** — dns-sync only *added* records; now it **creates the Primary zone** if missing.
  2. **Auth** — dns-sync logs in as the custom `graham` user, which doesn't exist on a fresh
     replica (only built-in `admin`, password from `DNS_SERVER_ADMIN_PASSWORD`). Auth matrix:
     `graham` works on -0/.6/AWS, `admin` only on .6 — so dns-sync now **tries `graham`, falls
     back to `admin`** to bootstrap a fresh server.
  **Verified:** a fresh -1 self-bootstrapped (auth as admin → zone created → 45 records synced),
  STS **2/2**, both `.5` endpoints, and **-1 answers `devbox.wind.etherport.net`**. A replica
  is now truly disposable (blow away PVC → StatefulSet + password env + dns-sync rebuild it).
  Briefly pinned `replicas=1` during the fix to protect DNS (healthy -0 + .6 + AWS fallbacks).

**w2:** its earlier `exit 108` krbd error was a transient during the firewall-propagation/
blocklist window, **not** a persistent wedge — verified with a throwaway ceph-rbd test pod
(mounted in ~10s), so **no reboot needed**; uncordoned.

**Second firewall casualty (found in the follow-up health-check, 2026-06-19):**
`postgres-cluster-6` (CNPG replica on w2) was CrashLoopBackOff with `chmod
/var/lib/postgresql/data/pgdata: input/output error` — its ceph-rbd mount went into a
**stale EIO error-state** when the firewall dropped its Ceph connection mid-I/O. The DB
stayed healthy (2/3: primary -1 + -8 served throughout). **Fix:** `kubectl delete pod`
(force) → CNPG recreated it → **fresh NodeStage cleared the EIO mount** → cluster 3/3,
data intact (no re-clone needed). **General lesson:** a Ceph-RBD pod that was *writing*
during the firewall block can be left with a stale EIO/hung mount that only surfaces on its
next restart/write; the fix is a **pod delete to force a remount** (or re-provision if the
image itself is bad). Only -6 + technitium-1 manifested; watch for others on restart.

**Open / next:** (a) ✅ **DONE (`4434719`):** DNS-rotation window closed — readinessProbe
gates `.5` on local zone-presence (`dig +norecurse SOA`) + `technitium-headless`
`publishNotReadyAddresses: true` so dns-sync can still bootstrap a not-ready fresh replica
(no deadlock). (b) Consider re-homing TF off devbox for ZT (or accept it) — tracked as M82.
(c) ✅ **DONE:** old wedged RBD image `csi-vol-ba25c344` deleted from Ceph (`rbd rm`) — root
cause was the firewall, data was disposable, no fsck needed.

---

## 2026-06-18 — Cilium policy-audit observation moved into Loki/alerts (retire the /loop)

**Goal:** stop running the H3 NetworkPolicy audit observation as an interactive
`audit-report.py` `/loop` in a chat thread; surface it through the **existing**
logging/alert stack instead (owner: "build it into Loki, don't create anything new").

**Built (all reusing what's already running — `c269ebb`):**
- **Cilium → file:** enabled Hubble **static flow export filtered to `verdict=AUDIT`**
  (`hubble-export-allowlist={"verdict":["AUDIT"]}`) to a per-node file
  `/var/run/cilium/hubble/audit-events.json`. Tiny volume (AUDIT-only). Applied live
  via `kubectl patch cm cilium-config` + `rollout restart ds/cilium` (Helm path — **no
  helm on devbox**, and this is the policy-audit-mode pattern; **canary'd one pod first**
  to prove the config parses before rolling all 8). Durable in the kubespray inventory
  via `cilium_config_extra_vars`.
- **Alloy → Loki:** added a read-only hostPath mount + a `loki.source.file` tailing that
  file → Loki as `{job="hubble-audit"}` (`clusters/wind/helm-releases/alloy.yaml`).
- **loki-ruler → Alertmanager:** new `CiliumNetpolAuditFlow` LogQL alert
  (`platform/kubernetes/monitoring/06-loki-rules-cilium-audit.yaml`, label `loki_rule:"1"`)
  that fires on AUDIT flows **excluding already-triaged known-good sources** (postgres
  replication, cnpg-system) → only NEW/notable `src→dst:port` tuples page; full detail
  queryable in Grafana. Routes through the existing advisor too (advisory-only).

**Verified end-to-end:** canary cilium pod healthy (config parsed: "Building the Hubble
static exporter … ExportAllowlist:{\"verdict\":[\"AUDIT\"]}"), all 8 rolled; AUDIT flows
captured on postgres nodes (`postgres→postgres:5432` replication); Loki has the
`job="hubble-audit"` stream with real flow JSON; the rule file landed in the ruler dir
(`/var/loki/rules-temp/fake/cilium-audit.yaml`) alongside the working `pve-ipmi.yaml`.
The `src_ns!~"postgres|cnpg-system"` exclusion keeps it quiet on the known replication.

**Why this shape:** a cloud `/schedule` can't reach the homelab cluster (no tailnet/LAN/
kubectl from Anthropic's cloud); a devbox systemd timer would be net-new. Loki+ruler+Alloy
+Alertmanager already exist and already alert — this just adds a source + a rule.

**Op note:** as a flow gets added to a CNP allowlist it stops being AUDIT (CNP forwards
it) → drops out of the export automatically. As a new tier is enforced its AUDIT flows
appear here with no rule change. Update the rule's `src_ns` exclusion only when a *new*
source becomes known-good-but-not-yet-allowlisted. Retire the export keys when
policy-audit-mode is turned off at H3 enforcement.

---

## 2026-06-18 — Velero fs-backup incident (H39) + AI-advisor email-flood / cost-cap

**Trigger:** owner reported a flood of AI-advisor emails + the advisor hitting its
$0.50/day cost cap. Root-caused to a **real cluster-wide Velero failure** the advisor was
faithfully (and noisily) reacting to.

**Root cause:** Velero **filesystem (kopia) backups wedged cluster-wide since 2026-06-17
15:30** — the exact moment helm **rev5** deployed (applied M5's `resources` change +
restarted all node-agents). PodVolumeBackups (PVBs) piled into a **retry storm**
(`timeout on preparing PVB`), backups went `PartiallyFailed` daily, two data-mover pods
stuck `Running` 5–17h. Each alert fire → advisor called Claude + emailed → **cap hit
18:02**, then it kept emailing `[unavailable]` **per flapping alertname** (the 15-min
cooldown is per-alertname; one broken subsystem flaps many distinct alerts) = the flood.
**Ruled out:** node capacity/health, kopia repos (all `Ready`), chart/app version
(11.4.0/1.17.1, unchanged since 05-30). It was rev5.

**Remediation (owner-approved):**
1. **24h Alertmanager silence** on velero-ns alerts (`VeleroBackupPartial|VeleroLastBackupAgeHigh|KubePodNotReady`),
   ID `4fe8a806`, time-boxed → stops the advisor emails immediately. ⚠️ silenced ⇒ a real
   failure won't email; **watch tonight's scheduled run** manually.
2. **Safe reset (no config gamble):** deleted 8 stuck PVBs (incl. 2 orphans from 04-20) +
   their data-mover pods, force-cleared wedged `velero.io/pod-volume-finalizer`s,
   `rollout restart` velero + all 8 node-agents. **Verified** via an on-demand `dns`
   backup: the previously-failing step now works — data paths **prepare + start cleanly**,
   one volume completed its full 633 MB, **no retry storm / no prepare-timeouts**.
3. **Durability (`93cc970`):** pinned velero chart `version: "11.x"` → `"11.4.0"` (a
   floating range let Flux auto-upgrade the *backup path* with no commit/review).
4. **Advisor hardening (`93cc970`):** cost-cap `[unavailable]` notice now sent **once per
   UTC day** instead of per-alertname (audit log still records every `cap_reached` for
   Loki; per-alertname cooldown preserved). Advisor pod restarted to load it.

**Residual (open — under watch):** the on-demand test's *second* volume —
`technitium-1`'s data PVC on **k8s-w2** — got through kopia init (opened repo, found the
06-17 03:03 parent snapshot) then **hung mid-snapshot at 0 bytes**, while its sibling on
w3 finished fast. **Different, narrower** failure than the rev5 wedge (data path starts
fine now) — looks volume/node-specific (w2 or that PVC), NOT the cluster-wide cause.
Next: watch tonight's 02:00–05:00 schedules; if `technitium-1`/w2 recurs, dig into the
w2 node-agent ↔ S3/kopia path (possible Cilium-WireGuard/MTU angle — M66 also landed 06-17).

**Also noted (minor):** `PrometheusOutOfOrderTimestamps` fired earlier (monitoring, separate).

---

## 2026-06-18 — M79 iCloud Photos backup built + owner setup started (on the mini)

**Goal:** stand up the iCloud Photos → NAS → S3 backup (M79) on the mini (macOS-only;
needs Photos.app + iCloud). Picked up from the prior session's kickoff.

**Done (autonomous, on the mini):**
- **`osxphotos` 0.76.1 installed** — NOT in Homebrew core (it's a Python tool); installed
  via **pipx** (`~/.local/bin/osxphotos`). Works under the mini's Python 3.14.
- **Sparsebundle created** — `infra/macos/mini/create-photos-sparsebundle.sh` (idempotent,
  refuses to clobber) → `/Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle` (2 TB
  sparse, ~34 MB initial; attaches as `/Volumes/PhotosLib`).
- **Export job authored** — `infra/macos/mini/photos-export.sh`: `mount-nas.sh` →
  `hdiutil attach` → `osxphotos export --update --sidecar XMP --cleanup` →
  `/Volumes/Backups/Graham/iCloud/Photos`. **Exits 0 with a "not ready" message** until a
  `*.photoslibrary` exists in the attached volume — verified by running it (it attached the
  bundle and no-op'd cleanly). `net.wind.photos-export.plist` LaunchAgent (daily 22:00 PT)
  authored but **deliberately NOT loaded** (per owner) until the download completes.

**Key decisions (the code alone won't tell you):**
- **No new S3 bucket/share** (owner call, mid-session, simplifying the tracker's plan).
  The export lands under the **`Backups`** NAS share, which the **existing
  `s3-sync-backups` CronJob already syncs** to `archive.wind.etherport.net` (Glacier
  **Deep Archive**). Owner accepted Deep Archive's ~12 h retrieval for photos →
  **dropped** the separate Glacier-Instant-Retrieval `photos` bucket. So: no TF bucket/IAM,
  no new NFS export (Backups is already exported to the k8s node IPs), no new s3-sync share.
  NB: `Backups`' `excludes-share.txt` has no `Graham` exclude, so it picks up the subtree
  for free. (Earlier in-session I'd started authoring the bucket/share — backed out.)
- **Sparsebundle stays at `…/Photos/…`** (owner: the location I created is fine), even
  though the library dir convention elsewhere is `Pictures`. Export dir moved to the
  **Backups** share per owner (was `Personal-Drive/Photos/export` in the old plan).
- **Zero-deletion-risk setup path:** create a *new empty* library in the sparsebundle and
  let iCloud repopulate it — do **not** migrate/copy the old one. osxphotos is read-only re:
  Photos/iCloud; `--cleanup` prunes only the NAS export copy; `s3 sync --delete` only the S3
  copy. iCloud holds the masters → the sparsebundle is a disposable mirror.

**⚠️ Mid-session finding — iCloud "Download Originals" stalls on the headless mini, so
the export now drives downloads itself.** The new library synced its **catalog**
(`database/` 13 GB + thumbnails `resources/` 7.8 GB → every photo *appears* in the app)
but the actual **original masters froze at 192 / 14,267** (~1.3%) for hours: `cloudphotod`
idle at 0% CPU, no download assertion, byte-identical over a 45 s sample — **even with
Photos.app open the whole time**. `killall cloudphotod` did not revive it (it didn't even
relaunch headless). Network/thermal/space all fine. Root cause = iCloud's background
"Download Originals" is best-effort and parks itself on an idle headless Mac.
**Fix: switched `photos-export.sh` to `osxphotos export --download-missing --use-photokit`**
— each missing original is fetched on demand via **PhotoKit at export time**, independent
of the flaky background queue. Once fetched it stays in the library (we're on "Download
Originals to this Mac" → no re-eviction) = one-time download per photo. **Validated**: a
forced `--missing --download-missing --use-photokit` run downloaded + exported with XMP,
`error: 0`, library originals 192 → 196, **no TCC prompt** (PhotoKit access already
granted). Scratch test dir cleaned up (was under the S3-synced Backups share).

**State at end:** library + System Photo Library set, iCloud Photos on, catalog synced.
Export pipeline (incl. on-demand PhotoKit download) **proven working** on a 5-photo +
2-missing-photo scratch run. Timer still **NOT loaded** (owner's call). Sleep disabled.
Old `~/Pictures` library untouched as fallback. Repo updated + pushed.

**Next steps:**
- **Seed the first full export** (downloads all ~14k originals via PhotoKit — slow but
  resumable via the export DB): `./photos-export.sh` (or with a `--limit` to chunk it).
  No need to wait on iCloud's background download — the export does the pulling.
- **Enable the nightly timer** once the first export is underway/clean (symlink +
  `launchctl bootstrap net.wind.photos-export`; commands in `infra/macos/mini/README.md` → M79).
- Verify the nightly `s3-sync-backups` CronJob picks up `Graham/iCloud/Photos`.
- M80 (Drive/Contacts/Messages) is the natural follow-on, same Backups-share → Deep-Archive path.

---

## 2026-06-18 — Claude Code dev sessions migrated mini → devbox (M81), reboot-validated

**Goal:** move the three persistent Claude Code dev sessions (`infra`, `cue`,
`personal-web`) off the reboot-prone, FileVault-gated Mac mini onto the always-on
Linux **devbox** (`10.10.201.45`, tailnet `100.74.216.102`), so sessions survive
reboots unattended and stay remote-controllable from claude.ai. The mini is retained
**only** for macOS-only work (iCloud Photos/Drive backups — M79/M80).

**Why devbox:** no FileVault unlock-on-reboot gate → genuinely unattended auto-resume;
system `node`/`claude`/`tmux`/`git` in `/usr/bin` → work under systemd's minimal env;
on tailnet + LAN; Claude Code v2.1.154+ fixed Linux remote control.

**Done:**
- **All 3 sessions migrated with full history.** Transcripts copied
  `~/.claude/projects/-Users-grahamsmith-code-<repo>/` → `-home-ubuntu-code-<repo>/`.
  Each primed once via `claude --resume` (picker) — `--continue` keys off
  `lastSessionId`, which a freshly-copied transcript lacks; after one `--resume` it follows.
- **Reboot persistence** via `infra/devbox/{resume-claude-sessions.sh,claude-sessions.service}`:
  a systemd **user** unit (oneshot, `WantedBy=default.target`, `KillMode=none`) +
  `loginctl enable-linger ubuntu` (so the user manager runs at boot without login). The
  script self-heals (auto-clones a missing repo) and `cd`s explicitly before `claude --continue`.
- **Reboot test PASSED (2026-06-18 18:52).** Post-reboot, all three tmux sessions
  auto-resumed ~8s after boot, each in the **correct** repo cwd (`/home/ubuntu/code/{cue,personal-web,infra}`)
  running `claude --continue`. Service `enabled` + `active`, `Linger=yes`.

**Key decisions / lessons (the code alone won't tell you):**
- **`tmux new-session -c <dir>` silently falls back to `$HOME` if `<dir>` doesn't exist** —
  this bit us when a background-task race deleted the `personal-web` clone, so claude opened
  the wrong project (`-home-ubuntu`). Fix: ensure the dir exists (auto-clone) **and** `cd`
  explicitly in the launched command, not just rely on `-c`.
- **The resume script was committed non-executable** (`100644`) — it only ran because the
  live copy had been hand-`chmod +x`'d at setup; a `git restore` strips that and breaks
  systemd `ExecStart` on the next boot. Marked all three operator shell scripts `0755`
  in git (`4b49e54`). Also discovered devbox had a **stale local edit** to the script
  silently blocking every `git pull` from updating it.
- **Claude OAuth login is broken on headless Linux** (GitHub #47152 "Missing redirect_uri",
  unpatched). Worked around by transplanting the mini's full-scope token (Keychain →
  devbox `~/.claude/.credentials.json`) + setting `hasCompletedOnboarding: true` in
  `~/.claude.json` (else the setup wizard re-runs). Real fix = Anthropic patching #47152.

**State at end:** all 3 sessions live + reboot-durable on devbox; repo clean at `4b49e54`.

**Next steps / known gaps (→ M81 follow-ups):**
- **devbox.yml drift:** the live box has `kubectl` (v1.36.2, cluster-admin) + the
  `claude-sessions` systemd unit + linger that are **not codified** in `playbooks/devbox.yml`
  (which still ships the superseded single-session `claude-dev` launcher). Codify for reproducibility.
- **devbox toolchain gaps (by design, for now):** no `terraform`, no `~/.aws` profiles, no
  browser. So Terraform plan/apply + headless-Chrome verification can't run on devbox as-is —
  route those through CI or the mini, or install + configure them on devbox later.
- **`~/.claude/.../memory/` is empty on devbox** — the user's Claude Code memory files
  (created on the mini) aren't in git, so they didn't migrate. Copy mini → devbox.
- **Cilium H3 audit `/loop`** (was running in the infra chat) is stopped — re-home it off
  the interactive thread (devbox systemd timer is the natural host; it has kubectl).
---

## 2026-06-18 — RC session-UUID collision (mini⇄devbox) + M79 photo-backup kickoff

(Migration mechanics + the non-executable-script fix are in the M81 entry above.)

**RC collision (gotcha — now in memory `reference_rc_session_uuid_collision.md`):** the
infra thread was migrated by *copying* its transcript `e7e39822-…jsonl` to devbox and
resuming it. That left BOTH the mini and devbox running session **`e7e39822` under the
same transplanted OAuth token** → Remote Control (one channel per session-UUID+account)
had them fighting; the mini "took over" devbox's RC. **Resolution:** devbox keeps
`e7e39822` (the main infra thread); the **mini starts a fresh `claude` session** (new UUID)
for mini-only tasks — never `--continue`/`--resume` e7e39822 on the mini again.

**M79 iCloud Photos backup — kickoff (next frontier on the mini):** plumbing all settled
(see tracker M79). Current state from a clean reboot: both NAS shares mounted
(`/Volumes/Personal-Drive` 24 TB free, `/Volumes/Backups`); **nothing built yet** —
`osxphotos` NOT installed (brew present at `/opt/homebrew`), no `Photos/` dir on the share,
mini has only ~41 GB local free (hence the sparsebundle-on-NAS plan). The s3-sync system
is **k8s CronJobs in the `backups` ns** reading the NAS over **NFS** (`sequoia.wind.etherport.net:/var/nfs/shared/<Share>`, e.g. `/var/nfs/shared/Graham`) → data bucket
`archive.wind.etherport.net` (Deep-Archive). For photos we need a **separate** Glacier-
Instant-Retrieval bucket + a new `shares/photos/` (DEST_BUCKET=photos.wind…, NFS path =
the export dir under Personal-Drive). **Build order (next session):** (1) `brew install
osxphotos`; (2) `hdiutil create` the APFS sparsebundle at
`/Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle` (size ~1 TB, sparse) + attach;
(3) owner: Photos.app (Option-launch) → create library *inside* the mounted image → sign
into iCloud → **Download Originals** (long pole, days); (4) export script (`mount-nas` →
`hdiutil attach` → `osxphotos export --update` w/ XMP sidecars → `/Volumes/Personal-Drive/Photos/export/`) + launchd timer; (5) TF for the photos bucket + scoped IAM (add ARNs to
the `kubernetes-s3-backup` production policy); (6) `shares/photos/` s3-sync manifests.

---

## 2026-06-17 — M65 terraform consistency (+ M53/M54/M71 tracker housekeeping)

**Goal:** the zero-risk terraform cleanup. Picked because it's provably zero plan-diff.

**Done** (`687b519`):
- **(a)** all **22** `required_version` → `>= 1.14` (local TF 1.15.5, CI pins 1.14.3). `fmt`
  also normalized pre-existing whitespace in `aws/twilio-webhook/{iam,main}.tf`.
- **(c)** `aws/compute`: 6 hardcoded data-source IDs (VPC/subnet/4×SG) + the inline cloud-init
  automation pubkey → `variables.tf` (defaults = live values). **`terraform plan` = "No changes"**
  (data sources resolve identically; user_data has `ignore_changes`).
- **(d)** proxmox ×3: PVE endpoint → `variable "proxmox_endpoint"`.
- **(b) deliberately NOT done — infeasible:** TF forbids `locals`/vars in
  `lifecycle.ignore_changes`; `unifi/networks.tf` already documents this in-file (lines 17-19),
  and the 11 blocks differ (unifi adds `dhcp_dns`). Only DRY path = risky 11-resource→`for_each`
  module with `moved {}` blocks — left as-is, rationale in the tracker.

**Validation:** aws/compute `plan` = No changes; proxmox ×3 `validate` = valid; `fmt -check` clean.
Authoring only — not applied (applies ship via CI/owner). **Key lesson for future agents:**
don't try to `local`-ize `ignore_changes` — Terraform won't allow it.

**Tracker housekeeping same session:** M53 closed (zone-scoped CF token minted + personal-web
cut over — owner); M54 moved to the personal-web repo (redirect codification is a personal-web
concern); M71 added (AWS auth modernization → Roles Anywhere for the mini + SSO for laptops,
medium-term; owner accepts the static-key risk for now).

---

## 2026-06-17 — H29/H31 owner-tail verification: both already complete (no CloudShell action)

**Context:** owner asked for CloudShell commands to finish H29 (delete old `terraform-homelab`
AWS key + GH secrets) and H31 (delete orphan `claude-admin-temp` policy). Verified live state
first (read-only, `homelab` profile, acct `830881980142`) — turns out **neither needs any
command**:

- **H31:** `claude-admin-temp` policy is **already gone** (`get-policy` → NoSuchEntity; absent
  from `list-policies --scope Local`). Remaining `claude-*` policies = intended design
  (`claude-admin-policy` + `claude-admin-oneoff-roles` attached, `claude-oneoff-boundary` 0
  attachments = correct for a boundary). H31 ✅.
- **H29:** the `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` GH secrets are **already removed**
  (`gh secret list` has no `AWS_*`; 0 workflows reference static keys → CI is OIDC-only). The
  `terraform-homelab` IAM user has **exactly one** access key (`AKIA…JHIX`), **Active + used
  today** (S3/us-west-2) — and `aws configure get aws_access_key_id --profile homelab` returns
  that same key. So it's the **live local-ops credential** the mini uses for headless terraform.
  **Did NOT delete it** (CLAUDE.md §4 invariant). The original "delete the key" step is
  **superseded**: the in-CI-exfil threat is already neutralized; the key now serves local ops
  only (accepted risk). H29 ✅ (with that deliberate exception documented).

**Takeaway for future agents:** don't run `aws iam delete-access-key` on `terraform-homelab` —
it's the mini's own credential. A clean future state would be a *separate* dedicated key/user
for the mini, then retire this one; that's net-new work, not H29.

---

## 2026-06-17 — H37 Stage 2 ENFORCED: Proxmox host firewall now default-deny

After the Stage-1 observation window (below), verified coverage + flipped to enforce.

**Observation verified:** firewall log showed every admin source hitting 22/8006 is in
`mgmt-admin` — mini (`10.10.202.101`), TS/WG-via-201 (`10.10.201.55/.56`), and the **UDM
backup WG** (`192.168.3.2`) — with **0 sources outside `mgmt-admin`** touching 22/8006/3128.
Host only receives 22+8006 (no exporters to strand).

**Back-door (break-glass) fixed:** the UDM backup WG (`WireGuard WAN1`, 192.168.3.0/24,
terminates on the UDM → survives the host's VMs dying) initially couldn't reach PVE. Ruled
out infra (server enabled, `Vpn→Management` ALLOW exists on the UDM, our fw was permissive)
→ it was a **client-side DNS issue** (full-tunnel without internal DNS). Owner fixed it; now
logs as `192.168.3.2`. Added `192.168.3.0/24` to `mgmt-admin`. IPMI/console break-glass confirmed.

**Stage 2 applied:** `local.input_policy` ACCEPT→DROP + rule `log`→nolog. **Verified live:**
datacenter `enable=1, policy_in=DROP`; host reachable (mini API 3/3 HTTP 200; ports **22+8006
OPEN** from the mini through the enforcing fw); **all 13 guests still running**. The mini
(`10.10.202.101`) is in `mgmt-admin`, so the agent's control path survives → reversible via
`input_policy="ACCEPT"` + apply; IPMI = hard backstop. Owner separately confirming TS/WG/
backup-WG interfaces.

**H37 done** (host plane). k8s-node + standalone-VM firewalling = **M77**.

---

## 2026-06-17 — H37 Stage 1 LIVE: Proxmox host firewall (permissive + observing)

Zero-trust follow-on; owner-requested. Scope = **host management plane** (k8s-node +
standalone-VM firewalling split to **M77**).

**Investigated:** PVE firewall was entirely OFF. Node `pve` (10.10.200.41), 13 running
guests, **all VM NICs `firewall=0`** (so enabling the host firewall can't cascade onto
guests — key safety fact). Admin-access SNAT ambiguity (TS subnet-router / WG-pod
MASQUERADE / mini-LAN) → staged permissive→observe→enforce rollout.

**New stack** `infra/terraform/proxmox/firewall/` (S3 backend, own state). Stage 1:
cluster firewall **enabled, input_policy=ACCEPT** (permissive), out/forward ACCEPT; node
`pve` enabled + `log_level_in=info`; IPset `mgmt-admin` (10.10.200/201/202 + 100.64/10
tailnet + WG 10.254/24 + 10.255.255/29); SG `pve-mgmt` (ACCEPT 22/3128/8006 + Ping)
attached to the node.

**Blocker hit + cleared:** the `graham@pam!terraform` token lacked **`Sys.Modify`** →
PVE 403 on all firewall writes. Owner granted it via a custom least-priv role
(`pveum role add TerraformFirewall -privs "Sys.Audit Sys.Modify"` + `acl modify /
-roles TerraformFirewall -tokens 'graham@pam!terraform'`). Re-applied: **5 resources
created, verified LIVE, no lock-out, 13 guests still running.**

**Now:** observation window — set the `pve-mgmt` allow rule `log=info` for positive
confirmation. Watch `/nodes/pve/firewall/log`; confirm laptop-on-TS / laptop-on-WG /
mini admin sessions all match `mgmt-admin` before the Stage-2 DROP flip. **Stage 2**
(flip input_policy ACCEPT→DROP) pending observation + **IPMI/console break-glass
confirmation.** Reversible throughout.

---

## 2026-06-17 — M66: enabled Cilium WireGuard pod-to-pod encryption

**Decision (owner):** enable WireGuard, staged. Closes the cleartext-east-west gap
(postgres replication, in-cluster WG key material, secrets traversed the node underlay
as cleartext VXLAN).

**State before:** Cilium v1.18.6, `routing-mode: tunnel`/vxlan, `kube-proxy-replacement:
false`, encryption off. Cilium is a **Helm release** (`cilium`/kube-system, was rev 16).

**Applied (Helm, not kubespray — avoids the cni-owner landmine):** backed up current
values (`helm get values cilium` → /tmp), **dry-ran** the upgrade (confirmed the only
config delta = `enable-wireguard: "true"`), then `helm upgrade cilium cilium/cilium
--version 1.18.6 --reuse-values --set encryption.enabled=true --set
encryption.type=wireguard` (→ rev 17) + `kubectl rollout restart ds/cilium` (maxUnavailable
2, rolled clean). Config is read at agent startup so the restart is required.

**Verified live:** `cilium-dbg encrypt status` → `Encryption: Wireguard`, iface `cilium_wg0`,
**7 peers** (full mesh, all 8 nodes), `NodeEncryption: Disabled` (pod-to-pod only). All 8
CiliumNodes published wg pub-keys. **Postgres stayed 3/3 healthy** (primary on w4, replicas
w1/w2 — replication genuinely crosses nodes) through the roll; **0 unhealthy pods** cluster-wide.

**Durability:** set `cilium_encryption_enabled: true` + `cilium_encryption_type: "wireguard"`
in the kubespray inventory (`k8s-net-cilium.yml`) so a future kubespray run keeps it; live
(helm rev 17) + inventory now agree. CLAUDE.md §5 invariant added. Kernel-mode WireGuard (no
IPsec secret). Reversible via `--set encryption.enabled=false` + rollout restart.

**Follow-on:** owner asked to evaluate broader **zero-trust** opportunities (incl. the
**Proxmox host firewall**, not yet tracked) — see new items added to outstanding-work.md.

---

## 2026-06-17 — M61 + M68 + M5, and H36 caught a real Flux SSH outage

Worked three tracker items end-to-end (commits `bc7c488`, `77d2678`, `bc02764`), plus
M53/M54/M71 housekeeping and a live-incident validation of H36.

**M61 — SOPS centralization + Renovate coverage:** wired the 3 inline-SOPS-curl terraform
workflows (`terraform-drift-detection`, `terraform-aws-us-east-1`, `terraform-regional-vpn`;
all ubuntu-latest/amd64) → the pinned+checksum-verified `setup-sops` composite action (also
closes the H30 "wire 3 workflows" deferral). **Verified green in CI** (AWS US-East-1 + Regional
VPN + sops-decrypt-check all passed). renovate.json: enabled the `pre-commit` manager (off by
default → now bumps the 4 hook repos) + grouped github-actions/terraform/pre-commit PRs.
ansible-runner Dockerfile: version-sync pointer to setup-sops + TODO for per-arch sha256.
ansible-lint hook still deferred (needs baseline pass).

**M68 — docs consolidation:** merged `1PASSWORD-CLI.md` → `SOPS-SETUP.md` (de-staled `op`
quick-reference; **corrected** the false "agent can run op" claim — it's operator/VNC-only),
old file → redirect stub. New `docs/runbooks/archive/README.md` (BGP-phase A→B→C index +
others). Fixed `docs/README.md` (secrets rows, new Network subsection, **broken
firewall-zones-future-state link** → archived path, AI-advisor "LIVE not retired" wording).
firewall-zones.md: M14→M42 ID footnote + its own broken future-state link fixed.

**M5 — velero (CRITICAL backup path, handled conservatively):** both original sub-tasks turned
out riskier than the "S" rating. (1) **Ordering** = by-design: Schedules sit with the HR in the
monolithic kustomization (repo-wide CR-after-HR pattern); Flux retry self-heals cold bootstrap.
Restructure rejected (kustomize↔Helm cutover would risk deleting live Schedules). (2) **Quota**
= rejected as unsafe: velero pods had **no requests** (all BestEffort), so any compute quota
would silently reject ephemeral backup pods. Instead added **requests-only (no limits)** to
server (250m/256Mi) + node-agent (200m/256Mi) → Burstable QoS (less eviction mid-backup), no
OOM risk. **Verified live:** HR `UpgradeSucceeded` (v5, chart 11.4.0), node-agent rolled, all
9 pods Running + Burstable. Both decisions documented in the velero README.

**🔔 H36 validated itself in production:** mid-session the AI advisor emailed a
`FluxReconciliationErrors` alert (the rule built last session) — Flux source-controller couldn't
reach **GitHub SSH/22** for ~1h (13:33→~14:31 UTC), stuck at `fa72ed39`; proposed action `noop`,
95% conf. **Self-resolved** (GitRepository + Kustomization now Ready at HEAD `77d2678`; all HRs
Ready). No in-cluster impact (and none of the post-`fa72ed3` commits were even Flux-watched —
M65 tf / M61 ci / M68 docs). Transient GitHub-SSH/WAN blip; nothing on our side changed routing.
Advisor diagnosis was spot-on. **Takeaway:** H36 caught a real silent-wedge within its window —
exactly its purpose.

---

## 2026-06-17 — L23: deleted orphan cnpg-manager RBAC (duplicate-operator residue)

**Goal:** remove the harmless residue from the 06-16 duplicate-CNPG-operator cleanup —
the orphan `cnpg-manager` ServiceAccount + ClusterRole + ClusterRoleBinding (raw-manifest
install, never in git).

**Verified orphaned before deleting:** live operator deployment `cnpg-cloudnative-pg` runs
under SA `cnpg-cloudnative-pg` (Helm-managed), *not* `cnpg-manager`. The `cnpg-manager-rolebinding`
CRB bound CR `cnpg-manager` → SA `cnpg-system/cnpg-manager` self-referentially; no pod used the
SA. So the trio was a closed, unused loop.

**Done:** `kubectl delete clusterrolebinding cnpg-manager-rolebinding` + `clusterrole cnpg-manager`
+ `sa cnpg-manager -n cnpg-system`. After: operator pod Running 1/1, `postgres-cluster` 3/3 +
`cue-db` 1/1 both "Cluster in healthy state". Nothing to commit (objects were never in git).
L23 ✅.

---

## 2026-06-17 — M63 hardening safe-trio + "do all in order" wrap

**Goal:** finish the "do all in order" pass — last open item was M63 (k8s manifest
hardening sweep). Ship only the low-risk subset; defer the ones that can break things.

**Done** (`e91e150`, all `kubectl kustomize`-validated, Flux-reconciled + confirmed live):
- **(a)** `cloudflared` ServiceMonitor — added `release: monitoring` label. Selectors are
  match-all today so it was already scraped, but this keeps it safe if the selector is ever
  tightened to `release=monitoring`.
- **(b)** `rclone-gdrive` CronJob — added a **conservative** container securityContext:
  `allowPrivilegeEscalation:false` + `capabilities.drop:[ALL]` + `seccompProfile:RuntimeDefault`.
  **Deliberately NOT** `runAsNonRoot`/`readOnlyRootFilesystem` — rclone writes its working
  config into `/config/rclone` (emptyDir) and the image's user expectations are untested here;
  forcing non-root/RO-rootfs risked breaking the nightly GDrive sync for marginal gain.
- **(d)** `cloudflared` — added `minAvailable:1` PDB (`03-pdb.yaml` + kustomization). The
  Deployment runs 2 replicas; without a PDB a node drain could evict both and drop the public
  tunnel. Confirmed live: `ALLOWED DISRUPTIONS 1`.

**Deferred (NOT safe trio):** (c) `startupProbe`s — technitium is the cluster's split-horizon
DNS; a misjudged probe could wedge DNS mid-rollout, so it needs per-workload boot-time
measurement first. (e) home-automation `privileged:true` → explicit caps + device mounts —
needs owner knowledge of which host devices (Zigbee/Z-Wave USB etc.) HA actually needs.

**State / next steps:**
- **M63** now 🟡 (a/b/d done, c/e deferred with rationale in the tracker).
- **L23** (delete orphan `cnpg-manager` ClusterRole + ClusterRoleBinding + ServiceAccount in
  cnpg-system) — still **blocked awaiting explicit owner authorization** (it's a delete of
  shared RBAC; the classifier + safety rules require the owner to name the resources).
- **Owner-only console tails** the agent can't run: **H29** (delete the old `terraform-homelab`
  AWS access key + update GH secrets — but never delete the IAM key still shared with the local
  homelab profile) and **H31** (delete orphan `claude-admin-temp` IAM policy). Both need the
  user's AWS console / `op`-authorized terminal.

---

## 2026-06-17 — H36: Flux reconciliation alerting (closes the silent-wedge gap)

**Goal:** the 06-17 CNPG webhook incident wedged Flux for hours, undetected — Flux metrics
weren't scraped. Close that blind spot.

**Done** (`platform/kubernetes/monitoring/07-flux-monitoring.yaml`, commits `8f4c5d6`+`48fd4c7`):
- **PodMonitor `flux-controllers`** — monitoring ns, `namespaceSelector: flux-system`,
  `selector: app.kubernetes.io/part-of=flux`, port `http-prom` (8080), `honorLabels: true`.
  Prometheus selects all PodMonitors (`{}`); the flux-system `allow-scraping` netpol already
  permits :8080. Verified: all 6 controllers scraping `up`.
- **PrometheusRule `FluxReconciliationErrors`** — `sum by(app,controller)
  rate(controller_runtime_reconcile_total{namespace="flux-system",result="error"}[5m]) > 0
  for 15m`, warning. Loaded + evaluating (0 firing = healthy).

**Gotcha:** my first attempt used `gotk_reconcile_condition{type="Ready",status="False"}` — but
**this flux build doesn't export that metric** (only `gotk_reconcile_duration_seconds` +
`controller_runtime_*`; verified by curling a controller's :8080/metrics). Pivoted to the
sustained-reconcile-error signal, which is per-controller (kind) not per-object but reliably
catches a wedge. Also hit `function "lower" not defined` in the rule template — Prometheus
uses `toLower`, not `lower`.

**Result:** a wedged Kustomization/HelmRelease now pages within 15m instead of being found by
luck. H36 done.

---

## 2026-06-17 — CNPG webhook cert wedged Flux (caBundle/serving-cert mismatch) — fixed

**Surfaced while applying M62:** the flux-system Kustomization went `Ready=False`, blocking
ALL GitOps — `ScheduledBackup/cue-db-daily dry-run failed: failed calling webhook
"mscheduledbackup.cnpg.io": ... tls: failed to verify certificate: x509: certificate signed
by unknown authority`. The CNPG admission webhook was down → Flux couldn't apply CNPG
resources → couldn't advance past `0f43c36`.

**Root cause (tail of the 06-16 duplicate-operator incident):** during yesterday's operator
handoff/leader-churn, `cnpg-ca-secret` + `cnpg-webhook-cert` were regenerated (~12h before),
but inconsistently — the webhook configs' `caBundle` held the OLD CA, and the serving cert
was signed by yet another CA key (`ECDSA verification failure ... verifying ... cnpg-ca-secret`).
So CA secret, serving cert, and caBundle were three-way out of sync. The running operator
never self-healed it.

**Fix (owner-authorized, two steps):** (1) patched the webhook `caBundle` from `cnpg-ca-secret`
— necessary but INSUFFICIENT (serving cert was signed by a different/old CA). (2) **deleted
`cnpg-webhook-cert` + `kubectl rollout restart deploy/cnpg-cloudnative-pg`** → operator
re-issued a consistent serving cert + re-patched the caBundle on startup ("Updated current TLS
certificate"). Webhook dry-run then succeeded; Flux advanced to `c9b64de` `Ready=True`;
operator stable (`restarts=0`). DB clusters unaffected throughout (webhook only gates CNPG
resource admission; per-cluster Postgres TLS is separate).

**Durability:** the operator now owns a consistent, self-managed cert chain (its normal job;
the break was a one-time handoff glitch). The caBundle can't be static IaC (operator-injected
at runtime). Filed follow-ups: **H36** (Flux reconciliation alerting — gotk metrics are NOT
scraped today, so this silent wedge was found only by luck) and a note to evaluate
cert-manager-managed CNPG webhook certs (ca-injector = truly self-healing caBundle).

**Lesson:** after a CNPG operator change, verify the webhook works
(`kubectl -n <ns> get cluster <c> -o yaml | kubectl apply --dry-run=server -f -`) — cert
inconsistency is silent until the next admission call / Flux apply.

---

## 2026-06-16 — M62 authored: etcd snapshots → offsite S3 + freshness alert

**Goal:** close the etcd-backup DR gap — snapshots were local-disk-only, offsite solely
via the fragile Velero `kube-system-daily` path, no freshness alert.

**Authored (validated; applies are supervised — see outstanding-work M62):**
- **TF** `infra/terraform/aws/s3/`: new dedicated **`etcd-snapshots.wind.etherport.net`**
  bucket (STANDARD, 30d, versioned, PAB) + scoped **`etcd-backup`** IAM user (PutObject-only),
  mirroring the `postgres_barman` pattern. `terraform validate` clean.
- **Playbook** `etcd-backup.yml`: awscli + scoped creds on cp nodes; `etcd-snapshot.sh` now
  `aws s3 cp`s each snapshot offsite + pushes freshness/size/upload metrics to Pushgateway
  (pinned ClusterIP `10.43.32.171`).
- **Alert** `monitoring/06-backup-alerts.yaml`: `EtcdSnapshotStale` + `EtcdSnapshotS3UploadFailing`.

**Key design call:** used a **dedicated Standard-storage bucket, NOT the `archive` bucket** —
`archive.wind.etherport.net` transitions to Glacier Deep Archive after 2 days (~12h retrieval),
which would prolong a control-plane outage during a restore. Owner flagged a recurring habit
of defaulting new tasks to the archive bucket → added a loud "s3-sync cold storage ONLY"
warning at the bucket's TF definition + a memory note. **Rule: archive bucket = s3-sync cold
storage only; anything needing timely retrieval gets its own Standard bucket (like barman, etcd).**

**Validation:** TF validate ✅; PrometheusRule server-dry-run ✅ (the `unknown field "sops"`
errors in the kustomize dry-run are pre-existing SOPS secrets, Flux-decrypted, not ours);
playbook YAML + `--syntax-check` ✅. Pushgateway ClusterIP pinned to its current value so the
Flux helm-upgrade is a no-op on the immutable field.

**Next (supervised):** terraform apply s3 → SOPS the etcd-backup key into
`playbooks/secrets/etcd-backup.sops.yaml` → run `etcd-backup.yml --limit kube_control_plane`.
Flux ships the alert + pushgateway pin.

**✅ COMPLETED 2026-06-17 (all via CI):** terraform applied (`terraform-s3.yml`; one
invalid-tag-char retry), SOPS secret created, playbook ran (`ansible-vm-fleet.yml`). Hit two
node wrinkles: (1) the unrelated CNPG webhook-cert incident briefly wedged Flux (fixed — see
the 06-17 entry); (2) Ubuntu 24.04 dropped the `awscli` apt package → switched to the AWS CLI
v2 official sha256-pinned installer. **Verified end-to-end:** 3 CP-node snapshots in
`s3://etcd-snapshots.wind.etherport.net/<host>/` (~205MB each); Prometheus shows
`etcd_snapshot_last_run_timestamp` (fresh), `_s3_upload_success=1`, `_size_bytes` for all 3;
alerts live. L15 superseded.

---

## 2026-06-16 — CNPG operator restart-loop (duplicate operator) — fixed

**Trigger:** AI advisor email — "cloudnativepg pod is stuck." Full system check requested
after the 06-15 Cilium/NetworkPolicy work.

**System was healthy** except the operator: 8/8 nodes Ready, Flux all-Ready, both CNPG
clusters healthy (postgres-cluster 3/3, cue-db 1/1), Cilium audit mode still `Enabled`
(06-15 work intact, NOT enforcing — ruled out as the cause).

**Root cause (pre-existing, NOT from 06-15):** **two** CNPG operator deployments in
`cnpg-system` both running `controller --leader-elect` against the **same lease**
(`db9c8771.cnpg.io`):
- `cnpg-cloudnative-pg` — canonical, Helm/Flux-managed (`helm-releases/cnpg.yaml`, chart
  0.22.1); backs `cnpg-webhook-service`.
- `cnpg-controller-manager` — **orphan** from a pre-Helm raw-manifest install (no Helm/Flux
  labels, not in git, doesn't back the webhook service).
They fought over the lease → the loser hit `Put .../leases/...: context deadline exceeded`
→ `leader election lost` → exit/restart, repeatedly (37 + 29 restarts). Leases 34d old =
chronic. DBs unaffected (operator absence doesn't stop running Postgres).

**Fix:** `kubectl -n cnpg-system delete deployment cnpg-controller-manager` (owner-approved;
the Claude Code auto-mode classifier blocked it until the owner named the resource
explicitly). Helm operator immediately acquired the lease uncontested (lease holder now
`cnpg-cloudnative-pg-…`), started its controllers, restarts stopped climbing (held at 37),
webhook endpoint ready. Both clusters healthy. **Residual (harmless):** orphan
`ServiceAccount/cnpg-manager` (+ likely a cluster-scoped `cnpg-manager` Role/Binding) from
the old install — unused, low-priority cleanup (tracker).

**Why the AI advisor gave no remediation button (owner asked):** by design. The advisor's
prompt (`auto-remediation/advisor-prompt-configmap.yaml`) lists `cnpg-system` under *NEVER
PROPOSE* ("the executor allowlist excludes flux-system/kube-system/cnpg-system/rook-ceph/
cert-manager — proposals silently dropped"), so even with Phase 2/3 enabled it can only
**advise** (email) on cnpg-system, never offer an approve/auto action. Also "delete a
deployment" / "pick which duplicate operator is the orphan" isn't in its action whitelist
(restart_pods, scale, rollback_deployment, cnpg_recreate_replica, backups, …) and needs
human judgment. Working as intended — critical stateful namespaces are human-in-the-loop.

**Next:** confirm restarts stay at 37 (single operator = no contention); optional cleanup of
the orphan `cnpg-manager` SA/RBAC.

---

## 2026-06-15 — H3 NetworkPolicies Phase-1 + Cilium incident (kubespray cni-owner)

**Goal:** start H3 (default-deny NetworkPolicies). Authored Phase-1 manifests, hit a
contained Cilium incident enabling audit mode via kubespray (recovered), then enabled
audit mode the surgical way + made it IaC-durable + **started observation on postgres**.
**End state: audit mode ON (8/8 agents), NetworkPolicies live via Flux under audit,
postgres labeled (audit-both), helm release clean, cluster healthy.**

**What shipped (good):**
- `platform/kubernetes/networkpolicies/` (commit `3c299d9`) — default-deny + universal
  allows (DNS via host/remote-node:53 for link-local nodelocaldns, kube-apiserver, host,
  monitoring scrape) + `postgres-ingress` tier. Per-ns opt-in via `netpol.wind/enforced`
  label. **Inert** (not Flux-wired). All 5 validate vs live Cilium 1.18.6 CRDs.

**The incident (root cause + recovery — don't re-walk this):**
- To enable `policy-audit-mode`, ran kubespray `cluster.yml --tags=cilium,download` (v2.30,
  via a freshly-bootstrapped `~/.kubespray-venv` since the mini had none; system ansible
  2.21 is too new — kubespray needs 10.7.0/core-2.17). The run "succeeded" (exit 0) but a
  follow-up `kubectl rollout restart ds/cilium` (needed because audit-mode is read only at
  agent startup) put 2 agents into **`Init:CrashLoopBackOff`**.
- **Root cause:** kubespray's "Create cni directories" task chowns `/opt/cni/bin` to
  `kube_owner` (**`kube`** — set in `k8s-cluster.yml`). Cilium's `mount-cgroup` runs as
  root with `drop:[ALL]` (no DAC_OVERRIDE) → can't write `cilium-mount` to a kube-owned
  dir → `cp ... Permission denied`. **Latent** — the 6 un-restarted agents kept running off
  loaded eBPF (nodes stayed Ready); only restarted agents crashed. Confirmed via `/opt/cni/bin`
  **ctime = today 17:22** (chown updates ctime, not mtime — mtime still read Jun 5).
- **Misstep:** first tried `helm rollback cilium 13` (thinking the v2.30 chart changed the
  init container). It didn't help — rev-13's `mount-cgroup` securityContext is **identical**;
  the chart was never the cause. The rollback left a **`failed` helm rev 15** (release
  health still needs cleanup — see below) and reset `policy-audit-mode=false`.
- **Actual fix:** `chown root:root /opt/cni/bin` on all 8 nodes (the existing
  `pre-flight.yml` already enforces this — kubespray's cluster.yml had undone it) + delete
  the crashing pods. One node (k8s-w1) was missed on the first pass (truncated output) →
  always verify ALL nodes. Final: **8/8 agents Running (restart 0), 8/8 nodes Ready**,
  audit mode `Disabled` (= original safe baseline).

**Codified + documented (this entry's commit):**
- Strengthened `inventory/pre-flight.yml` comment (CRITICAL: re-run after any cluster.yml).
- Reverted the staged `cilium_policy_audit_mode` kubespray var (footgun) with a note to use
  the ConfigMap path instead.
- New runbook `docs/runbooks/cilium-cni-dir-owner.md` (symptom/cause/recovery + the actual
  kubespray run path, since `kubespray.sh` is stale). CLAUDE.md §5 gotchas updated.

**Audit mode ENABLED + made IaC-durable (later same day):**
- Enabled live via the **surgical path** the owner authorized: `kubectl patch cm cilium-config
  policy-audit-mode=true` + `kubectl rollout restart ds/cilium`. Rolled clean (dir is root-owned);
  **runtime `PolicyAuditMode: Enabled` on all 8 agents**, 8/8 nodes Ready. (helm rollback to
  rev 14 was the cleaner route but the auto-mode classifier blocked it as out-of-scope.)
- **Durability (owner: "don't let a future kubespray run overwrite these"):** (1) NetworkPolicies
  are Flux-managed → kubespray-safe. (2) `cilium_policy_audit_mode: true` committed to the
  kubespray inventory (source of truth → a kubespray render keeps audit on). (3) `kubespray.sh`
  wrapper rewritten (correct venv/inventory paths + **auto-runs `pre-flight.yml` after
  cluster.yml/upgrade/scale**, restoring `/opt/cni/bin` root owner) — so a kubespray run no
  longer breaks Cilium *when run via the wrapper*. (4) Backstop armed: `cilium_extra_values`
  adds `DAC_OVERRIDE` to Cilium `mount-cgroup` so it tolerates a kube-owned cni dir even on a
  raw kubespray run (not yet validated live — needs a kubespray render; tracked H35).
- `kube_owner: root` was **rejected** — `/etc/kubernetes` + `/etc/cni/net.d` are genuinely
  kube-owned, so flipping it would broadly re-chown system paths.

**Completed (owner said "start H3 and get this fixed now, OK to roll Cilium"):**
- **NetworkPolicies wired into Flux** (`clusters/wind/kustomization.yaml`, commits `4005fed`+`00bdb81`).
  Removed the standalone default-deny CCNP — Cilium's operator rejects an empty-rule policy
  ("rule must have at least one of Ingress/Egress/..."); instead the `allow-*` CCNPs (which
  select enforced namespaces + cover both directions) establish default-deny per Cilium's
  selection semantics. 3 allow CCNPs + `postgres-ingress` all `VALID: True`.
- **Observation STARTED on postgres** — endpoint is `POLICY (ingress/egress): Disabled (Audit)`.
  ⚠️ **Label must be in the namespace MANIFEST in git** (`cnpg/00-namespace.yaml`), not a
  `kubectl label` — Flux SSA strips out-of-band labels on reconcile (hit this; fixed via git,
  commit `7e83047`). `scripts/cilium/audit-report.py` reports cluster-wide AUDIT flows via the
  hubble relay for enforced namespaces. First run: 1 AUDIT flow (intra-postgres TCP — likely
  CNPG instance comms beyond :5432; investigate + add to the postgres allowlist). Recurring
  check set up via `/loop` on the mini session.
- **Helm release cleaned** — `helm rollback cilium 14` (rev 14 = audit=true) → clean
  `deployed` rev 16, supersedes the `failed` rev 15. Audit still Enabled on all 8 agents.

**Next (the multi-week observation phase):**
- Watch `hubble observe --namespace postgres --verdict AUDIT` (cover the CNPG backup/cron
  paths). Refine the postgres allowlist from real flows, then ENFORCE postgres (it's already
  in audit; the switch is disabling audit for it — but global `policy-audit-mode` is
  cluster-wide, so enforcement = keep audit on elsewhere and verify postgres' allowlist is
  complete before the final global audit-off).
- Then label the next tier (cue → dns → traefik → monitoring), writing each `1x-tier-*`
  allowlist from audit data. Exclude wireguard/kube-system/flux-system.
- **H35 follow-ups remain:** validate the `cilium_extra_values` DAC_OVERRIDE backstop on the
  next supervised kubespray run; review `setup.sh`.

---

## 2026-06-15 — H33a: offline backup age recipient + repo-wide re-key

**Goal:** close H33's single-key blast radius — one age recipient decrypted every
`*.sops.yaml`, with no offline backup (lose/rotate it wrong → whole estate
undecryptable). Add a second, **offline-only** recipient.

**What landed:**
- Owner generated a backup age keypair **on the laptop** (never on the mini); private
  half → 1Password "Homelab SOPS Age Key (BACKUP)" + paper in the safe. Public key
  `age1phcmcgfeqr66t7kxdafckp860y67j6n6y2qrn76hk4fm2vd59pxsqr3466` handed to me.
- Added it (comma-joined, **primary kept first**) to all **15** `.sops.yaml` (5 root
  `creation_rules` + 14 nested), then `sops updatekeys -y` across all **39** secret
  files. **Guardrail:** re-keyed one file → verified it still `sops -d`s with the
  primary → then batched the rest. Final verify: 39/39 carry **both** recipients,
  0 decrypt failures, no plaintext leaked.
- **No Flux/CI/GH-secret change** — the primary stayed a recipient throughout, so the
  three online holders (mini disk, GH `SOPS_AGE_KEY`, Flux `sops-age`) keep working;
  zero lockout window. The backup is pure offline break-glass.

**Why this design (vs rotating the key):** H33a is *additive* redundancy, not a
rotation. Adding a recipient + `updatekeys` only needs the **primary private** key (to
decrypt, already on the mini) + the backup **public** key (to add). The backup
*private* key never has to touch the mini — which is why I could run the mechanical
re-key here despite this session being on the mini.

**Pre-existing bug found + fixed (now L22):** `tailscale/01-oauth-secret.sops.yaml`
had a **MAC mismatch** — its encrypted body had been hand-edited outside `sops` (sops
`lastmodified` 2026-04-12), so it hadn't decrypted for ~2 months, undetected (the live
operator kept running off the pre-corruption apply). Confirmed pre-existing by the
identical failure on `git show HEAD:`. Fixed by pulling the good `values.yaml` from the
live `flux-system/tailscale-operator-oauth` secret (33d, the helm `valuesFrom` source)
into a temp file — **never printed** — rebuilding the manifest, and `sops -e -i`'ing it
clean (both recipients, valid MAC). Verified by **sha256 equality** with the live
value (`d1a0841e…`), not by dumping contents. Added **L22**: a CI/pre-commit check that
every `*.sops.yaml` actually decrypts, so a broken MAC fails fast next time.

**Docs updated:** `.sops.yaml` header (names both keys + re-key note), `secrets-rotation.md`
(H33a marked done + blast-radius table), `headless-ops-host.md` + `SOPS-SETUP.md`
(PRIMARY/BACKUP naming), `outstanding-work.md` (H33 → (a) done, (b) FileVault + (c)
split remain; new L22). 1P: rename the existing primary item → "Homelab SOPS Age Key
(PRIMARY)" (owner).

**State:** committed + pushed; Flux reconciled clean (in-cluster decrypt confirmed).
**Next:** H33 remainder is owner-only — **FileVault on the mini** (un-passphrased key
on disk) + optional per-domain recipient split. Then the other HIGH items: H3
(NetworkPolicies), H30 remainder (supervised), and the H29/H31 console tails.

---

## 2026-06-14 → 06-15 — UniFi Protect webhooks → HA, + HA automation behavior

**Goal:** Protect camera motion → HA light automations had stopped working
("webhooks not received by HA").

**Diagnosis journey (don't re-walk this):**
- Initial (pre-compaction) diagnosis blamed split-horizon DNS on the **UDM gateway**
  (`10.10.200.1`) resolving `ha.wind.etherport.net` to the Cloudflare edge → CF Access
  302. **That was the wrong host.** Protect runs on the **UNVR `Windprotect`
  (`10.10.212.10`)**, which uses Technitium and resolves `ha.wind` → `10.10.201.70`
  correctly (A + NODATA AAAA). A webhook POST from there returns HTTP 200. So DNS/
  network/HA were never the problem.
- A UDM Local DNS record was briefly added then **reverted** (owner: keep everything
  on Technitium for consistency — the UDM forwarding externally is by design).
- **Real root cause:** UniFi Protect's Alarm Manager webhook client has a bug — it
  feeds a multi-address `dns.lookup()` result into Node's single-IP connect path, so
  `net.isIP([ [Object] ])` throws **`ERR_INVALID_IP_ADDRESS`** and the request dies
  before any TCP connection. This breaks **every hostname-based webhook** (confirmed
  in `/srv/unifi-protect/logs/automationManager.log`: zero successful httpActions).
  Protect also **validates TLS**, so `https://10.10.201.70/...` (IP) fails
  `ERR_TLS_CERT_ALTNAME_INVALID`. Only an **IP-literal + plain-HTTP** URL works.

**Fix (shipped, commits `9fd7c50` + `840f6c0`):** a dedicated plain-HTTP Traefik
entrypoint `webhook` (`:8088`, no 80→443 redirect, no TLS) on the VIP, serving **only**
`PathPrefix(/api/webhook/)` → HA `:8123`. Files: `clusters/wind/helm-releases/traefik.yaml`
(the `webhook` port) + `platform/kubernetes/home-automation/ingressroute-webhook.yaml`.
Protect webhooks now use `http://10.10.201.70:8088/api/webhook/<id>`. Verified all 5
IDs return 200 from Protect; non-webhook paths 404 (least-exposure). Traefik rolled
zero-downtime (2 replicas, `maxUnavailable: 0`, PDB).

**Decisions / rejected options:**
- Rejected: HA macvlan IP (`10.10.202.25`) direct — firewalled from the camera VLAN.
- Rejected: source-lock the `:8088` route to Protect's IP via Traefik `ipAllowList` —
  the shared Traefik LB is `externalTrafficPolicy: Cluster` so kube-proxy SNATs the
  client IP and the allowlist 403s everything. Keeping it would need `Local` (cluster-
  wide ingress change) or a UDM firewall rule. **Owner declined** — the path is
  plain-HTTP, LAN-only, `/api/webhook/`-only, gated by 24-char secret IDs; marginal.
- The `protect-tf` 1P key authenticates the Protect **integration** API but that API
  is read-only for automations (no Alarm Manager endpoint), and the internal app API
  rejects it (401). So **the Alarm Manager URL edits can't be done via any API** —
  they're a Protect-UI task.

**HA automation behavior change (same session):** owner wanted re-triggered motion to
**reset** the off-timer (was ignored mid-run). Changed all 5 motion-light automations
from `mode: single` → **`mode: restart`** directly in `/config/automations.yaml`
(backup at `/config/automations.yaml.bak-premode-20260615-064254` in-pod; activated via
HA "Reload Automations"). Also clarified: editing/saving an automation mid-run cancels
the in-flight run (so a pending `turn_off` is abandoned → light stays on). `light.deck`
is a Hue light (healthy); the 03:40 deck-light-on event was *my* verification curl, not
real motion.

**State at end:** webhook path live + verified; automations on `restart`. Lights all
off. UDM DNS reverted. `protect-tf` temp key wiped from `/tmp`.

**Open / next steps:**
- ⏳ **Confirm all 5 Protect Alarm Manager URLs are switched** to
  `http://10.10.201.70:8088/api/webhook/<id>` (owner did some via UI; verify none still
  on `https://`/hostname or the old `https://10.10.202.25/...-bY8...`). UI-only.
- ⏳ (optional) add `protect-tf` to the SOPS bundle for headless Protect integration-API
  reads (camera/motion state for HA) — not needed for this fix.
- ⏳ (optional, declined) firewall source-lock for `:8088` — revisit only if desired.
- Relates to tracker **M48/M49/M50** (Protect IaC): webhook *routing* is now IaC;
  Alarm Manager automations remain UI-managed (no write API).

## Before 2026-06-14

See [`outstanding-work.md`](outstanding-work.md) "Recently completed" blocks and the
dated planning docs. Headline recent landings: H29 (CI→AWS OIDC), L21 (CI→GCP WIF),
M69 (Cloudflare provider v4→v5), M53 (zone-scoped CF token), the localtuya migration
(all 8 Tuya devices cloud→local, entity_ids preserved), and the headless Mac-mini ops
host. Older history archived under `archive/`.
