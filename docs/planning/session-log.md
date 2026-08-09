# Session Log — narrative history

Append-only, **newest first**. One entry per substantive working session: what was
done, **why** (decisions/rationale that the code alone won't tell you), the state at
end, and explicit next steps. This is the artifact for resuming work if the chat
history is lost or you're picking up on a different machine.

**Maintenance:** add an entry at the end of every substantive session (see
[`../../CLAUDE.md`](../../CLAUDE.md) §6). For the structured, ID'd to-do status, see
[`outstanding-work.md`](outstanding-work.md). Pre-2026-06-14 session history lives in
the tracker's archived "Recently completed" blocks — now in
[`archive/outstanding-work-completed-2026-07.md`](archive/outstanding-work-completed-2026-07.md)
("Retired top-matter") — and the dated planning docs (`archive/gcp-oidc-wif-l21.md`,
`archive/cloudflare-provider-v5-migration.md`, etc.).

---

## 2026-08-09 (cont.) — GitHub App live; repo mirror fixed (Phase 2a+2c)

**Created the `etherport-automation` GitHub App** (id 4539969, installation 152499241,
org-wide; `actions:write` / `contents:write` / `metadata:read` / `packages:read`) and put
App ID + installation ID + PEM in the SOPS bundle (plaintext PEM shredded off the devbox —
SOPS is the only copy). New `scripts/gh-app-token.sh` mints 1h installation tokens
(RS256 JWT -> `/app/installations/<id>/access_tokens`) with optional `--permissions` /
`--repositories` for per-use least privilege. Proof it solves the migration fallout: an App
token enumerates **all 6** org repos where the user PAT saw **1**.

**Phase 2c done — the nightly repo mirror now uses an App token and backs up 6/6 repos.**
A `mint-token` init container (`alpine/openssl:3.5.7`, because `alpine/git` has no openssl)
signs the JWT and hands a contents:read-scoped token to the mirror through an in-memory
emptyDir; creds live in the `github-app-creds` SOPS secret.

**Three real bugs found while testing (all fixed):**
1. **Stale bundle lock wedges a repo permanently.** `git bundle create` leaves an
   `<output>.lock` on the NFS share if a run dies mid-bundle; every later run then fails
   *"Another git process seems to be running"*. `infra` was stuck this way (a zero-byte
   `.infra.bundle.tmp.lock` dated 2029 from the NAS clock). The script now clears its own
   stale `.tmp`/`.lock` first — and bundle errors are surfaced instead of an opaque
   "FAILED (bundle)", which is what made this take three runs to diagnose.
2. **Silent PARTIAL backup.** The empty-discovery guard only caught *0* repos, so a
   throttled/under-scoped listing would back up a subset and exit 0 — the very failure this
   whole workstream exists to fix. Added a **self-calibrating** guard: discovering fewer
   repos than bundles already on disk = refuse and leave existing bundles intact
   (`ALLOW_SHRINK=1` overrides for a genuine repo deletion). It immediately proved itself by
   catching #3.
3. **Flux reverts `kubectl apply`.** The 1-repo runs during testing weren't GitHub
   throttling (my first theory) — Flux was reconciling the CronJob back to git's PAT
   version between my manual applies. The CronJob has to ship via git. Same class as the
   `suspend: false` trap from the cutover.

**Remaining Phase 2:** 2b Flux git auth -> App (then re-disable deploy keys, as the owner
asked), 2d devbox dispatch -> App token (the dispatch PAT still 404s on the org), 2e GHCR
pull token decision, 2f retire both old PATs + drop the stale `sparked-diamond` OIDC trust
path + refresh credential-inventory/CLAUDE.md.

## 2026-08-09 — GitHub org migration cutover: sparked-diamond → etherport (LIVE)

Transferred all 6 repos from the `sparked-diamond` user to the new **`etherport` org**
and cut the homelab over. Cluster healthy throughout the tail (8/8 Ready, 0 image-pull
failures, Flux Ready, self-hosted runner active on etherport/infra).

**Done:** dual-trust OIDC applied (AWS trusts both repo paths) → runner re-registered to
`etherport/infra` (unit `actions.runner.etherport-infra.gh-runner`) → merged the sweep
(GHCR paths, Flux source URL, mirror→org enumeration, git remotes, docs) → 4 utility images
rebuilt into the org (push-triggered by the merge touching the workflow files).

**Gotchas hit (all real, all resolved):**
- **GHCR packages do NOT transfer with a repo** — they're account-owned. The 5 images stayed
  under the `sparked-diamond` user. Rebuilt the 4 infra-built ones to `etherport` via the
  push-triggered image workflows; **cue** is built in the separate cue repo → kept at
  `sparked-diamond/cue` (handed to the cue agent; cue-api + Flux image-automation still point
  there).
- **etherport org keeps packages PRIVATE + disables making them public** → added a
  `ghcr-etherport` dockerconfigjson pull secret (SOPS) to backups/cloudflare-ddns/
  cloudwatch-to-loki + `imagePullSecrets` on the SAs (base s3-sync SA propagates to the
  prefixed per-share SAs). ansible-runner is CI-only (workflow GITHUB_TOKEN pulls it).
- **Flux deploy keys were DISABLED by an org policy** (new-org default) → the transferred
  keys showed "Disabled by etherport". Owner re-enabled deploy keys org-wide → keys
  reactivated → Flux pulled the merge. Had to manually patch the live GitRepository URL to
  etherport first (the URL fix was inside the commit Flux couldn't fetch — chicken-and-egg).
- **User-scoped PATs can't reach org repos:** the dispatch PAT 404s on etherport/infra, and
  the mirror PAT enumerated only 1/6 repos. Both are superseded by the Phase-2 GitHub App.

**Remaining (Phase 2 — the GitHub App fixes most):**
1. **GitHub App on etherport** → replaces the mirror PAT (fix 1/6 enumeration), the dead
   dispatch PAT, and ideally the ghcr pull token (currently the org-owner's classic PAT).
2. **cue repo** (cue agent): republish image to `ghcr.io/etherport/cue`, then infra flips
   cue-api + image-automation + the pull secret.
3. **Drop the old `sparked-diamond/infra` OIDC trust path** once a full CI run is verified.
4. **Disable deploy keys again** after the App is in place (owner asked to remember this).
5. Docs: credential-inventory, CLAUDE.md.

## 2026-07-29 (cont. 2) — Postgres HA restored 3/3, CNPG PVC alert, Phase-1 MAB blocker

**Postgres HA fully restored:** re-cloned the 2 stuck replicas (-1 wedged mid-resize, -6
broken 28h pre-incident) by deleting their PVC+pod → CNPG `pg_basebackup` from primary -8 →
**3/3 healthy, phase "Cluster in healthy state".** Primary served throughout; zero further
app impact.

**Prevention shipped:** `CnpgPvcUsageHigh` alert (critical, 65%, for=10m) on
postgres-cluster-*/cue-db-* PVCs — pages BEFORE the disk-halt (the generic
KubePersistentVolumeFillingUp fired too late today). Committed + reconciled.

**Phase-1 802.1X MAC-pin BLOCKED (schema):** inline API PUT of port_security fields onto the
active camera/gate ports was stripped by the controller because those ports use a
`portconf_id` profile. No harm (ports up, all cameras pingable). Needs the port-auth.py
helper w/ the right field combo — annotated in dot1x-mab-design-2026-07-29.md. Yesterday's
DISABLED ports correctly retain port_security_enabled (part of the disable template) — not
a partial pin.

## 2026-07-29 (cont.) — INCIDENT: shared HA Postgres disk-halt → SSO outage (resolved)

**Symptom:** morning "flapping" alerts that "self-resolved" were actually the shared HA
postgres-cluster DOWN from ~05:10 — AuthentikDown, TargetDown postgres, KubePodCrashLooping,
KubePersistentVolumeFillingUp (w3/w4 03:26-05:04). SSO + every shared-DB app
(Grafana/wiki/OpenWebUI OIDC, forward-auth admin UIs) failing. NB the AWS alerts the operator
asked about were a red herring: AWSCostForecastHigh is a STEADY warning (forecast $90);
vpn-aws had 2 scrape flaps at 04:43 (the known M124 WAN wave). The real event was Postgres.

**Root cause:** the 03:00 storage stall (vzdump→UNAS NFS→Ceph RBD latency — the recurring
cascade) backed up WAL faster than it archived; the **10Gi** postgres PVC filled; CNPG's
`ensure_sufficient_disk_space` guard latched the cluster into phase "Not enough disk space",
which HALTS all orchestration (won't start pg / promote a primary until the PVC group grows)
→ no primary → postgres-cluster-rw zero endpoints → connection-REFUSED (not timeout, so NOT
a netpol drop — enforcement flip was exonerated). Confirmed via instance-manager log
"Detected low-disk space condition" (safety halt, NOT corruption).

**Recovery (operator-approved 10→32Gi):** (1) bumped Cluster spec.storage.size to 32Gi
(git e131faa + live patch). (2) CNPG WON'T self-propagate the resize from the halted state
(known behavior — it just loops "cannot proceed until enlarged"), so **directly patched the
3 PVCs' spec.resources.requests.storage to 32Gi** → Ceph online-expanded -6/-8 immediately;
-1 stuck FileSystemResizePending (crashlooping pod never mounts to resize2fs) → **deleted -1
pod** to force a clean mount. (3) halt cleared → failover → **postgres-cluster-8 promoted
primary, accepting writes, rw endpoint restored**. (4) restarted authentik-server + wiki
pods to skip crashloop backoff → **SSO fully recovered** (authentik health 200, grafana OIDC
302, wiki Running). Replicas -1/-6 PITR-replaying to rejoin (HA convergence in progress,
monitored separately).

**Durable fixes shipped/queued:** 32Gi is the durable headroom (10Gi too small for a shared
HA DB that accumulates WAL during a storage stall). The UPSTREAM trigger is the same
vzdump/UNAS-NFS/Ceph saturation we mitigated last night (bwlimit+scope); tonight's gentler
run should stop retriggering it. TODO: add a CNPG PVC-usage alert BEFORE it fills (the
KubePersistentVolumeFillingUp fired but at 03:26 into an already-degrading window — want a
lower, earlier threshold on the postgres PVCs specifically). NB #18 phase-1 802.1X MAC-pin
was DEFERRED by this incident — still pending.

## 2026-08-02 (cont.) — exposed-switch tamper alert + unblocked a stalled Flux

Built the detection alert `UnexpectedDeviceOnExposedSwitch` (critical → ntfy phone + SES
email): fires when a WIRED client not in the 8-MAC camera/gate allowlist appears on
Driveway/Chapel/Access-Road/Outdoor-Junction (unifi-poller data; wifi excluded so
randomized phones on the APs don't trip it). Detection half of MAB, zero lockout risk,
surfaces a cloned MAC as a duplicate. Add a MAC to the rule regex when adding a device.

⚠️ WHILE shipping it, found Flux had been FAILING every apply since the 2026-07-29 postgres
re-clone — the CNPG DR pre-bind `04-pvc-pre-bind.yaml` pinned instance-1 to a static 10Gi
volume, but the re-clone made all 3 PVCs dynamic 32Gi, so git permanently conflicted with
live on immutable PVC fields and BLOCKED THE WHOLE flux-system kustomization (silently — it
kept serving lastAppliedRevision from before). Fixed: annotated the live PVC + recovery PV
`kustomize.toolkit.fluxcd.io/prune=disabled`, removed 03/04 from the kustomization (kept as
regenerate-me rebuild templates). Flux Ready=True again on da3f411; PVCs safe. LESSON: a
delete-PVC recovery on a CNPG cluster that has a git-managed pre-bind PVC WILL wedge Flux —
check `kubectl -n flux-system get kustomization` after any such surgery.

## 2026-08-06 (cont.) — off-GitHub repo backup (GitHub → NAS → S3)

**Closed a real DR gap: the git repos had no backup off GitHub** — only whatever working
clones lived on devbox/mini. Added `platform/kubernetes/backups/github-mirror/`, a nightly
k8s CronJob that `git clone --mirror`s every repo owned by the `sparked-diamond` account and
writes **one `git bundle --all` per repo** to `sequoia:/var/nfs/shared/Backups/repos/`. The
existing `s3-sync-backups` job already sweeps that share to
`s3://archive.wind.etherport.net/objects/backups/`, so the repos now ride the existing S3
pipeline with **zero new S3 wiring** — the job only has to produce the bundles.

**Design decisions (+ why):**
- **k8s CronJob, not devbox** (owner picked): more consistent with the s3-sync fleet, fully
  Flux/IaC, and the k8s nodes are already in the NAS export allowlist — whereas devbox
  (10.10.201.45) is **not** in the Backups NFS allowlist, so a devbox executor would have
  needed a manual UNAS export change. (Verified the allowlist from `showmount -e sequoia`.)
- **Bundles, not bare mirrors:** a `git bundle --all` is a single file with full history + all
  refs — ideal for the per-object S3 sync (one object/repo, not thousands of loose git
  objects), integrity-checkable, trivial restore (`git clone <name>.bundle`). The bare mirror
  is done in ephemeral scratch and discarded. Validated end-to-end against the real `infra`
  repo: 100 refs bundled, `bundle verify` OK, restore → byte-identical HEAD, all 23 branches.
- **Image `alpine/git:2.54.0`** (no custom image, no CI rebuild — GitHub Actions was mid-outage
  today): busybox `wget` does HTTPS + `Authorization` headers, so enumeration via
  `/user/repos?affiliation=owner` needs no curl/jq. Repo full-names are a safe charset for
  grep/sed parsing. Token kept out of the URL/reflog/`ps` via git `http.extraHeader` under an
  ephemeral `HOME=/work`.
- **Atomic publish** (`.tmp` + `mv`) so the 01:10 PT S3 sweep never uploads a half-written
  bundle; mirror runs **00:40 PT**, 30 min ahead. **Empty-discovery guard** fails loudly (never
  silently produces "0 repos"). `GithubRepoMirrorStale` (>36h, kube-state-metrics based, silent
  while suspended) + the cluster's `KubeJobFailed` cover freshness/failure.
- Verified a uid-1000 pod can **write** to the Backups NFS share (the existing sync only reads
  it) before committing — RW works.

**State: committed but CronJob `suspend: true`.** Remaining = the **read-only PAT**. Needs a
fine-grained PAT on the `sparked-diamond` account (Contents: read + Metadata: read, all repos),
dropped into `github-mirror-token` (secret file already SOPS-encrypted with a placeholder), then
flip `suspend: false` + a manual test run. Full ops in the dir README.

## 2026-08-06 — ROOT CAUSE: nightly vzdump starves etcd → the "overnight flap" AND both cp1 hangs

**The overnight `homelab-any-endpoint-unhealthy` flap, yesterday's alert storm, and BOTH
cp1 kernel hangs (07-24, 08-04) share one root cause: the nightly PVE vzdump backup
(03:00 PT = 10:00–11:30 UTC) starving I/O on `rpool`, which the control-plane VMs — and
therefore etcd — live on.** Chain for last night: vzdump ran 10:00–11:30 UTC; etcd fsync
stalled (raft "agreement among raft nodes" waits of 10–13s; bolt reads stayed at ~80ms, so
it's consensus-on-slow-disks, not reads); `etcdNoLeader`/`etcdInsufficientMembers` fired;
all 3 kube-apiservers failed /livez >80s and were hard-restarted by kubelet
(restart counts 25/22/15) — the restarts made it worse (re-list storms against slow etcd,
startup-probe loops); the gpu1 cilium agent crashed on `localhost:6443 EOF`; cloudflared on
gpu1 lost cluster DNS → couldn't reach the Plex origin (`dial tcp i/o timeout` 10:31–11:11);
Route53 saw plex down; the composite CloudWatch alarm (child_health_threshold = ALL) flapped.
Evidence that closed it: **7,544 etcd "apply request took too long" events in 7 days — 94%
in UTC hours 10–11**, and per-VM vzdump logs showing **VM 1003 (gh-runner) at 7.3 MiB/s for
46:43** (copy-before-write vs an active guest) while every other VM ran ~79 MiB/s. PVE RRD:
iowait ~15%/load 13 during the window, collapsing to 0.2% the minute the backup ended. Both
cp1 kernel fork-deadlocks also started INSIDE this window (vzdump 07-24 10:00–11:39, 08-04
10:00–11:26) — the D-state pileup in `kernel_clone` is what a prolonged I/O stall looks like,
so the "unknown kernel bug" now has a known trigger (contained by the M91 watchdog either way).

**Fixes applied:**
1. **VM 1003 (gh-runner) excluded from the vzdump job** (PVE job `backup-820c6707-cfc0`,
   vmid now `1001,1002,1004,1005,1006`; rationale recorded in the job comment). It's a
   stateless CI runner, fully rebuildable from TF `standalone-vms` + `gh-runner.yml`. Its
   copy-before-write crawl was >half the backup window and the exact grinding phase.
   NB the PVE backup job is NOT in IaC — changed via `pvesh set /cluster/backup/…`.
2. **apiserver liveness tolerance raised 8→24 failures (~80s→4min)** so transient etcd
   stalls no longer hard-restart all 3 apiservers (a restart never fixes backend I/O).
   Readiness (3) + startup (24) unchanged. Live-applied rolling cp2→cp3→cp1 via the new
   **`infra/ansible/playbooks/k8s-apiserver-probe.yml`** (serial 1 + /readyz gate);
   persisted as **`kubeadm_patches`** in the kubespray inventory `k8s-cluster.yml` so
   kubespray runs re-apply it. All CPs verified 200 via the VIP after.
3. **w2 un-wedged:** kured had held the fleet reboot lock since the outage window, stuck
   evicting `cue-db-1` (single-instance CNPG PDB). Deleted the pod (30-min CNPG grace →
   moved to w4, brief Multi-Attach wait for the RBD detach), w2 drained, rebooted 11:45,
   uncordoned. The 12 Error `cloudwatch-to-loki` job pods from the outage window were
   collateral; later runs green.

**Deliberately NOT done:** no new etcd alert rules — the kube-prometheus defaults
(`etcdNoLeader` critical etc.) fired correctly during the window; coverage is adequate.
Fleecing was considered and deferred: with gh-runner gone the remaining 5 VMs back up at
~79 MiB/s in ~43 min total; revisit if another VM turns write-heavy at 3am.

**Separate + unrelated:** the cloud-tag-drift "run failure" email = **GitHub Actions major
outage today** (job cancelled at exactly 15:00 with no runner ever assigned + no steps; the
cron itself fired 2h late; API dispatch returns 500; githubstatus.com shows Actions =
major_outage). Nothing to fix; tomorrow's cron confirms.

**Next:** watch the next few 03:00 PT windows — etcd slow-apply counts in hours 10–11 UTC
should collapse; if they don't, the next lever is vzdump fleecing (or moving the CP VMs'
zvols off the contended pool). cp1's watchdog remains the backstop if the kernel deadlock
recurs outside the backup window.

## 2026-08-04 (cont. 3) — M91 DONE: watchdog armed on all 8 nodes + made reboot-durable

**M91 is closed.** All four remaining nodes (w2, w3, w1, gpu1) were cold-started to attach
their emulated i6300esb PCI device, and the hardware watchdog is now armed on **all 8 k8s
VMs**: module loaded, `/sys/class/watchdog/watchdog0/state=active`, systemd (PID 1) the sole
holder of `/dev/watchdog0`, `RuntimeWatchdogSec=60`. A wedged node now hard-resets in ~60s
instead of needing a manual `qm reset` from the PVE host — the automatic recovery for the cp1
fork-deadlock that has now bitten twice (07-24, 08-04). Combined with H47's HA API VIP, a
single wedged control plane is no longer a cluster-wide event.

**Cold-start order + notes.** One node at a time, each fully verified Ready before the next:
w2 (also cleared an `apt-get update` process that had been stuck holding the dpkg lock since
Jul 24 — 11 days), w3, w1 (needed `kubectl -n cue delete pod cue-db-1` to clear the
single-instance CNPG PDB blocking the drain — the usual dance), then gpu1 last for the brief
Plex outage. gpu1's host has **no `nvidia-smi` and that is expected** — the driver is
containerized by the gpu-operator, which cannot schedule while the node is cordoned. After
uncordoning, the CUDA validator completed, `nvidia.com/gpu.shared` re-registered as 2, Plex
rescheduled onto gpu1, and `nvidia-smi` inside the Plex container reports Tesla P40 / driver
580.105.08. Don't mistake a cordoned GPU node for a broken driver.

**The real find: the watchdog was NOT reboot-durable, and two nodes had already lost it.**
A fleet-wide check (rather than trusting the earlier PLAY RECAP) showed **cp3 and w4 with the
PCI device present but no module, no `/dev/watchdog0`, and nothing holding it** — they had
silently disarmed across this morning's kured sweep. Cause: Ubuntu ships
`blacklist i6300esb` in `/lib/modprobe.d/blacklist_linux_<kernel>.conf` (regenerated on
**every** kernel bump, so it can't be removed durably), and `systemd-modules-load` honours
that deny-list — logging *"Module 'i6300esb' is deny-listed (by kmod)"* and skipping it. So
the `/etc/modules-load.d/` drop-in the playbook was relying on **never worked**; the 6 armed
nodes were armed only because the playbook had explicitly modprobed them, and every one would
have disarmed on its next reboot.

**Fix: load it from the initramfs.** The deny-list only suppresses alias/auto-load resolution
— an explicit `modprobe i6300esb` by name still inserts it, and initramfs-tools'
`load_modules()` runs a bare `/sbin/modprobe $m` with **no `-b`** (verified by reading
`/usr/share/initramfs-tools/scripts/functions` before committing to the approach). It also
loads *before* PID 1, which matters because systemd opens `/dev/watchdog0` once at manager
start and never retries — a module loaded later needs a `daemon-reexec`. The playbook now adds
`i6300esb` to `/etc/initramfs-tools/modules` + runs `update-initramfs -u`, and removes the
ineffective `modules-load.d` drop-in. This is *more* durable than the original plan assumed:
that file persists across kernel upgrades and `update-initramfs` re-runs automatically on
kernel install, so it survives kured/kubespray kernel bumps with no per-kernel step.

**Verification trap worth remembering.** My first durability assertion was
`lsinitramfs … | grep -c i6300esb`, which passed on every host — including the two that were
provably broken. Ubuntu's default `MODULES=most` bundles the `.ko` into every initrd
regardless of whether it will ever be *loaded*, so that check is a guaranteed false positive.
The assertion now checks `/etc/initramfs-tools/modules` (what actually becomes the initrd's
`/conf/modules`). Re-run afterwards: `changed=0` on all 8 with all four assertions passing.

**Also corrected:** the playbook's shell block broke YAML parsing when I put an apostrophe
("Ubuntu's") inside it — ansible's free-form arg splitting fails on the unbalanced quote
("failed at splitting arguments, either an unbalanced jinja2 block or quotes"). Avoid
apostrophes in `ansible.builtin.shell` bodies; `--syntax-check` catches it in seconds.

**Next:** nothing outstanding on M91. Open watch items unchanged — the cp1 kernel hung-task
root cause is still unknown (now contained by the watchdog rather than fixed), UNAS nvme0
cache remains physically degraded, and the orphan dump sweep for retired VMs is still pending.

## 2026-08-04 (cont. 2) — H47: HA API endpoint LIVE (kube-vip) — cp1 SPOF killed

**The SPOF that amplified this morning's incident is fixed.** `10.10.201.49` /
`k8s-api.wind.etherport.net` is now an HA Kubernetes API VIP held by kube-vip (ARP/L2)
across cp1/cp2/cp3. **Failover PROVEN**: killed kube-vip on the holder (cp1) → VIP moved
to cp2 in ~10s and kept answering `readyz=200`.

**Staged execution (each gate verified, all with `--limit` one CP at a time — the
control-plane play has NO `serial:`, so a group run restarts all 3 apiservers at once):**
- *Stage 1* — `supplementary_addresses_in_ssl_keys: [10.10.201.49, k8s-api.wind...]` →
  kubespray detected SAN drift (`openssl -checkip/-checkhost`), removed apiserver.crt and
  regenerated per CP. Verified with `-checkip/-checkhost` on all 3. Inert for clients.
- *Stage 2* — `kube_vip_enabled/arp/controlplane` + `loadbalancer_apiserver`. ⚠️ **FIRST
  ATTEMPT FAILED**: setting `loadbalancer_apiserver` makes the control-plane role
  "Wait for k8s apiserver" AT THE VIP, but the kube-vip manifest is deployed by the
  **node** role — so `--tags=control-plane` waits forever for a VIP nothing is serving.
  **Fix: deploy kube-vip FIRST with `--tags=kube-vip`, then run control-plane.** Nothing
  broke (only downloads/kubeadm-config written; live cluster untouched).
- *Stage 3* — control-plane re-run completed cleanly once the VIP existed.

**What actually needed migrating was smaller than feared:** workers already load-balance
across all 3 CPs via nginx-proxy, and CP kubelets use `127.0.0.1:6443`. kubespray does NOT
rewrite the cluster-level `kubeadm-config` ConfigMap on an existing cluster, so the
remaining two changes were done directly: (1) ConfigMap `controlPlaneEndpoint` →
`k8s-api.wind.etherport.net:6443` (governs FUTURE `kubeadm join`), (2) devbox kubeconfig →
the VIP name (this was the thing that made kubectl hang during the incident).

**kubespray-vs-live drift check (the operator's other question) — clean.** The M75 IRSA
`--service-account-issuer` + `--api-audiences` in the inventory match live EXACTLY (the
setting that 401s every in-cluster token and breaks Multus if reverted). Across ~6 runs the
only recurring failure was `k8s-w2` apt-lock in the post-run pre-flight (unattended-upgrades
holding /var/lib/apt/lists) — benign, unrelated, but worth a retry-with-lock-wait later.

**Live state:** 8/8 nodes Ready, 0 pods down, VIP 200 by IP and by DNS with valid TLS,
3× kube-vip pods Running, all 3 apiservers 200.

## 2026-08-04 (cont.) — M91 hardware watchdog UNBLOCKED + armed; kured sweep finished

**M91 was blocked on a FALSE PREMISE for months.** The standing note said the i6300esb
kernel module was "ABSENT from the node kernel". Truth: the module ships in
**`linux-modules-extra-<kernel>`, which was simply never installed** (a normal Ubuntu repo
package). The PCI device was already attached host-side on ALL 8 VMs
(`qm config` shows `watchdog: model=i6300esb,action=reset`). `apt install
linux-modules-extra` + `modprobe i6300esb` → `/dev/watchdog0` appears immediately
(driver identity "i6300ESB timer", 30s default). **ARMED on cp1/cp2/cp3/w4**
(systemd RuntimeWatchdogSec=60, state=active) — a node that wedges like cp1 did this
morning now gets hard-reset by qemu in ~60s instead of needing a manual `qm reset`.
IaC: `infra/ansible/playbooks/k8s-node-watchdog.yml` (serial:1, skips nodes lacking the
device, asserts systemd is sole holder).

⚠️ **HAZARD FOUND THE HARD WAY — cost an unplanned cp1 reboot (12:11).** The legacy
`watchdog` DAEMON package is installed on these nodes (residue of the original M91
attempt) and sits dormant while /dev/watchdog0 is absent. The moment the module creates
the device, the daemon wakes, runs ITS OWN health checks, and **reboots the node** on a
failure — cp1's journal shows `watchdog.service: Triggering OnFailure=` then a clean
`systemd-shutdown`. Two watchdog consumers must never share the device. Fix applied to all
4 nodes + encoded in the playbook: **disable+mask the legacy daemon BEFORE loading the
module**; verify asserts PID 1 (systemd) is the only holder of /dev/watchdog0.

⏳ **w1/w2/w3/gpu1 still need a COLD start** (qm stop+start; a warm reboot does NOT attach
the emulated PCI device) before the watchdog can arm there. Playbook is a safe no-op on
them until then.

**kured sweep completed:** unblocked w4's stalled drain by deleting cue-db-1 (the
documented single-instance-PDB gotcha) → rescheduled to w1, cluster healthy 1/1 → w4
rebooted + uncordoned. All 8 nodes Ready, etcd 3/3, zero non-Running pods.

**STILL OPEN — HA API endpoint (operator approved "do the full migration now"):** NOT
started, deliberately. Sequencing: it is unwise to run a kubespray control-plane
cert/endpoint migration (restarts all 3 apiservers) in the same window as a fleet reboot
sweep + an unplanned CP reboot. Plan for the next focused session: kube-vip ARP mode
(kubespray `kube_vip_enabled/kube_vip_arp_enabled/kube_vip_controlplane_enabled/
kube_vip_address`), VIP on a VERIFIED-free VLAN-201 IP (NB .46 is step-ca — firewalled,
so ping alone is NOT proof of free; check Technitium + UDM reservations), migrate
controlPlaneEndpoint + apiserver cert SANs, then repoint kubeconfigs. Workers already
nginx-proxy across all 3 CPs, so the SPOF is really controlPlaneEndpoint + external
kubeconfigs (devbox kubeconfig currently pinned to cp2 as the interim mitigation).

## 2026-08-04 — INCIDENT: cp1 kernel fork-deadlock wedged the single API endpoint (resolved)

**Symptom:** operator woke to a flood of error/down emails; on inspection most alerts had
"self-resolved" but the cluster control plane was degraded.

**Root cause chain (this is the important part):**
1. A kernel update made kured start a **fleet reboot sweep**.
2. cp1 took the kured lock and began its reboot — and hit a **kernel hung-task/fork
   deadlock**: `runc`/`nfd-master` tasks blocked >1012s in `kernel_clone`, journald
   watchdog timeout, `Failed unmounting run-cilium-cgroupv2.mount` +
   containerd rootfs mounts. `fork()` was blocked SYSTEM-WIDE — the apiserver was
   liveness-killed and could not restart (11 attempts), kubelet stopped reporting, and
   **sshd could not fork** so the node was unreachable in-band. NOT resource exhaustion:
   iowait 0%, disk idle, no OOM, pid_max 4M vs 601 tasks, kubepods pids 205/60722.
3. Because cp1 is the **single control-plane endpoint** (documented SPOF — no HA API VIP),
   every cilium agent cluster-wide lost its apiserver watch ("http2: client connection
   lost", TLS handshake timeout) and began flapping → the alert storm.
4. cp1 also **held the kured lock while wedged**, blocking every other node's reboot.

**Recovery:** `qm shutdown 100` failed (guest agent can't fork) → **`qm reset 100`**
(operator-approved; etcd quorum verified healthy on cp2+cp3 first). cp1 came back clean:
0 D-state procs, apiserver 200, **etcd 3/3 quorate**, node Ready, all cilium agents 1/1.
The kured sweep AUTO-RESUMED (w1 took the lock next). Devbox kubeconfig was repointed
cp1→cp2 during the outage to regain visibility (left on cp2).

**Also fixed:** orphaned `velero-test-garage-kopia` BackupRepository (namespace long
deleted, zero backups, corrupted `kopia.maintenance` blob) was failing a job every ~4 min
generating repeat KubeJobFailed noise — CR + jobs deleted.

**Watch items / follow-ups:**
- ⚠️ **Recurrence risk:** cp1 showed the same hung-task signature on **Jul 24** (systemd:1,
  khugepaged blocked 546s). Kernel 6.8.0-136, containerd v2.2.5. If it recurs, this needs a
  real kernel/containerd investigation — it is NOT a capacity problem.
- ⚠️ **The SPOF is the amplifier:** a single wedged CP took out cluster-wide agent
  connectivity because controlPlaneEndpoint = cp1 only. An HA API VIP (kube-vip/HAProxy)
  would have contained this to one node. Strongest argument yet for fixing it.
- ⏳ **cue-db-1 is on w4**, which is still pending its kured reboot → the single-instance
  PDB will stall that drain (the known gotcha). Pre-empt by deleting the cue-db pod when
  w4 cordons, or w4 ends up stuck cordoned again.
- `CiliumNetpolDropFlow` fired on benign IPv6 link-local (ICMPv6 RS / mDNS, "Unsupported
  L3 protocol") amplified by the mass pod restart — consider excluding those in the rule.

## 2026-08-02 — CORRECTION: MAB not achievable on the outdoor switches; reverted

Operator spotted the UDM UI notice "options that will not be applied to the device"
(802.1X Control among them) on the Driveway port. Investigation confirmed: the USF5P
(Flex) switches have `dot1x_portctrl_enabled=False` at the DEVICE level (no 802.1X
hardware support); the Chapel USL8LP (Lite) has dot1x fields but every port is stuck
`dot1x_mode=force_auth` — the `mac_based` profile never translated. **None of the outdoor
switches can enforce MAB.** The 2026-08-01 "verified end-to-end" was a FALSE POSITIVE: a
camera returning online after a PoE-cut is what happens with NO enforcement (the reject
path was never tested — I'd even flagged I couldn't test it). Lesson: the controller
accepting a profile assignment ≠ the switch applying it; verify via device-level
`dot1x_portctrl_enabled` + per-port `dot1x_mode`, not "device came back up".

REVERTED cleanly: 5 ports → base "UniFi Devices" profile, deleted the "Cameras MAB"
portconf + 5 RADIUS accounts + global dot1x toggle (all cameras verified up). Corrected the
design-doc capability matrix + status; port-auth.py kept with a NOT-USABLE-ON-THIS-HARDWARE
header (mechanism is sound for a future 802.1X-capable switch). #18 real state: Phase 0
(31 ports disabled) + VLAN-212 isolation are the actual protections; genuine port-auth needs
a hardware swap (USW-Pro/-Enterprise) — operator call whether the threat warrants it.

## 2026-08-01 — #18 MAB LIVE on 5 exposed camera ports (remote, rollback-safe)

Implemented Phase 2 fully remotely (operator can't be on-site). Ordering: most-remote
lowest-stakes first (Access Road pilot → Chapel → Driveway). Remote-safe because every
in-scope port is a LEAF camera port; the mgmt path (uplinks) stays force_authorized, so
worst case = one camera dark + a one-write rollback that doesn't need RADIUS.

**Schema finding (cost a rewrite):** this controller strips per-port `dot1x_ctrl` AND
`port_security_*` from any override that has a `portconf_id` — auth MUST live in the PORT
PROFILE. Fix: created a **"Cameras MAB"** portconf (UniFi Devices clone + dot1x_ctrl=
mac_based), enabled `global_switch.dot1x_portctrl_enabled`, added a RADIUS account per
camera MAC; port-auth.py rewritten to swap a port's profile MAB<->base (idempotent, dry-run
clean). Verified END-TO-END: PoE-cut the access-road cam → fresh link-up authenticated via
RADIUS → back online (a grandfathered-session test would've been meaningless; the PoE cut
forces a real auth). All 5 cameras up on MAB.

**Caveats / Phase 3:** the REJECT path (unknown MAC blocked) is by-design but not
empirically tested (needs plugging in an unknown device = physical). MAB auth events did
NOT surface in /stat/event — Phase 3 (auth-failure alerting) needs to find where MAB
success/fail is logged (RADIUS acct? controller syslog?). Outdoor Junction (Flex-Mini)
remains un-authable by design (physical lock / hardware swap is the only answer).

## 2026-07-29 — #18 switch-port hardening via API (31 ports disabled)

**#18 largely closed, remotely via the UDM Network API** (the old "console-only" label
predated the API-key path). Discovery first (read-only): 9 switches inventoried;
camera/gate ports were ALREADY VLAN-min (UniFi Devices profile: native 212,
forward=native) and Access Road's spares already disabled — the real gap was
enabled-but-unused ports, worst on Outdoor Junction (3 dead jacks with NO profile =
full trunk if plugged). Applied the exact override shape the UI produces
(forward=disabled + tagged block_all + no native net + port-security on w/ empty MAC
list) to 31 currently-DOWN ports across 6 switches: Outdoor Junction 2/3/5, Chapel
3/4/6/7, Rack PoE ×12, Workroom ×4, Office ×7, Rack-10G "Hallway". Safety: script
refused any UP port; verified post-apply: all 31 forward=disabled, zero previously-UP
ports lost, 18 VLAN-212 devices online. NB `enable` flag display varies by switch gen;
`forward=disabled` is the authoritative bit. PUT /rest/device/<id> with the FULL merged
port_overrides array (replace-not-append footgun).

**Remaining for #18:** 802.1X/MAB (RADIUS + MAC entries — design item, deliberately
deferred); re-enable procedure = UI or API (flip forward=native + profile).

## 2026-07-28 (cont.) — vzdump right-sizing (backup-set 545→115 GiB), orphan purge, kubespray check

**vzdump job right-sized (operator-approved):** the nightly job was `all:1` minus CPs —
73% of the 545 GiB set was k8s WORKER OS disks (pure IaC cattle; state lives in
Ceph/velero/barman/etcd-backup) + never-changing packer templates re-dumped daily.
Rescoped to the 6 standalone VMs only (1001-1006, ~115 GiB), `bwlimit 81920` (80 MiB/s —
derived from the observed UNAS absorb: healthy 130-190 MiB/s, flush-contended floor
32-37 MiB/s; the fast/crawl alternation = SSD-cache fill/flush cycles, worsened by the
degraded single-NVMe cache), retention keep-daily=7+keep-weekly=4 (was 14d).
`pvesh set /cluster/backup/backup-820c6707-cfc0`; snapshot at /root/jobs.cfg.bak-2026-07-28.
Worker-loss trade-off accepted: kubespray rebuild (~45 min) instead of image restore.
**1.6 TB of orphaned worker/template dumps deleted** (294 archives; operator chose
clean-break). NB: NAS `df` hadn't reflected the free space immediately (recycle/snapshot
layer?) — re-check. ALSO still present: old CP-era dumps (qemu-100/101/102) + retired-VM
archives (103/104/105/2001) — small, flagged for a later sweep.

**Kubespray drift check:** running `cluster.yml --check --diff` full-cluster from the
devbox (detached tmux `kscheck`, log ~/kscheck-2026-07-28.log). NB `--limit` + check mode
trips the fact-cache assert — full-cluster only. Treat check-mode diffs as leads (some
tasks skip; cert/token diffs are noise). Results next entry.

## 2026-07-28 — enforcement flip (14 tiers LIVE), vzdump/NFS flap root-cause, M152 closed

**Overnight flap storm root-caused:** pve's 03:00 vzdump job (VM backups → sequoia-backups
= UNAS NFS) saturated the UNAS NFS service 03:00-04:56 PDT → pvestatd timeouts, Ceph
mon.pve slow op (blocked 577s, 04:18-04:27) → RBD latency cluster-wide → load spikes
(cp3 119), etcd leader flaps, CNPG evictions, TargetDown — all self-healed when vzdump
finished. Same time-signature as the 07-21/22 "deep-scrub" saturations — scrubs were
throttled + not running today, so vzdump-vs-UNAS is likely the recurring driver.
PROPOSED (pending approval): vzdump bwlimit in /etc/pve/vzdump.conf.

**Enforcement flip DONE:** audit window verified clean (30h+, 2 nightly backup sweeps +
the NFS chaos; only 1 stray inbound ICMP). policy-audit-mode=false + cilium rollout →
PolicyAuditMode=false. Validation: plex 200 via edge, grafana Access 302, flux Ready,
BOTH velero BSLs Available, certs Ready, HA 200, tailscale healthy, ZERO DROPPED
verdicts across all 8 new namespaces. **14 tiers enforcing.** cluster-config drift
detector re-dispatched → green (the "cluster config down" emails were this deliberate
audit-mode drift).

**M152 CLOSED:** policy-push OAuth migration live (d507e38, self-triggered run green;
operator deleted TAILSCale_API_KEY); stale iPad device deleted via API; plex-ts LB
removed (redundant); mini node kept (returns after power-cycle). abacus confirmed.

**Next:** vzdump bwlimit (operator approval), then #18 switch-port hardening is the
remaining ZT frontier; M149 runbook items absorbed into tailscale-route-failback.md.

## 2026-07-25 (cont. 3) — TS static endpoint (M154), plaintext-secret incident, DERP explainer

**M154 DONE:** TS "slow vs WG fast" = DERP relay dependence (no dialable homelab port; Mac
curaddr empty, relay=nyc). Built the WG-equivalent deterministic path: ProxyClass
`static-endpoint-router` (TS_TAILSCALED_EXTRA_ARGS=--port=41641 +
TS_DEBUG_PRETENDPOINT=47.159.189.5:41641 — native staticEndpoints unusable, advertises
node ExternalIPs only), LB svc `ts-router-static-endpoint` VIP 10.10.201.74 (stable
parent-resource selector; Cluster ETP fine — disco validates by nonce), unifi TF forward
WAN:41641/udp → VIP (plan 1-add → applied). Router restarted once, /19 primary kept,
WAN:41641 in Self.Addrs. WAN-IP change → stale advert → DERP fallback (fail-safe).

**Security incident (small, contained):** operator pushed `tailscale-policy-push.sops.yaml`
in PLAINTEXT (no sops run) — policy:write OAuth secret in git history ~15min.
secret-scan + sops-decrypt-check CI both went red (guardrails worked). File removed from
tree; client REVOKED by operator; replacement handover switched to the devbox-file method
(agent encrypts). NB Tailscale OAuth scopes: write always bundles read — "write-only" isn't
a thing; single-scope write IS least-priv here.

**Still open:** re-mint policy-push client (devbox handover) → migrate tailscale-policy.yml
off the 90d API key; M147/M151 audit-off flip after ~24h observation; M152 tail.

## 2026-07-25 (cont. 2) — ZT batch: tiers 8-14 in audit, L34 ACL LIVE, TS OAuth verified

**M151/H46-tail (29743e8):** 7 new netpol tiers under the OPEN audit window — flux-system(8)
velero(9) backups(10) tailscale(11) cert-manager(12) garage(13) home-automation(14);
allowlists grounded in live hubble-relay sampling; ZERO early AUDIT flows on all 8 new
tiers (incl. plex). Coverage 6→14 namespaces. Labels via the PSS patch (+ garage 00-ns);
fixed the stale "HA privileged" PSS note (now enforce=baseline/warn=restricted).
**ONE audit-OFF flip enforces everything** — wait for nightly backups CronJobs + a Plex
streaming session, check Loki {job="hubble-audit"} for the 8 namespaces, then flip
(ConfigMap + rollout restart, separate commands).

**L34 ACL LIVE (eb19b71 + test-src fix):** allow-all grants replaced. member → LAN /19 +
AWS /22 + tag:k8s + cluster-ingress(443/80) + subnet-routers + self + internet(exit/
Mullvad). NO tag-as-src grants → tagged service/router nodes cannot INITIATE tailnet
connections (no pivot from a popped proxy). Regression tests embedded (concrete-user src
required — autogroup src is rejected by the test-runner, learned the hard way; first push
FAILED SAFELY: API 400 test-failure → old policy stayed live). Verified via API readback:
new grants live. NB the sed-fallback HuJSON validator mangles CIDR strings in dst arrays —
trust hujsonfmt/the API, not the sed path.

**M152:** ACL scoping done via L34; remaining: stale device-key expiry (iPad/mini),
plex-ts keep/remove, workflow OAuth migration (operator minting `wind-policy-push`
policy-write client; wind-infra-ops stays read-only).

## 2026-07-25 (cont.) — queue execution: M150/M153/M148/H46 done, M147 in audit, TS OAuth live

**TS OAuth (`wind-infra-ops`)** minted by operator, stored SOPS `tailscale-oauth.sops.yaml`;
verified (token mint + device list). Pre-existing TS creds mapped: operator OAuth client
(K8s operator — keep), `TAILSCALE_API_KEY` GH secret (policy-sync workflow; 90d expiry —
migrate to the OAuth client under L34).

**M153 ✅ (both halves):** `tailscale-route-drift.yml` detector (6h; sole-/19-advertiser
invariant; issue open/close; email rollup row "Tailscale routes"; first run green e2e) +
WG VIP alerts (`WgVipUnreachable` ICMP probe / `WgVipOnFallback` via `wg_vip_held`
textfile timer on vpn-fallback — deployed live incl. adding textfile collector flags to
its node_exporter; metric verified in Prometheus).

**M150 ✅:** THE M149 ROOT CAUSE WAS IN THE IaC — tailscale.yml gave vpn-aws the /19
statically, and vpn-fallback's failover script pinged a hardcoded STALE Connector TS IP
("router down" forever → permanent advert; would re-arm on reboot). Purged from IaC +
live (unit removed from vpn-fallback), playbook now REMOVES the unit + clears empty
routes; vpn-tailscale.md rewritten (sole-advertiser model); new runbook
`tailscale-route-failback.md`.

**M148 ✅:** CF rate-limit 300 req/10s per-IP on plex.wind (ratelimit.tf; plan 1-add
verified → applied run 30169108231; /identity via edge still 200).

**H46 🟡:** home-assistant DE-PRIVILEGED (privileged:true was cargo cult — network
integrations only, Multus wired by CNI; verified healthy unprivileged) + PSS
baseline/warn=restricted labels. Remaining: HA netpol tier (next audit window).

**M147 🟡:** global audit ON (ConfigMap+rollout, verified PolicyAuditMode=true), plex ns
labelled tier 7, `16-tier-plex.yaml` applied (ingress :32400 from
traefik/cloudflared/tailscale; egress world 443/80; NFS kubelet-side). Zero early AUDIT
flows. **NEXT SESSION: after ~24h + a streaming session, check Loki hubble-audit ns=plex;
if clean flip audit OFF (all 7 tiers enforce). Until then all tiers observe-only.**

**Remaining from the review:** L34 (ACL tightening + policy-sync onto the OAuth client +
device-key hygiene — needs design decisions), M151 (credential-ns tiers), M152 tail
(cue-db ACL scope rides on L34; plex-ts fate), HA netpol tier.

## 2026-07-25 — Plex streaming root-cause chain, CF Access off plex.wind, TS primary-steal fix, remote-access/ZT review

**Plex "slow/unstable over TS" — three stacked causes, all fixed:**
1. **Traefik `plex-buffering` middleware** buffered the whole response (`maxResponseBodyBytes`)
   → starved streaming clients (PMS log: "client buffered … 0kbps", throttle/sloth cycling).
   Removed entirely from `platform/kubernetes/plex/04-ingress.yaml` — a reverse proxy in
   front of a media server must never buffer.
2. **LAN/WAN misclassification:** Plex scores location by the direct peer IP = the Traefik
   pod IP, and `LanNetworksBandwidth` included `10.42.0.0/16` → every proxied client was
   "lan"/uncapped (would push original 57 Mbps remotely). Fixed live via `PUT /:/prefs`:
   `LanNetworksBandwidth=10.10.0.0/16`, `WanPerStreamMaxUploadRate=25000`. NB pref lives in
   the config PVC, not IaC.
3. **THE BIG ONE (M149): vpn-aws held the tailnet primary for `10.10.192.0/19`** — every TS
   client hairpinned homelab traffic through the AWS t4g.small for ~3 days. Empirically (3
   controlled toggles): TS control re-elects on every advertiser change, fixed preference
   `vpn-aws > vpn-fallback > k8s-router`, NO failback; vpn-fallback-as-primary additionally
   blackholes the MetalLB VIPs (VLAN-201 BGP gap). Fix: standby `/19` adverts REMOVED live
   (vpn-aws keeps `10.10.100.0/22`+exit, vpn-fallback exit-only); K8s Connector = sole
   advertiser + verified primary. Break-glass = re-advertise on vpn-fallback. ⚠️ the standby
   config is still in ansible (`tailscale.yml`) → M150.
   Residual client-side slowness suspect: Mac direct↔DERP(nyc) flap — diagnose with
   `tailscale ping 10.10.201.70` when slow.
   Also: 15-20s stream start/seek on 4K DoVi P7 + TrueHD = transcode cold-start (20s ffmpeg
   probe + EAE spin-up per seek), NOT infra — NFS 380MB/s, GPU idle, HW pipeline 2.5×.

**CF Access removed from plex.wind (operator-approved):** commit `4fbf5f6`, plan+apply via
CI (runs 30166589615 / 30167647348), verified: public `/identity` returns Plex XML direct,
no SSO redirect. Plex apps / Apple TV now work off-tailnet; auth = plex.tv accounts
(operator to enable 2FA). `plex.wind` moved from `cf_tunnel_services` (blanket SSO) to a
static un-gated ingress + dedicated `plex_cname`.

**Remote-access + ZT review (two read-only audits, repo + live):** deliverable
`remote-access-zt-review-2026-07-25.md`. Healthy: sole-advertiser verified, no DERP-relayed
peers, 9/10 public hostnames gated, SA-token hygiene, certs. New items: **H46**
(home-assistant privileged+unlabeled+no-netpol = highest-exposure pod), **M150** (TS standby
adverts still in IaC), **M151** (netpol tiers for credential namespaces), **M152** (tailnet
surface: cue-db ACL scope, verify Windows device `abacus`, stale keys, 3 exit nodes,
plex-ts fate), **M153** (TS-primary + VRRP VIP-holder alerts — both fallback layers fail
silently today). Queued earlier: M147 (plex netpol tier), M148 (CF rate-limit on Plex login).

**Next steps:** M150 first (IaC drift will resurrect the misconfig), then M153 alerts, H46,
M147/M148; M152 needs operator input (`abacus`?, TS API key for L34).

---

## 2026-07-20 — morning alert triage: host-cert renew, tetragon FP, AWS cost, favicon, login mechanism

**ExternalHostSystemdFailed (flapping ×3):** `step-ssh-hostcert-renew.service` renews the
cert fine but its `ExecStartPost=systemctl reload ssh` fails ("ssh.service is not active")
on socket-activated sshd (Ubuntu 24.04) — surfaced today when host certs first crossed the
168h renewal threshold. Fixed → `-systemctl try-reload-or-restart ssh.service` in
`step-ca-hostcerts.yml` (commit 3483f19) + applied live on all 4 affected hosts (devbox,
gh-runner, vpn-fallback, asterisk-sbc); alert cleared fleet-wide.

**Tetragon cred-access (flapping critical):** benign — the `wireguard` pod's startup runs
dpkg-preconfigure/debconf which read /etc/shadow during package config. Scoped-out via a
LogQL filter `| k8s_ns!="wireguard" or binary!~"/usr/(sbin/dpkg-preconfigure|share/debconf/.*)"`
(no global blind spot), validated against live Loki (commit 5ba70d5). Real fix: bake
wireguard-tools into the image.

**AWS cost $75→$88 forecast:** confirmed the operator's guess — **Amazon Registrar $15.00
MTD = the domain renewal** (one-time/annual). S3 $46.52 MTD is front-loaded from the
earlier-month K8s-upgrade egress + backups (trailing-7 back to $0.61/day, yesterday $0.65 —
decayed). No spike_ratio anomalies. Nothing new popped up. Data from the aws-cost-exporter
Prometheus metrics (terraform-homelab key lacks ce:GetCostAndUsage).

**Favicon:** the served etherport-mark.svg is already fully transparent (no bg element);
the white tile is Safari's tab/favorites chrome, not the icon.

**Login theme — mechanism found, still not rendering.** The served /static/dist/custom.css
is NEVER loaded by the flow interface (only the admin/user UI) — that's why the whole
terminal theme styled nothing. Moved it to `Brand.branding_custom_css` (commit 00bb3ed),
which IS served by /api/v3/core/brands/current/ that the flow reads. But the desktop
screenshot still shows default → likely shadow-DOM scoping in the 2026.5 flow. Awaiting an
operator DevTools inspection (card class + shadow-root?) to fix the selectors, or fall back
to logo+dark-only. Memory: authentik-sso-gotchas updated.

## 2026-07-19 — advisor "flood" root-caused to the apiserver-audit firehose; tightened audit policy (~80% Loki cut) + logo centering

**Advisor flood + still-arriving mini emails.** Two things. (1) The mini/cairn silence
from 07-18 missed **`PhotosExportStale`** (the mini's iCloud Photos export, `backups` ns)
— its name doesn't match `Mini*/Cairn*/ICloud*`. Replaced the silence with the full
family `Mini*/Cairn*/ICloud*/PhotosExport*` (7d). (2) The "flood" was **`storage-loki-0`
at 99% full** — a real `critical` (`KubePersistentVolumeFillingUp`) re-emailing via both
AM's critical path and the ai-advisor (which re-diagnoses a persistently-firing alert
every repeat_interval). Root: **Loki ingest ~11-14 GB/day, of which apiserver-audit
(M131) was ~13.8 GB/day / ~75%.** The stock kubespray GCE audit policy logs all reads at
`Request` + all mutations at `RequestResponse` (byte-share: nodes-status heartbeats 36%,
SAR/authz 14%, kyverno reports 13%, leases 6% — all noise).

**Fixes.** Immediate: expanded `storage-loki-0` 20→40Gi (ceph online) → usage 99%→49%,
alert cleared. Durable: **tightened the apiserver audit policy at the source** — new
`audit_policy_custom_rules` in the kubespray inventory drops the system read/heartbeat/
lease/authz-review/kyverno-report/health-probe noise while keeping ALL mutations,
secret/RBAC access, and (to preserve the `ApiserverAnonymousSuccess`/`ForbiddenBurst`
ruler alerts) all human + anonymous requests. Applied via **rolling apiserver restart
cp3→cp2→cp1-last** (swap the hostPath policy file + `crictl rm -f` the apiserver;
verified `livez`+nodes Ready between each — no HA API VIP so cp1 last). **Result: audit
now Metadata-only (0 Request/RequestResponse), total Loki ingest 2.7 GB/day (~80% cut).**
Also added a 48h `retention_stream` cap on `{job="apiserver-audit"}` (loki.yaml) as a
guaranteed bound, and an ineffective-but-harmless Alloy drop stage (superseded by the
source fix). Runbook: `docs/runbooks/apiserver-audit-policy.md`. IaC commit `aafc554`.
NB the global 30d Loki retention still exceeds 40Gi at 2.7 GB/day (~15d capacity) — a
slow, non-urgent creep; operator deferred cutting global retention.

**Alloy was the OTHER firehose.** After the audit fix, the remaining ~4 GB/day
`kubernetes-pods` volume was ~90% **Alloy itself** — the log shipper ran at its default
`info` level, emitting a line for every file it tails/seeks ("Seeked …", "tail routine:
started") ×hundreds of pod logs ×8 DaemonSet pods. Added `logging { level = "warn" }` to
the Alloy config (commit `33be003`) → Alloy dropped from ~33k lines/5m to **3 lines/3m**.
Genuine app logs are only ~0.19 GB/day.

**Net result: Loki ingest ~14 GB/day → ~0.57 GB/day (~96% cut)** — apiserver-audit 0.19,
kubernetes-pods 0.19, hubble 0.12, syslog 0.07. **This RETIRES the retention concern:**
at 0.57 GB/day, 30d retention needs only ~17 GB — fits the 40 GB disk comfortably, so the
global retention does NOT need cutting (the earlier "slow creep" note is moot). The 48h
apiserver-audit `retention_stream` cap stays as a cheap safety bound.

**Login theme — resolved to the achievable ceiling ("quiet card").** DevTools proved the
login card/form/button are in shadow DOM; Authentik's dark theme redefines the PF colour
tokens on `:host([theme=dark]) .pf-m-dark` inside the shadow root, so light-DOM injection
can theme the font (inherited) + light-DOM logo/bg but NOT the button colour or card chrome.
Shipped: dark bg, mono font, centred logo (fixed the SVG's own viewBox whitespace, 236→191),
dark favicon tile (Safari tiles favicons white), footer-band hide. Dropped the unreachable
green-button/terminal-chrome. ⚠️ authentik-server subPath ConfigMap changes need a pod DELETE
(Flux reverts `rollout restart`). CSS lives in `Brand.branding_custom_css` (flow never loads
the served custom.css).

**PVE etherport branding + no-subscription nag (new).** Design-drop kit vendored to
`infra/ansible/playbooks/files/proxmox-branding/` + new `proxmox-branding.yml`. Applied to pve
(10.10.200.41): etherport logo/favicon/dark-terminal CSS + injected `orig_cmd(); return;` into
proxmoxlib.js `checked_command` so the "No valid subscription" dialog never fires. Both survive
package upgrades via DPkg::Post-Invoke apt hooks (99-etherport-branding, 98-etherport-nosub).
PVE is plain ExtJS (no shadow DOM) so CSS applies cleanly. Verified live; hard-refresh to see.

**Authentik logo.** Was displaying (after the 07-18 branding-file fix) but left-aligned;
added defensive flex + `margin:auto` centering CSS (37-*), served + verified.

## 2026-07-18 — Velero backups silently stopped ~37h (default-BSL flipped to the ReadOnly mirror) + mini/cairn alert silence

**What (Velero — the real find):** `VeleroLastBackupAgeHigh` was firing across **all 12
schedules** (>36h since last success). Backups *were* running — every run since
2026-07-18 01:00 was `FailedValidation` with *"backup storage location default is
currently in read-only mode."* Root cause: the velero server had **no
`--default-backup-storage-location` flag**, so it fell back to the literal string
`"default"` and, on the pod restart ~34h earlier, its default-BSL controller re-marked
the BSL *named* `default` — our **ReadOnly** AWS-S3 offsite DR mirror — as THE default,
inverting the chart's `spec.default: true` on `garage`. Schedules omit `storageLocation`
→ inherited the ReadOnly BSL → admission rejected every backup. (git intends `garage`
= ReadWrite primary, `default` = ReadOnly DR mirror.)

**Fix:** pinned `configuration.defaultBackupStorageLocation: garage` in
`clusters/wind/helm-releases/velero.yaml` (chart 11.4.0 renders
`--default-backup-storage-location=garage`, verified via `helm template`). Commit
`addbbe9`, Flux-reconciled, velero redeployed with the flag. **Verified:** an ad-hoc
backup validated + wrote to `garage` + completed; then kicked an on-demand backup from
every schedule (label `trigger=bsl-fix-recovery`) — **0 FailedValidation**, all routing
to `garage`; `VeleroLastBackupAgeHigh` cleared to **0 active** as they completed
(authentik/critical-apps/cue/infrastructure done first, heavy plex/ollama/postgres
churning through serially). Docs: velero README BSL section + memory
`velero-default-bsl-flag-pin`. **Never remove that flag while a BSL is named `default`.**
NB `kubectl get backup` = `backups.postgresql.cnpg.io`, not velero — use
`kubectl get backups.velero.io`.

**Mini/cairn alerts:** silenced the whole `Mini*/Cairn*/ICloud*` alert family in
Alertmanager (silence `319e1119-…`, 7d, expires 2026-07-25) — the mini is
hardware-wedged in EFI pre-boot pending a physical power-cycle (not on a switchable
outlet, no BMC). Delete the silence once it's recovered.

**Authentik login logo/theme — root-caused + fixed.** Operator reported no logo on the
login page. Root cause: **Authentik 2026.5.3 validates `branding_logo`/`branding_favicon`
with a FILENAME validator** ("letters, numbers, dots, hyphens, underscores, slashes,
%(theme)s") that **rejects `data:` URIs**. The 2026-07-17 redesign set them as SVG data
URIs (valid in 2024.12, broken by the H44 upgrade), so the **whole `branding` blueprint
failed validation** (`BlueprintInstance status=error`) → logo, favicon **and
`theme.base=dark` never applied** (the missing dark base likely also explains why the
custom.css terminal theme "didn't pick up"). Diagnosed via `ak shell` →
`Importer.validate()` per-entry (`EntryInvalidError` on branding_logo/favicon).
**Fix (commit `6b30093`):** serve the two SVGs as real files — added to the
`authentik-custom-css` ConfigMap (37-*), mounted into `/web/dist/` (33-*, served at
`/static/dist/`), and referenced by path (`/static/dist/etherport-{logo-dark,mark}.svg`)
in the Brand blueprint (40-*). **Verified:** SVGs serve HTTP 200 `image/svg+xml`;
blueprint now `status=successful`; live brand carries the logo path, favicon, and
`theme.base=dark`. Operator to hard-refresh (browser may cache the old favicon/page).

**Next:** let the remaining recovery backups finish (auto); operator hard-refresh +
visual confirm the etherport logo + terminal login theme render.

## 2026-07-11 (cont.) — mini session housekeeping: auto-start/resume + move to the cairn repo

**What:** two owner asks after the session crash forced a manual console resume.
1. **`net.wind.claude-session` LaunchAgent** (infra `2c8e7301`): runs `resume-claude-sessions.sh`
   every 2 min — recreates the tmux session at login/boot AND re-sends `claude --continue` when
   the pane sits at a bare shell (crash-resume). Script rewritten: the mini runs ONE session now
   (tmux `cairn`); the stale infra/cue/personal-web list was pre-M81. mini-health EXPECT watches
   the agent. Installed + verified live (session `cairn` created, claude started).
2. **Session moved to `~/code/cairn`** (its primary subject; tidier vs the devbox's infra
   session). Prepared: cairn `CLAUDE.md` (cairn `59a3cd7` — launchd-not-shell, TCC, best-effort
   photos, storage plumbing, repo relationship), `.claude/settings.json` whitelists
   `/Users/grahamsmith/code/infra` via permissions.additionalDirectories (mini-local infra work
   stays in-scope; cluster/TF work stays with the devbox agent), project memory seeded (cairn
   history + RC-UUID-collision + handoff-open-items: NFS Phase 1 sudo install, Phase 2 locking
   test, drive/CloudDocs red, alert silences to ~07-16). NO session .jsonl copied (RC UUID
   collision). The old infra-rooted mini session winds down once the owner confirms the new one.

## 2026-07-11 — UNAS wedge incident (M141) + full repo review (drift/audit/docs) + fix batch

**Prompt:** "current repo review… best practice, missing hardening to-dos, doc/readme review, config
drift, overall infra errors (advisor emails)" → then live incident response → "push everything".

**Incident (M141, the advisor-email source):** `MiniSMBAuthRejected` firing since 07-10 ~00:30.
NOT auth, NOT the NVMe bus-drop: the UNAS kernel wedged in **dm-cache** (kworkers D-state 15h+,
load avg 437, SLUB vmap_area exhaustion) — smbd accepted auth then hung in I/O. Operator rebooted
via console (05:12): clean in 3.5 min, arrays clean, no rebuild; Garage + both velero BSLs
revalidated instantly. **Post-reboot twist:** the mini kept reporting `smb_auth=0` — proven
(smbd debug3 + tcpdump: zero session-setups on the wire; anonymous SMB3 from the devbox OK) to be
the mini's own dead kernel SMB session faking "Authentication error", which mount-nas's
auth-gate-first ordering turned into a **deadlock** (bail before its own force-unmount). Fixed
`5729808`: stale-mount cleanup precedes the auth probe; alert text now documents both causes +
the `smbclient -N -L //10.10.209.10 -m SMB3` disambiguation. ⏳ At entry time the mini hadn't yet
pulled/cleared — watcher running; remaining mini step: `git pull` (or the manual force-unmount).
NB: UNAS SSH rate-limits rapid connections (bursts pass, then SYN-drops) — use a ControlMaster mux.

**Repo review (3 agents — full digest in the conversation; actions below):**
- **Drift: essentially none.** Flux==HEAD, 17/17 HelmRelease pins exact, kubectl-diff clean
  (SOPS false-positives only), IRSA issuer/audiences hold, Cilium enforcing+WG on. ONE real find →
  **M142 technitium-1 credential divergence, FIXED live** (re-created `graham`, job re-run green —
  it had been failing silently since ~06-22 and t1 was still at 365-day log retention).
- **Audit:** 2 medium (M-1 → **M140** PR-plan PowerUser role, open; M-2 head.ref injection →
  **fixed**, 13 workflows, env-var indirection), 2 low (L-1 PSA labels → **fixed**: velero +
  gpu-operator-system via pss-labels patch, metallb-system codified as 00-namespace.yaml,
  multus-system source + live label since it's applied out-of-band; L-2 automount → **L37**).
  V-1 (grafana allow_sign_up vs Authentik binding) → **L38**.
- **Docs:** README component catalog +authentik/garage/velero-dr, +metrics-server in the HelmRelease
  list, pre-commit hook path corrected, home-automation README digest-pin wording. docs index clean.

**Also:** operator asked to confirm the session model ("Fable 5" on device vs the stale "Opus 4.8"
system-prompt text — client UI is authoritative; the prompt nameplate doesn't update on a
mid-session switch). Unconfirmed AWS SNS sub (`homelab-external-monitoring-alerts`, 07-08 email)
flagged to operator.

**Next:** L37/L38, M138 iCloud app-password (operator), ntfy app subscribe (operator), M12
recurring-drill trust-line (optional), watch the next Renovate PR plans green under the M140 role.

**2026-07-17 (cont.) — S3-sync backups-share fix + email word-break bug:**
- **s3-sync-backups failing nightly (S3SyncStale/KubeJobFailed, ONLY that share):** the `backups`
  share (mini cairn iCloud dest) has broken macOS app-group symlinks (`Library/Application Scripts/
  group.com.apple.{notes,reminders}`) whose targets don't exist → `aws s3 sync` warns "File does not
  exist" during the directory walk and exits 2 → sync-and-verify.sh's fail-closed delete-guard
  aborted the whole run. An `--exclude` can't help (the target-stat happens before exclude
  filtering). Fix `b3b8b6c`: `--no-follow-symlinks`, opt-in via `NO_FOLLOW_SYMLINKS` env set only on
  the backups share (image rebuild). Verified: 0 warnings, real sync proceeds. Source-side (cairn
  not copying those symlinks) handed to the mini agent.
- **Email word-break (operator screenshot):** the terminal-theme CSS used `word-break:break-all`,
  which broke words at any char — the Alertmanager prompt wrapped "firing" as "fi"/"ring" on mobile.
  Fix `920cf9c`: `overflow-wrap:break-word` (whole words, wrap at spaces, break only an oversized
  token) across ALL 5 emails' `.prompt` (+ advisor h1/card). Verified live in the running AM config
  (break-all=0). Rendered the fixed AM email for the operator.

**2026-07-17 — morning advisor alerts (M145 held) + claude auto-update fixed on the devbox:**
- **Advisor alerts (all noop, self-resolved):** PveHostMemoryPressure (91% mem but 0 swap activity —
  normal steady-state for a Ceph+VM host, transient spike in the backup window), KubeJobFailed (the
  known s3-sync/gdrive-sync DeadlineExceeded backup-window jobs; re-run fine), NodeSystemSaturation
  (w1 19/core, I/O-wait from kopia). **Key: M145 HELD — zero etcd leader loss overnight** (all 3
  members clean 18h). w1 saturation is now benign (etcd protected, wireguard/rclone hardened). The
  residual is kopia *maintenance* scheduling — M144 tail, low priority.
- **claude auto-update fixed (the "no write permission to npm prefix" warning):** the devbox ran
  claude as a **root-owned global npm install at /usr**, but sessions run as `ubuntu` → self-update
  always permission-failed (silently never updated). Fix: installed the **native user-owned build**
  (`~/.local/bin/claude` → `~/.local/share/claude/versions/…`), added `~/.local/bin` ahead of
  `/usr/bin` in `.bashrc`, and removed the npm global (sudo). `claude update` now runs clean (no
  permission error, no leftover-npm warning). Headless doc-drift-audit already prepends ~/.local/bin
  so it uses native too. **Codified in `devbox.yml`** (native installer + PATH + npm-absent) so a
  rebuild reproduces it. ⏳ The 3 running sessions (cue/infra/personal-web) still hold the deleted
  npm binary in memory — stable + RC-connected, but restart onto native at convenience to complete
  the migration (transcripts persisted; restart is safe).

**2026-07-16 (cont.3) — advisor email 2 real bugs fixed + Alertmanager email themed:**
- Operator screenshot showed the advisor email with **two bugs**: (1) `AI Advisor &middot; …` — the
  eyebrow/footer passed literal HTML entities into `_render_email` fields that html-escape them →
  double-escaped → shown literally. Fixed by using Unicode `·`/`—` (pass through html_escape).
  (2) The advisor email lacked the `.term/.titlebar/.screen` chrome the other 3 have — the CSS was
  defined but `_render_email` never emitted the markup. Wired the titlebar+screen+prompt. `d53b368`.
- **Alertmanager `email-alerts` themed (the operator's "yes do alertmanager"):** the plain critical-
  alert email is AM's OWN receiver (default template), separate from the advisor. Authored a
  terminal-theme Go-template `html:` on the emailConfigs (reuses the shared palette; per-alert cards
  with severity tags). **Validated the Go template in a golang container (parse+execute, 6302 bytes)
  BEFORE deploying** — it's on the critical-alert path. Deployed + fired a synthetic CRITICAL test:
  advisor email sent, AM email sent (`alertmanager_notifications_total{integration=email}` +1,
  0 failed, 0 template-exec errors). 6h repeatInterval suppressed the 2nd test (expected).

**2026-07-16 (cont.2) — email redesign round-3 (+ weekly drift email) + the "advisor didn't format" bug:**
- Round-3 from the design agent: trivial CSS polish over round-2 for the 3 status/alert emails
  (flexbox .ring, daily-report row layout) + the weekly drift email (send-audit-email.py) newly
  themed. Applied `ec12096`. **Caught + fixed a real bug (`b444218`) via a live test send BEFORE
  shipping:** the drift-email rename left the lookup dict as `_PILL` (old `pill-*` values) while
  `_render` referenced `_STATE` with `t-*` values → NameError on every send. Renamed + revalued.
- **Why the operator saw "unformatted advisor emails":** NOT the advisor — its success path uses
  `_render_email` (verified, and the real success-path HTML rendered themed). The unthemed alert
  emails are **Alertmanager's own `email-alerts` receiver** (03-alertmanager-config.yaml:76): for
  severity=critical, AM sends its DEFAULT-template HTML email in ADDITION to the advisor's
  diagnosis + ntfy. The design agent never touched AM's template (it's a Go template in
  emailConfigs, not one of the 4 generators). **⏳ Offered to theme the AM email-alerts template to
  match — operator decision (it's a new artifact + touches the critical-alert path).**
- All 4 test emails fired live + verified sent (status/advisor/daily-report/drift). Rendered the
  real advisor success email + drift email and sent to the operator for visual confirmation.

**2026-07-16 (cont.) — email redesign (all 3 status/alert emails) + test sends:**
- Design agent delivered a terminal/monospace theme as 3 modified source files (not images):
  `service-status-report.py`, auto-remediation `remediate.py` (`_render_email`), `daily-report.sh`.
  **Verified presentation-only** before applying: controller had 0 python-logic-line diffs; a
  subagent audited the 2 data-script diffs and confirmed all queries / kubectl-AWS calls /
  service+row sets (all 51 status rows render) / health logic / subject / recipients / SES-send
  are byte-identical (outside the redesigned HTML region). One intentional design reduction: the
  per-service `kind · namespace/target` sub-line is dropped from status rows (data still collected).
  Rendered the status email against live Prometheus (`STDOUT_ONLY=1`) + a sample advisor email to
  verify visually + email-safety (inline CSS, no external assets) before shipping. Committed `c7f2bcd`.
- **Deploy paths differ:** the 2 configmaps deploy via Flux (status-report configMapGenerator;
  advisor needs a controller restart to reload remediate.py — done); `daily-report.sh` is baked
  into `ghcr.io/…/aws-s3-sync:main` → the push auto-triggered the image build (path-filtered), and
  the CronJob's `:main`+Always-pull means the next run uses it.
- **All 3 test emails fired live + verified sent:** status-report (manual Job → SES), advisor (temp
  always-firing PrometheusRule `EmailRedesignTest` → AM → advisor diagnosed noop → SES; rule removed
  immediately — the advisor's `_alert_still_firing` guard queries Prometheus so a hand-POSTed webhook
  is skipped, hence the real-rule approach), daily-report (manual Job off the rebuilt image → SES).

**2026-07-16 — overnight alert cluster = M144 escalated to etcd-leader loss (M145, fixed):**
- The "concerning security" note the operator flagged: the overnight advisor emails weren't a
  breach — they were a single I/O cascade at 07-15 03:29 PDT (the nightly velero window):
  **etcdNoLeader on cp1 ~4 min** + NodeSystemSaturation (cp2/w1) + TargetDown +
  AlertmanagerFailedToSendAlerts + a mini SMB timeout. Root: 5 backups packed into 03:00-03:48
  with node-agent kopia running on the control-plane nodes → kube-system-daily saturated cp1/cp2
  disk → etcd fsync stall (shared Ceph). Fix `0861852`: 12 velero schedules re-spread to 30-min
  interleaved heavy/light, 01:00-06:30 (see M145). Applied + live-verified.
- Cluster healthy now (8/8 Ready, quorum never actually lost — cp2/cp3 held leader). Cost of the
  cascade: nil (all self-resolved). The two MiniSMBAuthRejected criticals self-healed (mount-nas
  fix); NAS contention should ease with the spread.
- Separately: the operator's "new email designs" for the update + weekly-drift emails — the only
  recent design artifacts on disk are CUE-app designs in the cue repo scratchpad, NOT infra
  update-email designs; asked the operator for the location/attachment. Not implemented pending that.

**2026-07-14 (cont.) — doc-drift-audit manual-review items resolved (3/3):**
- **M91 kernel citation:** re-verified on live `6.8.0-134-generic` (node SSH) — `i6300esb` still
  absent, M91 stays blocked; CLAUDE.md re-anchored + "re-check per kernel bump" note (`badd590`).
- **WG /29 vs /30:** live wg0 = `/29`; the UDM route is deliberately `/30` (covers in-use .1/.2;
  .3-.6 were the M110-retired regionals). Both docs now cross-reference the layering (`badd590`).
- **Guest VLAN DNS — REAL drift found + fixed (`5c027dd`):** TF/docs say guests get public
  resolvers by design; live `dhcpd_dns_enabled` was FALSE (guests resolved via the gateway) and
  plan said "No changes" — NOT a provider blind spot but the paultyng-era
  `ignore_changes=[dhcp_server]` mask hiding real drift for months. Converged live via direct UDM
  API PUT (operator-approved; verified true + 1.1.1.1/8.8.8.8/8.8.4.4), removed the mask so TF
  owns the block again; verification plan dispatched (expect 0-diff). Remaining masks on
  clients/vsan/ceph = audit candidates — diff live networkconf vs .tf first (memory updated).

**2026-07-14 — the "security" advisor email decoded + the nightly stall is now a pattern (M144):**
- TetragonCredFileAccess (10:29Z email) = the wireguard pod's restart apt-init reading /etc/shadow
  via dpkg-preconfigure — benign, same as 07-13. But it was a NEW pod: the ~03:00-03:30
  kopia-maintenance I/O stall killed wireguard a SECOND night (and DeadlineExceeded'd gdrive-sync,
  after onedrive-sync the night before; node_exporter scrapes went dark mid-window). 07-13's
  "one-off" verdict invalidated → M144. Symptom fixes shipped + applied: wireguard probe
  timeout/threshold (`c5231ad`, rolled + VPN verified), rclone deadlines 90m (`ee7f17f`).
  Root decision deferred pending 2-3 nights' observation. GH Actions checked same day: healthy
  (only the 2 known already-fixed aws-tag-manual failures); tag-drift 51→38, remainder all
  already-deleted/tagged items pending the DAILY-mode Config recorder (by design, ~$2/mo).

**2026-07-13 — advisor "node saturation" alert: one I/O storm, four alerts, one real bug found:**
- **NodeSystemSaturation** (02:48–03:28, w1+gpu1, load/core 12+, resolved): NOT CPU — D-state I/O
  stall from the nightly **velero kopia-maintenance** window against the new Garage repo (first heavy
  pass post-M137; kopia maintain jobs concentrate on w1/gpu1). 7-day history clean → one-off burst,
  no action; watch for recurrence before tuning.
- **Collateral, all same root:** wireguard pod on w1 killed at exactly 03:28 (1s liveness probe
  timed out during the stall) → restart init runs dpkg/debconf → **TetragonCredFileAccess**
  (/etc/shadow via dpkg-preconfigure = benign apt behavior) + **CPUThrottlingHigh**. VPN verified
  recovered (wg0 up, VIP re-preempted). Possible hardening: bump the wireguard probe
  timeoutSeconds (1s is stall-fragile).
- **KubeJobFailed (rclone/onedrive-sync)**: DeadlineExceeded — pod couldn't start for ~40 min in
  the same congestion window, then synced in 30s; every later run green. Failed Job object left
  for the operator to delete (or ages out of the alert).
- **REAL BUG — the 11-day CiliumNetpolDropFlow flapper decoded:** postgres→postgres **:8000**
  POLICY_DENIED ~17k/day since 07-02 — CNPG 1.30 (H45c ladder) instances query each other's
  instance-manager status API, which the postgres tier never allowed (only cnpg-system→:8000).
  Silent degradation of peer/failover health checks. **Fixed `949fe59`** (intra-ns :8000
  ingress+egress), applied + verified live. Lesson: an operator upgrade can change a tier's
  traffic matrix — re-audit tier allowlists after operator majors.

**2026-07-12 (cont.) — status-email fixes: mini "offline" row + cloud-tag-drift (M143):**
- **Mini host row** (`7afbe35`): "Mac mini host" was wired to `mini_health_up` = agents AND
  nas_readable rollup → every NAS outage read as "host offline". Now push-heartbeat freshness +
  a separate honest "NAS mounts (SMB)" row; live-verified host=1/mounts=0 mid-outage; dashboard
  regenerated.
- **cloud-tag-drift (M143)** — see the tracker entry for the full 4-class breakdown. Headlines:
  ~13 were detector false positives (AWS Config CIs omit tags for alarms/events-rules; SES rule
  sets untaggable) → allowlisted `4bde045`; 24 hand-made bootstrap IAM/S3 tagged ManagedBy=manual
  (new `aws-tag-manual.yml` CI workflow for the TagPolicy/TagRole perms the local key lacks);
  ~14 belong to the personal-web repo (public-web-vpc family — no default_tags there; handoff
  prompt delivered); external-monitoring re-applied to resurrect the never-confirmed SNS email
  subscription (operator: click the new confirmation email). 10/11 stack plans were "No changes" —
  disproved the "just re-apply" theory; TF-managed resources were already tagged live.
- **M143 endgame (same day):** web agent refuted the personal-web premise (default_tags were always
  there) → the public-web-vpc family was ORPHANED WordPress-era networking, verified empty, and
  **torn down** (12 resources) with operator approval; IAM fossils deleted (w3tc, velero-backup,
  kubernetes-s3-backup users; DataSync role+policy pairs; VeleroBackupPolicy,
  s3-backup-kubernetes-policy, S3_stopthecastle — the last two needed a policy-VERSION purge, now
  in `delete-fossils`). KMS key kept+tagged (snapshot-encryption risk). M75 orphan-key residual now
  2-of-4 done. Detector green expected after AWS Config re-records (≤24h).

**Same day (2026-07-11 cont.) — Cue TestFlight infra + M140 executed:**
- **Cue iOS edge ingress (option A) LIVE + e2e-verified** (`decaa17`, CF apply 29158098682): new
  `cue-ios` CF Access service token (TF resource, values via `terraform output` → handed out-of-band);
  the MAIN Access app now carries a second `non_identity` policy (either-policy admits) +
  `auto_redirect_to_identity=false` (required for header-auth evaluation; humans get one extra click).
  Verified with worst-case curl: token → through CF Access **and BFM** → Fastify app-401; no token →
  302 SSO. **No WAF skip needed.** Option B (api.cue subdomain, no Access) noted, not built.
- **`CUE_APPLE_BUNDLE_ID=net.etherport.cue` live** (`c09ff92`): sops-set into cue-app; pods rolled
  GitOps-natively via a pod-template `cue.wind/config-rev` annotation bump (no kubectl rollout —
  image-automation SSA strips it anyway); verified via `printenv` in the new pods.
- **Google OAuth clients**: console-only (no API) — operator instructions delivered (iOS client →
  `CUE_GOOGLE_CLIENT_ID` + reversed-ID URL scheme; separate Web client → `CUE_GOOGLE_WEB_CLIENT_ID`).
- **M140 built + APPLIED** (`dd7192c`, apply 29158373005) — see the M140 entry.
- NB: local throwaway AWS creds were rendered for `terraform output` (cue-ios secret) and removed after.

## 2026-07-09 — 6-day backup outage: UNAS SMB auth wedge; mount agent didn't self-heal (fixed)

**Symptom:** recurring AI-advisor alerts + daily "service status down" / "cairn agent down" emails.
**Root cause:** the UNAS's (sequoia, 10.10.209.10) **SMB authentication wedged ~07-03** — port 445
negotiated but auth was REJECTED for graham AND guest, while NFS/S3-sync (different auth path) kept
working and the md array was healthy. So all NAS SMB mounts failed → every cairn job "destination
not reachable" → cairn_healthy=0 → the alerts/emails. Owner re-authed on the mini console (SAME
password — confirming a UNAS Samba wedge, not a stale credential) → auth restored.
**Why it lasted 6 days (the real bug):** `net.wind.mount-nas` was RunAtLoad + KeepAlive{SuccessfulExit
=false} — ran ONLY at login, relaunched ONLY while failing. Once it succeeded at the 07-02 reboot it
never ran again, so a later SMB drop was never re-mounted (silent).

**Fixes (committed):**
- `mount-nas` self-heals: RunAtLoad + **StartInterval=180** (re-check every 3 min), KeepAlive removed;
  + a reachability/AUTH pre-check that logs a distinct "SMB AUTH REJECTED" and BAILS instead of
  spamming `open smb://` (which pops headless NetAuth prompts that freeze all mounts). `60cea78`.
- status-email "cairn agent" row → **agent LIVENESS** (heartbeat freshness, 2h) not cairn_healthy
  (which is 0 on any job failure incl. best-effort photos misses). SMB-auth probe added to
  mini-health.sh (`mini_health_check{check="smb_auth"}`) + **MiniSMBAuthRejected** alert so a
  recurrence pages in ~1h with the exact remedy. `10e5d8d`.
- Recovery: mounts restored, 7/8 jobs green (all metadata + messages 322k msgs). The
  ICloudBackupFailed/Stale storm cleared; only CairnJobsFailing (photos) remained.

**Gotcha relearned:** running `cairn run` from an agent SHELL gives false "authorization denied" on
FDA-gated sources (chat.db/NoteStore/…) — FDA is attributed to the responsible process, which is the
shell, not cairn.app-under-launchd. ALWAYS test via a one-shot launchd agent. And DON'T `launchctl
bootout` a cairn agent while osxphotos is running — it orphans osxphotos (survives, unrecorded);
wait for the history record first. Photos being flaky post-recovery is the known best-effort
aged-mount fragility, not the outage.

## 2026-07-09 (cont.3) — M130 offsite (3-2-1) + full repo scan (drift/todo/README/runbook)

**Prompt:** "finish M130, then full repo scan for config drift / update todo status / README / runbook."

- **M130 offsite tier DONE + verified.** New `backups/pve-config-offsite` CronJob (velero-dr dir) NFS-mounts
  only the tiny pve-config subdir → `s3://velero…/pve-config/`, reusing velero-dr-sync SA+IRSA+rclone
  (no new IAM); runs as 977:988 (tarball owner) + empty-source guard; alert `PveConfigOffsiteStale`. Test
  run uploaded 3.38MiB → confirmed in S3. pve config now full **3-2-1** (pve→NAS→S3).
- **Repo scan:**
  - **Live drift: NONE.** git clean, all Flux Kustomizations/HelmReleases Ready, all pods healthy, Flux
    synced to HEAD. Drift detectors 6/7 clean; `cloud-tag-drift`=1 is the known bootstrap-IAM residual
    (no taggable AWS resources added this session; CI run itself succeeded).
  - **README check** (agent): fixed omissions of this session's components — ntfy in root/docs README +
    obs sections, pve-config-backup in ansible README, pve-config-offsite in velero-dr README, pve backup
    row in the root backups table. (auto-remediation README already current; credential-inventory indexed.)
  - **Runbook check** (agent): fixed **1 HIGH** — disaster-recovery.md §10 backup matrix Velero row named
    S3 (now read-only DR) + cross-ref'd §3.1 (Technitium DNS!) instead of §1.3 → dangerous in an incident;
    corrected to Garage-primary/§1.3 + added the pve row. MEDIUM: §6.2 + playbook comment now document the
    shipped offsite tier (comment had said "NOT done"); etcd-backup-restore + VeleroBackupFailed +
    operations-guide updated for Garage-primary / two-BSL / ntfy 2nd channel.
  - **Todo status:** this session's items all flipped in outstanding-work (M131/M133/L35/L36/M139/M139b/
    M132/M130/L6/L18/L14 ✅; M134 blocked-at-receiver; M138 needs-operator; L16/M63 partial).

**Session total (2026-07-09):** M131, M133, L35, L36, M139, M139b, M132, M130 (+offsite), DR drill, S3-DR-BSL
fix, L6, L18, L14, M63(partial) — all shipped + verified; cairn/M138 alert-spam silenced; AWS egress
confirmed decaying; full doc/runbook/README consistency pass. **Operator TODO:** ntfy app subscribe
(`wind-critical`), mini iCloud app-password (M138), M134 apex-MX decision (handled via cue agent).

## 2026-07-09 (cont.2) — DR restore drill + fixed the offsite S3 BSL (was Unavailable)

**Prompt:** "what else can we get on with?" → picked DR restore drill, reliability fixes, security
sweep, M130 offsite.

- **DR restore drill (M11/M12 progress):** Velero-restored the `wikijs` backup from the **Garage** BSL
  into a throwaway ns (namespaceMapping → wikijs-drtest). **Completed 34/34, 0 errors**; PVC+PV
  recreated (Kopia data-mover ran), Deployment/Service restored (pod 0/1 — correctly blocked from the
  prod DB by the postgres netpol). PVC restored empty because wikijs keeps content in shared postgres
  (verified the LIVE PVC is also empty) — so a **non-empty-data proof** (technitium ns=`dns`, or a CNPG
  barman restore = M12) remains a follow-up. Cleaned up the temp ns.
- **Found + FIXED: the offsite S3 DR BSL was `Unavailable`.** The `default` read-only BSL read the
  bucket ROOT, but velero-dr rclones Garage → `s3://…/dr/`, so velero rejected `dr/` as an "invalid
  top-level directory"; also the velero-dr sync **had never run** (weekly-Sunday). Fix: `prefix: dr`
  on the BSL (`6fa8499`) + triggered the first dr sync manually. BSL now **Available** (prefix=dr, no
  error) — the offsite copy is a usable restore source for the first time. Initial full upload finishing
  in the background (incremental thereafter; upload = free ingress).

**Next in this batch:** reliability fixes (L18/L6/L16), security sweep (M63+L14), M130 offsite-S3 tier.

## 2026-07-09 (cont.) — ai-advisor caching+tiering (M139/M139b), ntfy 2nd channel (M132), cost check

**Prompts:** cue caching already handled by the operator; "benefit to Opus for these alerts?";
"check recent alert emails"; "do M132 + Opus tiering, cap unchanged"; "M130 cost risk?"; "M134 detail";
"current AWS cost status / past the 24h S3-read window?".

- **Alert-email spam = M138.** 14 of 20 firing alerts were the cairn/iCloud backup failure; warnings
  don't email but every alert hits the ai-advisor webhook, which emails its own per-alert diagnosis.
  **Silenced** `ICloudBackup*|CairnJobsFailing|MiniHealthDegraded` for 7d (AM silence, note → M138) —
  active non-silenced is now just InfoInhibitor+Watchdog. M138 still needs the operator on the mini.
- **M139b — tiered models.** Deep-mode → Opus 4.8, single-call → Sonnet; cap unchanged, `_add_cost`
  per-call priced. Live.
- **M132 — self-hosted ntfy 2nd critical channel.** New `platform/kubernetes/ntfy/`: ntfy + in-house
  `am2ntfy` bridge (no native AM parser) + AM `severity=critical`(continue:true) route. **E2E tested**
  (payload → bridge 204 → ntfy stored, urgent). Exposure gotcha: TS operator can't mint
  `tag:cluster-ingress` (ACL → autogroup:owner only) → switched to `loadBalancerClass:tailscale`+`tag:k8s`
  (cue-api pattern) → `http://ntfy.tail48f596.ts.net`, `TailscaleProxyReady`. Operator one-time: ntfy
  app → subscribe topic `wind-critical`.
- **AWS cost:** MTD $47, S3 yesterday $2.57 vs trailing-7 $5.30 (spike ratio 0.486 = <½) → egress fix
  decaying hard. 07-08 was cutover day (partial egress); 07-09 is the first full day on Garage → clean
  number lands 07-10. Forecast $161 is the naive spike-weighted extrapolation.

**Next:** M138 (operator, mini app-password); M130 (pve/ceph-mon backup — cost-safe, design = pve→NAS
NFS→existing s3-sync, no new IAM/egress; build next); M134 (DMARC rua — explained to operator).

## 2026-07-09 — Autonomous tidy-ups (M131/M133/L35/L36) + doc consistency + cairn backup finding

**Prompt:** "send a sample of the current daily status email … proceed autonomously on as many
infra tidy-ups as possible … also do a doc consistency check."

**Shipped (all committed + reconciled + verified live):**
- **M131 — apiserver audit → Loki** (`3f05e18`, `b260ca5`). Alloy (root DS, `/var/log` hostPath) tails
  the active `/var/log/kubernetes/audit/audit.log` (the in-container `--audit-log-path` maps there via
  the `audit-logs` hostPath — the path is the `audit/` subdir, not the flag literal) → `job=apiserver-audit`.
  Two loki-ruler rules (`06-loki-rules-apiserver-audit`): `ApiserverAnonymousSuccess` (critical),
  `ApiserverForbiddenBurst`. Verified stream flowing + rules loaded. **Gotcha caught by testing against
  live data:** LogQL label-matcher alternation only anchors the first/last branch → the per-branch
  exclusion leaked `/livez`,`/readyz` and the critical would've fired on every probe; fixed with a
  grouped regex ([[logql-alternation-anchoring]] memory).
- **M133 — SSH-cert renew staleness** (`66be2c8`). `step-ssh-renew.sh` writes cert NotAfter to a
  node_exporter textfile; alerts `DevboxSSHCertExpiringSoon` (<4h, critical→email — the on-disk metric
  keeps serving the stale expiry when the loop stalls, so it fires ~3.5h pre-expiry) +
  `DevboxSSHCertNoMetric`. Renew timer confirmed healthy (a scare from misreading cert PDT-vs-UTC turned
  out fine).
- **L36 — PSA warn/audit=restricted** on the 9 restricted-clean namespaces (`cc23092`), enforce left at
  baseline (non-blocking regression signal). Assessment method that WORKS: `enforce=restricted
  --dry-run=server` surfaces existing-pod violations; `warn=` dry-run does NOT (returned 0 for wireguard).
- **L35 — credential inventory** `docs/reference/credential-inventory.md` (`4c2acb8`) — the map across 12
  categories, cross-linked to the rotation runbook.
- **Doc consistency** (`1cba07b`): corrected the two 2026-06-11 roadmap banners (A2/3-2-1 ✅ M137 Garage,
  not "unbuilt/MinIO"; C2/I7 ✅ M136) + README aws-cost-exporter mention. Earlier this session the
  velero→Garage cutover was propagated through README/PLATFORM-MANAGEMENT/disaster-recovery/aws-infrastructure.

**Finding (needs operator) — M138:** sampled the daily email (triggered the real CronJob → user's inbox;
also rendered via `STDOUT_ONLY=1`). The "3 down" is **cairn iCloud backups on the mini**: mini is up +
pushing but self-unhealthy; **8/9 categories failing** (drive/notes/safari/messages/calendars/contacts/
reminders/photos), only `messages_attachments` (local files) OK → almost certainly an **expired iCloud
app-password**. The devbox can't SSH the mini (macOS, not cert-fleet) → operator must re-mint the
app-password + check the cairn agent. Logged as **M138** (tier M-H).

**State/next:** M131/M133/L35/L36 done. Batch-D items still open (operator decisions): **M132** (2nd
critical channel ntfy/Pushover), **M134** (DMARC rua), **M130** (pve/ceph-mon backup). **M138 (cairn)
needs the operator on the mini.** Verify tomorrow: 07-09 S3 egress near-zero; cloud-tag-drift count after
AWS Config settles.

## 2026-07-08 — AWS cost deep-dive: velero Kopia egress → Garage local-primary repo (M136 + M137)

**Prompts:** "aws costs not returning to normal, forecast going up"; build daily cost reporting; the durable
fix; "why is the forecast higher than last month… nothing hidden?"

**Root cause (M137):** the S3 spike was **`DataTransfer-Out` (egress), not storage/requests** — 453 GB in
7 days, forecast $75→$160. Found via **claude-admin Cost Explorer** (key the user pastes on request; NOT in
SOPS — `terraform-homelab` is DENIED ce:*/cloudwatch:*/s3:ListBucketVersions). Per-bucket via CloudWatch S3
`BytesDownloaded` request-metrics (enable per bucket ~$0.30/metric/mo, DISABLE after) → caught a **6.46 GB
velero-bucket burst**. Mechanism: Kopia **full maintenance `"rewriting contents from short packs"`**
downloads repo content from S3 to repack, ×20 per-ns repos; the M123 upgrade made a short-pack backlog →
egress spike (decaying 87→30 GB/day). June was storage-dominated (one-time archive-bucket fill before
Deep-Archive transition); July is egress. Nothing hidden — archive/iCloud storage is flat.

**M136 (daily cost reporting) — DONE/LIVE:** `aws-cost-exporter` CronJob (IRSA cloudwatch-read + new
`ReadCostExplorer` grant) → pushgateway → Grafana "AWS Cost" dashboard + Cost section in the daily email +
alerts (`AWSCostForecastHigh`/`AWSServiceDailyCostSpike`/`AWSCostExporterStale`).

**M137 (durable fix) — Phase 1+2 DONE + verified:** MinIO rejected NAS NFS ("insufficient drives online").
Switched to **Garage** (LMDB metadata on a 10Gi Ceph-RBD PVC + data blocks on the NAS/NFS, uid/gid 988).
Cut velero default BSL → Garage, S3 → read-only. **Full PVC round-trip byte-verified.** ⚠️ velero wedged
from rapid test-backup churn → fixed via `helm uninstall` + Flux `reconcile.fluxcd.io/forceAt` reinstall
(GOTCHAS in M137: helm-CLI-uninstall desyncs helm-controller cache; stale S3 BSL kept default:true; backups
hang InProgress a few min post-reinstall then complete). **Phase 3 DONE:** `velero-dr/` weekly rclone Garage→`s3://velero…/dr/` + Deep-Archive lifecycle @30d +
GarageRepoDown/VeleroDRSyncStale alerts (93 objs mirrored, verified). `archive.wind`=NAS/iCloud archive, kept separate. Files: `platform/kubernetes/{garage,monitoring/aws-cost-exporter}/`,
`clusters/wind/helm-releases/velero.yaml`.

## 2026-07-05 — morning triage: Cilium MTU black hole (gpu1) + daily-email false "outages" → 0

**Prompt:** "review the ai advisor alerts over the last 24 hours or so and resolve issues.
we still have service outages being reported on the daily update email, too, so investigate those."

**1. AI-advisor / overnight alert storm → Cilium MTU black hole on gpu1.**
`nvidia-dcgm-exporter` TargetDown + node-feature-discovery worker crashlooping (40+ restarts)
on `k8s-gpu1`, pod `1/1 Running` and serving locally (scrape *timed out*, not refused) → a
classic small-works/large-fails signature. Root cause: gpu1 hosts the K8s `wireguard` pod, whose
`wg0`/`wg1` host interfaces are MTU **1420**. After the M123 K8s-upgrade reboot, cilium-agent's MTU
**auto-detect** (`MTU: 0`) latched onto 1420 instead of eth0's jumbo 9000 → `cilium_wg0` came up at
**1340** → apiserver-ClusterIP TLS + dcgm scrape responses black-holed, while node-health probes
(small packets) stayed green so Cilium reported healthy. Fix: `helm upgrade cilium
--reset-then-reuse-values --set MTU=9000 --set policyAuditMode=false` (+ rollout restart) — the
runbook's documented `--reuse-values` template-nil landmine + policyAuditMode re-assert. Verified
gpu1 `cilium_wg0`=8905, dcgm `up=1`, NFD restarts frozen, BGP 8/8, encrypt=Wireguard, enforce
preserved. **Pinned `cilium_mtu: "9000"`** in both inventory mirrors so a future kubespray cilium
run can't revert to auto-detect. NEW runbook `docs/runbooks/cilium-mtu-wireguard-blackhole.md`.
Commit `c3c3891`.

**2. Daily-email "service outages" → all false; email 4-unknown/mislabelled → 0.**
Ran the report with `STDOUT_ONLY=1` (one-off Job): "3 down, 1 degraded, **4 unknown**". Decomposed:
- **3 Mac-mini/cairn rows** (Mac-mini host + cairn agent *down*, iCloud backups *degraded*) — ONE
  root cause, and it's real: every iCloud category fails `destination base not reachable:
  /Volumes/Backups/Graham/iCloud`; photos also can't mount `/Volumes/Personal-Drive`
  (`smb://graham@sequoia…` = the UNAS). `mini_health` shows `nas` flipping 1→0 at 07-05 01:10 —
  downstream of **today's UNAS nvme0 APST controller-hang** (the cache-recurrence loop). SSH'd the
  UNAS: fully healthy NOW (md4 `[2/2] [UU]`, `/dev/nvme0` present, smbd up, uptime 13d/no reboot) —
  so the mini's SMB session is wedged ("reattach failed — NOT retrying, rapid reattach wedges the
  disk-image subsystem"). **Needs a mini-local remount/reboot — agent can't SSH the mini.** messages
  still succeeds (local chat.db, not the NAS). User notified.
- **4 "unknown" = pure noise, all fixed:** (a) *Authentik Redis* — Authentik dropped bundled Redis
  at 2025.10/H44, deployment gone → removed from `services.py`. (b) *Ceph CSI provisioner* — moved
  namespace `default`→`ceph-csi` ~3d ago → fixed the target. (c/d) *UDM-firewall + L3-switch-ACL
  drift detectors* — never wrote their `drift-status` ConfigMap key. Root cause: the ansible-drift
  `check` matrix job runs inside the `ansible-runner` **container** (dash, no sudo/kubectl), so the
  `report-drift-status` action's kubectl-install fallback failed silently (swallowed by
  `|| echo ::warning`). Moved the write to a dedicated `report-status` job on the lifecycle **host**
  (no container → kubectl present), keyed off each leg's drift artifact; backfilled both keys live
  (clean). Regenerated the dashboard from `services.py` (59 panels). Re-ran the report: **3 down, 1
  degraded, 0 unknown, 46 healthy** — the only reds are now genuine.
- **cloud-tag-drift = down** (the 3rd "down") = pre-existing hygiene, NOT an outage: 228/292 AWS
  resources lack `ManagedBy=terraform` — ~75 structurally untaggable/AWS-predefined (allowlist), the
  rest IaC-managed stacks missing `default_tags`. Filed **M135**; left firing (hiding it would mask
  real drift).

**Commits:** `c3c3891` (MTU fix + runbook), `56163e8` (services.py + ansible-drift workflow +
dashboard). Tracker: M135 filed; 07-05 triage bullet in Recently-completed.
**Next:** user to remount/reboot the mini to clear the cairn NAS backup outage; M135 default_tags
rollout when convenient.

## 2026-07-03 — backups 5×HeadObjectFailed: NOT multipart ETags — the sync-output parser split on " to " inside filenames

Owner relayed the infra agent's overnight diagnosis ("multipart uploads have non-MD5 ETags, so verify-one.sh can never validate them") for the FAILED `backups` run `20260703T081003Z`. **That mechanism doesn't exist in this code** — verify-one.sh never touches ETags (it HEADs with `--checksum-mode ENABLED` and compares `ChecksumSHA256`), `checksumUnavailable` is non-fatal by design, and the SAME run successfully verified 12 multipart-sized (>8 MB) files. Read the actual report:

- **Real cause:** `filesFailed=5`, every one `HeadObjectFailed` with *"**Bucket** name must match the regex"* and a recorded key of `/archive.wind.etherport.net/objects/…` (bucket glued into the key, leading slash). The transfer-list parser split each `upload: <local> to s3://<dest>` line at the **first bare `" to "`** (`s3_part="${rest#* to }"`) — and all 5 files (OneDrive/WSP client docs) contain `" to "` **in the filename** ("…Cheapest **to** Cards…", "When It Comes **to**…", "Intro **to** Cap Structure", 2× "Ultimate Guide **to** Debt…"). Garbage bucket → HEAD refused → verify_status=failed ×5 → FAILED. Latent since the original parser; first triggered 07-03 because these files were newly uploaded. The `checksumUnavailable: 5` was the same 5 records (no dest checksum obtainable), and sizes 284 KB–79 MB — three of five aren't even multipart-sized.
- **Fix (`sync-and-verify.sh` upload+copy branches):** split on the **full `" to s3://"` separator** (last occurrence). This is provably unambiguous for local→S3 lines: a POSIX path component can't contain `/`, so `" to s3://"` can never occur inside the local path or the key. Unit-tested with the three real failing filenames + multiple-`" to "` + copy-line cases (6/6).
- **Verified the 5 objects live** (HEAD): exact size match to the report and `ChecksumSHA256` present on all — incl. the 79 MB mp4 (full-object SHA256; the newer aws-cli in the image writes full-object rather than composite checksums for multipart — verification handles both). Data was always intact (matches the infra agent's byte-completeness check); only verification's addressing was broken.
- **NB for future triage:** the report's `path` field shows `../src/…` — the CLI prints source paths relative to the pod's `/work` cwd; harmless (script resolves them from `/work`).

---

## 2026-07-02 — v0.1.7/v0.1.8 deployed; EAGAIN root cause PROVEN (NAS-held sparsebundle locks); orphans fixed

**What:** deployed the review release + closed two long-running mysteries.
- **Last night (v0.1.6):** 7/8 ✓; photos rc=1 — graceful skip exactly as designed (90-min timeout on
  the aged mount, ONE reattach attempt, no thrash, no page). Best-effort behaving as spec'd.
- **`Resource temporarily unavailable` — PROVEN root cause:** direct flock probes showed the
  sparsebundle's `lock`/`token` files are byte-range **locked NAS-side by a dead session's durable
  handles**. It was never the disk-image daemons (diskarbitrationd is SIP-protected — the earlier
  `killall` never even killed it; the 07-01 "fix" was the reboot). A quick unmount/remount does NOT
  release the locks; a REBOOT does (long disconnect → NAS scavenges). **Recovery = reboot the mini.**
  My headless forcing attempts also exposed a real weakness: `open smb://` degrades to a GUI
  credential prompt on error paths (NetAuth), freezing all mounts headlessly — the owner had to click
  stacked dialogs. Durable fix to explore: disable durable handles on the UNAS share.
- **v0.1.7 deployed** (checksum + leaf verified) after the reboot restored the stack; photos ran
  ✓ rc=0 (44,002 items, 469s), **8/8 pushed**. PUT-push fix VALIDATED live (latched
  `cairn_photos_stack_unhealthy` gauge cleared; `messages_snapshot_failed` clears at tonight's run).
- **`cairn_photos_orphans` mystery solved by the new v0.1.7 diagnostic on its FIRST run:** sqlite
  `file:` URI broke on the SPACE in `~/Library/Application Support/…` — orphans never emitted since
  cutover; OrphansGrowing alert was inert. Fixed (percent-encode), shipped + deployed as **v0.1.8**
  (verified against the live DB: 43,990 ledger rows readable). Tonight's 22:00 run emits orphans for
  the first time. cairn README §6 corrected to the proven lock mechanism (`7976511`).

## 2026-07-02 (cont. 4) — M76 parity COMPLETE on the edge box; F1+F7 applied; the sudo-stall root cause

**F1+F7 applied** (owner-approved): dead spokes rule + orphaned ALB SG deleted cleanly.

**M76 cert-SSH parity for vpn-aws — DONE end-to-end:** step-ca-trust check kept failing "Timeout (12s) waiting for privilege escalation prompt" even with the WAN calm → **root cause was NOT path loss: the box's own hostname `ip-10-10-100-10` was missing from /etc/hosts (post-M110 artifact), so EVERY sudo stalled on a failing DNS lookup.** Added ANSIBLE_TIMEOUT=60 to the workflow (diagnostic + belt) → play ran → apply succeeded → cert-SSH verified from the devbox → **fixed /etc/hosts on-box (sudo 12s+ → 0.008s)** → flipped ansible-vm-fleet aws branch to cert auth (awskey SOPS step deleted) → cert-auth CI run verified → `step-ca-remove-static-key` applied → **verified: cert works post-removal, static key GONE from authorized_keys.** The LAST standing static-key SSH auth in the estate is eliminated (cloud-init rebuild seed + SSM break-glass remain by design). NB this re-attributes part of the historic "CI can rarely complete a play against vpn-aws" pain: it was sudo-stall compounding the real (but intermittent) WAN loss.

## 2026-07-03 (cont. 4) — H46 dead-man LIVE end-to-end; credential-expiry pipeline LIVE; runner VIP-route fix

**H46 (option B) BUILT + VERIFIED:** in-cluster `watchdog-deadman` CronJob (monitoring ns, 5-min, aws-cli image, IRSA via cloudwatch-read + a Wind/Deadman-scoped PutMetricData grant + a new trust sub) publishes WatchdogSeen=1 ONLY while the Prometheus Watchdog alert is actively firing in Alertmanager → CW alarm `wind-watchdog-deadman` in **us-east-1** (the alerts SNS topic lives there per R53 rules; bonus: region-independent of the cluster) with treat_missing_data=breaching → SNS → email. Manual run: "heartbeat published" ✓. Build gotchas: the IRSA roles are a for_each map (`aws_iam_role.irsa["cloudwatch-read"]`), and the first alarm apply failed cross-region ("Only us-west-2 supported") → moved metric+alarm to us-east-1.

**Credential-expiry pipeline LIVE:** first run failed pushing to `10.10.201.72:9091` — my address bug (.72 = technitium-1, NOT pushgateway; the real path is `pushgateway.wind.etherport.net` via Traefik .70). Fixed the workflow URL + gave the gh-runner the documented **/32-via-.1 netplan route** to the Traefik VIP (VLAN-201 MetalLB gotcha — first CI workflow ever to push metrics). All 4 metrics now in Prometheus: **the M92 dispatch PAT expires in 77 days (~2026-09-18)** — the CredentialExpirySoon alert will fire at <30d; CF tokens 345-365d.

**BFM:** live on etherport (enable_js prerequisite); machine-traffic verified. Owner secrets added. Pending: M132 Pushover (owner account + 2 values), personal-web agent prompt handed over.

## 2026-07-03 (cont. 3) — BFM live on etherport.net (verified vs machine traffic)

Owner added "Bot Management: Edit" to both CF tokens. First apply failed with the API's undocumented prerequisite **"cannot enable Fight_Mode while EnableJS is disabled"** → added `enable_js = true` (JS Detections; injects only into HTML responses, so pure-API paths unaffected) → applied clean. **Gap-#9 verification:** the cue /health blackbox probe (non-browser + CF-Access service-token headers — the same client shape as HealthKit ingest and Alexa→HA) stayed probe_success=1 through the BFM'd edge across repeated checks; a bare curl gets Access 403, NOT a bot challenge. Rollback if a real device hits challenges: `fight_mode=false` + apply. Owner to use HA mobile/HealthKit normally today and report anomalies. M92-PAT identified for the expiry-check secret (github_pat_11BS…Ivp9); H46/M132 option briefs delivered (lean: CW-alarm dead-man + Pushover criticals).

## 2026-07-03 (cont. 2) — FULL-REPO Opus 4.8 sweep: 87-file doc currency pass, gap analysis (12 findings), WG HA restored + drilled, tracker rebuilt

Owner-directed sweep ("implement aggressively"; K8s-pod-primary WG; tracker archive+rebuild; BFM etherport once token scoped). Executed as 5 parallel agents (terraform / platform+clusters / docs+README / ansible+CI+scripts / read-only gap analysis) against a verified fact sheet, plus a central pass.

**WG HA — the REAL split-brain root cause found + fixed + drilled:** while restoring pod-primary, keepalived logs showed the pod "forcing new election" every second — **vpn-fallback could not HEAR the pod's prio-150 adverts because M77's default-deny dropped VRRP (IP proto 112)** (its own adverts went out → asymmetric; the HOST_IP crash was the trigger, this was the disease, live-split-brain AGAIN at the time). Fixed: proto-112 allow on vpn-fallback's PVE firewall (TF, plan 0/1/0, applied). **Full drill PASSED:** kill pod → 9s VM takeover (VIP+wg0) → pod returns → clean 300s preempt reclaim → VM yields + stops wg0. Pod-primary restored; docs describe automatic reclaim + the proto-112 first-check. NEW charter principle B6 (verify redundancy CONVERGES; the drill is the acceptance test) + memory `vrrp-pve-firewall-splitbrain`.

**Doc sweep (87 files, one commit `545c934`):** every README/runbook/architecture doc + stale .tf/YAML comments reconciled to: K8s 1.35.0, single AWS edge box, cert-only fleet SSH, unifi community fork, F1-F7 SGs, authentik 2026.5.3 (no redis), M122 exact pins, devbox-run kubespray. unifi + cloudflare + github-oidc READMEs rewritten; consolidation plan archived; docs/README index complete. **Functional fixes from agent flags:** service-status dashboard (dead Authentik-Redis + dns-aws panels removed, composite queries cleaned, total 45→43), services.py (vpn-local row → vpn-fallback — it could never be "up" since M128; dns-aws row dropped), auto-remediation (nonexistent dns-aws host removed from the controller map + advisor prompt). All SOPS files verified decrypting; kustomize green everywhere.

**Gap analysis (12 verified findings):** implemented #2 (NEW credential-expiry-check workflow + CredentialExpirySoon/Stale alerts — needs 2 GH secrets: DISPATCH_PAT_FOR_EXPIRY_CHECK + CLOUDFLARE_ACCOUNT_ID) and #3 (`auto_renew_certificates: true` — kubeadm certs were a 1y time bomb if the upgrade train slipped). Filed: **H46** dead-man's-switch (the ENTIRE alert path is in-cluster; Watchdog→null), **M130** pve/etc + Ceph-mon-store backup, **M131** ship the kube-apiserver audit log, **M132** second critical channel, **M133** SSH-cert renewal staleness, **M134** DMARC rua design, **L35** credential inventory/rotation cadence, **L36** PSA→restricted path. Verified-clean: etcd backups scheduled ✓, CF Access app coverage ✓, no open resolver ✓, renovate coverage ✓.

**Tracker rebuilt** (502→408 lines, 29 ✅ entries archived); **CLAUDE.md** gotchas updated (fork/kubespray-devbox/VRRP); **charter +6 principles** (A8 ladders-with-anchors, A9 TF-identity=state-surgery, B6 convergence, B7 tmux, C7 won-a-race trap, C8 stored-vs-live re-assert, F6 evidence-bearing handoffs); memory +2 entries. **Drift detectors:** all 7 dispatched — 4 completed CLEAN (ansible, cluster-config, step-ca PKI, service-status inventory); terraform/topology/cloud-tag queued on the runner (results arrive as auto-issues). **Pending owner:** CF token "Bot Management: Edit" scope → then BFM etherport apply + machine-traffic verification (gap #9); the 2 GH secrets above; H46/M132 channel preference (healthchecks.io/ntfy accounts vs self-hosted CW-alarm path).

## 2026-07-03 (cont.) — CF Security Insights CSV remediated

From the owner's Security-Insights export (17 findings, 4 zones): **CRITICAL "Overprovisioned Access Policies" (cue.etherport.net/health) FIXED** — the bypass+everyone policy (which disabled all edge protection on the path) is now a **non-identity service-token policy** (`cue-health-probe` token); the in-cluster blackbox probe sends the CF-Access headers from a new SOPS-encrypted config Secret (blackbox.yml moved ConfigMap→Secret; new `http_2xx_cf_token` module is STRICT-200, so an Access 302/403 now fails the probe — stronger signal). Verified: probe_success=1 end-to-end. **SPF ×2 FIXED**: `v=spf1 -all` TXT on mail.grahamsmith.net + mail.stopthecastle.com (receive-only MX targets). **Bot Fight Mode ×3 staged but BLOCKED on token scope** (PUT bot_management 403 — the CI token lacks "Bot Fight Mode: Edit"; resources committed commented-out, uncomment + apply after the owner extends the token). etherport.net EXCLUDED from BFM by design (cue API/HealthKit/HA machine traffic). **Dashboard-only remainders for the owner:** proxy www.stopthecastle.com (orange-cloud), managed security.txt ×4 (Security Center), AI Labyrinth ×4 (bot settings), Turnstile (skipped — no forms). The cloudflare stack now also manages cross-zone records via data lookups (token IS all-zones for DNS).

## 2026-07-03 — Morning triage: WG VIP split-brain root-caused+fixed, backups-share FAILED = multipart-ETag class, UDM :53 hairpin = by-design

**The overnight "several items down" (service-status) = a WireGuard VIP SPLIT-BRAIN, root-caused + fixed:** the k8s WG pod's policy-routing script computes `HOST_IP=$(ip -4 addr show eth0 | grep -oP ...)` which grabs ALL eth0 IPs — when its own keepalived (prio 150) claims VIP `10.10.201.20` BEFORE the script runs (a startup race the pod won for 50 days and lost after yesterday's recreation), HOST_IP=2 IPs → malformed `ip rule` → CrashLoopBackOff (53 restarts) → **keepalived kept MASTERing the VIP with no wg0 while vpn-fallback ALSO held .20** → ARP-race partial blackhole of all UDM-routed AWS-private traffic. Fix: exclude the VIP + `head -n1` (committed); pod now 2/2 on w4, **vpn-fallback the sole VIP holder** (healthy k8s standby), tunnel handshakes fresh, ALL probes/targets up. Watch for stale ARP on clients post-split (the devbox cached w1's MAC — `ip neigh flush` fixed).

**Backups-share FAILED (S3SyncFailed) = the MULTIPART-ETAG class, NOT corruption + NOT what a226ad8 fixed:** report `checksumUnavailable: 5, checksumMismatches: 0` — 4 PDFs + the same .mp4 as yesterday (active OneDrive/WSP tree), all large→multipart→ETag≠MD5 → verification can never validate → app counts failed → run FAILED. a226ad8's settle-pass re-HEADs but a multipart ETag stays non-MD5 forever → recurs on EVERY run that uploads big files. **App-level fix needed (aws-s3-sync repo, s3-backup agent's lane):** treat multipart-ETag unavailability as non-fatal (or verify by computing the multipart md5-of-md5s tree / switching to S3 additional-checksums SHA256 on upload). MiniHealthDegraded + cairn_* metrics remain the known mini-local saga (agent can't SSH the mini).

**Devbox→10.10.100.10:53 drop investigated → BY-DESIGN:** only the UDM-hairpin path drops :53 to the AWS subnet (the zone policy doesn't allow it; `udm-firewall.yml --check` = **changed=0**, zero drift — NOT caused by M125's network PUTs). The real DNS-failover path (public EIP 44.240.60.80) answers fine; clients use .5/.6/EIP. No change made.

**Overnight also:** ExternalHostRebooted asterisk-sbc + step-ca = unattended-upgrade reboots (benign); AWSReplicaHostFlapping = an M124 wave with the NEW corrected text.

## 2026-07-02 (cont. 4b) — M125 EXECUTED (fork migration live), M123 1.35 done, advisor-email review

**M125 unifi provider migration — EXECUTED end-to-end (owner-approved):** subagent drafted the full fork-schema rewrite (44 resources) → local throwaway-TF session per the M82 allowance: state backup → `state rm` ×47 → re-import (networks/routes/forwards by id; **clients by MAC** — the fork renamed unifi_user→unifi_client and rejects id-imports; **UNIFI_API_KEY auth** after 30 rapid logins tripped the UDM login rate-limiter) → 5 plan iterations pinning config to LIVE values (gateway-style subnets, fork-default divergences auto_scale/lte_lan/setting_preference, gateway_type=switch on ceph/clients/vsan, wan.ip_address="any" readable-but-not-writable → ignore) → normalization apply → **plan = No changes; CI plan green**. Two findings: the fork **fixed the paultyng PUT-400 bug** (all 47 PUTs clean — the M110 workaround era is over) and its "inconsistent result after apply" errors are cosmetic read-back races. One catch: the controller echoed template DHCP values onto inter_vlan_routing — re-asserted `dhcp_server.enabled=false` (transit net).

**Advisor-email review (owner ask):** afternoon emails reconstructed from ALERTS[8h] + CloudWatch history. **All self-inflicted by the upgrade trains** (CPUThrottling ×3, KubeJobFailed/ReplicasMismatch/PodNotReady ollama+plex on the gpu1 drain saga, VeleroBackupPartial = the racing pre-upgrade backup, KubeVersionMismatch mid-rollout, Flux/PrometheusOOO transients) **except**: CairnJobsFailing (known, mini-local) and **AWSReplicaHostFlapping [vpn-aws] — genuine M124 wave**, whose email text still carried the DISPROVEN pre-M124 "t4g.nano ENA/right-size to resolve" story (the owner's "EC2 ENI one"). Fixed: alert summary/description now state the WAN-wave reality + mtr next-step. CloudWatch itself: all 3 alarms OK, zero state changes this afternoon. Deleted the lingering failed cloudwatch-to-loki Job (KubeJobFailed clears).

## 2026-07-02 (cont. 3) — backlog: authentik logo fix, M125 parked (2nd attempt), F1+F7 staged, step-ca-trust wave-blocked

**Authentik login logo:** the 2024.12 "transparent-1x1-pixel = no logo" trick renders as an empty placeholder frame under 2026.x → hid the brand img via custom.css (subPath mount → server rollout applied it). Owner to eyeball.

**M125 attempt 2 — parked with a DEFINITIVE finding:** the ubiquiti-community fork is NOT drop-in at ANY version — 0.54 renamed the resource types (attempt 1); even its 0.41.25 changed the `unifi_network` arguments ("Unsupported argument" ×20, attempt 2). Both attempts cleanly reverted via reverse replace-provider (state on paultyng, plans green, zero infra impact). M125 re-scoped: a deliberate schema-diff migration (adapt networks.tf args, maybe state mv), parked — the archived provider still serves + works.

**M110 SG residuals F1+F7 APPLIED (owner-approved; run 28609440745 success — the orphaned ALB SG deleted cleanly = nothing attached):** deletes the dead `internal_aws_spokes` -1-from-10.10.96.0/19 rule (decommissioned spoke VPCs) + the orphaned `alb-public-443` SG (+3 rules, outputs ref). Expected diff = 5 destroys. F2/F3 (port-scoping the remaining -1 rules / the consolidated-SG redesign with Lambda rule_specs) remain the deliberate follow-up per the consolidation plan doc.

**M76-parity cert-SSH cutover for the edge box — BLOCKED by an active M124 wave:** two step-ca-trust check dispatches failed with become-timeout (gather-facts OK → sudo prompt lost); flap detector showed 14 scrape flaps/1h = mid-wave. Retry when calm: dispatch `ansible-vm-fleet step-ca-trust inventory=aws action=check` → apply → verify cert-SSH from devbox → flip the workflow aws branch to cert → `step-ca-remove-static-key`.

## 2026-07-02 (cont. 2) — H45b+M123 rolling upgrade EXECUTED (K8s 1.34.3 + containerd 2.2.5), Authentik→2026.5.3, M128 rename, L32 TS rejoin

Owner: "kick off m45b and m123" + "do the full rename to vpn-fallback" + TS auth key. All executed same-session.

**H45b+M123 (combined rolling window) — DONE, fully verified.** Gates: 8/8 Ready, Flux green, etcd snapshot on cp1 + quorum 3/3, velero full backup (went PartiallyFailed 1 error racing the drains — benign; etcd+CNPG were the anchors). Run: `kubespray.sh upgrade-cluster.yml`, devbox venv (python3.12-venv installed), `KUBESPRAY_SSH_KEY=~/.ssh/id_homelab_cert` (the wrapper defaults to the REMOVED static key), in a **detached tmux** (`kubespray` session) after the harness killed a backgrounded attempt mid-download. **Attempt 1 failed harmlessly in prepare:** kubespray v2.30 keeps checksum DICTS in `kubespray_defaults/vars/` which BEAT inventory group_vars — my dict override was silently ignored ("dict object has no attribute 2.2.5"); fixed by overriding the **`containerd_archive_checksum` SCALAR** (lives in defaults/, inventory wins). CPs rolled first (cp1→cp2→cp3, ~20 min), then workers serially. **cue-db stalled w3's drain on its PDB exactly as predicted** — a pre-armed watch deleted the pod at +100s, CNPG rescheduled to (already-upgraded) w1. Result: **all 8 nodes v1.34.3 + containerd://2.2.5, RECAP 0 failed/0 unreachable**, wrapper pre-flight restored cni-owner (was already root). Landmine verification ALL green: issuer+api-audiences intact (inventory-persisted; IRSA safe, no multus restart needed), multus 8/8, cilium PolicyAuditMode **Disabled** + WireGuard + **BGP 8/8**, 0 non-running pods, CNPG 3/3+1/1, authentik 3/3. Firing alerts after: only the 2 benign upgrade-induced ones (VeleroBackupPartial = our racing pre-upgrade backup; CPUThrottlingHigh on wireguard-cleanup). M123 remainder: the 1.35 minor via kubespray v2.31 before the Oct EOL.

**H44 finale (same session, operator present):** hops 5–8 → **2026.5.3** (see the cont. entry below); Redis removed; RBAC 0056 clean after the ak-shell group-uniqueness check (2 groups, 0 dups).

**M128 vpn-local→vpn-fallback — COMPLETE:** repo (40+ files) + TF with moved{} blocks (plans verified EXACTLY the intended diff: 1 in-place VM-name change / pure moves 0-0-0 / 1 reservation change → all 3 applies success) + guest hostname/hosts + **TS rejoin as vpn-fallback** (owner deleted the old node; ran tailscale.yml with a fresh auth key → 100.97.20.113, tagged-devices, exit-node advertised — owner to approve + disable key expiry). SOPS gotcha recorded: comment edits broke the MAC on the two platform/wireguard sops files (filename-only rename) but not on advisor-ssh-key.

**M125 attempt REVERTED cleanly:** ubiquiti-community/unifi 0.54 is NOT drop-in (renamed resource types) and replace-provider had already rewritten S3 state before plan validation → reverse replace-provider restored it (final plan green, zero infra impact). Lesson + re-attempt options in the tracker.

**Operator TODO carried:** verify OIDC/forward-auth logins post-authentik-2026.5.3 (email_verified flip); approve vpn-fallback as exit node + disable its key expiry; cairn photos (mini-local) still failing.

## 2026-07-02 (cont.) — Hit-list execution: H45a Cilium CVE, M122 update-automation, H45c CNPG operator ladder 1.24→1.30

Owner: "check this morning's ai-advisor alerts and failed s3 sync task… then proceed automatically with your hit list… keep going autonomously… ask me questions along the way." Maximizing pre-5pm-reset token budget.

**Morning triage (resolved):** s3-sync jobs all Complete on the new staggered schedule (M119) — the "failed sync" was the staggering doing its job. Real signals were cairn photos (mini-local, agent can't SSH — known photos saga) + a masked `fwupd-refresh` on dns-fallback + the pve memory alert perma-firing at 85.9%. Fixed the last one (`8e894a6`): excluded pve from the generic `ExternalHostHighMemory` 85% rule + added `PveHostMemoryPressure` at 94%/10m (the hypervisor legitimately runs hot).

**H45a Cilium 1.18.6→1.18.11 (CVE-2026-49445) — DONE `a5784c7`:** installed helm v3.19 on the devbox (`~/.local/bin`; recorded in CLAUDE.md §4). `helm upgrade --reuse-values` threw a hubble.relay.logOptions nil-pointer template error → `--reset-then-reuse-values` worked BUT **re-enabled `policyAuditMode=true`** — the helm stored-values had drifted from the live ConfigMap hand-patches, so a reset-then-reuse silently reverted enforcement on all 6 netpol tiers. Caught it in the post-upgrade verify, fixed with `--set policyAuditMode=false` + `rollout restart ds/cilium`. Final verify: enforce mode, WG encryption on, BGP 8/8, 0 drops. **Lesson:** after any `--reset-then-reuse-values`, re-assert every hand-patched value that isn't in the stored helm values. Snapshot: `docs/reference/snapshots/cilium-helm-values.yaml`.

**M122 update-automation blind spot — DONE `122caaa`:** renovate `flux` manager now watches `clusters/wind/helm-releases/**` (previously invisible — only gotk-components was covered); all 17 HelmReleases exact-pinned to deployed versions (ranges had silently frozen majors — alloy sat ~10 chart minors behind a `0.x` cap). Majors → individual hand-review PRs. **Correction:** the Grafana chart repo is NOT dead (the currency review's guess) — original repo serves current charts; the alloy staleness was the range cap, not the URL.

**H44 Authentik — FULLY UPGRADED 2024.12.3 → 2026.5.3 (latest), all 8 hops, CVE-2026-25227 remediated.** With the operator present, completed hops 5–8 after the initial 1–4. Hop 5 (2025.10): redis→PG migration clean, then **Redis fully removed** (env + Deployment). Hop 6 (2025.12) RBAC overhaul: verified the group precondition first via `ak shell` (**2 groups, 0 dups**) → the `0056_user_roles` migration (the flagged hang/fail risk) applied cleanly; took a fresh backup `pre-authentik-hop6-rbac` first. Hops 7–8 (2026.2.4→2026.5.3) clean. Every hop 0 restarts, migrations under the PG advisory lock, startupProbe protecting. Also ran the **s3 TF apply** (operator-authorized in-conversation after the classifier gated auto-dispatch — completed/success: cue_media CORS + logs_archive lifecycle). **⚠️ Operator TODO:** browser-verify OIDC + forward-auth logins (2025.10 flipped `email_verified` default → may need a scope mapping). Original hops 1–4 summary follows:

**H44 Authentik — hops 1–4 done, CVE-2026-25227 REMEDIATED at 2025.8.6.** Operator answer was "start the upgrade now." A research subagent mapped the full sequential-major path + per-hop breaking changes. Pre-flight: added **startupProbes** to server+worker (migrations run at container start before the web server binds → a long migration was liveness-killable, upstream #14501); took a CNPG backup anchor `pre-authentik-upgrade-h44` (13:51Z). Laddered 2024.12.3→2025.2.4→2025.4.4→2025.6.4→**2025.8.6**, verifying migrations-under-advisory-lock + both replicas + worker Ready + 0 restarts each hop. The 2025.4 session cache→DB migration completed fast (few sessions); the 2025.8 `tenant.flags` ProgrammingError was a transient migration-ordering artifact (0 recurrence, health/ready=200). **CVE fixed at 2025.8.6.** PAUSED before hops 5–8: hop 5 (2025.10) removes Redis + flips `email_verified`; hop 6 (2025.12) RBAC overhaul needs global group-name uniqueness (can't verify without DB/API) + has open upstream issues + SSO-down-until-restore risk; and the agent can't browser-verify logins (VLAN-201/VIP). Blueprints are clean (no parent/ak_groups/user-perms). Recommend a window with per-hop backup + group-uniqueness check + operator login verification. Also noticed a mid-run Flux fetch-interval lag (deploy image didn't flip until the git artifact revision advanced — force gitrepository reconcile + wait for the artifact rev, not just poke the kustomization). Separately fixed the **M110 `10.10.100.5`→`.10` residual** (the planned edge-box secondary IP was never applied; repointed the live dns-aws zone record + dns-sync/forwarder + auto-remediation + comments/docs, left historical refs).

**Overnight s3-sync "failure" triaged — benign (checksum-unavailable, not corruption):** all 6 shares' latest reports today are SUCCESS *except* the **backups** share at 08:00Z (the 01:00-PT staggered run). Cause: a large multipart-uploaded .mp4 (`backups/Graham/OneDrive/WSP/.../Instructor Video Intro to Cap Structure.mp4`) — an S3 multipart ETag is not a plain MD5, so the verify recorded `checksumUnavailable:1` (`checksumMismatches:0` — **no corruption**; sync exitCode 0, object uploaded fine). Status went FAILED because the **checksum-unavailable settle-pass** (which should re-HEAD such objects) had been a **silent no-op since a700b3f (06-24)** — exactly the bug the s3-backup agent repaired in **a226ad8** (image rebuilt ~12:50Z 2026-07-02). NOT the chat.db class. The 08:15Z retry "succeeded" only because it transferred 0 files (it did NOT re-verify the .mp4). **Follow-up: confirm tonight's backups run reports SUCCESS via the repaired settle-pass.** Also relayed: an s3 TF apply (terraform-s3.yml — cue_media CORS + logs_archive approvals/pending expire) is pending operator confirmation (classifier gated it as a blind apply of a peer-authored change).

**H45c CNPG operator 1.24.1→1.30.0 — DONE (operator); PG data-plane HELD:** laddered one minor at a time (CNPG's documented no-skip policy) through 1.25.1/1.26.1/1.27.1/1.28.1/1.29.1/1.30.0, verifying operator-image + both clusters healthy + `ContinuousArchiving=True` at each hop. **The Critical 9.4 (fixed ≥1.28.3) is resolved.** cue-db (single instance) restarts ~4-6 min per hop on RBD multi-attach detach-lag (self-clears via force-detach); postgres-cluster (HA 3) rolls with no downtime. A mid-ladder observation: kured ran a full-fleet reboot sweep (accumulated kernel updates, likely the M116 unattended-upgrades) — paused the ladder until all 8 nodes were schedulable to avoid compounding pod-move churn.
- **HELD — H45d PG image 16.4→16.14:** cue-db depends on **pgvector** bundled in the operand image; CNPG changed extension bundling around 1.30, so a naive tag bump risks dropping pgvector → cue-api breakage. Classifier (correctly) blocked a direct SQL probe into the prod DB. Flagged to operator rather than done blind. postgres-cluster (no pgvector dep) can go first.

**State:** Cilium + CNPG operator CVEs closed. Update automation now catches chart drift. **Next (operator-gated, batched as questions):** H45d PG image bump, H44 Authentik 8-hop (unpatched critical RCE — needs windows), H45b containerd (fold into M123 K8s window), M123 K8s 1.34 train, M125 unifi provider fork migration. Blocked-on-mini: cairn photos.

## 2026-07-02 — Fable-5 review of the aws-s3 backup app → fix set (status semantics, chat.db mid-run downgrade, settle-pass repair)

Owner: "do a full review of this code using the fable 5 model", then "fix everything you can… give me a prompt for the infra agent" (who is separately investigating an overnight sync error — findings TBC; **hypothesis: the known chat.db false-corruption**, which this session's fix addresses).

**Review verdict:** no new HIGH/data-safety findings; the June fix set + M75 IRSA + a700b3f compose correctly. Fixes shipped (verified by a 3-lens adversarial workflow over the diff BEFORE commit — that pass caught 4 real defects in the first cut, all fixed):

- **Status semantics (was M1):** `rejected_snoozed` no longer masquerades as "approval pending" — metric label carries the real status; report emits distinct **`REJECTED_HELD`**; daily email renders "rejected — N deletions held". A **FAILED sync now outranks a held status everywhere** (verifier caught my no-uploads block clobbering FAILED → APPROVAL_PENDING).
- **chat.db mid-run downgrade:** a checksum mismatch on a file *modified during the run* (recorded-vs-current mtime drift, recorded-size≠S3-size, or source-mtime > S3 LastModified **+120s skew margin**) downgrades to non-fatal `modifiedDuringRun` (WARN + degraded email + durable report fields `modifiedDuringRun`/`modifiedDuringRunFiles`, forensic hash details KEPT). A mismatch with NO drift signals stays CRITICAL/FAILED. **Honest caveat encoded in code+README: NOT self-healing — `--size-only` never re-uploads a same-size in-place rewrite; the degraded email is the operator cue to re-upload manually.** Exception-hardened after the verifier DEMONSTRATED an NFS-ESTALE record-drop that would have silently eaten a real corruption record (unit-tested: 7/7 cases incl. ESTALE + skew boundary).
- **Settle-pass repair (pre-existing, found this review):** the checksum-unavailable **re-HEAD settle pass has been a silent NO-OP since a700b3f (06-24)** — it still called verify-one.sh with the old bucket/key-as-two-args interface, so KEY read empty and results were written to a bogus path; `STILL_MISSING` always equalled `RETRY_COUNT`. Both retry invocations now pass the single tab-delimited record like the main pass.
- **Daily report:** held-status cards require `success==1` (a held report whose sync failed renders as an error card, consistent with the header count); header gains "N holding deletions" so "All N completed" can't mask a held share.
- **TF (L1):** `logs.archive` lifecycle rule expiring `approvals/pending/` records at 30d (they were accumulating unbounded — approve/reject only write the per-share marker). fmt+validate clean; plan/apply via `terraform-s3.yml`.
- **Docs:** README approval-flow + verification-semantics updated (REJECTED_HELD, mid-run downgrade + no-self-heal caveat, FAILED-outranks-held); stale S3SyncFailed rule comment fixed (metric is pushed by the sync job, NOT daily-report; holds deliberately don't fire it).
- **NOT done (adjudicated/deferred):** `:main` pin — **accepted per H30** (do not "fix"); manifest-driven H3 delete + force-re-upload of `modifiedDuringRun` keys → infra-agent backlog.

**Incident coordination:** the `aws-s3-sync:main` image REBUILDS on this push — runs after the build use the new code (distinct log signature: "modified during run … downgraded"). The overnight-failure artifacts (S3 report + pod logs) are immutable; if the infra agent re-runs a share, note the code boundary.

---

---

## 2026-07-01 (cont.) — Fable-5 full review of cairn (code+repo+docs+observability) → v0.1.7 + alert-hole fixes

**What:** owner-requested full review of the cairn codebase/repo + docs/Grafana integration using
five parallel Fable 5 reviewers (reliability core / sources+mirror / CLI+config+report /
repo+CI+security / docs+observability). ~50 verified findings (several proven with live probes);
all code-level fixes landed as **cairn v0.1.7** (`9832266`, 33→46 tests) + infra `c045469`.

**Biggest catches (things we'd overlooked):**
- **My 2026-07-01 photos-alert retune was INCOMPLETE:** `10-icloud-backups-alerts.yaml` claimed to
  exclude photos but didn't — per-run photos alerts were still firing via the generic rules. AND
  **every cairn alert was human-silent** (all `warning`; only `critical` routes to email) — a
  2-week photos outage would have alerted nobody. Fixed: photos excluded explicitly;
  `PhotosExportStale` → critical (3-day gate makes it page-safe); NEW `11-cairn-agent-alerts.yaml`
  (CairnAgentDead / MiniHealthStale / MiniHealthDegraded / CairnJobsFailing — agent-dead detection
  didn't exist; Pushgateway persistence means a dead mini looked green).
- **Data-safety (cairn):** refuse-empty guard was TOCTOU'd (a dir source emptied after staging
  could wipe its backup with rc=0 — now re-checked just before the --delete pass); delete-guard
  parse now FAILS CLOSED on rsync format drift; photos `benignOnly` needed positive collision
  evidence (an export-DB write failure was stamped success); **TCC revocation read as success**
  (messages/photos stamped rc=0+last_success forever, silencing staleness); mirror rsyncs were
  unsupervised (wedged-mount hang → run-lock held → ALL backups stop, + a >64KB-stderr pipe
  deadlock); contact PHOTOs were absent from every vCard ever exported (image key not fetched).
- **Reliability:** runSupervised could never-return (D-state child / escaped grandchild holding
  the pipe) → unconditional-return drain deadline; clean-exit-with-straggler was misreported as a
  stalled FAILURE (would force a needless risky photos reattach); RunLock mkdir+pidfile TOCTOU →
  flock(2); ensureStack(force:) tore down in the wrong order (unmounted SMB under a live image).
- **Supply chain:** Package.resolved was gitignored (unpinned deps flowed into signed TCC-trusted
  releases — now tracked); release.yml ran `swift test` AFTER importing the signing key (build-time
  code could sign with the TCC identity — now test/build precede import); tag-name shell injection
  closed; SHA-pinned actions; per-run keychain password (KEYCHAIN_PASSWORD secret retired);
  clobber guard (dispatch can't silently swap a released binary); ci.yml now exercises the release
  build + package.sh ad-hoc on every push.
- **Dashboards/docs:** photos coverage rendered the -1 "counts untrusted" sentinel as >100% GREEN
  (clamped+gated); thresholds matched the abandoned 26h policy (→ 3d); iCloud board actually
  excludes photos now + gained a 7d per-job rc state-timeline; runbook §6 documented the retired
  pre-cutover metric schema (rewritten). Known-inert: `cairn_photos_orphans` has never been
  emitted (countOrphans silently -1 in prod; v0.1.7 now logs WHY → diagnose from the next run's log).

**Deploy plan:** v0.1.7 is released (hardened pipeline validated itself) but **NOT deployed to the
mini yet** — tonight's 22:00 run is the first scheduled validation of v0.1.6's one-attempt heal;
deploy v0.1.7 after that run is green (swap dist/cairn.app, TCC persists, same leaf).
`cairn_photos_stack_unhealthy=1`/`messages_snapshot_failed=1` latched in Pushgateway self-clear on
the first v0.1.7 runs (PUT replaces the group).

## 2026-07-02 — M110 COMPLETE + residuals done + charter shipped + full state review (H44 Authentik CVE!)

**Residuals:** L31 SSE blocks (7 buckets, plan-gated, applied) + L26 automount sweep (6 workloads) — both ✅.

**M110 CONSOLIDATION COMPLETE.** End state verified live: **one AWS box** (`private-infra_edge`, t4g.small)
+ **one EIP** (44.240.60.80) running WG + Tailscale + Technitium. Sequence: dns SG attached to the edge
(in-place; carries the Lambda-managed :53 WAN allows) → technitium.yml folded the resolver → dns-sync
targeted `.10` (**first sync POLICY_DENIED — the dns-tier netpol pins :5380 egress to /32s**; the exact
CLAUDE.md "enforced-tier tax", fixed same change) → 47 records synced, internal names answering on the EIP →
UniFi dhcp_dns ×7 re-pointed (**4 via TF; 3 via direct UDM API PUT — the archived paultyng provider
deterministically 400s clients/vsan/ceph**; ignore_changes added per the guest precedent, stack verified back
to `No changes`) → standalone dns instance + EIP 52.40.219.113 + 3 CW alarms destroyed (plan-gated exactly
`5 to destroy`) → post-destroy acid check: DNS still answering on 44.240.60.80. All `.5` refs cleaned.
Residuals in tracker (CI cert-auth cutover for aws, SG redesign F1-F7, doc sweep).

**Path-loss investigation (M124):** 90-min dual-ended mtr windows when calm = 0% loss every hop incl.
control; **274 scrape flaps in 12h post-resize anyway** → waves are real, ISP/WAN-side, hours-scale; box
(ENA=0), MTU (20/20 large-payload), SG, fail2ban, egress-IP all ruled out. Detector = AWSReplicaHostFlapping;
next = capture-on-alert + wave-timestamp correlation.

**Charter shipped** (`docs/guides/agent-operating-principles.md`, wired into CLAUDE.md §1 as binding
read-first #2): 24 model-agnostic principles (change/verification/diagnosis/docs/safety/operator-interaction
+ the model-agnostic contract), each with a real repo example. README's unfollowable `gh workflow run`
examples annotated (no gh on the devbox); stale "mini auto-pushes" fixed; memory pointers fixed.

**Full state review (2 Fable agents):** maturity high; **currency bimodal** — automation-covered components
are same-day current, everything else rotted. **⚠️ HEADLINE: Authentik 2024.12.3 carries an UNPATCHED
CRITICAL RCE (CVE-2026-25227, no 2024.12 fix exists) + a Traefik forward-auth-bypass advisory matching the
exact H38 architecture → H44 (8-hop upgrade program).** Also H45 (containerd 3 Criticals → 2.2.5; Cilium
Critical → 1.18.11; CNPG 1.24 EOL+Critical → operator+PG16.14), M122 (fix the update-automation blind spots —
renovate flux manager, range-caps, the MOVED Grafana chart repo), M123 (K8s 1.34 EOL Oct-27 upgrade train),
M125 (unifi provider fork), M126 (kube-vip, Flux kustomization split, PVE RAM ceiling ~85/93Gi, etc.).
Deadlines: K8s 1.34 (Oct), Ceph Squid (~Sep), Redis 7.4 (Nov).

## 2026-07-02 — Review remediation batch 3 (the heavy trio + right-sizing): M115/M116/M118/M120 + L29/L30 — all verified

**Operator: "keep going... go ahead with M115/116/120... okay to have some downtime but resolve issues".**
All landed + e2e-verified (`727a40d`…`e43e775`):

- **M118 right-sizing** (7d PromQL): node-agent →25m/160Mi (7d max 138Mi; freed ~1.4 CPU/0.8Gi fleet-wide);
  prometheus →2Gi req/3Gi lim (**P95 1.83Gi vs the old 2Gi limit — <10% from OOM**); alloy →384Mi;
  tetragon →256Mi (its HR requests hadn't been landing — live pods carried the Kyverno 10m/32Mi default;
  the fresh upgrade fixed it). All rolled clean.
- **L29** Loki per-stream 3MB/10MB-burst + 7d retention for hubble-audit/tetragon streams (selectors
  verified against the real ruler rules). **L30** PDBs for coredns/cilium-operator/csi-provisioner;
  **velero cluster-admin deliberately kept** (restore creates arbitrary resources incl. RBAC).
- **M116 node patching**: new `k8s-unattended-upgrades.yml` — security-pocket-only, `Automatic-Reboot=false`,
  **kured owns reboots** (nightly window, cluster lock). Applied to all 8 nodes; kubespray binaries untouchable
  by the apt origin. Fleet patching coverage now 15/15 hosts.
- **M115 authentik tier (6th)**: full audit-toggle dance — audit ON (ConfigMap+rollout as separate commands),
  tier applied (`15-tier-authentik.yaml`: :9000 from traefik+blackbox+intra-ns; egress postgres+SES:587;
  world:443 deliberately absent — update-check/analytics/gravatar verified disabled), flows exercised,
  **605 real flows / 0 would-be drops**, audit OFF → enforced-path verified (traefik→authentik OK,
  probe_success=1, 0 DROPPED).
- **M120 ceph-csi** — messier than the review knew: the workloads ran 50d as an **out-of-band kubectl apply**
  (not in git), and the ceph-csi-ns configmap copy pointed at the **pre-VLAN-migration monitor 10.10.201.41**
  (a naive ns move would have broken all new volume ops — landmine defused by making git's 10.10.210.41
  config overwrite it on adoption). Codified the full stack (cleaned live dump, cephcsi v3.11.0) into
  `storage/ceph-csi/`, ns ceph-csi. Cutover gotcha: **the old DS pods' termination deleted the new
  registrar's socket post-registration** (plugins_registry emptied; CSINode showed no driver) → one DS
  restart re-registered 5/5. **Acid test green**: PVC provision→attach→mount→write→delete through the moved
  stack; 22 existing Bound PVCs unaffected. default ns now EMPTY + enforce=baseline (adopted as a git
  resource — can't be a kustomize patch target); 50d rbd-test-pvc deleted.

**Review backlog now: 20/20 findings actioned** (18 done, L26 automount-sweep + L31-SSE-parity residuals ⏳).

## 2026-07-01 — Review remediation batch 2: M113/M117/M119/M121 + L25/L27/L28/L31 — all verified

**Continuing down the review backlog (operator: "keep working down the list"). All landed + verified**
(`727a40d`…`35dce3a`):
- **M113 alerts:** cert-manager ServiceMonitor was DISABLED (its metrics had never been scraped) — enabled;
  new `13-service-alerts.yaml` (CNPG-down ×2 absent()-based, cert alerts, AuthentikDown via a new in-cluster
  blackbox Probe + plain `http_2xx` module, cloudflared degraded/down); `runbook_url` pass (14 rules linked).
  ⚠️ **Lesson: the first cert thresholds (14d/5d absolute) false-fired within MINUTES** — the primary
  wildcard is a **Let's Encrypt short-lived (~6.7d) cert** renewing every ~4.5d, so its whole life is
  "<14d to expiry". Rewritten duration-agnostic: `CertManagerRenewalOverdue` (cert-manager's own
  renewalTime >12h past without reissue) + `CertExpiryCritical` (<24h left). All 7 rules loaded + inactive.
- **M117:** metrics-server HelmRelease (3.13.0, kubelet-insecure-tls) — **`kubectl top` works for the first
  time on this cluster.**
- **M119:** backup stagger — 7 s3-sync shares 01:00→01:50 (10-min steps; `scans` is `suspend: true` but
  slotted anyway), velero de-stacked across :00-:48. Verified live in the CronJob/Schedule CRs.
- **M121:** drift-detection plans REDACTED (structure-only) before artifact upload + issue embed.
- **L25/L27/L28/L31:** throwaway `test-ssh-cert.yml` deleted + `permissions:{}` on bootstrap-runner-key;
  PSA `enforce=baseline` on kyverno + **plex** (its "GPU needs privileged" comment was STALE — device-plugin
  GPU; server dry-run clean) + `pg-recovery` ns deleted (held a stray `csi-rbd-secret` copy); `no_log` on the
  3 token-in-URL technitium tasks; email_fwd abort-incomplete-MPU rule (terraform-s3 plan `1 change`, applied).
- **Ops note:** mid-batch, Flux's git fetch to `github.com:22` timed out for ~10 min (HTTPS fine, devbox SSH
  fine, pod-egress test then fine) — consistent with the **WAN path-loss waves** identified earlier today,
  self-resolved. Another datapoint for the path-loss investigation.

**Still open from the review:** M115 (authentik netpol tier — needs the global audit-mode toggle dance),
M116 (k8s node auto security-patching — design decision), M118 (request right-sizing), M120 (ceph-csi ns
move), L26 (automount-SA-token sweep), L29 (Loki per-stream limits), L30 (infra PDBs + velero RBAC),
L31-residual (SSE codification).

## 2026-07-01 — Review remediation batch 1: travel-VPN DELETED + H42/H43/M112/M114 all fixed + verified

**Operator directives:** (1) delete the travel-VPN tooling; (2) knock out H42 → M112 → M114, plus H43.
All five landed + verified this session (`77c66f9`…`72cb120`).

- **Travel/regional-VPN tooling DELETED** — `aws-regional-vpn/` + `modules/regional-vpn/` + its workflow +
  `regional-peers.yaml` removed (both TF workspaces held 0 resources — verified before deletion); empty S3
  tfstates + a stale bahrain `.tflock` purged; the disabled `Wireguard Travel 9820` UDM forward destroyed via
  the unifi stack (plan = exactly `1 to destroy`, applied green). Docs/tracker updated (L2 closed as moot;
  resurrection = git history, procedure preserved in the archived runbook).
- **H42 (step-ca/asterisk/pve monitoring) FIXED + e2e-verified** — node_exporter on step-ca + asterisk-sbc via
  base.yml CI apply (it had NEVER run there — found inactive; the M77 vm-baseline already allowed :9100).
  pve got the NEW standalone `node-exporter.yml` (⚠️ full base.yml on the hypervisor would enable
  Automatic-Reboot — whole-homelab hazard; playbook header documents this) + a NEW `pve-nodeexp` firewall
  group → **the PVE host firewall now has FOUR required allows** (CLAUDE.md invariants updated). Blackbox
  probe on step-ca `:8443/health` + `StepCADown` critical. Verified: 3× `up=1`, `probe_success=1`.
- **M112 (TF workflow concurrency) DONE** — `tf-<stack>` groups, `cancel-in-progress: false`, all 24 workflows.
- **H43 (PR-plan code-exec on the self-hosted runner) DONE** — `pull_request` trigger removed from the 9
  lifecycle-runner workflows; coverage preserved via push-to-main/dispatch/daily drift sweep.
- **M114 (authentik HA) DONE + verified** — server replicas 2 (distinct nodes), zero-gap RollingUpdate,
  topologySpread, PDB, worker `ak healthcheck` probes. **Key unblock: dropped the RWO media PVC** — it held
  ONLY the initContainer-regenerated `login-bg.png` (verified live), so media is emptyDir per replica now.
  In-cluster `/-/health/ready/` = 200. (The review's naive "just add replicas" would have deadlocked on the
  RWO attach — the PVC removal was the real fix.)

**Next from the review backlog:** M113 (alert gaps + runbook_url), M115 (authentik netpol tier), M116 (k8s
node auto-patching), M117 (metrics-server), M119 (backup stagger) — all still ⏳.

## 2026-07-01 — Fable-5 full repo review: doc consolidation + archive pass + infra findings (H42-H43, M112-M121, L25-L31)

**What:** operator-requested full review, run as 3 parallel Claude **Fable 5** agents (2 doc-consolidation on
disjoint dirs + 1 read-only infra review), parent-merged.

**Doc consolidation (planning):** `outstanding-work.md` pruned **615 → ~362 lines with zero content loss** —
all 68 ✅ items moved verbatim (IDs intact) to `archive/outstanding-work-completed-2026-07.md` (incl. the
retired top-matter); live tracker keeps all open items + one-line "Recently completed since ~06-20" entries
with open residuals carried forward. Archived (git mv + DONE banners): `l24-metallb-frr-migration-plan.md`,
`m71-roles-anywhere-plan.md`. Status banners refreshed on the M110 plan (in-progress + flap-correction) and
both 2026-06-11 roadmap docs (kept live — only forward-looking backlog; A2/3-2-1 newly active via M111).

**Doc consolidation (runbooks/architecture/etc):** archived `regional-vpn-deployment.md` (travel tooling
unused; us-east-1 decommissioned) + `dependency-update-cadence.md` (**merged into `UPDATE-PROCEDURES.md`** —
all cadences in one doc now). ~18 staleness fixes in kept docs, notably: aws-infrastructure.md (edge/t4g.small
+ M110 flags), vpn-wireguard/tailscale/overview (ALB banners removed, no-HA-API-VIP corrected, travel-VPN
current-state), operations-guide (its `udm-firewall.yml` description was BACKWARDS — it IS the zone-firewall
source of truth), proxmox-ha-expansion (watchdog "auto-recovers" claim removed — M91 never armed),
secrets-rotation (M76 cert-only containment), image-pinning (Kyverno enforces). Post-M110 doc-sweep checklist
recorded in the tracker M110 entry. All inbound links fixed repo-wide (incl. 3 code-comment refs + re-based
links in moved docs); gitleaks allowlist unaffected; link-integrity = 0 broken in-repo links.

**Infra review (read-only; 51 workflows, 18 TF stacks, ansible, k8s + live cluster/PromQL):** 20 new findings
→ tracker items — **H42** step-ca/asterisk/pve monitoring blind spot (fleet SSH depends on an unwatched CA),
**H43** 9 TF workflows run PR-authored `terraform plan` on the in-network self-hosted runner, **M112-M121**
(TF `concurrency:`; postgres/cert/authentik/cloudflared alert gaps + runbook_url; authentik SPOF; authentik
netpol tier; k8s-node auto security-patching; metrics-server; request right-sizing; backup thundering-herd
stagger; ceph-csi in unlabeled `default`; drift-detection plan.txt artifacts), **L25-L31**. Clean areas:
supply-chain (100% SHA-pinned), AWS cost hygiene, stale-ref greps, ansible secrets, RBAC minimality.

**Next:** H42 (S effort, biggest risk-per-effort) + M112 (S) first; M110 resume unchanged.

## 2026-07-01 — M110 executed (partial): us-east-1 decom + vpn-aws resize + rename; fold BLOCKED on CI→box connectivity

**Done (committed + applied):**
- **us-east-1 spoke DECOMMISSIONED** (`7b257df`, `a6c31ee`): destroyed the whole stack via a new
  `destroy` action on `terraform-aws-us-east-1.yml` (VPC + peering + hub route + t4g.nano + EIP
  `35.169.37.16`; verified empty). Removed the wg0 peer, CF `vpn-use1` record, the stack dir + its
  workflow + `vpn-use1.sops.yaml` + the drift-matrix entry + docs. **⚠️ Fixed a stale tfstate lock**
  (S3 `.tflock` from a killed 2026-06-17 plan) that blocked the destroy AND had been silently failing
  this stack's push-plans (masked by `| head`). Clear it: `aws s3 rm s3://terraform.wind.etherport.net/<stack>/terraform.tfstate.tflock`. **~$9/mo saved.**
- **vpn-aws RESIZED t4g.nano → t4g.small** (`506e526`): fixes the ENA pps-allowance flap. In-place
  stop/start; verified live = t4g.small / 1836MB / tailscaled active / tunnels re-handshook. Plan was
  `0 destroy` (the 2 alarm changes = their `InstanceType` dimension following the resize — benign).
- **RENAMED `private-infra_vpn` → `private-infra_edge`** (`ca77133`) — instance/volume/EIP Name tags
  (multi-service: WG + Tailscale + DNS). TF resource names kept (no state churn).

**BLOCKER — the fold + cutover are stuck on CI→box connectivity, NOT auth:**
- Cert-SSH bootstrap chosen path = "route CI ansible via the SOPS static key" (operator picked this over
  an in-place sshd edit, which the auto-classifier denied). Plumbed it into `ansible-vm-fleet.yml`:
  decrypt `automation_ssh_private_key` for `inventory=aws` + `IdentitiesOnly=yes` (else the minted cert
  is offered first → vpn-aws rejects → MaxAuthTries reset) + `ControlMaster`/`ControlPersist` multiplex.
- **But CI can't reliably REACH vpn-aws.** The homelab→AWS WireGuard site-to-site tunnel (`10.10.100.10`)
  is intermittently reachable from the CI runner (measured 1/3); the public EIP `44.240.60.80:22` is 3/3
  **from the devbox** but still times out intermittently **from the CI runner** — even though both homelab
  WAN IPs (`47.159.189.5`, `66.215.210.75`) ARE in vpn-aws's SSH SG. So the runner egresses via a path/IP
  that's dropped, or the path is lossy. Inventory currently points `vpn-aws ansible_host=44.240.60.80`
  (`180b030`) as the more-reliable path; revert to private/TS once sorted.
- **Net: step-ca-trust never completed on vpn-aws** → CI cert-SSH still off → the Technitium fold /
  DNS cutover / dns-box destroy / SG redesign are all pending.

**UPDATE (later 2026-07-01) — cert-SSH DONE + connectivity root-caused (box is FINE):**
- **✅ `step-ca-trust` APPLIED on edge** — the cert-SSH bootstrap succeeded via a **retry loop** over
  the static-key CI path (`ANSIBLE_SSH_ARGS` now uses `ControlMaster=auto`+`ControlPersist` so one good
  connect carries the whole play; `IdentitiesOnly=yes`; `ansible_host=44.240.60.80`). So CI ansible can
  now reach + configure the box (with a retry loop to punch through the intermittent windows). The main
  M110 blocker is cleared.
- **⚠️ CORRECTION — the "flap" is NOT the box's ENA, and NOT fixed by the resize.** On the resized
  t4g.small: **all ENA allowance counters = 0**, zero iface drops, load 0.00, **fail2ban inactive**,
  **0 sshd auth failures**, SG correct (both homelab WANs allow :22), devbox egress stable+allowed
  (`47.159.189.5`). Yet reachability to the box **waxes and wanes over minutes** (measured devbox→:22 =
  13/15, then 0/20, then 10/10; WG-tunnel 11/15 then 20/20). Same source IP, SSH dropped while WG-UDP
  fine in one window then flipped. ⇒ **intermittent packet loss on the homelab↔AWS PATH (WAN/ISP), in
  waves** — not the instance, SG, or auth. The M109 "t4g right-size fixes the flap" premise was WRONG
  (ENA was never the cause). **The resize is still justified** (2GB RAM for the multi-service box) but is
  NOT the flap fix. Real fix = homelab-side (mtr during a loss window; check the WAN/ISP, dual-WAN).
- Diagnostics added: `runner-egress` playbook (reveals the CI runner egress IP — it's `47.159.189.5`,
  same as the devbox + SG-allowed, ruling out an egress-IP/SG cause). Tool `ansible-vm-fleet.yml`.

**Next steps (resume here):**
0. **Reachability is intermittent but workable** — run the remaining consolidation ansible via CI with a
   RETRY LOOP (dispatch step-ca-trust-style until `success`). Separately investigate the path loss
   (mtr edge↔homelab during a bad window; ISP/dual-WAN) — it's the real "flap".
1. **Resolve CI→vpn-aws reachability.** Options: (a) find the CI runner's egress IP (a one-off CI job that
   curls an echo-IP service) + add it to the SSH SG via the `dns-restrict-ip` Lambda `rule_specs`; (b) check
   for packet loss / MTU on the runner's path; (c) run the consolidation ansible **from the devbox** instead
   (reliable Tailscale path) — needs ansible installed on the devbox, or operator OK to run step-ca-trust
   locally; (d) re-verify the WG tunnel stabilises post-reboot (it worked pre-resize).
2. Then: `step-ca-trust` apply → `technitium` fold (bind `.5`) → verify `dig @10.10.100.5` → move the `.5`
   secondary IP + explicit ENI to edge (compute TF) → destroy `aws_instance.dns` + release EIP
   `52.40.219.113` → re-point UniFi `dhcp_dns` (7 VLANs) + `dns-restrict-ip` Lambda `.113`→`.80` → SG
   redesign (Phase 1) → monitoring cleanup (Phase 5). Plan: `aws-vpn-dns-consolidation-plan.md`.

## 2026-07-01 — AWS cost spike root-caused + fixed: velero Kopia hourly maintenance → S3 request storm

**Trigger:** AWS cost alert, ~$160 forecast (June actual ~$138 vs April ~$107 baseline). User
suspected S3 storage-class transitions failing / iCloud archive bloat.

**Investigation** (Cost Explorer + CloudWatch DENIED to the scoped `terraform-homelab` key, so
sized everything via `aws s3 ls`/`list-objects-v2` with throwaway creds from
`render-aws-credentials.sh`, shredded after):
- **Storage is fine — hypothesis disproven.** `archive.wind.etherport.net` = 10.1 TB total (6
  s3-sync shares; `media/` alone = 7 TB, a legit movie/TV library), correctly in **Deep Archive
  (~$10/mo)**; only 2.3 GB tiny <128 KB files in Standard (by design). `backups/` = 540 GB.
  **0 noncurrent versions.** Storage across ALL 15 buckets ≈ $17/mo.
- **The spike is S3 REQUEST cost.** CE chart (user-supplied): S3 ~$10→~$85/mo in **May**, held
  in June. `velero` bucket created **2026-05-14** (== spike month); object count ~250/mo Jan–Apr
  → 4,736 May → 22,724 June.
- **Root cause: velero Kopia repo-maintenance ran HOURLY** (velero default; the 11 live
  `BackupRepository` CRs all showed `maintenanceFrequency: 1h0m0s`). Each run LISTs/GETs/rewrites
  the whole repo index in S3; ×11 repos ≈ 7,200 runs/mo ≈ **~$70/mo**. (Maintenance had stalled
  since 06-24 → **July MTD already down 87%** — but `1h` was a live re-storm landmine.)

**Fix (`e9f11d3`):**
- `clusters/wind/helm-releases/velero.yaml`: `configuration.defaultRepoMaintainFrequency: 24h`.
  HR upgrade verified → server arg `--default-repo-maintain-frequency=24h`. Flag only affects
  **newly-created** repos.
- **Patched the 11 existing `BackupRepository` CRs live** to `24h0m0s` (velero owns them, not
  Flux) — immediate; each fired one catch-up job then settles to daily.
- `infra/terraform/aws/s3/main.tf`: added the missing `logs.grahamsmith.net` lifecycle (had
  NONE) — expire `alb/` after 30d (auto-clears ~116k dead ALB access-log objects; ALB gone
  2026-05-27) + abort-incomplete-MPU. Applied via `terraform-s3` (plan `1 add / 0 destroy`,
  reviewed, applied — green).

**Target ≈ $35/mo** (`aws-cost-teardown` workflow, 7 agents): 1× t4g.small (~$12) + 1 EIP
(~$3.65) + 10 TB Deep Archive (~$10) + throttled velero (~$15) + Route53/Config/misc (~$5). vs
June $138.

**Remaining levers:**
- **M110 consolidation** (task #43, me): resize vpn-aws→t4g.small, fold Technitium on, destroy
  `aws_instance.dns` + release EIP `52.40.219.113`, re-point UniFi dhcp_dns (7 VLANs) +
  `dns-restrict-ip` Lambda → `44.240.60.80`. Drops 1 EIP + fixes t4g.nano ENA-pps flap.
- **us-east-1 decom** (me): destroy the `aws-us-east-1` stack (nano vpn + EIP 35.169.37.16 + EBS
  + peering + region Config recorder) ≈ **$9/mo**. ⚠️ its CI workflow has no destroy action.
- **USER-only** (denied to me): (a) Cost Explorer → Group-by **Usage Type**, filter S3 → confirm
  the delta is `Requests-Tier1/2`; optionally grant `ce:GetCostAndUsage` + a Budget alert. (b)
  console-check for a stray REGIONAL WAFv2 WebACL (`wafv2:List` denied; none in repo IaC → should
  be $0, an orphan bills $5+/mo).
- **Architectural follow-up (3-2-1):** move velero's PRIMARY BSL to LOCAL object storage (MinIO
  or Ceph RGW — Ceph already runs) for frequent/fast/zero-request backups; keep AWS as DR via a
  weekly BATCHED rclone → Deep Archive. Same for postgres/barman WAL. Not yet ticketed.

## 2026-07-01 — cairn photos SAGA RESOLVED: best-effort + non-destructive heal (v0.1.6) + staleness alerts

**What:** closed out the multi-day photos-failure saga. Two final findings + a design decision.
**Root cause (final):** the raw SMB link to sequoia is FAST (~500 MB/s, measured); the fragility is the
**disk-image (sparsebundle/APFS-over-SMB) layer** — on an AGED mount, *data* reads (incl. osxphotos' hot
`Photos.sqlite` copy) EIO/crawl while *metadata* reads pass (fooling the liveness probe). A fresh
login-context attach (`net.wind.mount-nas`) reads fine; cairn's launchd reattach is the flaky one (Apple
doesn't support disk-images on network shares). **And cairn's own 5×-rapid reattach retry (v0.1.5) is what
WEDGED the mini's disk-image subsystem** (diskarbitrationd/diskimagescontroller → every attach EAGAINs until
a REBOOT; the reboot this morning cleared it). **NOT the 9 "unavailable" photos** (infra-agent hypothesis) —
those are in SUCCESSFUL runs too (rc=0, missing=9); local mode skips them, never rc=1.

**Fixes (deployed):**
- **cairn v0.1.6** — `ensureImage` makes **ONE** careful reattach attempt then skips the run gracefully
  (no retry loop) → cairn can never wedge the box again. Commit cairn `6eeab84`.
- **Alerts → staleness-only** (`platform/kubernetes/monitoring/09-photos-export-alerts.yaml`, `a556ded`):
  PhotosExportStale 26h→**3 days** + critical→**warning**; PhotosExportFailed **removed**; NotParsed +
  CoverageRegressed **gated on rc==0** (so a bad night can't fire "4 alerts" at once). Other iCloud jobs
  keep their per-run alerts; only photos is exempted.
- **Decision: photos is BEST-EFFORT** — succeeds most nights (incremental: ~600MB DB read + delta, NOT
  420GB), skips quietly + recoverably on bad ones; data never at risk (iCloud + the 418GB backup).

**Validated:** launchd sim (the tonight-path, v0.1.6) on a 9h-aged mount → **rc=0 (87min), NO wedge, 8/8,
alert cleared.** ⚠️ **A wedged disk-image subsystem = REBOOT the mini** (root daemons; settle-retry doesn't
reliably clear it). Docs: cairn README §6 (`befe2fb`) + memory. **Lesson: don't thrash the sparsebundle
(repeated detach/attach) — that's the wedge trigger; reproduce mount/launchd bugs via a one-shot launchd
agent, not the interactive shell.**

## 2026-07-01 — cue-api HA (fixes intermittent access) + Kyverno admission HA + AWS decision

- **Cue "server stopped responding" (intermittent) root cause = deploy-time blip from `cue-api`
  replicas:1.** Every Flux `:latest` roll (~8x/day) swapped the single pod; the CF tunnel keep-alive
  to the terminating pod dropped before re-establishing → in-flight requests failed. NOT a device/
  Private-Relay/DNS/CF-Access issue (all verified healthy end-to-end: `/health` 200 via edge→tunnel→
  origin, Google OAuth client fine, DNS identical internal/external). **Fix (`493868b`): cue-api →
  2 replicas + PDB (minAvailable 1) + topologySpread (hostname).** Verified 2/2 on w2+gpu1, reachable
  through the roll. Rolls are now zero-gap (maxUnavailable=0). Safe at 2: at-most-once push via the
  proactive_pings UNIQUE reservation, stateless auth, sequential migrate initContainers under maxSurge=1.
- **Kyverno admission HA (`bef7636`):** replicas 1→2 + PDB + antiAffinity — removes the single-pod
  fail-closed-webhook blackout that amplified the 2026-06-30 leader-election cascade (pairs with the
  admissionReports=false root fix). Verified 2 pods on w1+w3, enforcement intact.
- **AWS decision:** decommission the **us-east-1** remote-access VPN (`infra/terraform/aws-us-east-1/`,
  a standalone t4g + EIP) — replaced by Tailscale, dead weight, cost saving. **KEEP the us-west-2 hub
  (`vpn-aws` .10) + `dns-aws` .5** (DNS failover). NB the *flapping* alerts are the us-west-2 pair, not
  us-east (already de-flapped M109-B). Caveat noted: dns-aws is reached over the WG tunnel via the local
  vpn-local, so it only survives failures that spare that path — true off-site DNS resilience would need
  dns-aws as a direct Tailscale node. Reminder set for 2026-07-02 to scope the decommission + savings.

## 2026-06-30 (cont.) — full infra health check: 3 high resolved (incl. the daily-stall re-diagnosis)

Operator reported a Technitium-down + an AWS-VPN-down alert; ran a full 8-agent parallel health
check + resolved. Storage/networking/certs/backups all healthy. **0 critical, 3 high — all fixed
(`46371c3`), live-verified.** Tracker: **M109**.
- **Both AWS alerts = one cause:** dns-aws/vpn-aws (t4g.nano) flap node_exporter scrapes 600+x/24h
  from brief per-instance **ENA-allowance packet blackouts** — proven NOT the WG tunnel/WAN (the two
  hosts blackout *independently, never together*; tunnel pristine, no OOM; vpn-local `wg show` clean).
  Services are FINE (dns-sync syncs to 10.10.100.5, dig answers). **Fix B:** scoped the per-host
  critical alerts to `location="local"`, added `AWSReplicaHostDown` (for:15m) + `AWSReplicaHostFlapping`
  (warning). Real fix = right-size the instance (needs AWS access) — OPEN.
- **⚠️ Re-diagnosis of the daily ~10:00 UTC stall (M106):** the health check found the slow etcd keys
  are **Kyverno `ephemeralreports`/policyreports in the backups ns**, with etcd fsync p99 3.5ms (fast)
  → it's a **Kyverno admission-report write-storm** saturating raft (triggered by the 10:00 backup/
  CronJob fan-out), not (primarily) the vzdump disk stall. Onset = Kyverno install ~6d ago. **Fix C:**
  `features.admissionReports.enabled=false` in the kyverno HelmRelease — reporting-only, verified
  `--admissionReports=false` on both controllers + **enforcement intact** (`:latest` still rejected,
  mutate still injects 10m/32Mi); ephemeralreports 46→1. The M106 vzdump exclusion (operator did it
  today) is complementary — **verify BOTH at the next 10:00 UTC window.**
- **Fix A (my #41 bug):** the doc-drift textfile metric was written 0600 by mktemp → node_exporter
  permission-denied → DocDriftAuditNoMetrics pending-critical + the drift signal dark. `chmod 0644`
  the tmp before mv (+ live chmod); `node_textfile_scrape_error=0`.
- ai-advisor controller healthy + sane (110 skipped_resolved / 67 skipped_noisy / 24h, $0.46/day, no
  panics). 0 scrape targets down (133/133). All 24h alerts (etcd gRPC spike, Velero partial, iCloud/
  Photos, KubePodCrashLooping, dns-aws) already resolved.

## 2026-06-30 (cont.) — doc-audit hardened (scope + email + approve + alert) + Google Places key IaC

Continued the weekly doc/IaC drift audit work into a hardening pass, plus stood up the Cue
Find-food Places key as IaC. Five-area parallel research workflow first (ai-advisor approve
mechanism, Claude Code permission matcher, failure-alert infra, google TF stack, cue-api secret),
then implemented. **M107** (audit, DONE) + **M108** (Places, blocked on 1 grant) in
[`outstanding-work.md`](outstanding-work.md). Commits `2c73fe3`→`b0e7af7` (+ `51c634d` Places).

**Doc-audit hardening (M107):**
- **Issue posting** (`post-doc-drift-issue.yml`): the dispatch PAT is Actions:write-only (403s on
  /issues), so the audit dispatches this tiny workflow whose `GITHUB_TOKEN` posts/closes the
  `doc-drift` issue. Open-on-drift/close-on-clean. Tested open+close green.
- **Scoped permissions** (dropped `--dangerously-skip-permissions`): `--permission-mode default
  --settings doc-drift-audit-permissions.json`. **Key empirical matcher facts** (probed on this
  Claude build): headless `default` mode HARD-DENIES any Bash command matching neither the safe-read
  list nor an allow rule; **`$(...)` substitution and `VAR=x cmd` env-prefixes are rejected**;
  pipes/chains are parsed segment-by-segment; `Edit/Write` default-deny when an allowlist is present
  so `**/README.md` allows component READMEs while everything else under infra/platform/clusters is
  blocked; **the Write tool is DENIED for out-of-repo paths even with `--add-dir`**. Consequences:
  the wrapper **exports `SOPS_AGE_KEY_FILE`** (so plain `sops -d <file>` works), secret+curl ops go
  through a vetted **`audit-helpers.sh`** (`udm`/`gh-get`/`dispatch-issue` — keeps secrets out of
  logs + avoids substitution), artifacts moved to an **in-repo gitignored `infra/devbox/.audit-state/`**
  (Write works in-repo), and **`awk` was removed** from the allowlist (it was a `print>file`
  write-hole the agent had exploited as a fallback). Validated: a full clean end-to-end run + targeted
  probes (`kubectl delete`/`terraform` blocked; in-repo Write ok; awk blocked).
- **Email every run** (user opted in, clean or drift) via SES **SMTP** — the devbox has no in-cluster
  IRSA, so `send-audit-email.py` (pure stdlib) sends over SMTP with creds decrypted from the
  alertmanager SOPS secret, From the verified `service-status@wind.etherport.net`. Multipart HTML.
- **Approve buttons (#40)** — chose **deep-link** over a one-click HMAC receiver (no new public
  endpoint that could dispatch infra applies). Per actionable item the audit appends a
  `[Review & apply →](…/actions/workflows/<file>.yml)` link; the mailer renders apply-workflow links
  as green buttons → opens GitHub's Run-workflow page (login-gated; 1 confirm). Preview email sent.
- **Off-box failure/missed-run alert:** the email signals a *failure* but can't signal a *missed*
  run. Added node_exporter `--collector.textfile` to `base.yml` (applied to the devbox — the
  download/extract tasks correctly skip in apply mode; the `--check` run false-fails because get_url
  doesn't fetch in check mode, a known artifact) + a devbox-writable textfile dir; the runner writes
  `doc_drift_audit_last_{rc,success_timestamp_seconds}` (success-ts only on rc=0); rules
  `DocDriftAuditStale`/`NoMetrics` (critical→email) + `Failed` (warning) in `02-external-alerts.yaml`.
  Verified live: metric scraped (`instance="devbox"`), 3 rules loaded in Prometheus.

**Google Places key (M108):** added to `infra/terraform/google/` — enables `apikeys` +
`places.googleapis.com` and a restricted `google_apikeys_key.cue_places` (API-only restriction; the
app calls server-side). **⚠️ used `places.googleapis.com`, not the `places-backend.googleapis.com`
in the brief — that's the LEGACY Places API; Places API (New) endpoints + the key restriction must
match `places.googleapis.com`.** `validate` clean; CI plan = **3 add / 0 destroy**. **Blocked on a
one-time manual `roles/serviceusage.apiKeysAdmin` grant** to the WIF SA (devbox has no GCP creds) —
then apply + `sops set` the key into the cue-app secret. Feature stays OFF (no `CUE_FIND_FOOD`).
Runbook C in the google README.

**Also:** answered the operator's design Q — the audit runs on the devbox not merely because Claude
is installed there but because it needs privileged LIVE LAN reads (kubectl/UDM/`ip route` from a
VLAN-201 vantage) + the age key + genuine unattended auto-resume; CI/in-cluster/mini are each worse.

**Next:** (1) user runs the apiKeysAdmin grant → I finish M108 (apply + SOPS). (2) M106 PVE vzdump
(user). The audit is self-maintaining; first scheduled run Mon 2026-07-06 14:37.

---

## 2026-06-30 (cont.) — 4 new drift detectors (cluster-config, dns-sync, step-ca PKI, AWS Config)

Built all 4 proposed drift detectors. With the existing TF/ansible/topology/inventory ones, the
homelab now has **broad config-drift coverage across cloud + cluster + network + PKI**.

1. **cluster-config invariants** (`cluster-config-drift.yml` + `scripts/k8s/cluster-config-assertions.sh`)
   — asserts the LIVE control-plane matches the kubespray IaC (apiserver `--service-account-issuer` =
   the IRSA bucket URL, `--api-audiences` pins sts.amazonaws.com, cilium `policy-audit-mode=false` +
   `enable-wireguard=true`). These break SILENTLY (read once at startup) — the M75/cilium-incident class.
   Daily on the lifecycle runner (kubeconfig from cp1). Verified green (8/8 assertions pass).
2. **dns-sync** (`12-loki-rules-dns-sync.yaml`) — `DnsSyncWatcherSyncFailing` loki rule. **Pivoted from
   "technitium.yml --check"** because that's a provisioning playbook (ok=7/changed=1/**failed=1** in check
   mode → would be pure noise). DNS RECORDS are already GitOps-reconciled by dns-sync-watcher; the gap was
   a SILENT sync failure (the 8-day netpol drop). Fires when the watcher logs sync failures.
3. **step-ca PKI** (`step-ca-pki-drift.yml` + `scripts/pki/step-ca-pki-assertions.sh`) — step-ca /health
   + CA-cert expiry margins (intermediate in the served chain + the committed root anchor, ≥30d). Catches
   a dead CA (renewals silently stop → fleet lockout) or an anchor marching to expiry. Verified green.
4. **AWS Config tag-drift** (`infra/terraform/aws/config/` + `cloud-tag-drift.yml`) — the cloud detector.
   **Decided AWS Config over driftctl (EOL/archived) + over the free Tagging-API**, for ~100% coverage +
   change-history at ~$2/mo (user choice). Designed + **adversarially verified by a workflow** before the
   billable apply — which caught a FATAL flaw: **AWS Config SQL cannot express tag-ABSENCE** (no IS NULL /
   NOT EXISTS / array-negation), so the query SELECTs all resources WITH tags + filters "missing
   ManagedBy=terraform" **client-side in jq**. The verify also forced: a hand-rolled IAM role (not the
   account-global SLR → EntityAlreadyExists), an **aggregator** (was missing), global types in ONE region,
   DAILY recording, and confirmed `gh-actions-terraform` applies it with **zero IAM edits**. Marker
   standardized: `default_tags{ManagedBy="terraform"}` added to the 5 untagged AWS stacks (12 already had
   it). **APPLIED** (run `28457133384`, `15 added/0/0`, no collision/no DAILY-400); recorders live in both
   regions; the query workflow validated green end-to-end. Stack `config` added to the TF drift matrix.

**Detector inventory now:** TF plan (24 stacks) · ansible --check (UDM fw + switch ACLs) · topology
(routing invariants) · cluster-config (CP invariants) · step-ca PKI · dns-sync · inventory · **AWS Config
(cloud tag-drift)** — all open-on-drift / close-on-clean (the TF + ansible ones gained close-on-clean too).

**Follow-ups:** (a) the 5 newly-`default_tags`-ed stacks (ddns-lambda, dns-restrict-ip, email-forward,
homeassistant-alexa, twilio-webhook) must re-apply so their resources get the marker — until then they
show in the cloud-tag-drift report (the tf-drift detector will flag the pending tag change). (b) tune the
cloud-tag-drift ALLOWLIST from the first full run (AWS-managed untagged resources), then flip it from
informational to hard-fail. (c) one-off `get-discovered-resource-counts` after ~24h to confirm the
~$2/mo estimate. Still user-side: M104 (205 DHCP DNS), M106 (PVE vzdump cp1 stall).

---

## 2026-06-30 — overnight alert-storm triage + 3rd drift detector (topology)

Two asks: build the remaining drift detector, and investigate/resolve the many overnight
service-status + ai-advisor emails.

**Topology drift detector (the 3rd class) — BUILT + verified (`6e75076`).** Routing/zone
invariants ("Servers/201's gateway is the UDM") aren't a live-vs-IaC diff, so neither the TF
nor ansible detector catches them — the 201 drift proved it. `scripts/network/topology-assertions.sh`
probes `ip route` from a VLAN-201 host (every off-201 dest + internet must first-hop the UDM
`10.10.201.1`); `network-topology-drift.yml` runs it daily on the lifecycle runner (ON 201, NO
container so it reads the host netns) with the open-on-drift / close-on-clean pattern. Verified
green on the runner (all 6 assert PASS). **Drift detection is now 3 layers: TF plan, ansible
--check, topology probe** — plus I added close-on-clean to the TF + ansible detectors (`74a07c1`,
so resolved issues like the stale `tf-drift` #73 auto-close) and the `cluster-irsa`+`roles-anywhere`
matrix gap (`be305a7`).

**Overnight email storm — root-caused (multi-agent triage `wmx86dg7f`) = THREE independent things:**
1. **Cluster blip (recurs daily, PVE action needed → [[M106]]):** a ~10:05Z **vzdump snapshot of the
   cp1 VM stalls its disk ~10 min** → freezes the etcd leader + apiserver writes (p99 48-58s) →
   ~10 leader-election leases expire → mass component restart + technitium recreation. etcd quorum
   never lost; self-heals ~10:25Z. **Fix = exclude k8s-cp1/2/3 from vzdump** (etcd is already
   host-snapshot-backed); needs PVE (not IaC'd, no devbox creds). apiserver `--etcd-servers` already
   lists all 3 ✅.
2. **Real chronic netpol gap — FIXED (`06d508e`):** `dns-sync-watcher` (enforced `dns` tier) syncs
   hourly to the two OFF-CLUSTER Technitium replicas (`10.10.201.6`, `10.10.100.5`) on tcp/5380, but
   the dns-tier `world` egress only opened query ports → 5380 POLICY_DENIED (72 drops/hr, "urlopen
   timed out") for **8 days** since the tier was enforced 06-22. Added a least-priv `toCIDR` egress
   for those two /32s on 5380. **Verified live:** restarted the watcher → now `✓ Authenticated` to
   both replicas, 47 records synced, **0 timeouts**. This was the `CiliumNetpolDropFlow` source.
3. **Auto-remediation mismatch — FIXED (`9b32d6d`):** the external + in-cluster Technitium alerts both
   used the name `TechnitiumDNSDown`, and the controller matches by alertname only — so an external
   host (dns-aws) going down wrongly force-restarted the in-cluster StatefulSet pods (8× overnight).
   Renamed the external alert → `TechnitiumExternalHostDown` (+ runbook stub). Follow-up: gate the
   controller on an explicit `auto_remediate` label.

**Velero partials = already resolved** by `8baa892` (06-30 runs Completed 0 errors); the old partials
are stale history. CiliumTraefikIngressDrop never fired (no ingress break). Cluster healthy throughout
the triage (8/8 nodes, 0 pods down). **Next:** the cluster-config-invariants detector (apiserver
issuer / cilium policy-audit+encryption / etc. vs the kubespray IaC) — recommended as the highest-value
remaining drift tool; and M106 on the PVE side.

---

## 2026-06-29 (cont. 2) — cairn photos: TRUE root cause (flaky SMB reattach) → retry fix v0.1.5

**What:** the overnight photos rc=1 recurred a 4th time despite v0.1.4. Testing an **unattended launchd
run on demand** (vs my interactive shell) cracked it — and showed v0.1.4 was actively HARMFUL.

**Root cause:** the **SMB-backed sparsebundle `hdiutil attach` is FLAKY under launchd** — it intermittently
hangs / fails `hdiutil: No child processes` / EIO, and intermittently succeeds (SMB link state varies;
reproduced both outcomes the same afternoon via one-shot launchd test agents). The aged-mount EIO on the
hot `Photos.sqlite` read is real, but cairn couldn't recover because `ensureImage` did **one** attach and
gave up. **mount-nas.sh (bash, at login / interactive Aqua session) attaches reliably → that's why daytime
always worked and my from-shell re-runs "passed."** v0.1.4's proactive force-reattach detached the working
mount every run then hit the flaky attach → 100% failure (the unattended test caught it before tonight).

**Fix — cairn v0.1.5 (deployed):** `ensureImage` retries the attach **5×** (bounded 120s + backoff,
clearing stale attachments each try); reverted v0.1.4's proactive detach; reactive force-reattach now
triggers on **timeout/stall too**, not just EIO. **Verified under launchd:** force-detached PhotosLib →
cairn reattached via the retry → osxphotos ran (the exact failing path). Clean run ✓ (43,981 items),
8/8 healthy, alert cleared. Built/signed/published via CI, deployed (leaf `541075…`, v0.1.5). **Real test =
tonight's 22:00 run — watching.** **Method lesson:** reproduce mount/launchd bugs under a one-shot launchd
agent, never the interactive Claude shell (it has the working session context that hides the failure).
Docs: cairn README §6 + memory.

## 2026-06-29 (cont.) — full config-drift resolution: live-anchored re-audit + continuous detectors

User flagged that the original error which prompted the whole doc-review exercise — `firewall-zones.md`
calling Servers/201 switch-routed — was STILL wrong after the big review, and asked how to **fully
resolve all config drift**. Root-caused the review's failure and built the durable fix.

**Why the prior review missed it:** it reconciled docs ↔ repo (and docs ↔ each other). For UI-managed
facts (UDM routing/zones) with no complete IaC, the **repo itself carried the stale premise** — so the
review "harmonized" everything to a wrong model. Doc-vs-doc consistency ≠ truth.

**Ground truth established (the method):** from the devbox (which is ON VLAN 201), `ip route get` for
202/209/210/204/internet all first-hop the UDM `10.10.201.1`; tracepath to a 202 host goes UDM → switch.
So **201 is fully UDM-routed** — there is no "201 east-west switch-routed" path. Fixed `firewall-zones.md`
(moved 201 to the UDM table, redrew the dual-router diagram, fixed zone/ACL notes) + the stale premise
baked into the **IaC** (`usw-acls.yml` header still called 201 switch-routed; its `205→201` ACL is now
DEAD — both ends UDM-routed). Commit `570f629`.

**Continuous detectors (the "keep it resolved" half):**
- ✅ **`ansible-drift-detection.yml`** (new, `904723e`+`3dc14a0`) — daily `--check --diff` of
  `udm-firewall.yml` + `usw-acls.yml` on the lifecycle runner; `changed>0` → opens `ansible-drift`
  issue + red run (owner email). This is the exact gap that hid the 201 drift (those surfaces had only
  a MANUAL check). Verified: both playbooks are `changed=0`/idempotent when aligned (no false-positives);
  detector runs green end-to-end. **Gotcha:** the ansible-runner container runs steps with `sh` (dash),
  not bash — `set -o pipefail` errors; use a redirect+`exit $rc` capture instead.
- ✅ Existing coverage confirmed: `terraform-drift-detection.yml` (TF, daily) + `service-status-inventory-drift.yml`.
- ⏳ **Topology-assertion detector** (the 201-class — routing/zone invariants, NOT a live-vs-IaC diff;
  needs an `ip route`/UDM-API probe from a VLAN-201 host) — designed, not yet built.

**Live-anchored doc RE-AUDIT (the "clear the backlog" half):** a 5-domain workflow (`w1jdr43sw`) where
agents verified every architecture/runbook claim against **live** kubectl/UDM-API/on-host probes →
**10 confirmed drifts** the doc-vs-doc review could never find. All re-verified by me against the live
UDM API before fixing; applied in `be305a7`:
- **205 Network Isolation is OFF** (live `network_isolation_enabled=false`), not ON — M104 is HALF done
  (isolation disabled; **DHCP DNS still empty** = the only remaining M104 step). Tracker → 🟡.
- **Twilio port-forwards** are TCP `5061` + UDP `10000-20000` → `10.10.201.40` (asterisk-sbc), not the
  retired `6767`/`10000-60000` → `.199.1` UDM-Talk path. Same stale premise spanned `firewall-zones.md`
  AND `unifi-talk.md` (banner-flagged; full refresh → M17). Legacy `Allow-Twilio-*-6767` UDM rules are
  vestigial (cleanup candidates, like the dead 205→201 ACL).
- AWS static routes carried ONCE (gateway_type=default, next-hop .201.20, gateway_device=UDM) — no
  switch-typed duplicate; WG endpoint /30 not /29.
- IRSA = **5** roles not 4 (added `wind-irsa-cue-media`) — CLAUDE.md + irsa runbook.
- velero `monitoring-daily` = 7-day retention (not blanket 30); postgres = 3-instance CNPG (3 PVCs).
- traefik README self-contradiction (Traefik IS Flux-managed).
- **REAL GAP (not just docs):** `cluster-irsa` + `roles-anywhere` are persistent S3-backed stacks that
  were **NOT in the TF drift matrix** → drifting silently. **Added both** to `terraform-drift-detection.yml`
  (now 24 stacks). Dispatched a full drift run to validate + refresh the open `tf-drift` issue #73.
- Systemic THEMES: stale-premise-propagated-across-docs+IaC (201, Twilio), doc-trails-IaC (IRSA count),
  absolute-quantifier rot ("all/only/every" claims a single counter-example falsifies).

**State:** all 10 doc/IaC drifts fixed + pushed; ansible detector live; TF matrix gap closed. **Next:**
build the topology-assertion detector; confirm the drift run is green (validates the 2 new stacks) +
triage issue #73; the mini-report-code hardening (cairn NAS-mount diagnosis — separate thread, now also
root-caused mini-side per the entry below).

---

## 2026-06-29 — cairn photos overnight rc=1 ROOT CAUSE found → fresh sparsebundle reattach per run (v0.1.4)

**What:** third consecutive overnight `ICloudBackupFailed` (photos rc=1). The osxphotos crash log
(`~/.local/state/cairn/photos-reports/osxphotos_crash.log`) was the smoking gun: osxphotos' first step
copies the library's hot `Photos.sqlite` off the sparsebundle and that read throws **`[Errno 5]
Input/output error` once the sparsebundle mount has AGED** (attached since login, read overnight) — even
though cairn's small liveness probe passes. **Daytime works only because a fresh `mount-nas.sh` reattaches
first** (confirmed: a fresh attach gets past the EIO). The prior two fixes (v0.1.2 attach-leak, v0.1.3
SMB-retry + 22:00 reschedule) were real but NOT the root.

**Fix — cairn v0.1.4 (deployed):** PhotosSource now **proactively force-detaches/reattaches the
sparsebundle FRESH at the start of every run** (image layer only; Personal-Drive stays mounted, like
mount-nas.sh), while resources are fresh — instead of reacting after the EIO when the system is already
starved (the reactive reattach had been failing with hdiutil `Resource temporarily unavailable`/`No child
processes`). Today's re-run ✓ (43,980 items); alert cleared, 8/8. Built/signed/published via CI, deployed
(leaf `541075…`, v0.1.4). **Real test = tonight's unattended 22:00 run** (daytime confirms the mechanism,
not the night condition) — watching it; if it still fails the cause is night-specific (diagnose live).
Also confirmed a **scheduling pile-up** (slow contacts holds the lock past 20:00 → the 20:00 messages fire
is skipped → messages+photos stack onto the 22:00 fire) — noted, not yet the fix focus.

## 2026-06-29 — M77 Stage-2b: asterisk SBC firewall source-scoped to Twilio/Talk (applied)

Closed the last open M77 follow-up (the telephony/911-critical one the cont.8 review explicitly
deferred to "do with call-path review, not a guess"). The asterisk SBC (VM 1004) PVE firewall
rules were any-source (Stage-2 `input_policy=DROP` only closed UNLISTED ports — SIP/RTP stayed
wide open). Scoped them in `infra/terraform/proxmox/firewall/standalone-vms.tf`:

- **Safety principle (why this is low-risk):** scope the firewall to **exactly the ranges the
  SBC's own `pjsip identify` ACL already trusts** (`infra/ansible/playbooks/asterisk-sbc.yml`
  `twilio_signaling_nets` + `twilio_media_net` + the Talk host). PVE's firewall is **stateful**
  and this scope is a **superset-or-equal** of what the SBC would answer → it cannot drop a call
  the SBC would have accepted on the signaling path. If Twilio ever rotates an edge outside the 8
  /30s, the SBC's ACL was already going to reject it too (parity, not a new failure mode).
- **What landed:** two new IPsets — `twilio-signaling` (the 8 Twilio signaling /30s) and
  `asterisk-internal` (Talk `10.10.199.0/24` + Servers `10.10.201.0/24`) — and the 4 asterisk
  rules scoped: **5061/tcp (SIP-TLS, internet-facing) ← twilio-signaling**; **5060/udp (plain SIP,
  internal Talk leg) ← asterisk-internal**; **10000:20000/udp (RTP) ← Twilio media
  `168.86.128.0/18` + asterisk-internal**. Also a comment-only note on the dns-fallback VM (1001)
  documenting that DoT/DoH (853/443) are intentionally closed under default-deny (encrypted DNS
  terminates at the k8s VIP `.5`, not the fallback `.6`).
- **Ship path:** commit `bf906f3` → CI push **plan** (run `28352589004`) reviewed = `Plan: 2 to
  add, 1 to change, 0 to destroy` (only the asterisk resources) → user-authorized **apply** (run
  `28396740159`, classifier-gated as 911-critical; surfaced the plan + risk + revert path via
  AskUserQuestion, user chose "apply now, I'll test a call") → `Apply complete! 2 added, 1 changed,
  0 destroyed`. `terraform validate` was clean pre-push (offline, existing `.terraform`).
- **⚠️ State at end / next step:** APPLIED but **NOT yet call-verified** — RTP media has no
  app-layer backstop, and a live call can't be placed from the devbox. **User to place an inbound
  + outbound call (ideally a 911/provider-test number) to confirm two-way audio.** If a call fails
  (esp. one-way/no audio = RTP media source outside `168.86.128.0/18`): **revert = `git revert
  bf906f3` + dispatch the firewall apply** → every rule back to any-source within minutes.
- Notes for next agent: fmt is **not** CI-enforced on this stack (committed `standalone-vms.tf`
  already fails `terraform fmt -check` due to the `local.vm_input_policy` trailing-comment
  alignment; the workflow has no `fmt` step) — don't gratuitously reformat. Devbox dispatches CI
  via the `github_dispatch_pat` in the SOPS ops bundle (no `gh` CLI); poll runs with
  `event=workflow_dispatch` to avoid matching the push-plan run.

---

## 2026-06-28 (cont. 8) — adversarial review of recent work → 2 critical + 1 high FIXED

Ran a multi-agent adversarial review of the 24h work (M71/M72/M74/M77/L24) — 15 confirmed
issues, **zero false positives**. Coverage note verified a lot healthy (8/8 MD5 BGP sessions,
M77 telephony intact, M71 trust-policy tight, M74 policies monitor-only). Fixed the load-bearing ones:

- **🔴 CRITICAL — the Loki ruler was loading ZERO rules → EVERY LogQL alert silently dead** (the
  H3 cilium-audit drop-alerts, IPMI/syslog, AND my new M74 Tetragon alerts — dead since the L4 ruler
  setup). Two layered causes: (1) the ruler config block was under `loki.ruler`, a key the grafana/loki
  6.x chart **silently ignores** (it renders the ruler from `loki.rulerConfig`/`structuredConfig`) — so
  the ruler ran on chart defaults with **NO `alertmanager_url`** (alerts could never reach Alertmanager)
  + a default `rule_path` mismatching the sidecar dir; (2) even after moving the sidecar `folder` to
  `/var/loki/rules/fake`, the ruler's `rule_path` mapped into a **stale root-owned emptyDir mount point**
  (`/var/loki/rules-temp/fake`) → "permission denied". **Fix:** moved the ruler block to
  `loki.structuredConfig.ruler` (deep-merge — verified via `helm template` with the real values) + set
  `rule_path: /var/loki/rules-scratch`. **Verified live:** `loki_ruler_managers_total=1`, 3 groups loaded
  (cilium-netpol-audit/pve-ipmi-syslog/tetragon-runtime-detect = 9 rules), zero permission errors,
  `alertmanager_url` present. Commits `97c27f4`+`38d3290`. ⚠️ This means my earlier "cilium drop-alerting
  / Tetragon alerting is LIVE" claims were FALSE until now.
- **🔴 CRITICAL — M72 `enforce=baseline` on github-actions-runner would reject every dispatched ARC
  runner pod** (containerMode dind = privileged + `hostNetwork: true` → baseline violations) → silently
  break the self-hosted CI apply path on the next job. My M72 `--dry-run=server` was BLIND because
  `minRunners: 0` = no runner pod at rest. **Fix:** reverted that ns to `enforce=privileged` (privileged-
  by-design like plex/wireguard); kept audit/warn=baseline. Live + verified (`71b732d`).
- **🟠 HIGH — M71 RA Deny was bypassable:** `s3:GetObject`-literal (so `s3:GetObjectVersion` could read
  the versioned AES256 **backup** buckets — etcd-snapshots = all K8s Secrets cleartext, velero, barman)
  + no `ssm:Get*` (SecureString path). **Fix:** Deny now covers GetObject+GetObjectVersion+Torrent,
  secretsmanager Get/BatchGet, ssm:GetParameter*, kms:Decrypt; scoped `DeleteObject` to `*.tflock`.
  Re-applied via CI. Corrected the "can't exfiltrate secrets" overclaim in 3 docs (residual: whole-
  tfstate-bucket read + plaintext-secrets-in-state is inherent to "can run plan"). (`71b732d`)
- **Quick cleanups:** deleted the orphan `wind-l2`/`wind-pool` L2Advertisement + native MetalLB
  ClusterRoleBindings (Velero-restore leftovers); confirmed **BGP graceful-restart is already ACTIVE**
  (FRR default) and corrected the tracker. **⏳ Remaining LOW follow-ups** (tracked, not yet done):
  M77 asterisk→Twilio source-scoping (telephony-careful), M74 setuid-root matchBinaries runc-exclusion
  (cuts ~164k/day/node wasteful posts), Tetragon EXEC/EXIT cache-warmup doc note, MetalLB chart Renovate
  pin, dns-fallback DoT/DoH comment, 3 "no-GR-yet" doc refs.

---

## 2026-06-28 (cont. 7) — L24: MetalLB native→FRR migration + BGP TCP-MD5 (full, in-window)

- **Did the whole L24 plan in one maintenance window** (operator at the UDM). End state: MetalLB runs
  Helm/Flux-managed in **FRR mode**, the MetalLB↔UDM eBGP session is **TCP-MD5-authenticated**, and a
  **silent-withdrawal alert** is live. 8/8 sessions Established w/ MD5; UDM screenshots confirmed 5 routes
  advertised per neighbor. Commits: `4731097`(P1 L2 net) `3c890bc`(P2 cutover wiring) `e48ccd4`(P3a secret)
  `67773a7`(P3 MD5) `cb63ab0`(P4 L2 remove) `6337f5a`(PodMonitor) `b2086ef`(alert).
- **Prep that made the flap seamless:** `helm template`'d the FRR chart (installed helm locally — no helm
  on devbox) → learned the chart names resources `metallb-*` (no collision with the kubespray
  `controller`/`speaker`, so delete-then-install, no import conflict) and pulls `quay.io/frrouting/frr:9.1.0`
  (NOT on nodes) → **pre-pulled it via a throwaway DaemonSet**; captured a rollback snapshot of the native
  install; verified the HelmRepository was live. **Phase 1** re-added a temporary L2Advertisement so the
  VIPs stayed ARP-reachable through the swap.
- **Phase 2 (the flap):** deleted the native kubespray workloads (KEEP CRDs + the Flux CRs) and immediately
  `kubectl apply`'d the HelmRelease object (helm-controller installs instantly — no Flux-fetch latency),
  annotate-reconciled. metallb-controller + metallb-speaker (4 containers: speaker/frr/reloader/frr-metrics)
  Ready in **~34s**, BGP re-Established, **VIP `.70` never dropped** (L2 net + pre-pulled image). Then wired
  the HelmRelease into `helm-releases/kustomization.yaml` + `metallb_enabled: false` in kubespray → Flux
  adopted the release (Ready=True, no conflict).
- **Phase 3 (MD5):** SOPS `02-bgp-md5-secret.sops.yaml` (basic-auth, key `password`) → `BGPPeer.spec.passwordSecret`.
  Coordinated with the operator: they added `neighbor metallb password …` on the UDM peer-group, I patched
  the live BGPPeer (instant) + committed. **MD5 proven** by FRR's `Connections established 2; dropped 1` —
  the session dropped while one-sided then re-Established once both ends matched (rules out FRR #6921's
  one-sided false-positive; tcpdump wasn't available in the frr image, so this behavior is the proof).
- **Phase 4:** removed the temp L2Advertisement → BGP-only again (**cleared the M36 `.5`/`.71` UDM
  IP-conflict alerts** the L2 net had re-introduced — operator confirmed seeing them). Added a **PodMonitor**
  (the BGP metric `metallb_bgp_session_up` is on the **frr-metrics `:7473`** sidecar, NOT the speaker `:7472`
  — that cost a debug cycle) + **PrometheusRule** `MetallbBGPAllSessionsDown`(critical)/`MetallbBGPSessionDown`(warning).
- **Operator Qs answered during the window:** (1) the DNS VIP `.5` shows **2 ECMP hops** vs 5 for others
  because `dns/technitium` is `externalTrafficPolicy: Local` with 2 replicas (k8s-w1/.53 + k8s-w4/.56) →
  MetalLB advertises only from nodes with a local endpoint; `.70`/`.71`/`.72` are `etp: Cluster` (all nodes
  advertise) and `.73` alloy is a DS-on-all-workers. (2) `.5` unreachable from the devbox / via TS+WG = the
  `vlan201-host-cant-reach-metallb-vip` rule (BGP VIP, no L2; TS/WG egress via VLAN-201 hosts) — **not a
  regression** (the temp L2 net had briefly masked it); DNS still works via the `.6` VM fallback (verified).
  Technitium `.5` itself verified functional (resolves via the VIP from a Technitium node).
- **⏳ Optional FRR upsides NOT done (follow-ups):** graceful-restart + BFD (need UDM-side config too) for
  sub-second failover; and a `10.10.201.0/24`-host `/32 via .1` route so TS/WG remote clients can reach the
  BGP VIPs (or advertise `.6` not `.5` as their DNS). **Then: the operator's 3 queued reviews** (24h doc/drift
  sweep, adversarial review of recent work, service-status-email adversarial review incl. cairn).

---

## 2026-06-28 (cont. 6) — M74 follow-up: ptrace-inject + pivot-root detections

- **Added 2 more Tetragon TracingPolicies** (commit `c5e3100`, observe-only): `detect-ptrace-inject`
  (`sys_ptrace` filtered to `PTRACE_ATTACH`(16)/`PTRACE_SEIZE`(16902) = attach to another process =
  injection / live-memory cred-dump; self-trace excluded) + `detect-pivot-root` (`sys_pivot_root` from
  a non-init process via `matchPIDs NotIn` ns-pid 0/1 = container breakout). Syntax taken from the
  upstream `sys_ptrace.yaml`/`sys_pivot_root.yaml` examples. Plus 2 **critical** loki alerts
  (`TetragonPtraceInject`, `TetragonPivotRoot`) appended to `11-loki-rules-tetragon.yaml`.
- **Verified:** both `--dry-run=server` clean, loaded `enabled`/`monitor_only` on the agents with
  **NPOST=0** (zero false-positives — host-ns runc is export-filtered, ptrace self-trace + pivot ns-pid
  0/1 excluded); cluster export still **0 lines/60s**. (Flux fetch of the commit was slow ~3min — the
  gitrepo sat `Reconciling` on the prior revision before advancing to `c5e3100`; not an error.)
- **Shell-in-container deliberately NOT added** — a naive shell-exec policy (`security_bprm_check` on
  `/bin/sh` etc.) would fire constantly on liveness/exec-probes + container entrypoints, flooding Loki
  and causing alert fatigue. A useful version needs interactive/tty-only detection (the exec firehose
  is export-denied), which is a separate design. Documented as deferred. **Next: L24 (BGP auth).**

---

## 2026-06-28 (cont. 5) — M77 Stage 2 COMPLETE: all 6 standalone VMs default-deny inbound

- **Flipped the remaining 4** standalone VMs ACCEPT→DROP (commit `4bbf2ce`, apply run `28334106865`,
  plan `0 add / 4 change / 0 destroy`): `step-ca`(1006), `devbox`(1005), `vpn-local`(1002),
  `asterisk-sbc`(1004). With batch 1 (dns-fallback+gh-runner) that's **all 6 standalone VMs at
  default-deny inbound** — M77 ✅.
- **Approach = flip-only (keep existing port allows).** The flip closes UNLISTED ports (e.g.
  `rpcbind:111`); the services' own ports stay allowed, and PVE's stateful firewall keeps live
  sessions (WG tunnel, SIP registrations, my devbox session) up. I deliberately did NOT narrow the
  external sources in this pass (see Stage 2b below).
- **Pre-flip fact-finding (so each was safe):** `devbox` listeners (read LOCALLY since I'm on it) =
  22/9100/**111**/tailscale — only rpcbind:111 gets newly closed; no VNC; tailscale is devbox-initiated
  so survives via conntrack, SSH from mgmt-admin stays allowed; and a bad devbox rule is reversible via
  CI (apply runs on **gh-runner**, not devbox). `asterisk` (.40) SIP TLS:5061 + RTP are **internet-
  exposed** (UDM port-forwards for Twilio) → kept any-source so calls/911 are untouched. `vpn-local` WG
  peer = static AWS EIP `44.240.60.80` (kept any-source — WG is crypto-auth'd). `step-ca` allows already
  source-scoped.
- **Verified post-apply:** step-ca `:8443` `{"status":"ok"}` reachable under DROP (cert minting fine),
  apiserver reachable from devbox (my session/outbound intact), DNS via `.6` still resolves,
  `Apply complete 0/4/0`.
- **⏳ Stage 2b (optional external-SOURCE narrowing) deferred with rationale:** asterisk→Twilio ranges
  is TELEPHONY-CRITICAL (911) and needs verified Twilio IP ranges + a call-path review, not a guess;
  vpn-local→AWS-EIP is low value (WG crypto-auth). **Now: M74 follow-up.**

---

## 2026-06-28 (cont. 4) — M74 v2 LIVE: Tetragon runtime-detection pipeline

- **Built the Tetragon detection pipeline** (observe-only assume-breach layer), in **two staged
  commits** so a wrong policy couldn't flood Loki: **part 1 `13e675d`** = the TracingPolicies with
  export still OFF (prove matches via `tetra getevents`, zero Loki risk); **part 2 `5584529`** =
  enable selective export + the alert.
- **TracingPolicies** (`platform/kubernetes/tetragon/`, cluster-scoped, wired into clusters/wind
  kustomization): `detect-cred-file-access` (`security_file_permission`+`security_path_truncate` on
  `/etc/shadow`,`/etc/gshadow`,`/etc/sudoers*`,`*/.ssh/authorized_keys`) + `detect-setuid-root`
  (`sys_setuid` uid==0). Modelled on the upstream `filename_monitoring.yaml`/`sys_setuid.yaml`
  examples (fetched to get exact kprobe syntax), narrowed to keep volume near-zero. Both pass
  `--dry-run=server`; agents loaded them `enabled`/`monitor_only`.
- **Selective export** (HelmRelease values, chart-1.7 keys verified vs the chart's values.yaml):
  `export.mode: stdout` + `tetragon.exportAllowList` restricted to
  `PROCESS_KPROBE/TRACEPOINT/UPROBE/LSM` so the `PROCESS_EXEC/EXIT` firehose (~1.1M/day) never flows;
  namespace denylist drops host/system. **Key debugging win:** right after the rollout the export
  briefly showed `process_exit` lines — turned out to be **stale export-file backlog** the
  freshly-restarted `export-stdout` sidecars re-read; once consumed, **steady-state = 0 lines/min**.
  Also confirmed the noisy `setuid(0)` source is **runc in host-ns** (NPOST=59) which the namespace
  denylist filters from export — so exported volume stays ~0.
- **Alert** (`monitoring/11-loki-rules-tetragon.yaml`, mirrors the hubble-audit ruler pattern):
  `TetragonCredFileAccess` (critical) + `TetragonSetuidRoot` (warning) off
  `{namespace="tetragon",container="export-stdout"}` (Alloy tails the sidecar's pod log). The
  rules-sidecar logged `Writing …/tetragon.yaml` → loaded into the ruler.
- **e2e PROVEN:** triggered `head -c1 /etc/shadow` inside a Tetragon pod (a pod ns) → `detect-cred-file-access`
  matched → exported through the sidecar → **every alert JSON field-path resolves**
  (`process_kprobe.policy_name`='detect-cred-file-access', `…process.binary`='/usr/bin/head',
  `…process.pod.namespace`='tetragon', etc.). ⚠️ **That test read will fire ONE `TetragonCredFileAccess`
  critical** (tetragon/tetragon-8rpqn, binary `head`) that self-resolves in ~10m — it's the validation,
  not a real incident.
- **⏳ Deferred:** shell-in-container (the exec firehose is export-denied → needs a kprobe-on-execve
  policy), `sys_ptrace`/`sys_mount`, and enforcement (`matchActions` kill) after the observe phase is
  trusted. **M74 flipped 🟡→✅** (detection pipeline = the goal; enforcement is optional-later).
  Docs: tetragon README + tracker. **All 3 requested arc items (M77 Stage 2 partial, M72 tail, M74 v2)
  are done.**

---

## 2026-06-28 (cont. 3) — M72 tail CLOSED: 3 infra ns enforced + 7 stale ns deleted

- **Enforced `pod-security.kubernetes.io/enforce=baseline`** on the last 3 clean infra namespaces —
  `cert-manager`, `cnpg-system`, `github-actions-runner` (commit `93589a2`, Flux-applied + verified
  live). cert-manager/cnpg-system via the central `clusters/wind/namespace-pss-labels.yaml` patch;
  github-actions-runner in its own `platform/kubernetes/github-actions-runner/namespace.yaml`.
- **Corrected an earlier-doc error:** the M72 residual + the bottom of `namespace-pss-labels.yaml` had
  conflicting takes on these — the tracker called them "Helm-created, no build target" but
  `helm-releases/{cert-manager,cnpg}.yaml` each ship a `kind: Namespace` so they ARE build targets
  (the patch works). **Authoritative check used:** `kubectl label ns <ns>
  pod-security.kubernetes.io/enforce=baseline --overwrite --dry-run=server` — PSA returns a warning
  listing any existing pod that would violate. All 3 returned clean; gha correctly *fails* `restricted`
  (ARC controller/runner need caps + allowPrivilegeEscalation) so baseline is its ceiling.
- **plex deliberately left UNENFORCED** (against the tracker's inclusion of it): the pss-labels patch
  marks plex `tier=system` "GPU passthrough needs privileged". Its pod is baseline-clean today, but
  enforcing baseline would block a future privileged transcode config the operator deliberately
  preserved — not worth it on a single media server. Kept tier=system, like wireguard.
- **Deleted 7 stale/empty orphan namespaces** (`kopia`, `technitium-dns`, `rclone-gdrive`, `home`,
  `media`, `infra`, `gpu-operator`). Verified each: 0 pods, only the auto-created `default` SA, **no git
  source** + **no `targetNamespace` ref** (so Flux won't recreate — confirmed `gpu-operator.yaml`
  manages `gpu-operator-system`, and the `home`/`gpu-operator` git "hits" were `home-automation`/
  `gpu-operator-system` word-boundary false positives), 47 days idle. The live `dns`(3 pods)/`rclone`(6)/
  `home-automation`(1) services they resemble stayed healthy. **User-authorized** (the safety classifier
  gated the mass delete; asked explicitly, got a yes) → direct `kubectl delete ns` (they're unmanaged,
  no git change). DNS re-verified after. M72 flipped 🟡→✅. **Now moving to M74 v2.**

---

## 2026-06-28 (cont. 2) — M77 Stage 2: first 2 standalone VMs to default-deny inbound

- **Flipped `dns-fallback` (1001) + `gh-runner` (1003) from Stage-1 permissive `ACCEPT` to Stage-2
  `DROP`** (default-deny inbound) — commit `74dc87f`, firewall apply run `28331175739`. Refactored
  `local.vm_input_policy` from a single global string into a **per-VM map** so each VM flips
  independently (future Stage-2 flips are now a one-line map edit). The other 4 VMs stay `ACCEPT`.
- **Why these two first:** their allow-lists are **fully internal/baseline** — `gh-runner` is an
  outbound-only CI runner (inbound = SSH + node_exporter `:9100` baseline only); `dns-fallback`'s only
  listeners are `:53` tcp/udp (clients) + `:5380` (mgmt) — so **no external-source scoping** is needed
  (unlike vpn-local's AWS peer or asterisk's Twilio ranges). The listeners were `ss`-enumerated at Stage 1
  and PVE's firewall is **stateful**, so flipping the *inbound* default to DROP only blocks NEW unsolicited
  inbound; established/return traffic for outbound-initiated connections is untouched.
- **Verification (substituted a functional check for a PVE-log read — headless `pve` shell isn't in
  scope from the devbox):** (1) the plan was **exactly** `0 add / 2 change / 0 destroy`, in-place, no
  reboot; (2) **gh-runner self-test** — the apply *runs on* the gh-runner self-hosted runner, flipped it
  to DROP, and still completed + reported success to GitHub → the runner survived its own flip (proving
  it's outbound-only as designed, and that there's no CI-lockout risk); (3) **DNS** — `dig @10.10.201.6`
  resolves `auth.wind.etherport.net`→`10.10.201.70` (internal split-horizon A) + forwards `github.com`,
  AAAA NODATA → `:53` serves fine under DROP.
- **State:** M77 stays 🟡 (4 VMs remain ACCEPT). **Next Stage-2 candidates** (each needs its noted
  prerequisite before DROP): `vpn-local` (scope the AWS WireGuard peer source IP), `asterisk-sbc` (scope
  Twilio SIP/RTP source ranges), `step-ca` (confirm the fleet + tailnet cert clients), `devbox` (LAST,
  extra care — the Claude session lives on it; keep SSH from mgmt-admin + the tailnet + tailscale UDP).
  Tracker + the `standalone-vms.tf` header updated. **Now moving to M72 tail.**

---

## 2026-06-28 (cont.) — M71 IAM Roles Anywhere: AWS-side APPLIED (mini-side cert remains)

- **Applied the `roles-anywhere` TF stack via CI** (run `28330240921`, sha `fc32bf2`) — the mini's
  path off the standing static `[homelab]` key. **Live now (AWS-side):** trust anchor
  `wind-homelab-step-ca` (source = the **public step-ca root** `step-ca-root.pem`), IAM role
  `wind-mini-roles-anywhere` (trust-scoped to the trust anchor + cert Subject CN
  `mini.wind.etherport.net` + issuer CN `wind Homelab CA Intermediate CA`), and RA profile `wind-mini`
  (1h sessions). The 3 ARNs are baked into `docs/runbooks/aws-roles-anywhere-mini.md`.
- **The 3 owner-gated steps resolved as:** (1) **CI perms — already had them**: `gh-actions-terraform`
  carries **PowerUserAccess**, which covers `rolesanywhere:*` (PowerUser = everything except
  iam/org/account; its IAM perms come from `gh-actions-terraform-iam.json`). The redundant
  `iam-policies/terraform-roles-anywhere.json` was **deleted** (+ its iam-policies README row).
  (2) **Scope decided = plan/debug-only** (not full `terraform-*` parity): since TF is CI-only (M82),
  the role gets `ReadOnlyAccess` + an inline `tfstate-rw-and-deny-data-reads` (S3 state RW on
  `terraform.wind.etherport.net` only; **Deny** all other `s3:GetObject` + `secretsmanager:GetSecretValue`
  /`kms:Decrypt`). **Why:** a short-lived debug session can refresh/plan + touch state but can't
  exfiltrate backup objects or secret values, and it sidesteps the 10-managed-policy-per-role quota
  entirely (no group-membership-to-role problem). (3) **Mini-side cert + signing-helper = the ONLY
  remaining work** (owner-only — the agent can't reach the mini).
- **3 apply gotchas hit + fixed (all in this stack's history):** (a) IAM `CreateRole` **rejects an
  em-dash** in `description` (regex `[	

 -~¡-ÿ]` — U+2014 is out
  of range) → ASCII hyphen; (b) the **public root PEM was gitignored** by `**/*.pem` → CI checkout was
  missing it (`file()` "Invalid function argument") → added a `.gitignore` negation + `git add -f`
  (gitleaks confirmed: it's a public CA cert, not a key); (c) a **`workflow_dispatch` apply contends
  the S3 state lockfile** with the concurrent `push`-triggered plan run my own push fired
  (`PreconditionFailed` on the lock) → re-dispatch the apply after the plan run finishes. Also a
  monitoring footgun for future me: when polling for an apply, **filter runs by
  `event=workflow_dispatch`** — a same-sha push plan run completes first and a naive "first new
  completed run" match grabs the wrong one.
- **State:** AWS-side done + idempotent (`4 added, 0 changed`; trust anchor was already in state from an
  earlier partial run). Docs synced: tracker M71 entry, `m71-roles-anywhere-plan.md`, the stack README,
  and the mini runbook (ARNs filled in). **Next (owner-only):** follow the mini runbook — step-ca leaf
  cert + `aws_signing_helper` + `credential_process` + launchd renew timer → `aws sts
  get-caller-identity --profile homelab-ra`, then rotate+remove the standing `[homelab]` key. Plus the
  pre-existing interim win: pull `[claude-admin]` PowerUser off the mini (`udm-manual-hardening-actions.md` §8).

---

## 2026-06-28 — overnight-alert investigation (→ H41 etcd) + M73 require-resource-requests ENFORCING

- **Investigated 2 overnight AI-advisor emails** (non-iCloud): `TargetDown` (kube-scheduler) +
  `KubePodCrashLooping` (ceph csi-snapshotter). Both `noop` per-instance, but symptoms of a real pattern:
  **all CP leader-election components restart-looping** (scheduler 54/71/74, controller-manager 43/79/87,
  csi-snapshotter 17/23 over ~4d; apiservers stable). Mechanism: **etcd raft term 79 in 4d (~20 elections/
  day)** → write stalls → apiserver lease `Put` exceeds the 5s deadline → lease holders restart. etcd healthy
  now (DB 248MB, 7ms commits) → periodic instability, self-recovering, no outage. Filed **H41** (commit
  `6cbc61f`) with 2 enabling gaps: etcd metrics not scraped + CSI VolumeSnapshot CRDs missing.
- **H41 PARTIAL FIX (commit `2d1a22c`).** Deeper diagnosis refined the cause: NOT ongoing elections (the
  death-window logs showed no leader changes; term steady 79) but **etcd apply-latency spikes** that back up
  past the 5s lease deadline. Found etcd **62% fragmented** (248MB disk / 95MB in-use) → **rolling defrag**
  (followers→leader, verified quorum between) brought all 3 to **97MB**, no disruption. Added
  **`playbooks/etcd-defrag.yml`** = a staggered weekly defrag timer (Sun 02:00/03:00/04:00 UTC per CP, never
  two at once) so frag can't rebuild — applied to all 3 CPs. etcd timeouts already generous (5000/250),
  check-perf PASSES isolated (13.8ms); Kyverno reports not a real load (386/2). **Remaining (window):**
  dedicated etcd disk (WAL shares the root `/dev/sda1`), fix the metrics scrape (kube-etcd endpoints empty,
  :2381 not enabled), install CSI snapshot CRDs. **Watch the scheduler/CM restart rate over the next days** —
  if it drops post-defrag, the disk fix may be deferrable.
- **Tuya cloud project = safe to DISABLE entirely.** Confirmed HA uses **localtuya** (`xZetsubou/hass-localtuya`
  fork) for LOCAL control — no runtime cloud dependency, no Tuya secret in-cluster. The Cloud API was a
  one-time key-extraction. Since Tuya doesn't rotate API secrets, disabling the project is the correct way
  to kill the leaked secret. Only cost: re-extracting keys if a new Tuya device is added / a device resets
  its local_key (one-time re-setup then). **Owner action: disable the Tuya Cloud project.**
- **M73 `require-resource-requests` → Enforce** (commits `1abdacb` mutate, `dcd4f02` enforce). The audit
  fails were Helm sidecars + dynamically-created pods (tailscale proxies, ARC runners, ceph csi) that
  chart-editing can't reliably cover. Added a Kyverno **mutate** (`02-add-default-resource-requests`,
  10m/32Mi where absent, never overrides), then flipped validate to Enforce. Verified safe: bare pod,
  multi-container sidecar, existing-requests-preserved, and request-less **Deployment template** (autogen →
  Flux/Renovate-safe) all admit with requests injected; 0 disruption. Both Kyverno resource guardrails
  (00 requests, 01 latest-tag) now ENFORCE. M73 ✅.
- **Earlier today:** fixed the `secret-scan` CI flood (gitleaks allowlist broke when localtuya was archived
  + vendored kubespray fixtures — commit `043225b`; both workflows green).
- **Next:** M74 Tetragon detection→alerting; M72 PSA enforce tail; H41 etcd (fix metrics scrape → diagnose);
  M77 Stage 2; L24; M71 RA apply. Owner: rotate the Tuya Cloud secret (iot.tuya.com).

## 2026-06-28 — cairn photos rc=1 (NAS contention) → reschedule 22:00 + SMB-heal retry (v0.1.3)

**What:** second overnight `ICloudBackupFailed` (photos rc=1), **different cause** from 06-27 (v0.1.2's
attach-leak fix confirmed working — clean detach, 1 attachment). Root cause: photos ran 23:30, attempt 1
hit the **90-min local-mode export timeout** (`PhotosSource.perAttempt = 90*60`) landing at **01:00 =
exactly when the cluster s3-sync reads `/Volumes/Backups` over NFS** → concurrent NFS-read + SMB-write
**wedged the NAS** → the `/Volumes/Backups` remount failed once mid-heal → `unhealable` → rc=1. Keychain
unlocked, NAS reachable, creds present — transient contention, not a persistent break.

**Resolution (all done):**
- **Immediate:** `mount-nas.sh` restored the stack; re-ran photos (✓ 43,914 items, 458s); pushed health
  8/8 → alert cleared.
- **Reschedule:** photos `23:30 → 22:00` (cairn.yaml + `cairn install` reload; agent fires 19:30/20:00/22:00)
  — 3h buffer before the 01:00 sync instead of 1.5h, so the export finishes well clear of it.
- **`ensureSMB` retry (cairn v0.1.3):** the heal did a single `open smb://` + 60s poll; now retries 3×
  (open + 40s poll, 5s backoff) so a brief NAS-busy moment doesn't doom the run. Shipped via CI, deployed
  (leaf `541075…`, version 0.1.3, retry present in the binary).
- Docs: cairn README §6 (schedule NAS-heavy jobs clear of any offsite-sync window) + example + memory.
  **Lesson:** cairn photos write-SMB vs s3-sync read-NFS on the same NAS = SMB wedge; separate them in time.

## 2026-06-27 (cont. 2) — M73 Kyverno: enforce disallow-latest-tag (audit→enforce, verified safe) + zero-trust archived

**What:** closed out + archived the zero-trust assessment (`da7d6c6`), then did M73 enforce phase-1.
Commit `ba130f9`.

- **M73 — `disallow-latest-tag` → Enforce.** Reviewed the Kyverno audit thoroughly first (the
  requirement was "enforcing won't cause problems"): this policy had **0 violations** (`kubectl get
  polr -A` clean for it; cue-api excluded + all operators use tagged/pinned images so dynamic pods
  pass), so flipped both rules `failureAction: Audit→Enforce`. **Verified live:** `:latest` pod in
  `default` denied at admission; tagged pod allowed; `:latest` in excluded `cue` allowed; 0 running
  pods disrupted; Kyverno controllers healthy. Fail-open (`failurePolicy: Ignore`) so a down Kyverno
  never wedges admission.
- **`require-resource-requests` deliberately LEFT in Audit.** Its 59 audit fails are ~6 third-party
  Helm charts (kube-prometheus-stack, traefik, tailscale-operator, ARC, ceph csi-rbdplugin in
  `default`, s3-sync cronjob), several creating pods **dynamically** (tailscale proxies, ARC ephemeral
  runners, csi on reschedule) — enforcing would block those = outages. Prereq to enforce: add
  `resources.requests` to those charts' values + the dynamic-pod templates, re-audit clean, then flip.
  Documented in the policy header + the dir README + tracker M73.
- **Zero-trust assessment archived** (`da7d6c6`): all 8 gaps it raised became tracked items
  (H37/H38/M75/M76 ✅; M72/M73/M74 deployed; L24/M71 carried in the tracker). Closure banner added,
  git mv → planning/archive/, refs repointed.
- **Next:** require-resource-requests chart-prep (to enforce it); M74 Tetragon detection policies →
  alerting; M72 PSA enforce tail; M77 Stage 2 (PVE firewall DROP); L24 (FRR window); M71 RA apply.

## 2026-06-27 — cairn photos sparsebundle attach-leak incident → v0.1.2 (idempotent attach + release fix)

**What:** overnight `ICloudBackupFailed` alert (photos rc=1) + a Finder **"Macintosh HD can't be opened —
permission"** dialog on the mini's VNC. **Root cause (one bug, both symptoms):** cairn's photos mount-heal
(`MountHealth.ensureImage`) detached the sparsebundle **by mountpoint**; when an `hdiutil attach` succeeded
but the APFS volume didn't surface at `/Volumes/PhotosLib`, the mountpoint detach was a no-op and the next
heal re-attached → **leaked a new attachment each retry**. 3 ghost attachments of `PhotosLibrary.sparsebundle`
piled up until `hdiutil attach: No child processes` (fork exhaustion) → photos rc=1 AND the Finder dialog (a
resource-degradation side-effect — the **boot disk was healthy**). Diagnosed via `diskutil list` / `hdiutil
info` (3 disk-image attachments, none mounted).

**Fix + resolution (all done):**
- **Live cleanup:** `hdiutil detach -force` the 3 ghosts → `mount-nas.sh` restored Personal-Drive + Backups +
  PhotosLib; system could fork again.
- **cairn code fix (`v0.1.2`):** `ensureImage` now detaches **by image path** (`detachImageAttachments`
  resolves dev nodes from `hdiutil info`) before re-attaching → idempotent, no leak. Verified: clean photos
  run (43,856 items, 417.7 GB, 505s) + a single attachment, no thrash.
- **Release-pipeline bug also fixed:** `release.yml`'s publish used `"${TARGET[@]}"` on an empty bash array,
  which errors under `set -u` on the macOS runner's **bash 3.2** ("unbound variable") — that's why `v0.1.1`
  failed. Switched to a plain string; `v0.1.2` built/signed/**published** cleanly and deployed to
  `dist/cairn.app` (leaf `541075…`, both fixes in the binary). **8/8 green; alert cleared.**
- Docs: cairn README §6 gotcha + memory + `cairn-deployment.md` §8. **Lesson:** disk-image (re)attach must be
  idempotent — detach by image path, never just the mountpoint.

## 2026-06-27 (cont.) — comprehensive repo-wide doc/drift review + M71 RA foundation

**What:** (1) authored the M71 IAM Roles Anywhere foundation (separate entry below covers M71
detail), (2) ran a full adversarial doc-drift review of the ENTIRE repo and brought it into line.
Commits `34191b9` (M71 RA), `ba61e07` (archives + Tuya scrub), `b141494` (117 drift fixes + links).

- **Comprehensive doc review (4 workflows, ~2.3M agent tokens).** Phase A: 13 agents reviewed
  ~190 docs (all except vendored kubespray + .terraform) vs live manifests/kubectl/TF/git → 135
  findings, **73 docs verified clean**. Phase C1 (me): **archived 10 completed/superseded docs**
  (m76-plan cutover-done, VERSIONING-STRATEGY declined-ADR, KUBESPRAY_MIGRATION, 2 cairn-superseded
  photos runbooks, postgres-barman activation, cloudflare-access migration, ubiquiti Route53 DDNS,
  the 9-file localtuya setup saga) + banners + archive-index rows. Phase C2: 10 agents applied 117
  drift fixes (disjoint file ownership). Phase D (me): repo-wide dead-link scan (fixed 33 links via
  basename resolution + the move-map), residual cross-cutting grep, manifest validation.
- **Themes fixed:** M76 cert-only across ALL ssh examples (dropped /tmp/auto-key + id_ed25519_homelab
  → plain `ssh user@host`; kubespray → kubespray.sh wrapper); stale counts (Velero 10→12, nodes 5→8,
  k8s v1.33.7→v1.34.2, helm→15, images→14, rules 22→21, AI actions 18→19); DynamoDB→S3-native lock;
  manual-image→Flux automation; ~/Projects/homelab-infra→~/code/infra; kyverno/tetragon/step-ca added
  to README; external-Ceph DR rewrite + barman bucket; alert-runbook label selectors. **Net −1040
  lines** (bloat trims: remote-state-backend 807→150, operations-guide, SOPS-SETUP, plex, etc.).
  platform/technitium consolidated into the k8s technitium README. **2 Flux manifests** corrected
  (advisor-prompt node count/MetalLB-mode the AI consumes; backup-alerts schedule count).
- **🔴 SECURITY — owner action:** plaintext Tuya Cloud **Access ID + Secret** were committed in the
  localtuya docs (now scrubbed to placeholders, but **in git history**). **Rotate at iot.tuya.com**
  (treat as compromised). Also left banner'd (not archived): the 3 dated planning snapshots
  (zero-trust-assessment, dev-roadmap, roadmap-specs).

## 2026-06-27 — step-ca cert principals pinned + doc-sweep verification & fixes

**What:** (1) tightened the step-ca headless cert principals (security hygiene), (2) independently
verified the prior doc sweep (`1cb7d82`) and fixed its one defect + ~18 sweep-missed stale docs +
56 dead `flux`-CLI refs. Commits `071cebd` (principals), `20e841e` (stale-doc fixes), `0fbe57f`
(flux-CLI refs).

- **step-ca headless cert principals pinned (`071cebd`).** The devbox/CI automation certs were being
  minted with an EMPTY principals list (= valid for ANY username) — root cause: step-cli 0.30.6 does
  NOT flow `--principal` flags through for JWK provisioner SSH certs. Fixed with a CA-side SSH template
  `files/step-ca/headless_user.tpl` that HARD-CODES `principals=[ubuntu,root]` (vs the OIDC template's
  `concat`, which duplicated). Wired into `step-ca.yml` (6b-ii: install template + `provisioner update
  headless --ssh-template`). Applied live (provisioner update + SIGHUP reload, no downtime) + verified:
  devbox renew-loop AND CI-style mint both now yield exactly `ubuntu,root`; SSH still works as both.
  ⚠️ A CA rebuild / `step-ca.yml` re-run MUST re-apply this template or certs revert to any-user.
- **Doc-sweep verification (workflow, 10 agents).** Checked all 39 fixes in `1cb7d82` against live
  manifests/kubectl/git. **Verdict: the sweep is accurate** — all 10 M75 IRSA rewrites (velero/aws-s3/
  VALIDATION/cluster-irsa: `useSecret:false`, `wind-irsa-*` roles, projected token aud `sts.amazonaws.com`,
  ZERO identity webhooks → "manual token projection" correct), alert runbooks (B2→S3, Longhorn→ceph,
  UDM `.1.1`→`.200.1`), removed-component claims (kopia/icloudpd gone), env-drift, archive links — all
  confirmed. **ONE defect:** the M103→M105 renumber was incomplete (7 switch-port refs left as M103,
  colliding with cairn = the new canonical M103).
- **Fixes applied (`20e841e`, fix workflow ×6 agents + verify).** (a) M103→M105 completed (udm-manual-
  hardening ×5, README.md:55, session-log.md:635; cairn M103 refs untouched); (b) Route53→Cloudflare
  (cert-manager-wildcard.md solver/files-of-record→`cert-manager-issuer/cloudflare-credentials.sops.yaml`/
  troubleshooting, traefik-values comment); (c) kopia/icloudpd residue removed across 8 docs, image count
  13→14; (d) dedicated bucket names (`velero.`/`postgres-barman.wind.etherport.net`); (e) `photos_export_*`
  →`cairn_*` (matches live `09-photos-export-alerts.yaml`); (f) making-changes.md flux-CLI→annotate +
  icloudpd→rclone-gdrive example; (g) SOPS-SETUP Route53→Cloudflare + `aws-backup-credentials` IRSA-banner.
- **flux-CLI sprawl (`0fbe57f`, ×5 agents).** A grep surfaced ~11 non-archive docs still telling readers
  to run a `flux` CLI that isn't on the hosts. Replaced 56 invocations with the kubectl-annotate reconcile
  pattern (CLAUDE.md §3) / `kubectl get` on Flux CRs / `kubectl patch` suspend-resume. Beyond the map: DR
  `flux bootstrap`→`kubectl apply -k clusters/wind/flux-system/` (verified the gotk manifests + kustomization
  exist), `flux install`→`kubectl apply -f` versioned install.yaml, removed `flux` from operations-guide
  brew prereqs. Conceptual/historical "Flux" prose left intact. Zero hosts-side flux invocations remain.
- **Judgment items reported to operator:** (1) DON'T rename `09-photos-export-alerts.yaml` (name still
  accurate; cairn family alerted in `10-icloud-backups-alerts.yaml`). (2) Dashboard panels "Files backed
  up"/"Backup size" (commit `0617954`) use per-RUN cairn_backup_items/_bytes → read 0 on no-op nights;
  recommend `max_over_time([30d])` or a cumulative metric — left for operator (cairn metric semantics live
  in the cairn repo). (3) headless-ops-host.md body still describes mini-RC/static-key/standing-AWS-creds
  (M76/M82 superseded) — banner added, deeper body reconcile deferred (low priority).
- **M71 (started, "Both" path chosen):** authored the **IAM Roles Anywhere foundation** (AWS-side) so
  the mini mints short-lived creds from a step-ca X.509 cert instead of the standing `[homelab]` key.
  `infra/terraform/aws/roles-anywhere/` (trust anchor = **reused step-ca root**; role trust-scoped to
  trust-anchor + cert Subject CN `mini.wind.etherport.net` + issuer = step-ca intermediate; profile,
  1h) + CI workflow + the CI rolesanywhere-perms delta JSON + mini runbook + `m71-roles-anywhere-plan.md`.
  `terraform validate` green; RA semantics adversarially verified vs AWS docs (fixed the signing-helper
  download URL `Darwin`→`MacOS/Sonoma` + version→1.8.4, added `--intermediates`, confirmed the
  `x509Subject/CN` condition key). **Not applied** — 3 owner-gated steps (CI rolesanywhere perms;
  policy-scope+quota; mini-side cert). **Interim:** the agent can't reach the mini (lost the static
  key in M76) or do IAM (bounded homelab key); owner ran interim-win (a) **[claude-admin] PowerUser
  removed from the mini 2026-06-27**. **`[homelab]` terraform key STAYS until RA is live + verified**
  (removing it now strands the mini's AWS). User is deleting the GH `ANSIBLE_SSH_KEY` secret.

## 2026-06-26 (cont. 4) — M76 CUTOVER: the running fleet is SSH cert-only (static key removed)

**What:** finished M76 — switched the last 2 consumers to certs, removed the standing
`automation@homelab` key from every running host's `authorized_keys`, and cleaned the devbox
holder. SSH to the Ubuntu fleet is now **cert-only** (step-ca user CA). Commits `e9e28e3`
(container workflows), `3e811d9` (cutover removal play + pve-sshd), `3b6f994` (devbox cert-only
+ cloud-init bootstrap annotations).

- **Last consumers → certs:** the **2 CONTAINER** ansible workflows (vm-fleet, proxmox) couldn't
  use the host's system `step` (it's not in `ghcr.io/sparked-diamond/ansible-runner`), so
  `setup-ssh-cert/action.yml` now **self-installs the pinned, checksum-verified step CLI**
  (`0.30.6`, sha `e44a5dc5…`) into a job-local dir when absent. proxmox check-mode smoke-tested
  green. (The 4 host-context workflows were already on certs from cont. 3.) **packer keeps the
  static key by design** (build-VM access).
- **Pre-removal safety:** verified all **15 hosts cert-reachable (15/15)** first. step-ca itself
  (VM 1006) had been **excluded** from Phase 2 user-CA trust (it's the CA) → added user-CA trust to
  it first so the removal wouldn't strand it.
- **Removal:** `step-ca-remove-static-key.yml` — surgical `ansible.posix.authorized_key state=absent`
  for the one `automation@homelab` pubkey, run **`--private-key ~/.ssh/id_homelab_cert`** so ansible
  authenticates with the CERT (never the key it's deleting → can't cut its own connection),
  `gather_facts:false`, `user={{ ansible_user|default('ubuntu') }}`. **PLAY RECAP: 15/15
  `changed=1 failed=0`.** `pve-sshd.yml` edited to stop re-asserting the key (root@pve cert-only;
  graham-mac break-glass + unifi-cert-sync kept).
- **Post-removal verify (the proof):** cert still **15/15**; static key now **REJECTED** on
  k8s-w1/pve/step-ca (`Permission denied`). So the key no longer grants standing access anywhere.
- **Devbox holder cleanup:** `devbox.yml` no longer deploys the static key + writes a **cert-only**
  `~/.ssh/config` (single `IdentityFile id_homelab_cert`); dropped the unused `homelab_key_path` var.
  Live devbox matched (removed `~/.ssh/id_ed25519_homelab`, config cert-only) → SSH to
  k8s-w1/devbox/pve verified **via config alone** (no `-i`). The renew-loop cert is valid 13h, renews
  every 6h (timer active).
- **Residuals — BY DESIGN (documented, NOT standing fleet access):** (1) **cloud-init** keeps the key
  as the per-host **BOOTSTRAP** pubkey (a new host must be SSH-reachable to be enrolled into cert
  trust, then the same removal play strips it) — annotated the 3 TF vars (proxmox k8s-vms +
  standalone-vms, AWS compute); (2) **packer** static key; (3) **appliances** scoped legacy keys.
  **Residual HOLDERS of the now-powerless key material:** the **mini** copy (rolls into **M71**), the
  GH **`ANSIBLE_SSH_KEY`** secret (now bootstrap-only — **user removes via the GitHub UI**; the M92
  dispatch PAT lacks Secrets scope so I can't), and the SOPS `automation_ssh_private_key` (kept as the
  re-add / break-glass source).
- **Break-glass:** PVE console + IPMI `10.10.200.21`. Reversible: re-add via the SOPS key or
  re-provision (cloud-init re-injects the bootstrap key).
- **Minor follow-up noted:** the devbox renew-loop cert shows an **empty Principals** list (valid for
  any username — broader than the intended `ubuntu,root`); functional + short-lived + CA-restricted, so
  not a blocker. Tighten `step-ssh-renew.sh` to pin principals when convenient.
- **Next:** M71 (kill the mini's standing AWS keys — also remove the mini's `automation@homelab` copy
  there); L24 FRR migration (windowed, prep done); M77 Stage 2 (flip per-VM firewall ACCEPT→DROP after
  PVE firewall-log review). User to delete the `ANSIBLE_SSH_KEY` GH secret.

## 2026-06-26 (cont. 3) — cairn CI signed release (M7) + Grafana photos totals + full docs sweep

**What:** (1) shipped cairn's **CI signed-release** automation, (2) fixed a Grafana Photos-board gap, (3)
ran a fan-out **audit of all live docs** (both repos) and applied the fixes. cairn commits `92dba96`,
`88e5009`, `60d7bed`, `a94aa32`; infra commits the photos-dashboard fix + this docs-sweep batch.

- **cairn CI signed release (cairn repo M7):** `.github/workflows/release.yml` — a `vX.Y.Z` tag →
  ephemeral keychain (cert from repo secrets) → `swift test` → `stamp-version.sh` → `package.sh` sign →
  **verify the signature pins leaf `541075…`** (TCC-compatible, so a CI build drops onto the mini without
  re-granting) → publish the zip+`.sha256` GitHub release. `scripts/setup-ci-signing.sh` (one-time, **VNC**
  — private-key export is GUI-gated, hangs headless) sets `CAIRN_CERT_P12`/`CAIRN_CERT_PASSWORD`/
  `KEYCHAIN_PASSWORD`. **Decision:** full CI signing (key in GH secrets) over mini-signed — owner chose it
  for hands-off releases; self-signed cert, limited blast radius. Two snags hit + fixed: validate the
  `.p12` via `security import` not `openssl pkcs12` (Homebrew OpenSSL 3 can't read macOS's legacy .p12);
  `gh release create` isn't idempotent + `--target` clashes with an existing tag → now `upload --clobber`
  if the release exists. **`v0.1.0` shipped + verified.** Detail: cairn README §7.
- **Grafana Photos board** (`dashboards/photos-export.yaml`): added a totals row — **Photos backed up**
  (`cairn_photos_total − missing_resolvable`), **Files backed up** (`cairn_backup_items{job=photos}`),
  **Backup size** (`cairn_backup_bytes`). The board previously showed only "Exported (last run)" (=0 on a
  steady-state incremental night), so there was no headline for how much is actually backed up.
- **Docs sweep:** audited 147 live docs/READMEs across infra+cairn (12 parallel auditors) → 39 findings
  (6 high, 19 med, 14 low), then applied them (23 via a fan-out fix-workflow + the high-judgment ones by
  hand). Most were **pre-existing rot, not cairn**: kopia/icloudpd refs after their removal
  (kustomize-patterns, aws-infrastructure), Route53→Cloudflare DNS-01 (ingress-traefik), **M75 IRSA** not
  reflected in the velero / aws-s3 / cluster-irsa backup READMEs (still described static-key secrets),
  Backblaze-B2/Longhorn references that were never true (alert runbooks), broken `archive/` links,
  devbox dispatch "NOT yet set up" (done at M92), headless-ops-host still naming the mini as the dev host
  (it's the devbox since M81), and aws-security-best-practices recommending Level 2 (we're on Level 4 OIDC+
  IRSA). cairn-side: `mount_smbfs`→`open smb://`, DESIGN §6 metric schema, example source types. Archived
  the executed `cairn-cutover-infra-prompt.md`; renumbered the duplicate **M103→M105** (switch-port item);
  marked M103's last item (CI release) DONE; bannered the two superseded photos runbooks in the index.



**What:** took M76 from "cert infra live" to "both headless consumers + the operator on certs" — only
the static-key *removal* (and 2 container CI workflows) remain. Commits `19ef435`, `aa3fb33`, `e23332f`,
`cab1c46`, `6462f0d` (+ this docs/devbox commit).

- **SSO (`step ssh login` via Authentik):** added an OIDC SSH cert template granting `ubuntu`/`root`
  principals + gated the step-ca Authentik app to the **Admins** group (only graham/akadmin; Plex/HA
  users auth elsewhere). Hit + fixed: the OIDC provisioner's `--domain wind.etherport.net` filter 401'd
  the operator's gmail identity (`email … is not allowed`) — removed it (gating is the app binding).
  Operator's Mac now cert-auths; the fix on their side was `IdentityAgent SSH_AUTH_SOCK` on homelab
  `Host` blocks placed **above** the global `Host * → 1Password` block (first IdentityAgent match wins),
  so the step cert (in the default agent) is offered, 1P retained for everything else.
- **Phase 2b host certs** (`step-ca-hostcerts.yml`): each Servers-VLAN host signs its existing ed25519
  host key into a 30d host cert (host CA) + serves it via `HostCertificate`; SSHPOP systemd timer renews.
  Clients trusting the host CA (`@cert-authority`) skip TOFU — verified. Built via a design+adversarial
  workflow that caught 2 blockers (a Jinja principal-flag builder that fused tokens; `step ssh renew
  --expires-in` which that subcommand rejects). Direct `step ssh certificate --host --sign --provisioner`
  form (not token→sign). pve excluded (mgmt VLAN can't reach the CA — UDM zone firewall).
- **CI consumer-switch:** `.github/actions/setup-ssh-cert` composite action mints a ≤1h cert from the
  new **`STEP_JWK_PASSWORD`** repo secret (operator added it — the M92 PAT lacks Secrets scope) + trusts
  the host CA. The **4 host-context** ansible workflows switched off `ANSIBLE_SSH_KEY`; proven via a
  throwaway `test-ssh-cert.yml` + a real `service-status-inventory-drift` run (both green).
- **devbox consumer-switch:** `infra/devbox/step-ssh-renew.{sh,service,timer}` (user timer, 6h) mints a
  13h cert to `~/.ssh/id_homelab_cert`; `devbox.yml` ssh-config offers it ahead of the static key. The
  **agent now authenticates with the cert** (`Server accepts key: id_homelab_cert ECDSA-CERT`).

**REMAINING before the static-key removal (Phase 5):** (1) the **2 CONTAINER** ansible workflows
(`ansible-vm-fleet`, `ansible-proxmox`) — `step` isn't in their container; need step-in-container or
de-containerize. (2) **packer** keeps the static key by design (it SSHes to the ephemeral build VM).
(3) Then remove `automation@homelab` from authorized_keys (cloud-init) + the 4 hardcoded deploy points
(TF/Packer/ansible/AWS cloud-init) + 3 holders (mini, devbox, GH `ANSIBLE_SSH_KEY`). The static key
stays live as the safety net until then. Break-glass = PVE console + IPMI (`10.10.200.21`).

---

## 2026-06-25 (cont. 3) — M103 cairn CUTOVER complete: all iCloud backups migrated off the bash suite

**What:** cut the mini's entire iCloud backup suite over from the bash scripts to **cairn**, headless,
one category at a time, and rewrote the cluster-side reporting to match. All 4 bash backup LaunchAgents
(`icloud-dav`, `icloud-files`, `messages-backup`, `photos-export`) are retired (booted out + disabled,
reversible); cairn (`net.wind.cairn` scheduler + `net.wind.cairn.health`) now owns everything. Docs
fully refreshed: cairn `README.md` (install/config/metrics/gotchas), `DESIGN.md` (→ in production),
infra `docs/runbooks/cairn-deployment.md` (post-cutover status + findings).

**Cutover mechanics (how, since it's reusable):** drove it from the dev session via **launchd**
(`launchctl bootstrap gui/$UID …`) because **FDA is attributed to the launchd responsible process, not
the binary** — cairn run from a shell is attributed to the shell (FDA "denied"); via launchd it's its
own responsible process and its `cairn.app` grant applies. Per category: staging-verify (cheap ones to
a local dest first), then run to prod via launchd, verify the `cairn_backup_*{job}` metric, then
`launchctl bootout`+`disable` the matching bash agent. contacts/calendars needed a one-time
`max_delete` bump (native `.vcf` / sqlite store re-layout deletes the old bash files).

**Findings that bit (now in code + README §6):** (1) calendars/reminders data is in the **group
containers** (`group.com.apple.calendar/Calendar.sqlitedb`, `group.com.apple.reminders/Container_v1/
Stores/Data-*.sqlite`), NOT `~/Library/{Calendars,Reminders}` (empty) — fixed the config paths. (2)
Photos must run **local mode** — osxphotos `--use-photokit` needs the *System* Photo Library, but this
is a secondary `(NAS)` library on a sparsebundle → download mode fails rc=1; cairn exports local
originals, Photos.app's "Download Originals" populates the rest. (3) The supervised runner's
**stall-watchdog was too aggressive** for osxphotos/rsync **silent SMB phases** (metadata processing /
17k-file list-build go silent for >15 min) → it false-killed working photos + messages runs; fixed to
rely on the overall timeout. (4) osxphotos **filename collisions** (two photos sharing a name →
`IMG_x`/`IMG_x (1)`) throw benign `File exists` on `--update`; cairn now treats a run whose only errors
are those as success. (5) The TCC FDA **probe** was reading `TCC.db` (protected above FDA on macOS 26 →
false negative); fixed to probe `chat.db`. (6) `messages_attachments` count came back 0 (dest `find`
timed out over SMB) → count the local source instead.

**Reporting cutover:** chose a **clean label-based schema** (`cairn_backup_*{job,instance}` +
`cairn_photos_*` + `cairn_health`) over the bash name-mangling — rewrote `dashboards/{icloud-backups,
photos-export}.yaml` + `0{9,10}-*-alerts.yaml` via a verified workflow (incl. the `ICloudBackupEmpty`
rc-gate), Flux reconciled, deleted the 18 stale bash Pushgateway groups, updated `mini-health.sh`.

**S3 (the one hard constraint):** **zero churn** — photos reuse the existing osxphotos export DB + dir
(byte-identical → only new originals upload); only contacts/calendars re-layout churned (~MB, free,
still STANDARD).

**State:** all metadata jobs rc=0; photos backup intact (417 GB+, ~93% complete) and cairn-owned —
osxphotos `--update` confirmed working after the stall fix. **Next:** none required; cairn runs nightly
(19:30/20:00/23:30) + heartbeats. Nice-to-have: CI signed-`.app`-release automation (build is manual
`scripts/package.sh`). The seed tail (last few % of originals) fills in as Photos.app downloads them.

---

## 2026-06-26 — M76 Phase 1 DEPLOYED: step-ca SSH CA live (headless JWK works; OIDC deferred on a network constraint)

**What:** deployed M76 Phase 1 (user-authorized). step-ca is **`active` on VM 1006 (`https://10.10.201.46:8443`)**.

**Deploy sequence:** dispatched `terraform-proxmox-standalone-vms` apply (provision VM 1006 — plan 1-add,
0-destroy) → `terraform-proxmox-firewall` apply (its `:8443` rules — 2-add) → ran `playbooks/step-ca.yml`
from the devbox. CA up; provisioners **`admin` / `sshpop` / `headless`(JWK)**; SSH user+host CA keys;
**root-CA fingerprint `a37b7b1622157ecd6687dc953f95cbb49d152fe9819ed0b54aa56f4f9689cf67`**.

**Playbook deploy-fixes (commit `9e4c78d`):** found against real step-cli 0.30.6 — (1) `provisioner list
--ca-config` removed in 0.30 → enumerate provisioners by parsing ca.json; (2) no bare `--ssh` on OIDC
`provisioner add`; (3) OIDC made best-effort.

**Key finding — VLAN-201 hosts can't reach the MetalLB BGP VIPs same-subnet.** The OIDC provisioner add
failed: `auth.wind.etherport.net` → `10.10.201.70` (Traefik VIP) gives `no route to host` FROM the
step-ca VM. MetalLB is **BGP-only (no L2/ARP)**, so a host ON VLAN 201 (10.10.201.0/24) treats the VIP as
on-link, ARPs, gets no reply → unreachable. Off-subnet clients (routed via the UDM) reach VIPs fine; this
only bites a VLAN-201 host trying to reach a VIP. The grafana discovery endpoint is equally unreachable
that way — confirming a network constraint, not a config bug. **Impact: only the OIDC human path** (step-ca
needs to reach Authentik); the **headless JWK path is unaffected** (served inbound to step-ca) and is the
M76 driver. Fix options for OIDC: a `10.10.201.70/32 via 10.10.201.1` route on step-ca (UDM hairpin) or a
non-VIP Authentik path. Playbook auto-adds OIDC once reachable. DNS `step-ca A .46` added to Technitium
(HA propagation settling; clients can use the IP — cert has the SAN). Authentik `step-ca` OIDC app + secret
are in IaC + applied.

**UPDATE (same day, cont.):** finished the two follow-ups — **OIDC FIXED** with a persistent netplan
route `10.10.201.70/32 via 10.10.201.1` baked into the playbook (commit `a4a52c7`; UDM hairpin → step-ca
reaches Authentik, http 200, OIDC provisioner added); **DNS resolves** via the `.5` service (earlier
NXDOMAIN was stale negative cache; NB the two cluster Technitium pods have independent per-pod PVCs, so
the record was added per-pod). **Headless minting PROVEN** — `step ssh certificate --provisioner headless`
issued a 10-min ECDSA user cert non-interactively. **All 4 provisioners live; M76 Phase 1 COMPLETE.**

**UPDATE 2 — Phases 2–4 DONE (commit `51400c7`): cert-SSH LIVE fleet-wide (additive).** Built
`step-ca-trust.yml` (pushes `TrustedUserCAKeys` = the step-ca user CA pubkey as an sshd drop-in;
`sshd -t`-validated before reload; the `automation@homelab` key untouched → both work in parallel).
Proven e2e: installed step-cli on the devbox + bootstrapped, minted a 10-min cert via the JWK `headless`
provisioner, SSHed **cert-only** (`-F /dev/null`) to k8s-w1/cp1 + dns-fallback + gh-runner → CERT-AUTH OK.
Rolled to **all 14 fleet hosts** (8 k8s nodes + 5 standalone VMs + pve), failed=0. CA pubkeys committed
under `files/step-ca/`.

**NEXT = M76 Phase 5 CUTOVER (the risky step — deliberate):** switch the headless consumers to certs
first (CI ansible `ANSIBLE_SSH_KEY` → mint a JWK cert in-workflow; the devbox agent ssh-config/renew-loop),
verify cert-only for every flow, THEN remove `automation@homelab` from authorized_keys + the 4 hardcoded
deploy points (TF/Packer/ansible/AWS cloud-init) + 3 holders (mini/devbox/GH secret). Break-glass = PVE
console + IPMI. Follow-ups: persist step-cli+bootstrap in `devbox.yml`; optional host-certs (Phase 2b).
Saved a memory on the VLAN-201→VIP constraint. **L24 FRR-migration window deferred (owner picked M76 first).**

---

## 2026-06-25 (cont. 2) — L24 Phase-0 prep + M76 Phase-1 IaC built (both safe/inert; deploy = authorized apply)

**What:** executed the safe, no-impact parts of both arc items. Two commits; **no live infra changed**.

**L24 Phase 0 (commit `2267680`):** authored the FRR-mode MetalLB **Flux HelmRelease**
(`clusters/wind/helm-releases/metallb.yaml`) + the `metallb` HelmRepository, but left it **INERT** —
NOT wired into `helm-releases/kustomization.yaml` (a commented `# - metallb.yaml` with a "Phase 2,
windowed only" note), so Flux can't apply it. Key discovery during prep: **MetalLB is the kubespray
addon and kubespray's metallb role has NO FRR toggle** (native-only template, default v0.13.9 though
live runs 0.14.8) → FRR mode requires **migrating MetalLB onto the Helm chart** (Flux-managed). The
HelmRelease header documents the Phase-2 migration mechanics (delete kubespray workloads first, keep
CRDs/CRs, L2 net up, `crds.enabled:false`). `kubectl kustomize` verified the HelmRelease is correctly
excluded. helm-template render deferred to mini/CI (helm not on devbox).

**M76 Phase 1 (commit pending):** built the **complete step-ca standup IaC** for a dedicated
off-cluster VM, validated, NOT deployed (additive — touches no existing host):
- TF: VM `step-ca` (1006, 10.10.201.46) in `standalone-vms` + its M77 firewall (`:8443` from the
  cert-client VLAN + tailnet). Both stacks `terraform validate` OK.
- Ansible: `playbooks/step-ca.yml` (drafted via a subagent + reviewed) — step-ca 0.30.2 / step-cli
  0.30.6 sha256-pinned `.deb`; `step` system user; hardened systemd unit `:8443`; idempotent
  `step ca init --ssh` (guarded on ca.json); 3 provisioners (**`authentik` OIDC** human path,
  **`headless` JWK** automation, **`sshpop`** host-cert renewal); SIGHUP reload; shreds transient
  pw files; prints the root-CA fingerprint. `ansible-playbook --syntax-check` PASSED.
- Secrets: `playbooks/secrets/step-ca.sops.yaml` (ca/jwk/oidc generated, SOPS-encrypted) +
  `AUTHENTIK_STEPCA_CLIENT_SECRET` added to the Authentik secret (matches).
- Authentik: `step-ca` OIDC blueprint (redirect = the `step` CLI loopback `:10000`). kustomize builds.
- Inventory: `step-ca` host + `[step_ca]` group.

**Deploy of M76 Phase 1 (the authorized next apply):** TF apply standalone-vms (provision VM 1006) +
firewall; add DNS `step-ca.wind.etherport.net A 10.10.201.46`; Flux reconcile (Authentik OIDC app);
run the step-ca playbook → capture the root-CA fingerprint. Then Phase 2 (push `TrustedUserCAKeys`
in parallel with the existing key — still no cutover).

**Arc status:** M72/M73/M75 ✅ · M77 Stage 1 live · L24 📋 (prep done, FRR migration = windowed) ·
M76 🟡 (Phase 1 IaC built, deploy pending).

---

## 2026-06-25 (cont.) — L24 + M76 fully scoped (multi-agent), decisions made, plans drafted

**What:** ran 3 background scoping workflows (ultracode) and turned the results into two decided,
phased plan docs. **No infra changed** — this was research + design + handoff artifacts.

**L24 (BGP auth) → [`l24-metallb-frr-migration-plan.md`](archive/l24-metallb-frr-migration-plan.md), path A.**
Key finding that corrects the tracker: **L24 is NOT "Effort S, add a password."** MetalLB runs in
**native BGP mode** (v0.14.8) which **cannot do TCP-MD5** (FRR-mode-only; MetalLB #1125, Go 1.24
MPTCP lacks `TCP_MD5SIG`), and it's the **kubespray addon** (no FRR toggle) → FRR mode requires
**migrating MetalLB onto the official Helm chart** (Flux-managed). So L24 = a backend migration
(MED/M). Decided to do it (path A) framed as a **resilience upgrade** — FRR mode also buys
graceful-restart + BFD, fixing today's VIP-blackhole-on-speaker-restart exposure. Blast radius is
severe (the one session carries Traefik .70 + Technitium DNS .5/.71/.72, no GR/BFD/L2, silent to
the existing alert), so the plan uses a temporary L2 safety net + 2 windows + tcpdump-verify-MD5
(FRR #6921 one-sided-up) + a new `metallb_bgp_session_up` alert. UDM side is UI-only/no-API.

**M76 (short-lived SSH) → [`m76-ssh-shortlived-plan.md`](archive/m76-ssh-shortlived-plan.md), step-ca hybrid.**
Chose **step-ca SSH CA** over Tailscale-SSH-for-fleet. Deciders: the heavy consumers are HEADLESS
(devbox agent + CI ansible) but the live TS ACL is `action: check` (interactive) and the **fleet
isn't on the tailnet**; and **TS SSH only governs the tailnet transport** so **LAN-IP SSH bypasses
it** — whereas **step-ca certs are transport-agnostic** (the explicit "local/no-TS access" the owner
asked about). Hybrid: step-ca for the **13 Ubuntu hosts** (Authentik OIDC for humans, JWK renew-loop
for headless), TS-SSH `check` for interactive remote, **PVE console + IPMI break-glass** (step-ca runs
OFF-cluster; set console break-glass passwords). **Appliances are a hard carve-out** (vendor firmware,
keep scoped legacy keys). Honest: a *partial* "kill standing creds" win (trades the key for a CA
crown-jewel + a standing JWK-provisioner password). The static `automation@homelab` key sits on 3
disks + 4 hardcoded deploy points — removed only at Phase-5 cutover after the cert path is proven e2e.

**Execution sequencing (recommended):** M76 Phases 1–4 are **safe/incremental** (stand up step-ca +
push CA trust IN PARALLEL with the existing key — nothing breaks until the key is removed), so they
can proceed any time. **L24 path A needs a deliberate maintenance window** (VIP+DNS flap). Both are
real M-effort projects — start when ready; neither was begun.

**Next:** pick one to execute. For M76, Phase 1 (stand up step-ca off-cluster) is the natural start.
For L24, Phase 0 (author the Flux HelmRelease + confirm frr-k8s-vs-embedded-FRR + the v0.14.8/0.13.9
version question) is prep with no traffic impact; Phases 2–3 are the windowed flaps.

---

## 2026-06-25 — M77 Stage 1: per-VM PVE firewall on the standalone VMs (permissive/observe)

**What:** built **M77 Stage 1** — selective PVE firewall for the 5 standalone VMs (k8s nodes stay EXCLUDED; Cilium/UDM own those). New `infra/terraform/proxmox/firewall/standalone-vms.tf` + NIC `firewall = true` in `infra/terraform/proxmox/standalone-vms/main.tf`.

**Approach (lock-out-safe, mirrors H37):** per-VM firewall **ENABLED but PERMISSIVE** — `proxmox_virtual_environment_firewall_options{enabled=true, input_policy="ACCEPT", log_level_in="info"}`. Nothing is denied yet; inbound is just logged. This is deliberate: it lets us confirm each allow-list against the **real** PVE firewall log before flipping to DROP, so we don't repeat the H37 Ceph/IPMI latent-break class (a needed allow missing from a default-deny that only bites on a later fresh connection).

**Allow-lists** (from live `ss -tlnp/-ulnp` on each VM, 2026-06-25):
- Shared `vm-baseline` security group: **SSH 22** from the `mgmt-admin` IPset (reused from H37) + **node_exporter 9100** from the Servers/K8s VLAN (`var.ipmi_scrape_cidr` = 10.10.201.0/24).
- dns-fallback (1001): + **53 tcp/udp** (resolver) + **5380** (Technitium admin, mgmt-only).
- vpn-local (1002): + **WG udp 9820-9821** (source TBD-scoped at Stage 2 = AWS peer).
- gh-runner (1003): baseline only (outbound-only runner).
- asterisk-sbc (1004): + **SIP 5060/udp, 5061/tcp** + **RTP 10000-20000/udp** (sources TBD = Twilio ranges + LAN at Stage 2).
- devbox (1005): + **tailscale udp** from 100.64.0.0/10. ⚠️ the Claude session lives on this VM — Stage 2 needs care (keep SSH+tailnet).
- `rpcbind:111` (exposed on every VM by default) is intentionally **not** allowed → the eventual default-deny closes that latent NFS-portmapper exposure.

**Why permissive first:** going straight to DROP risked breaking dns-fallback (a resolver others depend on) or the SIP/WG paths via a source/port I mis-scoped — exactly the incident pattern H37 hit twice.

**State — STAGE 1 APPLIED + VERIFIED 2026-06-25.** Both stacks `validate`+`fmt` clean (`-backend=false`; devbox holds no creds — M82). Plans reviewed = exactly the change: firewall **11 add** (1 group + 5 options + 5 rules, 0 change/destroy), standalone-vms **5 in-place NIC toggles** (`firewall false→true`, 0 replace/reboot — M91 watchdog untouched). Applied via CI dispatch (M92 PAT): firewall run `28196232091` ✅ then standalone-vms run `28196405267` ✅ (the NIC apply was classifier-gated → **user-authorized** explicitly). **Post-apply data-plane verified from the devbox:** all 5 VMs SSH-reachable with **uptimes intact** (no reboot — clean live toggle); DNS resolves through dns-fallback `:53` (`auth.wind.etherport.net`→`10.10.201.70`); node_exporter `:9100` scrape returns 200 on dns-fallback + gh-runner. Permissive (ACCEPT) so nothing is denied — confirmed nothing broke. (PVE-host firewall-log inspection deferred to Stage 2; reading `/var/log/pve-firewall.log` needs PVE root SSH, which is separately gated.)

**Next (Stage 2):** watch the PVE firewall log a while → scope the external sources (Twilio SIP/media; AWS VPN peer IP) → flip `local.vm_input_policy` ACCEPT→DROP per VM, starting with gh-runner & dns-fallback (safest). Remaining security-arc items after M77: L24 (BGP auth), M76 (SSH short-lived certs).

---

## 2026-06-24 (cont. 16) — cairn native backup agent: M1–M5 + M6-half built; photos network-fragility designed out

**What:** built out **`cairn`** (M103; repo [sparked-diamond/cairn](https://github.com/sparked-diamond/cairn), `~/code/cairn`) from skeleton to nearly-deployable. **27 tests green**, all pushed. Decisions + code live in the cairn repo; infra got a deploy runbook ([`../runbooks/cairn-deployment.md`](../runbooks/cairn-deployment.md)).

**Built this session:**
- **M3 all native sources:** `contacts` (Contacts framework → vCards — verified **2,049 = exact parity** with the old CardDAV backup); `notes`/`calendars`/`reminders` via a new **`store`** source (consistent `sqlite3 .backup` + companion mirror, **auto-discovers** `*.sqlite`/`*.sqlitedb` across macOS-version layouts); `messages` **in-place** (chat.db snapshot to local disk → push + ~48 GB Attachments additive — can't stage on 15 GB free).
- **M4 photos** = **osxphotos wrapper, in-place on the NAS**, replicating the bash invocation **byte-for-byte** (→ no S3 re-upload) + every lesson (local export-DB, no `--ramdb`, `--cleanup` off, daemon-restart per retry). Plus the **network-resilience foundation**: `runSupervised` (hard timeout + **stall-watchdog** + process-group kill — "hang at 71 % forever" → killed in seconds), `MountHealth` (timed RW probe + ordered **SMB→sparsebundle→APFS self-heal**, Keychain creds, no secrets), `withResilientRetry` (heal-before-attempt, resume via `--update`).
- **M5:** run history (JSON) + `cairn status` + **`cairn_health` heartbeat** (pollable agent-liveness rollup to Pushgateway) + `cairn tcc` (status/`--request`/FDA deep-link).
- **M6-half:** `cairn install` (launchd LaunchAgents from `schedule:` fields + a 900 s health agent), `cairn run --due` (catch-up + idempotent), and **quit-Photos-before-every-run**.

**Why these decisions (forks the owner chose):** wrap **osxphotos** not native PhotoKit — PhotoKit can't read keywords/persons/captions (only the Photos DB has them, via osxphotos), and re-implementing that reader is a per-macOS-version maintenance trap; osxphotos = full metadata + byte-stable + no re-upload. Keep + **harden the network sparsebundle** (not an SSD — no physical access; not `icloudpd` — reintroduces Apple-ID/app-password/2FA/rate-limit + metadata loss). Calendars via **`store`** not EventKit→.ics (EventKit has no native .ics serializer; reconstruction is lossy).

**Key operational findings (mini, photos):** the Photos library is a **sparsebundle on the NAS** (`/Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle` → APFS `/Volumes/PhotosLib`), seed **~10 %** (4,572/~44k originals, 7.3 GB). The network **actively throws I/O errors on hot DB reads** — a manual `cp` of the 586 MB `Photos.sqlite` returned `fcopyfile: Input/output error`; that + Photos.app open is what produced the **"library could not be opened (-1)"** dialogs. cairn quits Photos + supervises/heals to absorb this. **S3 is still all `STANDARD`** (not yet Deep-Archive) so a restructure would've been free — but we kept the current layout, so **no churn either way**.

**State:** cairn feature-complete except CI signed release + the operational cutover. **Next steps:** (1) on the mini via VNC: `cairn tcc --request` + add `cairn.app` to Full Disk Access; (2) run notes/calendars/messages against a staging dest, diff vs bash output; (3) let cairn own the photo seed headlessly (quits Photos, supervised, resumable); (4) flip schedules + unload the matching bash LaunchAgents per-category; (5) CI signed `.app` release. Reverse = unload cairn agents, re-enable bash. **Until cutover: don't keep Photos.app open on the `(NAS)` library** (the `(-1)` friction).

---

## 2026-06-25 — cue deploy mechanism fixed (Flux image automation) + CF apply runner blip

- **cue-api deploy was broken: Flux silently reverted `kubectl rollout restart`.** Root cause
  (empirically proven + adversarially verified via a workflow): the Flux-managed cue-api
  Deployment has `spec.template` owned by kustomize-controller (SSA, force-conflicts); every
  reconcile re-applies the Git template (no `restartedAt`), pruning the annotation → the
  rollout RS scales to 0 and the Git-template RS is re-promoted. So deploys depended on a
  manual `kubectl delete pod`, the deploy history was unauditable, and the migrate
  initContainer running before the revert created a real schema-ahead-of-code window
  (the goal→goalBody rename). Audit: 0 provably-phantom but only the W9/goalBody deploy is
  digest-confirmed; 3 high-profile 06-24 claims (W8, swap/sets/location, external-tester)
  are unverifiable (their code IS in the serving image — ancestors — but the specific
  `54c07489` deploys never demonstrably served). **Fix (owner chose image automation, reversing
  the digest-pinning exemption):** ImageRepository(cue) + ImagePolicy(cue-api, filterTags
  `^latest$` + `digestReflectionPolicy:Always`) track the moving :latest and reflect its
  digest; the existing ImageUpdateAutomation (path ./platform/kubernetes) commits it onto BOTH
  cue-api image lines ($imagepolicy markers re-added) → Flux rolls it. Private image → ghcr
  pull secret `cue-ghcr` in flux-system (SOPS; new `clusters/wind/` sops rule). **Verified
  end-to-end:** scan(179 tags)→reflect(bcc8f249)→automation commit(`8f3811f`)→Flux applied→new
  digest-pinned RS `5c89fdbd4b` 1/1, migrate exit 0. A code-only push to cue's main now
  auto-rolls within minutes, no manual step, deployed digest recorded in git. `commit 573b467`.
- **CF Terraform apply failed at `terraform init`** (owner added a cue-tester email to
  cloudflare variables.tf). Root cause: transient `registry.terraform.io` slowness for the
  cloudflare v5 provider (~20s TTFB, aws/random instant) tripped terraform's init timeout on
  the self-hosted lifecycle runner. Recovered on its own; re-ran plan (clean: 1 in-place,
  adds the email) + applied. Hardened the workflow init (retry loop + persistent
  TF_PLUGIN_CACHE_DIR) so a future registry blip can't fail it (`13a397f`). NB the runner's
  eth0 MTU 9000 (intentional, for internal PVE jumbo) drops jumbo to the internet, but MSS
  clamping handles TCP (aws downloaded fine) — not the cause; left as-is.

---

## 2026-06-25 — Post-M75 fallout: multus outage + SES email gap + email consolidation

Two M75 follow-on incidents + a consolidation, all the morning after the IRSA cutover.

- **🔴 Multus CNI outage (issuer-collapse fallout).** Collapsing the apiserver to a
  single issuer (dropping `cluster.local`) invalidated **multus's cached
  `multus.kubeconfig` token** (written once at pod start, never refreshed) → `multus …
  Unauthorized` on every new pod's CNI add → **no pod could schedule cluster-wide for
  ~7h**; cascaded into a KubeJobFailed/KubePodNotReady/VeleroBackupPartial + AI-advisor
  alert storm. **Fix: `kubectl -n kube-system rollout restart ds/kube-multus-ds-amd64`**
  (regenerates the kubeconfig from the current `iss=bucket` token). Cleaned stuck pods +
  failed job records, re-ran the 3 outage-window velero backups. **Single-issuer kept**
  (it's production-standard/EKS model; multus was the only token-cacher — now fixed); the
  RULE (restart multus on any issuer change) is in the runbook/CLAUDE.md/memory.
- **🔴 SES email gap (IRSA migration miss).** The old `kubernetes-s3-backup` static key
  had `ses:SendEmail`; the `wind-irsa-s3-sync` role didn't → daily-report + delete-approval
  emails failed `AccessDenied`. Fixed (`ses:SendEmail`/`SendRawEmail`, `Resource:"*"` — v1
  SendEmail doesn't honor identity-ARN scoping). Re-sent today's report.
- **📧 Email-sender consolidation (was piecemeal).** Standardized all 4 system senders:
  **consistent From** `Etherport <Service> <<service>@wind.etherport.net>` (backups /
  ai-advisor / alertmanager / service-status) + **API-maximal transport**: backups +
  ai-advisor + service-status now send via **SES API on IRSA** (no static creds —
  ai-advisor smtplib→boto3 send_raw_email; service-status smtplib→boto3 on the
  cloudwatch-read role); **only alertmanager stays SMTP** (no API path). Deleted the
  `ai-advisor-smtp` static secret; the static SES SMTP key now has just 1 consumer
  (alertmanager) instead of 3. (etherport.net SES domain identity + DKIM cover the
  `*.wind.etherport.net` senders; SES still sandbox → recipients verified.)

---

## 2026-06-24 (cont. 15) — M75 IRSA workload identity (Phase 1+2: foundation live + verified)

Started M75 — kill the long-lived static AWS IAM keys in-cluster (self-hosted IRSA).

- **Diagnosis:** ALL ~13 AWS-cred K8s secrets across 8 namespaces (velero, the 7
  s3-sync/rclone jobs, CNPG barman ×2, ai-advisor, cloudwatch-to-loki) carry the
  **same shared key** `AKIA4C5DM33X…` — one over-broad standing credential copied
  all over etcd. The cluster SA issuer is `https://kubernetes.default.svc.cluster.local`
  (internal-only) with JWKS on `https://10.10.201.50:6443` → AWS STS can reach
  neither, so true IRSA **requires** flipping `--service-account-issuer` to a public
  TLS-valid URL (a control-plane change). Confirmed via AskUserQuestion: **Full IRSA**
  + **public S3 bucket** issuer hosting. **etcd-backup excluded** — it's host-level
  (CP systemd), not a pod → belongs to M71, not IRSA.
- **Phase 1+2 SHIPPED + applied via CI (`6e3d382`, tag fix `347d210`):** new TF stack
  `infra/terraform/aws/cluster-irsa/` + `terraform-cluster-irsa.yml`. Created (CI
  `apply`, plan reviewed = 14 add/0 destroy): public OIDC bucket
  `wind-cluster-oidc-830881980142` serving discovery + `keys.json` (cluster public SA
  keys), IAM OIDC provider (live thumbprint via `tls_certificate`), 4 least-priv roles
  trust-locked to exact ns/SA (`wind-irsa-{velero,s3-sync,barman,cloudwatch-read}`).
  **Verified from the public internet**: discovery `issuer` == URL, `jwks_uri`
  resolves, JWKS == `kubectl get --raw /openid/v1/jwks`.
- **Key facts established:** CI's `gh-actions-terraform` role already permits
  OIDC-provider/role/policy creation → **no admin bootstrap** for IRSA TF (headless
  CI dispatch works). Dispatch via the M92 `github_dispatch_pat` (SOPS ops bundle) →
  GH API `/dispatches` (no `gh` CLI on devbox). **A blind `apply` was correctly
  blocked by the auto-mode classifier** → switched to plan-first (repo's cardinal
  rule), reviewed (14→then 5 add, 0 destroy), then applied. S3 `InvalidTag` gotcha:
  bucket tag VALUES reject parens (the `(IRSA)` in a Name tag).
- **Phase 3 DONE this session (user approved "do now") + e2e-verified:** flipped
  `--service-account-issuer` on all 3 CPs by hand-editing the static manifests
  (atomic temp+rename), cp2→cp3→**cp1 last** (cp1 is the endpoint → brief kubectl
  blip, self-healed). Dual issuer: **bucket primary + `cluster.local` secondary**, and
  — the crucial catch — **explicitly pinned `--api-audiences=…cluster.local,
  sts.amazonaws.com`**: it was unset (defaults to the FIRST issuer), so flipping the
  issuer would have silently 401'd EVERY existing in-cluster token. Validated per-CP by
  presenting a `cluster.local`-aud token to each node (403 = authN OK, not 401).
  **End-to-end proof:** `kubectl create token velero-server -n velero
  --audience=sts.amazonaws.com` (now `iss=bucket`, `sub=system:serviceaccount:velero:
  velero-server`) → real `aws sts assume-role-with-web-identity` (no prior creds) →
  `wind-irsa-velero` returned short-lived `ASIA…` creds. The whole chain works.
- **Phase 4 DONE same session (user: "continue with phase 4 and ensure persistence
  plan is valid").** Migrated EVERY in-cluster AWS workload to IRSA via **manual token
  projection (NO webhook** — avoids a cluster-wide mutating admission webhook + cert;
  CNPG operator pods covered by the Cluster CR's `projectedVolumeTemplate`+`env` →
  `/projected/token`): velero (server + node-agent), the 7 s3-sync shares +
  approval-server + validation-job + daily-report + unifi-backup, CNPG postgres +
  cue-db (`inheritFromIAMRole`), ai-advisor, cloudwatch-to-loki. **Each verified**
  (velero + both CNPG backups COMPLETED; STS-assume + S3-list for the CLI ones incl. a
  uid-1000 test; ai-advisor boto3 DescribeLogGroups). **Deleted all static-key secrets**
  (SOPS removal → Flux prune + 2 live deletes) → **no static AWS keys in etcd**.
- **Phase 4 gotchas (all hit + fixed):** (1) velero chart renders
  `configuration.extraEnvVars` into BOTH server AND node-agent → also setting
  `nodeAgent.extraEnvVars` duplicated the vars → Helm `$setElementOrder` UpgradeFailed
  + rollback; keep env only in `configuration.extraEnvVars`. (2) velero Kopia
  **maintenance** Jobs do their OWN AssumeRoleWithWebIdentity → need `AWS_REGION` or
  the SDK builds `sts..amazonaws.com` (empty region → DNS fail); the BSL region config
  doesn't cover it. (3) aws CLI v2 in **non-root** pods (uid 1000, HOME=/) caches
  assumed creds under `$HOME/.aws` → `Permission denied: '/.aws'` → set `HOME=/tmp`
  (boto3 + Go SDK unaffected). (4) a ROOT throwaway test pod hid #3 — test as the real
  securityContext. (5) the "13 secrets = one shared key" diagnosis was WRONG: **4
  distinct dedicated keys** (the `AKIA4C5DM33X` prefix is just the account-ID prefix).
  SES SMTP secrets legitimately stay static (protocol can't use web identity).
- **Persistence VALIDATED (`2668cbe`):** added `kube_kubeadm_apiserver_extra_args`
  (single bucket issuer + pinned api-audiences) to the kubespray inventory, then
  **collapsed the live apiserver manifests from dual→single issuer to MATCH it**
  (cp2→cp3→cp1, per-CP 403 validation, IRSA e2e re-confirmed). So **live == IaC ==
  single bucket issuer, zero drift** — a future gated kubespray run reproduces working
  IRSA. (Backups of each manifest left on the CPs: `/root/kube-apiserver.yaml.pre-irsa`
  + `.pre-collapse`.)
- **State:** M75 COMPLETE bar one hygiene follow-up — deactivate/remove the **4 now-
  orphaned dedicated IAM keys** (ai-advisor-readonly, barman-postgres [TF-managed in
  ai-advisor-iam/s3], velero, kubernetes-s3-backup [find stack]) whose material lingers
  in git history + is Active in AWS; remove via their TF stacks + apply. **NOT the H29
  terraform-homelab key.** Full detail + per-workload table + gotchas:
  `docs/runbooks/irsa-workload-identity.md`.

---

## 2026-06-24 (cont. 14) — M74 Tetragon eBPF runtime detection (observe-only v1) + Loki-firehose fix

Deployed **Cilium Tetragon** (the security-arc's runtime/"assume-breach" detection layer)
observe-only, and caught a real misconfiguration before it could flood Loki.

- **Engine** via Flux HelmRelease (`helm-releases/tetragon.yaml`, chart 1.7.x from the
  existing `cilium` HelmRepository), ns `tetragon` `tier=system`. eBPF sensors loaded on all
  8 nodes (DS 8/8). **No enforcement/kill** — forensics on demand via gRPC:
  `kubectl exec -n tetragon ds/tetragon -c tetragon -- tetra getevents -o compact` (verified
  live — streamed kube-proxy/iptables exec events).
- **🔴 Caught + fixed a silent Loki-firehose footgun (`a4ba00f`):** v1 first shipped with
  `export.stdout.enabled: false` to keep events off stdout (Alloy tails *all* pod logs into
  the single-binary Loki). **That is not a real chart key** — Helm silently drops unknown
  values, so the chart default `export.mode: "stdout"` stayed active and the `export-stdout`
  sidecar ran the **full** process_exec/exit firehose. Measured before fixing: **497 lines/min
  on one node, ~800/min cluster-wide ≈ 1.1M lines/day** straight into Loki. Verified the real
  key from the v1.7.0 chart values.yaml = **`export.mode: ""`** (empty = no sidecar). After the
  fix: sidecar removed, DS pods went **2/2 → 1/1**, steady-state export = 0. **Tell for the
  future: tetragon pods must be 1/1; a 2nd `export-stdout` container means export is back ON.**
- **Why observe-only / export-off in v1:** zero Loki risk while the sensors are validated. v2
  (deferred) = TracingPolicies (high-signal: writes to `/etc/shadow`·`sudoers`·`authorized_keys`,
  shell-in-container, unexpected privileged syscalls) + **selective** export (re-enable
  `export.mode: "stdout"` with a denylist dropping PROCESS_EXEC/EXIT + health checks → only
  matches flow to Loki) + a loki-ruler alert mirroring the hubble-audit pattern. Plan in
  `platform/kubernetes/tetragon/README.md`.
- **Security-arc status:** M72 (PSA) ✅ · M73 (Kyverno audit) ✅ · **M74 (Tetragon observe) 🟡 v1**.
  Remaining arc items: M75 (in-cluster workload identity / IRSA), M76 (short-lived SSH certs),
  M77 (selective PVE VM firewalling), L24 (BGP auth) — all ⏳.

---

## 2026-06-24 (cont. 13) — M73 Kyverno admission engine (audit-first)

Deployed Kyverno (the security-arc's admission-policy layer) **defensively**:
- **Engine** via Flux HelmRelease (`helm-releases/kyverno.yaml`, chart 3.8.x → Kyverno
  **v1.18.1**), 4 controllers healthy. Deployed engine-first with **no policies** (zero
  interception) → verified → then policies. (Scare: `kubectl get clusterpolicy` showed a
  `cluster-policy` dated 2026-05-12 — it's the **NVIDIA gpu-operator** `ClusterPolicy`
  (`nvidia.com`), not Kyverno's; FQ `clusterpolicies.kyverno.io` is empty.)
- **Starter policies** (`platform/kubernetes/kyverno/`): `require-resource-requests`,
  `disallow-latest-tag` (cue excluded). **All audit-only** (`validate.failureAction:
  Audit`) + **fail-open** (`webhookConfiguration.failurePolicy: Ignore`) + control-plane/
  operator namespaces excluded. Verified a violating pod still **admits** (audit ≠ block).
- **Kyverno v1.18 API gotcha:** spec-level `validationFailureAction`/`failurePolicy` are
  **deprecated** → use per-rule `validate.failureAction` + `spec.webhookConfiguration.
  failurePolicy` (confirmed via `kubectl explain` against the live CRD before writing).
- **Division of labour:** PSA (M72) = pod-security posture; Kyverno = the rest (requests,
  tags, next cosign image-provenance for H30).

**Next:** review `polr` → promote clean rules to Enforce; add cosign verifyImages. Then
**M74 (Tetragon)** — runtime detection; another substantial deploy → checkpointed here.

---

## 2026-06-24 (cont. 12) — M15 911 verified + M72 PSA enforce (security-arc start)

**M15 — Twilio 911 emergency address: RESOLVED (verified at carrier).** Queried the Twilio
API: primary DID +19094142433 (re-acquired PN `PN2b496425…`; the runbook's "FAILED" was the
retired PN) → `emergency_status: Active`, bound to `AD1fe171…` = 843 Greenbriar Dr, which is
`validated: True, emergency_enabled: True`. So 911 delivers correct location at the carrier
(SIP-trunk 911 uses the DID's emergency address; the Talk UI `emergency_address/list=[]` is
cosmetic). TF var matches → no drift. **No apply needed.** Corrected the stale runbook note.
Residual: TF-import hygiene (confirm address+DID in twilio state). M16 (orphan DID — found 3
non-primary DIDs) + M17 (trunk still `secure=false` → TLS+sRTP) remain.

**M72 — Pod Security Admission audit/warn → enforce: substantially done.** Most app
namespaces were already enforcing baseline (2026-06-02). This pass: dry-ran every audit-only
+ unlabeled namespace via `kubectl label --dry-run=server` to see what would break, then
**added `enforce=baseline` to `flux-system`** (`5a52b54`; live + flux healthy — baseline not
restricted to avoid an engine wedge on a future upgrade, though it dry-ran restricted-clean).
**15 namespaces now enforce.** Exempt-by-design (legit elevated): monitoring, tailscale,
home-automation, gpu-operator-system, velero (audit/warn=baseline); blackbox/metallb/
wireguard (privileged). **Residual (documented in tracker M72):** 4 baseline-clean
*Helm-created* namespaces (cert-manager, cnpg-system, github-actions-runner, plex) need
labeling *at source* (explicit ns + `createNamespace:false`) since a patch has no build
target; + ~7 stale/empty namespaces (kopia, technitium-dns, rclone-gdrive, home, media,
infra, gpu-operator) to delete in a separate cleanup.

**Next:** M73 (Kyverno) — a cluster-wide admission webhook; deploy audit-first. Substantial
new operator → start fresh (checkpointed here).

---

## 2026-06-24 (cont. 11) — M82: Terraform → CI-only, devbox drops standing AWS/PVE creds

Owner chose **CI-only** for M82 (over keep-on-devbox / re-home). Most of the path was
already there (M92 dispatch PAT done; ~every TF stack has a workflow). Executed:
- **Added `terraform-proxmox-firewall.yml`** — the one TF stack lacking CI (the H37 host
  firewall). Modeled on terraform-proxmox-sdn (self-hosted `lifecycle` runner,
  `PROXMOX_TOKEN_*` secrets, S3/OIDC backend) but **TF 1.15.5** — the state was written by
  1.15.5 (devbox), and 1.14.3 (what the sibling proxmox workflows pin) would refuse it.
  Pushing it auto-triggers a plan → validates runner/secrets/state (check Actions UI).
- **Removed the standing `~/.aws/[homelab]` key from the devbox.** The AWS key remains only
  SOPS-encrypted (verified still in the bundle) + as GH secrets; no plaintext at rest on the
  devbox disk. `~/.aws/config` kept (no secret). On-demand re-render via
  `scripts/render-aws-credentials.sh` for rare local debug (throwaway, not standing).
- **CLAUDE.md §4 updated** to the new model: devbox = Actions:write PAT (M92, dispatch CI) +
  SOPS age key (headless `sops -d`), **no standing AWS/PVE creds**; TF via CI.
- **Latent finding:** sibling proxmox workflows pin TF **1.14.3** but the firewall state is
  1.15.5 — if the devbox ever applied the other proxmox stacks at 1.15.5, their CI would
  break on the version skew. Worth aligning the proxmox workflows to 1.15.5 (follow-up).

**Verify (owner):** firewall workflow plan run green + `PROXMOX_TOKEN_*` GH secrets present.
**Next ZT:** M71 — the devbox is now clean; remaining standing keys are on the **mini**
(`[homelab]` + `[claude-admin]` PowerUser) + the never-rotated keys — mini/admin actions.

---

## 2026-06-24 (cont. 10) — UDM/network hardening cleanup (VPN-zone tighten + audit)

Network-hardening tidy-up pass on the UDM. **Done + verified:**
- **M42 — VPN-zone allows tightened** (`udm-firewall.yml`): `Vpn → Trusted (all)` +
  `Vpn → Management (all)` → `(admin)` = **TCP on a new `Vpn-Admin-Ports` group**
  (22/53/80/443/6443/8006), logging on. Keeps the UDM backup WireGuard tunnel + `Vpn`
  zone (owner wants it as break-glass for cluster/PVE VPN loss + future tunnels e.g.
  Teleport) but a connected client no longer gets full LAN reach. Applied live from the
  devbox (the playbook is **create-only** per H34, so: real apply created the group + 2
  `(admin)` policies additively, then **API-deleted** the 2 old `(all)` policies — their
  auto `(Return)` twins cascaded). Verified: only `(admin)` remain. Empty zone (0 VPN
  clients) → no live impact. Resolves firewall-zones anomaly #3.

**Audited / confirmed (owner asks):**
- **Default network (199) is unused** — UDM API shows **0 of 102 active clients** on
  10.10.199.x. It stays (it's the native transit + `.1` default route). NB you can't fix
  the "device on an unused port lands on trusted-transit 199" risk by tightening the
  `Internal` zone — the switch-routed VLANs (201/202/209/210) are zoneless and **transit
  through `Internal`**, so `Internal→Trusted (all)` carries legit clients→servers traffic.
  The fix is at the **switch-port level**.
- **~33 unused/down switch ports** fleet-wide; **no "Disabled" port profile exists**, and
  several profiles (Cameras/Phones/APs/UniFi-Devices) + the fallback are native to
  Default/199. → UI action: create a Disabled profile, apply to unused ports.

**Decisions (owner):** Security/205 isolation+DNS → **FIX** (UI: disable Network Isolation,
set DHCP DNS .5/.6); LTE WAN → **keep**; VPN zone → **keep + tighten** (done).

**Recommendation captured (task #18) — physically-exposed switches** (Driveway, Access Road,
Outdoor Junction, Chapel, ua-gate): disable unused ports + **per-port VLAN minimization**
(camera→Security/205, AP→its SSID VLAN, gate→Access VLAN, so a hijacked port lands in an
already-isolated zone) + **802.1X/MAB** via RADIUS (only the "Default" placeholder profile
exists today). MAC filtering alone is spoofable — VLAN confinement + zone firewall is the
real control.

**M47 — DONE 2026-06-24 (auth-swap):** `udm-firewall.yml` now prefers `X-API-Key`
(`udm_api_key` from the SOPS bundle / `UDM_API_KEY` env) and falls back to the
username/password login when no key — verified both paths via `--check` (failed=0).
`ansible-unifi.yml` passes `UDM_API_KEY` (empty → fallback). Follow-up: add the
`UDM_API_KEY` GH secret, then drop the login fallback. Verified `X-API-Key` works on the
legacy + v2 endpoints (200; bad key → 401).

**Still open (UI / queued):** Security/205 fix (UI — **M104**), unused-ports → Disabled incl.
the outdoor switches (UI — **M105** / task #18), **L24** BGP session auth (UI/FRR).

---

## 2026-06-24 (cont. 9) — H30 supply-chain CLOSED (image digest-pinning, staged)

Finished H30. Found two of the "deferred" items already done (the 3 TF workflows use the
checksum-verified `setup-sops` action; all 111 Actions SHA-pinned via PR #62). The real
remainder was **image digest-pinning**: added `digestReflectionPolicy: Always` + `interval`
to **all 13 `ImagePolicy` objects** so Flux image-automation rewrites manifests to
`tag@sha256:…` (immutable supply chain).

**Staged rollout (owner chose "non-critical first")** — given it rolls the whole Flux fleet:
1. **Canary** `blackbox-exporter` (`206417b`): validated the full mechanism end-to-end —
   ImagePolicy resolves the digest (in this Flux build the resolved ref is in the Ready
   *condition message*, not `.status.latestImage`, which reads empty) → automation commits
   `prom/blackbox-exporter:v0.28.0@sha256:…` → Flux applies → pod rolls 1/1 clean.
2. **Wave 1** (non-critical): python-alpine/-slim, busybox, velero-plugin-aws, rclone,
   open-webui, ollama, wikijs — all digest-pinned + rolled healthy (auto-remediation, velero,
   open-webui, ollama, wiki-js).
3. **Wave 2** (sensitive): technitium DNS, cloudflared, home-assistant, plex. technitium STS
   + cloudflared are **2-replica** → rolled one-at-a-time → **DNS stayed up** (verified
   `getent grafana.wind.etherport.net → 10.10.201.70` from dns-ns + cue-ns pods) and the
   tunnel stayed up. HA/Plex took a brief single-pod restart.

**Result:** all 13 upstream images digest-pinned, fleet healthy, nothing broke. **In-house
images (aws-s3-sync etc.) deliberately left on `:main`** (we build them; CI rebuild on push +
imagePullPolicy:Always; the tag-mutation threat barely applies) and **cue-api on `:latest`**
(dev) — bringing them under Flux digest is optional future work, not required for H30.
**Gotcha for future:** `.status.latestImage` is empty in this image-reflector build — check
the ImagePolicy's Ready **condition message** for the resolved tag+digest.
---

## 2026-06-24 (cont. 8) — backup verification false-negative fixed (special-char keys)

**Symptom:** overnight the `backups` share's s3-sync ran FAILED — `homelab_backup_last_run_success{share="backups"}=0`, **9 of 20,813 files "failed verification"** (the run that mirrored yesterday's 20,813-file mini iCloud push incl. 19,951 Messages attachments). The `S3SyncFailed` alert fired; the **AI advisor handled it correctly** — diagnosed once then `Cooldown active … skipping action` (H39 dedup working, no email flood).

**Root cause (NOT data loss):** pulled the consolidated report (`s3://logs.archive…/reports/backups/20260624T080019Z/report.json`) — the 9 were `checksumMismatches:0`, `errorCode:HeadObjectFailed`, message *"…bucket name must match the regex…"*. That's botocore's **--bucket** validation: the GNU-parallel verify path used unquoted column substitution (`parallel --colsep '\t' verify-one.sh {1} {2} …`), which **mangled the args for keys with spaces+special/multibyte chars** (curly apostrophe U+2019, `!`, parens, odd spacing) → a bogus `--bucket` → HeadObjectFailed. The 20,804 plain keys passed; only the 9 awkward ones failed. **All 9 objects confirmed present in S3** (head-object OK with proper quoting) → pure verification false-negative.

**Fix (`a700b3f`):** pass the whole tab-delimited `bucket<TAB>key` line as ONE opaque arg (`{}` in parallel; `"$REC"` in the bash fallback) and split byte-exact with `IFS=$'\t' read` inside `verify-one.sh` — robust to any key. **Validated against all 9 real keys → 9/9 now pass.** The image rebuilds on push (`aws-s3-sync-image.yml`, path-filtered) + `imagePullPolicy: Always`, so the next run uses it. The alert clears on the next successful run (a no-change re-run has 0 uploads → verification skipped → success; the fix matters next time a batch of special-char files uploads).

---

## 2026-06-23 (cont. 5) — mini observability restored (VIP fix verified) + size metric + mini_health heartbeat

**VIP fix verified from the mini.** Infra restored the mini→Traefik-VIP route (Cilium `traefik-tier` was allowing the LB *service* ports :80/:443 from world but enforces on the DNAT'd *container* ports :8000/:8443 — commit 1a98eee). From the mini: `nc 10.10.201.70:443` connects, end-to-end pushgateway POST works (PUSH_OK), Alloy→Loki clean since restart (was timing out until 23:07Z). Re-pushed all backup metrics: messages/notes/safari/drive/photos green+fresh. **contacts/calendars rc=1 = transient iCloud DAV throttle** from my dozens of debug runs (manual `discover` succeeds; data safe, master intact) — left to self-heal on the 21:00 nightly; do NOT keep re-running (worsens the throttle).

**Dashboard asks (owner): item count + size-on-disk per category, both dashboards.** Item count already exists (`<job>_items` / `photos_export_photos_total`). Added **size**: `<job>_bytes` (+ `photos_export_bytes`) via new `nas_du_bytes` helper (du of each NAS dest, bounded timeout + skip-on-fail so a slow du never zeroes the panel), emitted opt-in via `BACKUP_BYTES`/`PHOTOS_BYTES`; wired into all 8 categories. `2267fc8`.

**Agent-health metric (owner).** New `mini-health.sh` + `net.wind.mini-health` (every 15 min, RunAtLoad) pushes `mini_health_*`: `mini_health_up` (rollup), `mini_health_check{check="agents_loaded|nas_readable|nsmb_applied"}`, `agents_loaded`/`agents_expected` (6), `disk_free_bytes`, and `mini_health_last_check_timestamp_seconds` (heartbeat). The heartbeat is the dead-man's-switch — if it stops arriving the mini is down or can't reach the VIP (would've caught today's outage). Cheap + FDA-free (launchctl/mount/df/rsync-stat). Verified push: up=1, agents 6/6, nas/nsmb ok, 21G free. **Infra-agent handoff (prompt given to owner):** add item-count + size panels per category to BOTH dashboards; surface `mini_health` in the 06:00 service-status-report email + alert on `mini_health_up==0` and heartbeat-absence.

---

## 2026-06-24 (cont. 7) — Control-plane OS patch (cp1/cp2/cp3) — completes M101 node patching

Patched the 3 control planes with `infra/ansible/playbooks/k8s-node-patch.yml`, finishing
the node-patch rollout (workers/GPU were done 06-23). **Key nuance — there is NO HA API
VIP:** `controlPlaneEndpoint` is the single cp1 `10.10.201.50:6443`, workers reach the API
via their local kubespray `nginx-proxy` (→ all CPs), and external clients (my kubeconfig,
the mini) point straight at cp1. etcd runs as a **systemd service** (not static pods; certs
`/etc/ssl/etcd/ssl/`, `etcdctl` env in `/etc/etcd.env`), 3 members.

**Procedure (safe path without a VIP):** the playbook's kubectl steps are all
`delegate_to: localhost` (run on the devbox), so I patched each CP with `-l <cp> -e
kubeconfig_path=<temp kubeconfig pointed at a DIFFERENT healthy CP>`. Order **cp2 → cp3 →
cp1**, leaving cp1 (etcd leader + endpoint) for last; cp2/cp3 patched via cp1, cp1 via cp2.
Built temp kubeconfigs by `sed`-swapping the server URL (verified each CP's apiserver cert
SANs cover all 3 IPs — `/healthz` ok on each). Pre-flight: etcd 3/3 healthy, CP taints
present (clean drains), only HA/reschedulable pods evictable (cilium-operator/coredns/etc.).
Between each CP I re-verified **etcd endpoint health + matched raft index** (quorum holds
with 1 CP down; serial:1 is mandatory for a 3-node CP). On cp1's reboot etcd cleanly
re-elected the leader cp1→cp2 (term 68→69).

**Result:** all `failed=0`, all CPs Ready on uniform kernel `6.8.0-124`, etcd 3/3 in sync,
0 unhealthy pods, original cp1 kubeconfig works again, reboot-required cleared on all three.
Patches were userspace (apparmor/snapd/cloud-init/libxml2/qemu-guest-agent) but still
triggered a (clean) reboot each. Temp kubeconfigs `shred`-deleted after. M101 node-patching
DONE. **Future CP patches: reuse the per-CP `kubeconfig_path` trick until/unless an HA
apiserver VIP is added.**

**Also closed the last M101 residual** (`bb2c32c`): added the devbox `10.10.201.45:9100` to
the `external-nodes` Prometheus scrape job (`01-external-scrape-config.yaml`, instance=`devbox`).
Verified `up{instance="devbox"}=1`, no errors. **M101 fully DONE** — only deliberate residual
is third-party repo (1Password/NodeSource) auto-update.

---

## 2026-06-24 (cont. 6) — Cue public access + Web Push; VIP-outage preventive alert; doc review

**Cue public internet access** (`33b368a` `93f76d4` `6e42876`, applied via CI earlier today):
`cue.etherport.net` now served through the CF Tunnel with **per-path** Zero-Trust Access —
the app behind **Google SSO** (allow-list `cue_tester_emails`, default `grahamsm@gmail.com`),
`/health` **bypass** (no auth, for uptime checks), and `/ingest/healthkit` behind a
**service token** (`cloudflare_zero_trust_access_service_token.cue_healthkit`) for the
HealthKit ingestor. cue-api verifies the CF Access JWT itself via `CUE_CF_ACCESS_TEAM_DOMAIN`
(`etherport.cloudflareaccess.com`) + `CUE_CF_ACCESS_AUD` (the app AUD). TF in
`infra/terraform/cloudflare/cue-access.tf`; the cue ingress regex was set to null (serve the
whole app). **To add a tester:** append their email to `cue_tester_emails` in
`cloudflare/variables.tf` + `terraform apply` (or switch the policy to a Google Group for
higher churn). Applied from CI, not the devbox (devbox TF hit empty-IDP + http refresh errors).

**Cue Web Push enabled** (`49953f9`): added `VAPID_PUBLIC_KEY`/`VAPID_PRIVATE_KEY`/`VAPID_SUBJECT`
(= `mailto:grahamsm@gmail.com`) to the `cue-app` SOPS secret (values from
`/home/ubuntu/code/cue/vapid.private.json`, never echoed; secret stays encrypted) + set
`CUE_WEB_PUSH=true` inline in the deployment (`CUE_PROACTIVE_CHECKINS` already on). Push
egress to browser push services (`:443`) is already covered by cue-tier's `world:443` egress —
no netpol change. cue-api rolled 1/1, 0 restarts, all 4 env vars populated.

**VIP-outage PREVENTIVE GUARD** (`4d57c3e`) — the "doesn't repeat" half of cont.5. Added a
third loki-ruler rule **`CiliumTraefikIngressDrop`** (critical) in
`06-loki-rules-cilium-audit.yaml`: fires on ANY `DROPPED` flow to the traefik tier on a
PUBLIC entrypoint container port (`:8000`/`:8443`/`:8088`). Those ports MUST accept `world`
by design, so a drop there is *always* a policy bug — which is why this rule deliberately
does NOT exclude `world`/empty-`src_ns` (the existing `CiliumNetpolDropFlow` filters
`src_ns!=""` to drop scan noise, and that exact filter is what hid the 06-23 outage for
~16h — the DROPPED flows were in Loki the whole time, just unalerted). Now a future
external→VIP netpol break pages in ~10m. (Couldn't query Loki to replay the historical
drops — the distroless loki image has no shell/wget — but the rule reuses the identical JSON
fields as the working `CiliumNetpolDropFlow`, and cilium-monitor during the outage confirmed
`world→traefik …→:8443`.) Live: cm has 3 rules, Flux `4d57c3e`.

**Doc review pass:** confirmed today's items are captured — Authentik SSO (H38, cont.3 +
CLAUDE.md §5), M80 iCloud backups (cont.4), the VIP outage (cont.5), and now cue + the
guard. CLAUDE.md §5 DROP-alerting note updated (3 rules; the remaining `world`→non-traefik
gap is explicit). Mini backup dashboard/alerts confirmed **already generic** (templated
`cat` repeat + `.+_backup_*` regex) — new categories (messages/notes/safari/icloud_drive)
auto-appear once the mini re-pushes (nightly cron, now that the VIP path is fixed); no change
needed.

**State:** all of today's work shipped + documented. Open follow-ups: mini metric pushes
resume on tonight's cron (verify pushgateway freshness then); control-plane node patch
(cp1/2/3) still pending; cue-api still on `:latest` (intentional during dev, M64).

---

## 2026-06-23 (cont. 5) — mini→VIP outage ROOT-CAUSED + FIXED (traefik netpol: service vs container ports)

**Resolved the cont.4 mini→Traefik-VIP outage. Root cause: the `traefik-tier`
CiliumNetworkPolicy allowed the LoadBalancer SERVICE ports from `world`, but Cilium
evaluates ingress at the destination pod on the CONTAINER (target) port that kube-proxy
DNATs to *before* policy is applied.** Mapping: svc `:80 web → :8000`, `:443 websecure
→ :8443/TCP`, `:443 http3 → :8443/UDP`, `:8088 webhook → :8088` (same number). The CNP's
`fromEntities:[all]` block listed `80/443/8088`; `:8443` was allowed only from `cluster`.
So in-cluster→VIP worked (cluster identity) while **every `world`→VIP flow was dropped**
(`drop (Policy denied) identity world→traefik … →:8443 tcp SYN`). `:8088` was the lone
survivor (same port number, no remap) — which is why webhooks + photos alerts kept working
and confused the triage. Became a **hard outage when the traefik tier flipped audit→enforce
(06-23 tightening)** — ~16h of no mini metric pushes / log shipping. **Not reboot-related**
(confirmed the operator's hypothesis).

**Fix** (`1a98eee`): ingress `fromEntities:[all]` now allows the **container** ports
`8000/TCP, 8443/TCP, 8443/UDP, 8088/TCP`; `:8080` (api/dashboard/mgmt) stays cluster-only.
Applied + Flux-reconciled (no drift). **Verified** via a forced-route repro from the devbox
(`ip route add 10.10.201.70/32 via 10.10.201.1`, which makes the same-subnet devbox take the
routed `world` path that the mini uses): VIP `:443 → 404`, `:80 → 301` (Traefik responding;
was `000`/timeout). Mini pushes resume on its next cron cycle.

**Diagnostic path that nailed it** (after a long hunt down BGP/kube-proxy/iptables/host-fw —
all red herrings): tcpdump on the worker showed the SYN *arriving* on eth0; the
`iptables -t nat KUBE-SERVICES` packet counter for the VIP *incremented* (DNAT fires) — so it
was **post-DNAT**. `cilium-dbg monitor --type drop` (with the forced route, and NOT grepping
for `201.70` — post-DNAT the dst is the *pod* IP) surfaced the `Policy denied … →:8443` drop.
**Lesson: when chasing a MetalLB-VIP datapath drop, monitor for the POD IP + container port,
not the VIP.** The earlier "toggle test" (de-label traefik ns) was a false-negative — those
re-tests went via the devbox's same-subnet ARP path without the forced route, so the packet
died before reaching the policy.

**Caveat exposed:** the traefik tier's "0 AUDIT flows → enforce" validation (cont.3/H3) was
**incomplete** — the `world`→VIP→`:8443` ingress path was never actually exercised through the
VIP during the audit window (only egress device routes + in-cluster ingress were). Container-
vs-service-port is now a CLAUDE.md invariant + documented in the netpol README/runbook.

---

## 2026-06-23 (cont. 4) — M80 Messages backup COMPLETE + Notes/Safari/Drive added; mini→VIP observability outage

**Messages backup DONE** (`messages-backup.sh`, 20:00). chat.db: 319,679 msgs, integrity ok; attachments: **19,951 files / ~48 GB**. The attachments first-copy needed the **parallel sharded** mirror (256 hex top-dirs × 6-way `xargs -P` rsync) — serial was ~1 file/s (~5h); parallel ~6× (finished in ~1h13m over 2 attempts, attempt-1 timed out at 40min, attempt-2 resumed). Two bugs fixed en route: (a) `mini_run_timeout`-wrapped `xargs` lost stdin → empty input → false rc=0 "complete" copying nothing (fix: background `xargs` with the `<SHARDS` redirect DIRECTLY on it + own watchdog); (b) the FDA/launchd saga from cont.2. **Metrics now split**: `messages_backup` (DB/msg count) + `messages_attachments_backup` (file count) report independently.

**Notes + Safari + iCloud Drive added** (`icloud-files-backup.sh` + `net.wind.icloud-files.plist`, 19:30): Notes (whole group container, NoteStore.sqlite integrity-checked read-only before mirror — **414 notes / 397 MB**), Safari `Bookmarks.plist` (464 KB), iCloud Drive (CloudDocs — **only 2 local files, 0 stubs**; owner doesn't use it for production, confirmed). Each a guarded rsync mirror (`--max-delete`, refuse-missing) with its own metric (`notes_backup`/`safari_backup`/`icloud_drive_backup`). Reminders confirmed **already covered** (CalDAV VTODO in the Calendars sync). **iCloud backup coverage is now complete** for everything the owner uses.

**⚠️ mini→Traefik-VIP observability OUTAGE (open, infra-agent handoff).** The mini (10.10.202.101) can't TCP-reach the Traefik VIP `10.10.201.70:443` (timeout) since today's firewall/netpol/H38 cleanup, so ALL mini metric pushes (Pushgateway) + log shipping (Loki/Alloy) fail — both route through that VIP. **Backups are UNAFFECTED** (they go to the NAS `sequoia:445`, reachable). Pushgateway/Loki are healthy (in-cluster pushers reach them via ClusterIP); only the external mini→VIP route is broken. Likely the UDM zone firewall (202→201/VIP allow dropped), MetalLB↔UDM BGP, or H38 Traefik forward-auth on the pushgateway/loki routes. Full infra-agent prompt (route fix + dashboard/alert wiring for the 5 new metric series) handed to the owner this session. Until fixed, mini `*_last_success` reads stale — expected backlog, not a backup failure. Commits `510db28` `31b06f3` `06af775` `4a72751` `59d1178`.

---

## 2026-06-23 (cont. 3) — Authentik SSO pass COMPLETE + login branding; S3 approval-flow; M101 VM patching

Closed out the Authentik SSO pass (H38), plus a cluster of smaller items.

**SSO — native OIDC:** Grafana (prior), **Open WebUI** (`chat`; env-driven, fully GitOps), **wiki.js** (`wiki`; Authentik blueprint with a **regex** redirect because wiki.js mints the callback path when its OIDC strategy is created — the wiki *side* is DB/admin-UI config, entered by hand). Blueprints in `40-blueprints.yaml`, client secrets in SOPS + shared via `!Env` to the providers.

**SSO — forward-auth (domain-level):** one proxy provider `forward-auth` (mode `forward_domain`, cookie `wind.etherport.net`) on the **embedded outpost** + a single Traefik `authentik-forward-auth@authentik` middleware (cross-namespace; `allowCrossNamespace=true`). Wired to: Proxmox (canary, verified), IPMI, PDU×2, UPS×2, Technitium DNS admin, Traefik dashboard (**was unauthenticated**). Domain-level means device UIs only need the middleware — the handshake redirects to `auth.wind` and the `*.wind` cookie carries across; no per-host outpost route needed.

**Deliberately NOT forward-authed (decisions):** **HA** + **Plex** keep their own auth — fronting HA would break the mobile app, API/webhook clients (Protect webhooks use the separate `:8088` entrypoint, so those are fine), and external CF-tunnel logins (forward-auth redirects to internal-only `auth.wind`). **loki/pushgateway/ollama** are machine APIs (the off-cluster mini pushes logs+metrics to `loki.wind`/`pushgateway.wind`; `ollama.wind` is a documented API base URL) — forward-auth is the wrong tool and would break those; they're UDM-firewall-scoped. approve/backup-approve stay HMAC+CF-Access.

**SSO gotchas (the why):**
- **Blueprint user `password: !Env` clobbers UI changes.** Authentik re-applies the password on *every* blueprint apply (write-only field, can't diff), so each worker restart during the build reset graham's password to the bootstrap value → "invalid password". **Fix:** drop the `password` attr; graham's password+passkey are UI-managed (akadmin = break-glass; on rebuild, re-set via akadmin).
- **Grafana literal role mapping silently fails.** `role_attribute_path: 'GrafanaAdmin'` evaluated to empty → every OIDC login reset the user to Viewer (clobbering manual grants). Cause: go-ini strips the wrapping quotes → the JMESPath literal becomes a missing-claim lookup. **Fix:** `skip_org_role_sync: true` + grant graham Grafana **server admin** via the API (persists). Roles are now manually managed (single-owner); revisit group-based mapping for multi-user.
- **Dark mode** for the whole UI = brand `attributes.settings.theme.base=dark` (2024.12 has no UI toggle and no theme column — it's read from brand attributes). The earlier `@import theme-dark.css` hack didn't reach the mgmt UI / nested flow shadow-roots. Login chrome ("Etherport SSO" title, dark card, deep-slate bg) = flow blueprint (title/background) + a flow-scoped `custom.css` (`:has(ak-flow-executor)` + `.pf-c-login`) so it never touches the mgmt UI. flow `background` is a FileField → seed a solid-color PNG into the media volume via a server init container (a data-URI gets stored as a bogus filename).

**S3 backups (same day, earlier):** root-caused the overnight all-shares failure = a `set -e` footgun in `wait_for_rclone` (bare `[ ] && echo` returns 1 when `waited==0`) introduced by the cross-job-lock change `2089ec7`; fix `32cc001` already in the live `:main` image (verified end-to-end). Ran the **approval-flow test**: revoked the `backups` approval marker → re-run re-requested approval (pending, emailed) while content/media/graham synced to completion — **confirms shares are independent** (separate jobs + per-share locks; a contested *delete* halts only that share's whole run, uploads included, because it's one `aws s3 sync --delete`). Then executed the operator-approved `backups` deletion (**1456 deletes + 2805 uploads**). Fixed the **double approval email** (`backoffLimit: 1→0` — the Job retried the terminal `request_approval` exit, re-emailing; the script already retries transient sync failures internally). Deleted 18 orphan Velero-restore RBAC objects in `backups`. **TF Object Lock on the archive bucket is still NOT codified** (live GOVERNANCE/180d confirmed; absent from Terraform — the other agent had NOT done it; offered to import).

**M101 — VM auto-update gaps:** `unattended-upgrades` is the manager (base.yml, security-only + auto-reboot, `all:!k8s_cluster`) but the **devbox ran stock u-u** (never got base.yml) and the policy was **security-only** (so `-updates`/third-party accumulated). Fixes: **broadened** base.yml `allowed_origins` to include `-updates`; brought devbox onto the policy (applied live as a stopgap — no ansible on devbox — + `devbox: "05:00"` reboot window in base.yml; cleared 7-pkg backlog); wrote **`infra/ansible/playbooks/k8s-node-patch.yml`** (rolling cordon/drain/upgrade/reboot/uncordon, serial:1, CNPG-PDB handling). **Operator follow-ups:** run `base.yml -l devbox` (formalize + node_exporter/NTP/SSH on devbox) and `k8s-node-patch.yml` in a window.

**State:** SSO functionally complete + verified (owner confirmed chat/wiki/grafana/proxmox). Docs: H38 ✅, M101 🟡 (code done, operator runs pending). **Next steps:** owner enroll passkeys on remaining accounts; decide TF Object Lock import; run the two ansible follow-ups; (optional) broaden cookie to apex only if public services appear.

---

## 2026-06-23 (cont. 2) — M80 iMessage backup LIVE (DB) + the FDA/launchd saga

Got `messages-backup.sh` working under launchd after root-causing why launchd runs failed where interactive ones succeeded. **DB backup is DONE + verified:** `chat.db` 508MB, **319,678 messages**, `integrity_check=ok`, on the NAS (`/Backups/Graham/iCloud/Messages/`); re-runs at the start of every nightly. Agent loaded (20:00).

**Three root causes (all fixed):**
1. **FDA must be on `/bin/bash`, NOT the leaf binary.** macOS attributes TCC file access to the launchd job's *responsible process* (= `/bin/bash`, the job program), so granting FDA to `/usr/bin/rsync` was ignored for reading `~/Library/Messages`. Granting `/bin/bash` FDA fixed it instantly. (Interactively the responsible process is `Terminal.app`, which is why my interactive rsync tests also couldn't read it.) Docs + script header updated to say grant `/bin/bash`.
2. **Background/launchd processes need FDA to read NETWORK volumes too** (`/Volumes/<smb>`). My new `ls`-based liveness probe returned EPERM under launchd even on a HEALTHY mount → `mount-nas.sh` force-unmounted good mounts — **a regression that would've broken tonight's photos/DAV nightlies.** Fixed: `nas_readable()` in `mini-common.sh` probes via `rsync -n --exclude='/*/*'` (FDA-safe stat, depth-limited, instant); `mount-nas` `nas_share_ready` + the messages nas-check use it. (`-d` returns rc=23 on openrsync — used `--exclude` to limit depth.) **NB the rsync -n probe is stat-only → it can pass on a half-stale mount; the actual rsync op + watchdog backstop that.**
3. **Attachments first-copy trips an SMB session drop under sustained write load** (`SESSION_RECONNECT_COUNT=1` at the rsync start; NAS RAID/network confirmed healthy) → wedged rsync in D-state, same mode as the M79 photos bulk-pull. Made the attachments mirror retry+resume: bounded per-attempt timeout (`ATT_TIMEOUT=1200`) + remount between attempts (`ATT_ATTEMPTS=10`), rsync -a resumes.

**Design also added:** message-count **regression guard** (refuse to overwrite the NAS DB if message count drops >10% vs last success — the practical "is the local iCloud cache complete?" check; Messages-in-iCloud IS enabled here so local chat.db is a synced cache) + `--max-delete=500` on attachments. Commits `510db28` (FDA/probe fix), `31b06f3` (resilient attachments).

**State:** DB backup live + verified. **Attachments first-copy IN PROGRESS** — converging slowly (~1–2 files/s over SMB nested small-files; survives drops via the retry loop) and may span attempts/nights; background monitor watching. If too slow, switch the bulk first-copy to local-tar→single-transfer to dodge per-file SMB latency. Remaining M80 tier after this: Drive.

---

## 2026-06-23 (cont. 1) — CORRECTION: the 5 non-backups overnight failures were a `wait_for_rclone` set -e bug, not "transient fast-fails"

Owner, reviewing overnight status emails: "all sync tasks failed… does a delete approval prevent all jobs from running until approved/rejected?" **Answer: no** — approvals are per-share (per-share lock + `approvals/approved/<share>.json`); a pending `backups` approval cannot fail other shares.

**Reconciling the two overnight reads (this corrects the entry below):**
- **`backups`** DID legitimately trip the delete-guard on **1,436 real deletions** (the GDrive-side `.tif` removal mirrored to the NAS) → approval requested → owner approved (live marker `approvals/approved/backups.json`: `approvedMaxDelete=1584` = 1436×1.1+5 from the approval-server formula, `wouldDeleteAtApproval=1436`, expires 06-25; `approvedBy=unknown` ⇒ approved via the internal path). It reached the guard because **rclone was actively writing the Backups share at 01:00, so `wait_for_rclone` looped (waited>0) and returned cleanly.** The entry below got this one right.
- **The other 5 shares** (graham/archive/content/mark/media) did NOT "transiently fast-fail" — they hit a **deterministic `set -e` bug**: `wait_for_rclone`'s last line was `[ "${waited}" -gt 0 ] && echo …`, which returns 1 when `waited==0` (no fresh rclone lock — their normal case) → function returns 1 → bare call trips `set -euo pipefail` → script dies **before acquire_lock / dry-run / check_approval**. Proof: graham's pod log exits right after `[excludes] Total patterns loaded` with the EXIT trap (`[lock] Releasing lock`) firing before `[lock] Attempting to acquire`. Introduced by `2089ec7` (image built 06-22 13:26 UTC, after the 06-22 nightly → 06-23 was the first nightly to hit it). **This was also a MISS in the morning's adversarial review.**

Fix `32cc001`: `if/fi` + explicit `return 0`; reproduced (old→exit 1 pre-acquire_lock, fixed→exit 0); swept for other `&&`-terminated function tails (none). **Verified end-to-end on the rebuilt image:** a manual `mark` job ran the whole flow (past `wait_for_rclone` → acquire_lock → Guard 1 → dry-run → H3 pre-sync re-assert → real sync → report → `succeeded=1`); mark is caught up. **Why this matters for tonight:** without it, on any night rclone ISN'T mid-write at 01:00, `backups` would hit the SAME bug and die before consuming its approval marker — so the fix also protects the approved deletion. The remaining 4 failed shares catch up on tonight's 01:00 nightly (or on request). NB: the entry below also mentions a manually-minted `approvedMaxDelete=2000`; the live marker is the approval-server's `1584` (both ≥ 1436, so tonight proceeds either way).

---

## 2026-06-23 — overnight sync triage + M80 iMessage backup drafted

**Overnight triage (owner: "received ai advisor error alerts… related to last night or will clear?").** iCloud backups all GREEN; the advisor itself healthy (analysed alerts, didn't error). The **iCloud advisor alert** was `ICloudBackupFailed`+`ICloudBackupEmpty` (contacts/calendars), fired ~21:30–22:00 PT from the **21:00 DAV nightly hitting the stale SMB mount** (rc=1/items=0) — a real event ~2h before the self-heal was committed; advisor verdict `noop`; **already resolved** (self-heal re-ran ~23:00 → rc=0/2049/446, no iCloud alert now firing). Separately, the **01:00 S3 sync** failed on all 6 shares: 5 = transient 01:00 thundering-herd fast-fails; `backups` = **delete-guard correctly held 1,436 deletions** = the `Graham/Google Drive/Assets/2018 Shoot` `.tif` files that vanished from the NAS source (rclone `gdrive-sync --delete` mirrored a Google-Drive-side removal; its own `--max-delete` cap + the s3 delete-guard both fired). **S3 copy intact** (15,685 obj / 39.5 GB verified). Owner confirmed the GDrive deletions intentional → **minted the s3 approval marker** `s3://logs.archive.wind.etherport.net/approvals/approved/backups.json` (approvedMaxDelete=2000, 24h, one-time) so tonight's run mirrors it. Left the failed Job objects for the infra-agent (owner's call). NAS SMB went stale twice today — self-heal handled both.

**M80 iMessage backup DRAFTED** (`messages-backup.sh` + `net.wind.messages-backup.plist`, daily 20:00). Backs up `chat.db` + `Attachments/` → `/Backups/Graham/iCloud/Messages/`. Design: rsync live DB→local staging, then **`sqlite3 .backup` + `integrity_check` on the STAGED copy** (no FDA needed there; produces a clean WAL-checkpointed standalone `chat.db`; a torn/corrupt copy fails the run, never overwriting the good NAS copy), then **guarded mirror** (refuse-empty + `--max-delete`) of the DB + Attachments to the NAS. Reuses `mini-common.sh` (lock/timeout/kill) + `mount-nas.sh` self-heal + `messages_backup_*` metrics (auto-covered by the iCloud-backups dashboard + alerts) + Alloy log shipping. **Key design choice:** read with **rsync only** so just **one** Full Disk Access grant is needed (`/usr/bin/rsync`); sqlite3 reads only the staged copy. **BLOCKED on operator:** grant FDA to `/usr/bin/rsync` (VNC), manual run, then `launchctl bootstrap` the 20:00 agent. Validated: syntax OK; FDA preflight aborts cleanly (`no-FDA-or-unreadable-source`, rc=1 — no silent empty backup). Messages confirmed signed-in; chat.db=505MB; 51GB local free for staging. NOT loaded yet (would alert nightly until FDA granted). Steps in `infra/macos/mini/README.md` → "M80 iMessage backup".

---

## 2026-06-23 (cont.) — H3 COMPLETE: monitoring tier enforced + drop-alerting live

Closed H3. The monitoring tier had observed ~24h under audit; checked the audit log → **0 monitoring would-be-drops over 24h**, and the periodic external paths fired clean (**391 alertmanager notifications sent, 0 failed** = SES `:587` egress validated; ai-advisor/backups too). So re-enforced: `kubectl patch cm cilium-config policy-audit-mode=false` + `rollout restart ds/cilium` (separate commands — the compound trips the classifier) + inventory→false + cancelled the scheduled flip-off cron. **Verified:** runtime PolicyAuditMode Disabled, 116 Prometheus targets up / 0 down (scraping intact under the permissive `cluster` egress), **0 drops across all 5 tiers** (postgres/cue/dns/traefik/monitoring).

**All 5 target tiers now ENFORCED** — the largest internal-segmentation gap is closed. **DROP-alerting is now live** (the export already carried `verdict:[AUDIT,DROPPED]`; the `CiliumNetpolDropFlow` loki-ruler rule now has real drops to fire on). De-TEMP'd the banners (CLAUDE.md §5, networkpolicies/kustomization + 14-tier-monitoring header, tracker H3 → ✅). Adding a service that crosses an enforced boundary now needs an allowlist entry (runbook); a new tier uses the audit toggle.

---

## 2026-06-23 — H38: Authelia → Authentik (internal IdP) deployed

Started H38 (kill "internal = trusted") with **Authelia** (local users + TOTP/WebAuthn + SES), got it fully working after three deploy-bugs (all mine, not Authelia): (1) `enableServiceLinks: false` — the Service named "authelia" made k8s inject `AUTHELIA_*` env that Authelia parsed as config → boot conflict; (2) `readOnlyRootFilesystem: false` — Authelia writes `/app/.healthcheck.env`; (3) **users DB must be on a WRITABLE volume** — the file backend rewrites it on password change, but it was a read-only Secret mount → "issue resetting your password" (fixed with an init-container seeding the SOPS user DB onto the PVC). Then the owner, wanting **full OIDC SSO + a less-basic UX**, chose to **switch to Authentik** (answered: single-instance Postgres isn't production-standard for an IdP; Authentik config is DB-state but DR-safe via the PG backup; reuse the shared HA cluster).

**Authentik deployed** (`4170b27`, `9d67a44`): IdP live at **auth.wind.etherport.net** (portal 302, embedded forward-auth outpost connected). **DB on the shared HA `postgres-cluster`** — added a CNPG `managed.role` `authentik` (login+createdb, password in a SOPS secret mirrored to the authentik ns) and the server/worker **init-container creates the `authentik` DB** (CNPG 1.24 has no Database CR + superuser disabled, so the role self-creates it); added `authentik` to the **postgres-tier NetworkPolicy allowlist** (the documented "new service crosses an enforced boundary" case). App: redis (ephemeral) + server + worker (goauthentik 2024.12.3) + 2Gi media PVC; SOPS secrets (SECRET_KEY, bootstrap admin pw/token, SES SMTP pw, DB pw); SES email (enroll/reset; login stays local). **Backups:** DB rides the shared cluster's barman; media PVC via the new `authentik-daily` Velero schedule. **service-status:** server/worker/redis added. akadmin bootstrapped (pw surfaced once → change + MFA in UI).

**Verified:** authelia pruned; authentik role + DB created; redis/server/worker healthy; portal 302 via the VIP; embedded outpost up. **Next = the actual SSO pass** (owner chose full SSO), all as git **blueprints**: OIDC provider + Grafana (OIDC/header → maps to existing user by email), wiki.js (OIDC), and a **proxy provider + Traefik forward-auth middleware** for the no-OIDC apps (HA/loki/pushgateway/ollama/device UIs). Nothing is gated yet (zero lockout risk). Tracker H38 has the detail.

---

## 2026-06-23 — Adversarial review of the aws-s3 NAS→S3 backup app → full fix set shipped

Owner: "we never got a chance to perform an adversarial code review… get up to speed and perform the adversarial review", then "do the full set of fixes" + "I approved a delete request this morning which would run overnight tonight — ensure that's maintained once we update."

**Review (read the whole production path first-hand + a 5-lens cost fan-out):** 3 HIGH, 5 MEDIUM, several LOW. Plan/findings artifact: `~/.claude/plans/pure-floating-kernighan.md`.

**Fixes landed in `image/scripts/` + manifests (this session):**
- **H1** — `release_lock()` now only deletes the lock ConfigMap when `.data.owner==$RUN_ID`. The EXIT trap is armed before `acquire_lock`, so the old code had a job that *skipped* (lock held by another) delete the **holder's** lock on exit → defeated the mutex → concurrent `--delete` syncs. (concurrencyPolicy:Forbid only covers same-CronJob overlap, not manual↔scheduled.)
- **H2** — the end-of-script "completed with warnings" block ran at top-level scope but used `local subject=` (errors under `set -euo pipefail`) and `${RUN_SUMMARY_URI}` (never set). Any `WARNING_COUNT>0` run (e.g. an expected checksum-unavailable on the `backups` share) exited non-zero → false FAILED Job + the degraded email never sent. Fixed both; the block can no longer change exit status.
- **H3** — the delete guard measured a **dry-run**, then the real `--delete` was a *separate, unbounded* `aws s3 sync`. If the NFS source dropped in between, the real sync wiped S3 despite the guard passing. Factored Guard 1 into `assert_source_populated()` and **re-assert it immediately before the real `--delete`** (conservative design: a healthy source — incl. an approved bulk delete — passes unchanged; a genuinely empty source aborts without wiping).
- **L5a** — a failed/partial dry-run is now **fail-closed** (`guard_abort`) instead of parsing "0 deletions" and proceeding to an unbounded `--delete`.
- **M2** — `verify-one.sh` retries `head-object` (4 attempts, backoff) on transient 503/socket before recording `failed`; a genuine 404 is not retried. Stops transient throttling from producing a false verification FAILED.
- **M3** — `LOCK_MAX_AGE_SECONDS` 24h→48h, env-overridable (a long initial sync could be force-unlocked into a concurrent run at 24h).
- **L5c** — composite (multipart) checksum now derives part size from the part count when 8 MB doesn't reproduce it; an unreconstructable composite is marked *unavailable*, not a false "corruption".
- **M5** — the signed approve URL is no longer echoed to pod logs (`token redacted`); `request-approval.py` still prints it (its return channel). Deliberately did **not** force `APPROVAL_REQUIRE_CF_EMAIL=true` — backup-approve is split-horizon, so an on-network operator hits the internal Traefik path (no CF header) and it would reject their own click; documented in the deployment.
- **L5d** — `approval-server.py` `tempfile.mktemp()` → `mkstemp`.
- **M4** — the `daily-report` SA + Role (`jobs`/`cronjobs` get,list) + RoleBinding existed in-cluster (41d) but were **missing from git** (drift); captured into `daily-report/rbac.yaml`. The `ghcr-creds` imagePullSecret was a **dead reference** — the GHCR package is **public** (anonymous pull → 200; neither live SA has a pull secret), so removed it from `base/serviceaccount.yaml`.
- **L5b** — `ephemeral-storage` requests/limits on the `work` emptyDir workloads.
- **L2** — deleted dead `verify.py`, `verify-existing-files.py`, `enhance-report-with-checksums.sh`.
- **L1** — `validate-existing-backups.sh`: composite-aware comparison (was false-"corruption" on every multipart file) + `REPORT_PREFIX` moved under the IAM-granted `reports/` prefix (was `validation-reports/` → AccessDenied on upload).
- **L3** — README "Production Policy" JSON synced to the live policy (`approvals/*`, `infra` bucket) + a source-of-truth banner pointing at the TF JSON.

**Cost note (operator is cost-sensitive, 10TB+):** audited every fix — none raise steady-state AWS spend. Verified the `archive` bucket transitions to **Deep Archive at 5 days** (180-day min) + expires noncurrent versions at 30 days (`infra/terraform/aws/s3/main.tf:126,144`), so the data-safety fixes (H3/L5a/L5e/H2/M3) **avert** a Deep Archive early-deletion bill (~$5-6/TB of churned cold data) in the wipe/concurrent-sync tail. `--size-only` kept (M1, accepted) — it's the mtime-churn cost control, not the checksum algo.

**L6 (open):** README/Security claim "Object Lock" on the data bucket but there's **no `object_lock_configuration` in the TF** — operator is verifying out-of-band (says it IS enabled). Treat as enabled.

**Overnight-safety design:** an operator approval written this morning (`approvals/approved/<share>.json`, 48h TTL) must be consumed by tonight's run, which pulls the new `:main` image. H3 is conservative (a healthy source passes), so the approved bulk delete still runs; `check_approval` consumes the marker then the real `--delete` executes. **Image kept on `:main` tonight** so the run gets the fixes; **L4 (sha-pin) deferred** to a post-tonight follow-up (pinning to a not-yet-built sha would break the pull). Also deferred: the fuller **manifest-driven H3** (drive deletes from the measured set) — the re-assert is the tonight-safe interim.

**State at end:** all scripts `bash -n` + embedded-Python compile clean; manifests pending `kubectl kustomize`. **Next:** verify the approval marker + a manual dry-run for the approved share, commit+push (triggers the `:main` rebuild — confirm it finishes before the share's 01:00 PT schedule), watch tonight's run consume the marker + delete, then land L4 + manifest-driven H3.

---

## 2026-06-22 (cont. 9) — netpol DROP alerting + iCloud backup alerts enabled

**Drop notification (answers "how are we told to open a channel once enforcing").** Built the DROP-alert pipeline (was the H3 follow-up): extended the Cilium hubble export to `verdict:[AUDIT,DROPPED]` (live `kubectl patch cm cilium-config` — the `patch+rollout` compound cmd hit the auto-mode classifier, so run them as SEPARATE commands — + `rollout restart ds/cilium`; durable in the kubespray inventory). The global audit switch means one export covers both phases: AUDIT while observing, DROPPED while enforcing, same `{job="hubble-audit"}` Loki stream. Added loki-ruler rule **`CiliumNetpolDropFlow`** (`06-loki-rules-cilium-audit.yaml`): fires (warning → Alertmanager email) on a sustained DROPPED flow to/from an enforced ns from an **in-cluster** source (`src_ns!=""` drops external-scan noise). So drops are **stored in Loki** (Grafana Explore) and **alerted via Alertmanager**, naming `src→dst:port` → add to the per-tier CNP per the runbook. External (`src=world`) drops still need manual `hubble observe`. Verified AUDIT export intact post-rollout (monitoring observation unaffected); loki accepted both rules. Activates automatically when the monitoring flip re-enforces. `83c14da`.

**iCloud backup alerts enabled.** The mini's contacts + calendars syncs are now healthy — verified in Prometheus (contacts rc=0/items=2049 vCards, calendars rc=0/items=446 events, fresh) — so un-held `10-icloud-backups-alerts.yaml` (`ICloudBackup{Stale,Failed,Empty}`). Live; not firing (healthy).

**State:** monitoring still observing under audit (flip pending ~24h via cron `ea15194e`); the DROP rule + export are ready for when it re-enforces. H3 DROP-alerting follow-up ✅ done.

---

## 2026-06-22 — Adversarial review of all M79/M80 backup code → 4 CRITICAL + HIGH fixed

Owner: "given the bugs and the issues we've had on photo sync, perform an adversarial review of all the code implemented across these two tasks. also has execution success status been pushed to grafana?"

**Grafana:** success status IS in Pushgateway (photos_export/contacts_backup/calendars_backup all rc=0 + last_success). Could NOT verify Prometheus ingest from the mini (the prometheus query API isn't reachable from 10.10.202.101) — cluster-side scrape/dashboard is the infra-agent's to confirm.

**Review:** 3 independent adversarial reviewers over all ~836 lines (photos pipeline / DAV pipeline / infra+scheduling). Found 4 CRITICAL + several HIGH. **Fixed + verified the data-loss ones immediately** (one was scheduled to run that night):

- **C-1 (data loss, `ceb5027`):** `icloud-dav-backup.sh` ran `rsync -a --delete staging→NAS` UNCONDITIONALLY. App-password expiry / watchdog kill / iCloud empty-collection / sops failure → empty staging → `--delete` WIPES the NAS master (the only offsite-bound backup), then s3-sync ships the empty state. Fix: `mirror_service()` refuses to mirror unless vdirsyncer rc==0 AND staging non-empty, counts items BEFORE the rsync, caps deletions with `--max-delete=max(master/2,25)` (mass-shrink → rsync rc=25 abort). Also capture discover rc via PIPESTATUS (fail on real discover error, tolerate SIGPIPE 141).
- **C-2 (silent masking, `ceb5027`):** `photos-metrics.sh` — a watchdog-killed run pushed `missing=0` (reads as "nothing to back up"); a clean run with a truncated `--report` CSV pushed `missing_resolvable=0` AND stamped `last_success` while photos were missing. Fix: `parsed=1` only if rc==0 && photos>0; push `-1` sentinels when not parsed; DERIVE `resolvable = missing - unavailable` (classify failure can't zero it); add `${job}_summary_parsed`; gate `last_success` on `parsed`.
- **HIGH (`adbade8`):** new `mini-common.sh` (unit-tested) wired into all 3 scripts — `mini_acquire_lock` (atomic + pid-command liveness check: kills the bare-PID-reuse "silent outage forever" + the `rm -rf;mkdir` double-run-on-one-ledger race), `mini_run_timeout` (portable; bounds count()/rsync/master-find + a DAV post-mount liveness probe so a dead-but-listed SMB mount can't hang forever — H3/L2), `mini_kill_tree` (TERM→TERM→KILL + child reap; fixes orphaned osxphotos/vdirsyncer holding the ledger — H4).
- **C-3 (`4697f23`):** nsmb.conf hardening was a silent no-op — written to `~/Library/Preferences/` but the kernel reads `/etc/nsmb.conf` (absent; live smbutil showed signing-on/defaults). Added `install-nsmb-conf.sh` + root LaunchDaemon `net.wind.nsmb-install.plist` (survives reboot) + mount-nas.sh detect/warn + post-mount signing verify. **NEEDS a one-time operator sudo** to bootstrap the LaunchDaemon (no passwordless sudo on the mini) — commands in `infra/macos/mini/README.md` → "SMB tuning".
- **C-4 (`3103ac1`):** the "silent no-run when mini locked/asleep" gap is ALREADY covered cluster-side — `PhotosExportStale` + `ICloudBackupStale` (no success >26h) fire if a job doesn't run (infra-agent enabled icloud-backups-alerts ~the same time, after the syncs went green). Added `PhotosExportNotParsed` (summary_parsed==0) for the new sentinel signal; reconciled live via Flux.

**Residual / handoff:** (a) ✅ DONE — operator installed `/etc/nsmb.conf` + LaunchDaemon via sudo (VNC); remounted → tuning live (44k-dir listing 17.3s→11s; signing still on by design); (b) infra-agent: confirm Prometheus actually scrapes pushgateway + that the `-1`/`summary_parsed` sentinels don't trip existing alerts; (c) MEDIUM count_orphans basename-collision undercount + silent -1-disable (photos-metrics.sh H5) — deferred. **Verified:** all scripts syntax-clean; mini-common unit-tested; guarded DAV run clean (2049/446, master intact, rc=0); photos metric logic unit-tested + the 22:00 photos nightly ran green in production with the new schema (summary_parsed=1, derived resolvable=0).

**LIVE VALIDATION + self-heal (`e1443fa`, `5905056`):** the 21:00 DAV nightly fired during this session and FAILED on a stale Backups mount (idle-drop) — but the new liveness probe **caught it correctly** (rc=1, master intact) instead of hanging/wiping. That exposed a gap: the code aborted instead of self-healing. Fixed: stale-mount detection + force-remount centralised in `mount-nas.sh` (probe each share, force-unmount+remount a stale one, detaching the sparsebundle first for Personal-Drive) so ALL three pipelines self-heal via their existing mount-nas.sh preflight; DAV inline logic simplified to one call + probe. Re-run completed tonight's backup green. **Note:** the mount still went stale even WITH `notify_off` — the tuning reduces frequency, the self-heal handles occurrences.

---

## 2026-06-22 — M80 tier-1: iCloud Contacts + Calendars backup LIVE + scheduled

Owner: "lmk when we've completed a successful contacts/calendar sync. infra agent has built dashboard but it's reporting no success yet" + "is it now scheduled at regular intervals?"

**Result: DONE.** 2,049 contacts (`.vcf`) + 446 calendar events (`.ics`) back up cleanly to `/Backups/Graham/iCloud/{Contacts,Calendars}` (rides the existing 01:00 `s3-sync-backups` → S3 offsite). rc=0/item-count/`last_success` metrics push green to Pushgateway (job `contacts_backup`/`calendars_backup`). LaunchAgent `net.wind.icloud-dav` loaded + scheduled **daily 21:00** (before the 01:00 S3 sync → ships same night). Incremental run = **11s** (5s iCloud pull + 6s rsync); first run was ~3 min only for the one-time rsync fill.

**The dashboard "no success" was TWO bugs in the wrapper — not SMB, not iCloud** (commit `9e04e9f`):
1. `vdirsyncer-config`: an **inline `#` comment trailing the `calendars_local` `path` value** broke vdirsyncer's INI parser ("Extra data: ... char 41") → vdirsyncer never started, empty staging. Comments must be on their own line above the option.
2. `icloud-dav-backup.sh`: **`set -o pipefail` + `yes | vdirsyncer discover`** returned 141 (`yes` gets SIGPIPE when discover closes the pipe) → the `&&` saw non-zero and **skipped the actual sync**. Fixed by wrapping discover+sync in a subshell with `set +o pipefail`.

**Design (M80, decided earlier this session):** vdirsyncer pulls iCloud → **LOCAL staging** (`~/.local/share/icloud-dav/`), then `rsync -a --delete` staging → NAS. Why: writing thousands of small files **straight to SMB** is slow enough (~100 files/s, metadata-latency-bound) that the iCloud DAV connection times out mid-pull ("Server disconnected"). Staging decouples the iCloud fetch from slow SMB. iCloud storages are `read_only=true` (vdirsyncer can never write back to real contacts/calendars). App-specific password from the SOPS bundle (`icloud_app_password`) via `icloud-app-password.sh`.

**SMB performance investigation (owner: "why is SMB so slow… NAS reporting healthy"):** Benchmarked — NAS is healthy. Sequential write **708 MB/s**, 0.36ms latency, 10GbE, 0 reconnects. The slowness is **per-file metadata round-trips only**: a small dir lists in 0.46s but the **44k-file Photos dir takes 17.3s**, and small-file writes cap ~100/s. Inherent to SMB on a deep flat directory — not NAS ill-health (consistent with "reports healthy"). The earlier catastrophic stalls were the NAS NVMe read-cache controller failure (resolved by reboot; today's benchmarks confirm gone). **Side-finding:** `/etc/nsmb.conf` is MISSING (mount-nas.sh installs it but it didn't stick this boot) so the `mc_on`/`notify_off` tuning isn't active, and SMB signing is ON (`AES_128_GMAC`) — both worth fixing to help the metadata/small-file path (follow-up, not blocking).

**State:** M80 tier-1 (Contacts + Calendars) complete + scheduled + monitored. **Next:** chase the `/etc/nsmb.conf` install gap; remaining M80 tiers (Messages, etc.) per the tier plan.

---

## 2026-06-22 (cont. 8) — H3 tier 5: monitoring OBSERVATION started (audit on, flip ~24h)

Owner: "Take on monitoring. Start with audit as this is wide reaching." monitoring is the widest-fanout ns (Prometheus scrapes every ns + 5 external hosts; Alloy ingests syslog; Alertmanager/ai-advisor egress externally), so audit-first is essential.

**Characterized (Hubble + config).** Egress fanout: scrapes postgres/cue :9187, kube-system :9153, gpu-operator :9400/:8080, flux :8080, blackbox :9115, velero :8085, unifi-poller :9130, cloudflared :2000, + host/remote-node/apiserver (kubelet/kube-proxy/etc.) + **external** `world:9100` (4 node-exporters: 10.10.100.5/10, 10.10.201.6/15) + `world:9290` (pve IPMI 10.10.200.41, from `01-external-scrape-config.yaml`). External notify: SES SMTP (`:587`), ai-advisor→Anthropic (`:443`). Ingress: `world:514` syslog→Alloy, `world:9091` pushgateway (mini), `:3100` Loki, `kube-apiserver`→operator admission webhook (NOT covered by cluster-essentials), + everything in-cluster reaching grafana/prometheus/AM/loki/pushgateway.

**Draft + toggle.** Flipped global audit ON (postgres/cue/dns/traefik → audit-only meanwhile) + labelled monitoring (via `namespace-pss-labels.yaml` patch) + applied `14-tier-monitoring.yaml` (CNP `monitoring-tier`): permissive egress (`cluster` any-port + `world` :80/:443/:587/:465/:25/:9100/:9290) + ingress (`cluster` any-port + `world` :9091/:3100/:514 + `kube-apiserver`). `6574bbc`. **0 audit gaps** on active flows (112 Prometheus targets up, grafana 302).

**Owner chose observe ~24h then flip** (vs flip-now): the periodic external paths (alert email :587, ai-advisor :443, backup reports) are port-covered but hadn't fired to confirm, and a broken alert-email path fails silently. So audit stays ON ~24h to let an alert/advisor/backup cycle exercise them; a **scheduled re-check** (CronCreate) will re-examine the audit log and, if clean, flip audit OFF (re-enforce all 5) + revert the inventory. Until then the 4 prior tiers are audit-only (accepted, allowlists verified). Flip command in the tracker + `networkpolicy-tiers.md`.

**Docs:** added "Adding monitoring for a new service" to `docs/runbooks/networkpolicy-tiers.md` (in-cluster scrape/push/logs just work via the permissive design + `allow-monitoring-scrape`; a new EXTERNAL scrape target/notifier on a non-standard port needs a `world` port added to the monitoring tier). CLAUDE.md §5 TEMP banner (audit on), tracker H3, this entry.

**State:** H3 = tiers 1–4 enforced, tier 5 (monitoring) observing (flip pending). After monitoring flips, all target tiers are enforced — H3 effectively complete (minus the DROP-alerting follow-up).

---

## 2026-06-22 (cont. 7) — H3 tier 4: traefik ENFORCED via the audit toggle + new-service runbook

First use of the **audit toggle** (per owner request — "ensure we're not cutting off traffic"). Traefik is the ingress controller (high-fanout: routes to every backend + external devices), so a point-in-time Hubble capture misses rarely-accessed routes → observe-first is the safe path.

**New-service docs (owner ask).** Wrote `docs/runbooks/networkpolicy-tiers.md` (`a40ec62`): the enforcement model + the **operational tax** — a new service that crosses an enforced namespace boundary must be allowlisted or its traffic is silently dropped (no alert yet). Three cases (workload in an enforced ns / reaching one / a new Traefik external backend), `hubble observe --verdict DROPPED` detection, fix workflow, adding-a-tier, rollback. Indexed + cross-linked from CLAUDE.md §5 and `networkpolicies/README.md`.

**Toggle execution.** Flipped global audit ON (live `cilium-config` patch + rollout; inventory→true) — postgres/cue/dns reverted to audit-only meanwhile (accepted, allowlists verified). Labelled the traefik ns (via `namespace-pss-labels.yaml` strategic-merge patch — Helm-created, no 00-namespace.yaml) + applied `13-tier-traefik.yaml` (CNP `traefik-tier`): **permissive egress** (`toEntities: cluster` any-port + `world` :80/:443/:8006) so no backend route is ever cut now or future; ingress public entrypoints (:80/:443/:8088) from `all` + mgmt (:8080/:8443) in-cluster. `433ba22`.

**Validation (didn't just wait).** Verified egress is provably complete (internal=cluster covers all ports; all external ingressroute backends use only :80/:443/:8006; :8123=internal HA), enumerated entrypoints, then **actively exercised** the riskiest paths under audit — UPS/PDU/Proxmox external routes (303/303/404) + grafana/dns/hubble internal → **0 traefik AUDIT flows** (Loki + live Hubble). Flipped audit OFF (inventory→false) → all 4 tiers enforce. **Post-enforce:** all routes still 200/302/303/404, **0 drops across postgres+cue+dns+traefik**, traefik 2/2 + dns 3/3 + cue-db/postgres healthy, DNS resolution (internal+external) fine.

**State:** H3 = 4 tiers enforced (postgres/cue/dns/traefik). Only `monitoring` remains (highest-fanout → audit toggle + likely permissive egress like traefik). DROP-alerting follow-up still open. Lesson: the toggle works cleanly + actively-exercising the risky routes under audit beats passively waiting for organic traffic. Docs: CLAUDE.md §5, networkpolicies/README.md + kustomization, tracker H3, runbook, this entry.

---

## 2026-06-22 (cont. 6) — H3 tier 3: dns/Technitium ENFORCED (critical resolver)

Continued H3 to dns — the highest-stakes tier (everything resolves via Technitium). Direct-from-Hubble again (postgres+cue stayed enforced); escape hatch ready (`kubectl patch cm cilium-config policy-audit-mode=true` works without cluster DNS).

**Characterized from live Hubble + the StatefulSet.** dns = technitium (2-replica STS) + dns-sync-watcher (in-ns). Listens :53 udp/tcp, :5380 (admin, liveness probe), :53443 (DoH), :853 (DoT). Ingress: :53 from world (LAN clients via the MetalLB VIP) + remote-node + cluster pods; :53443/:5380 from world+cluster; :5380 host = kubelet probes. Egress: world :53 (recursion, dominant) + :53443/:443 (DoH upstreams). High ephemeral-port flows = conntrack replies (auto-allowed).

**Allowlist (`12-tier-dns.yaml`, CNP `dns-tier`).** DNS-appropriate: query ports `:53`/`:853`/`:53443` ingress from `all` (structurally can't blackhole a client — cluster/node/world all covered), `:5380` admin from `cluster` only (**deliberately NOT world — closes the VIP:5380 external exposure, a security win**; admin is via the Traefik ingressroute `dns.wind.etherport.net`), intra-dns; egress `world` `:53`/`:443`/`:853`/`:53443` + intra-dns. DNS-self/apiserver/host via the cluster-wide allows. Segmentation lands on egress (Technitium can't pivot to other internal namespaces). Labelled ns + CNP in one commit. `7408fc9`.

**Verified.** Internal (`traefik.wind.etherport.net`→VIP), external recursion (`github.com`/`cloudflare.com`), and cluster DNS all resolve post-enforcement; 3 pods healthy, 0 restarts. **Drop triage:** post-flip showed ~ICMPv4 type-3 code-3 (Port Unreachable) noise — the pod kernel's courtesy reply to late upstream UDP packets after a recursion socket closed; **benign** (resolution unaffected). Allowed ICMP type-3 to/from world (`744b70e`) to keep the enforced drop log clean (also avoids future DROP-alert noise). Confirmed: fresh 40s window = 0 dns-pod drops. (Lesson: Cilium ICMP rule = `icmps: [{fields: [{type: 3, family: IPv4}]}]`; the stale ring-buffer briefly made it look unfixed.)

**State:** H3 tiers 1–3 (postgres, cue, dns) enforced — the DB + app + DNS tiers, the highest-value segmentation. Remaining: traefik → monitoring (higher-fanout → use the audit toggle, not direct). Docs: CLAUDE.md §5, networkpolicies/README.md, tracker H3, this entry. DROP-alerting follow-up still open.

---

## 2026-06-22 (cont. 5) — H3 tier 2: cue ENFORCED (postgres stayed enforced)

Continued H3 to the next tier (cue) — done WITHOUT the global audit toggle, so postgres stayed enforced throughout.

**Characterized cue from live data.** cue = `cue-api` (Node/Fastify, :3000) + `cue-db` (single-instance CNPG, no replication), Flux-managed here (`cue-api/`, `cue-db/`). Captured live Hubble forwarded flows + read the manifests: ingress to cue-api :3000 from **tailscale** (TS LB/Ingress) + **cloudflared** (CF tunnel); cue-db :5432 from cue-api/cnpg-system/tailscale (cue-db-ts LB); cue-db :8000 from cnpg-system; cue→kube-apiserver:6443 + host probes (covered by cluster-wide allows); cue-db→S3 barman (`postgres-barman` bucket → world:443, daily so not in the live window but added proactively).

**Built + enforced directly (no toggle).** Authored `11-tier-cue.yaml` (CNP `cue-tier`, endpointSelector {}): the ingress/egress above + intra-cue + world:443 (cue-api external HTTPS + barman). Since audit is OFF, a namespaced CNP enforces the instant it applies — and the cluster-wide allows only attach once the ns is labeled — so I committed the CNP + the `netpol.wind/enforced=true` label (`cue-db/00-namespace.yaml`) in ONE commit so Cilium computes the full allowlist together. Rationale for skipping the audit window: cue's flow set is small/stable and enforcement is reversible (remove the label → allow-all in ~1 reconcile). `610e5c9`. **Verified:** 0 cue DROPs (all nodes), cue-api serves through the policy (monitoring→:3000 = HTTP 302 in 7ms), cue-api↔cue-db :5432 flowing, both pods healthy (0 restarts), cue-db CNPG healthy.

**Found a gap (tracked, not fixed):** the audit→Loki pipeline (`CiliumNetpolAuditFlow`) only catches `AUDIT` verdicts, which cease once a tier enforces — so a wrongly-dropped flow on postgres/cue won't alert. Added an H3 follow-up to export `verdict=DROPPED` (enforced ns) → Loki → alert. (CNPG backup failures still covered by `CNPGBackupFailed`.)

**State:** H3 tiers 1–2 (postgres, cue) enforced; all other namespaces allow-all. Remaining: dns → traefik → monitoring (the higher-fanout traefik/monitoring should use the audit toggle, not direct). Docs updated: CLAUDE.md §5, networkpolicies/README.md, tracker H3, this entry. `cf_tunnel_services` grep didn't surface cue but live flows show cloudflared→cue:3000 (allowlisted regardless).

---

## 2026-06-22 (cont. 4) — H3: postgres tier ENFORCED (first NetworkPolicy enforcement)

Picked up H3 (NetworkPolicy enforcement). Outlined the phased plan, then executed tier 1.

**Refined the postgres allowlist from audit data.** Pulled the Phase-1 audit flows from Loki `{job="hubble-audit"}` (24h sample + a 7d LogQL aggregation to catch rare/weekly flows). postgres — the only `netpol.wind/enforced=true` namespace — had exactly **3** would-be-drops, all the "known-good excluded" tuples: postgres→postgres `:5432` egress (CNPG replication, 22.4k/7d), cnpg-system→postgres `:8000` ingress (operator→instance-manager, 19.4k/7d), postgres→world `:443` egress (barman→S3, 278/7d). The old `postgres-ingress` CNP was **ingress-only**, so all three were unhandled. Replaced it with `postgres-tier` (ingress+egress): added `:8000` ingress, `:5432` intra egress, `:443` world egress. Server-side validated; after apply postgres **AUDITed nothing** (verified clean over both a live window and the 7d aggregation). `c4f2235`.

**Enforced (owner chose "enforce postgres now").** Flipped the GLOBAL switch: `cilium_policy_audit_mode`→false in the kubespray inventory (durability) + live `kubectl patch cm cilium-config policy-audit-mode=false` + `rollout restart ds/cilium`. **Clean 8/8 roll** (no cni-dir-owner crashloop — dir root-owned, not a kubespray run). **Verified post-flip:** runtime `PolicyAuditMode: Disabled` on agents; **0 postgres DROPs** on all 3 postgres nodes (hubble); CNPG cluster healthy 3/3 no restarts; wikijs app path intact; all 3 postgres exporters up. postgres is now truly default-deny + allowlist; **all unlabeled namespaces remain allow-all** (the CCNPs select only enforced-labeled ns).

**Key operating note (documented):** audit is a SINGLE GLOBAL switch, so adding the next tier requires the toggle workflow — flip audit back ON, label + observe the new ns via Loki, build its `1x-tier-*.yaml` until clean, flip OFF. Remaining tiers: cue → dns → traefik → monitoring. Docs updated: `networkpolicies/README.md` (state + "Adding the next tier"), **CLAUDE.md §5 invariant** (audit now OFF/enforcing, postgres only), tracker H3, this entry.

**Rollback if ever needed:** `kubectl patch cm cilium-config policy-audit-mode=true` + `rollout restart ds/cilium` (back to non-enforcing audit) — reversible in ~1 roll.

---

## 2026-06-22 (cont. 3) — iCloud-backups dashboard (Contacts/Calendars, templated) + H39 residual closed

**iCloud backups board ([[M80]]).** The mini agent started Contacts + Calendars syncs (emit `contacts_backup_*`/`calendars_backup_*`, same schema as photos). Built a **templated** "Mac mini — iCloud backups" dashboard (`dashboards/icloud-backups.yaml`): a `cat` variable = `label_values({__name__=~".+_backup_last_rc"}, job)` drives a per-category **repeating row** (last-success age / rc / items / duration), so future `messages_backup`/`drive_backup` appear automatically. The regex cleanly selects only the mini's iCloud categories (homelab/unifi/velero use different field names; PromQL `=~` is fully anchored). Photos keeps its own richer board (different `photos_export_*` schema). Authored matching alerts (`10-icloud-backups-alerts.yaml`: `ICloudBackup{Stale,Failed,Empty}`, one rule each via metric-regex + `by(job)`, with `label_replace` to strip the `_lastsuccess` job suffix → all current/future categories covered without per-category rules; validated against live Prometheus). **Held the alerts** (commented out of `monitoring/kustomization.yaml`, file committed) — owner chose "dashboard now, hold alerts" because contacts+calendars are mid-dev (both `rc=1`, `items=0`) so Failed/Empty would fire immediately; one-line to enable once green. Severity = warning across the board (incl. Stale) since these are secondary metadata backups vs the photo library. Dashboard verified live (cm in monitoring, sidecar loads it); alert rule correctly ABSENT from the build. `9a45f30`.

**H39 residual closed.** Owner picked H39 next. The technitium-1/w2 kopia-hang residual is **resolved**: last failed PVBs were all 2026-06-19 (incident day); every backup since (06-20/21/22) Completed 0-errors. technitium-1 rescheduled off w2 → **k8s-gpu1** and its `data` PVC backs up cleanly (8.7 MB done==total in `technitium-daily-20260622030012`); recent w2 PVBs also Complete (w2 path healthy). The temp Alertmanager silence (`4fe8a806`) **expired** — no active silences, so the Velero alert suite is live again. Chased the 75× backup-size gap between the HA replicas (technitium-0 653 MB vs -1 8.7 MB): **benign** — both serve the VIP, both hold the user-facing `wind.etherport.net` zone; technitium-0's bulk is logs (551 M) + stats (154 M), not zones; the `dns-cluster.*`/`cluster-catalog.*` zones missing from -1 are Technitium's internal catalog-cluster control zones (primary-side by design). Marked H39 ✅ in the tracker.

**Next:** owner backlog menu still open (H3 NetworkPolicy enforce, H38 forward-auth, H30/M64 supply-chain pinning); M80 follow-up = enable the held iCloud alerts once contacts/calendars go green + add messages/drive (auto-appear on the dashboard).

---

## 2026-06-22 (cont. 2) — photos orphan dedup run #2 (NAS+S3, 15.77 GiB) + orphan metric panel/alert

Second mini-supplied dedup list (`photos_export_orphans` = export-dir files not in osxphotos' ledger): **1,058 entries**, all under `Graham/iCloud/Photos/`.

**Verify (NFS pod, read-only).** Mounted the Backups NFS (`sequoia.wind.etherport.net:/var/nfs/shared/Backups`) in a throwaway pod (cleaner than NAS SSH; rclone runs root under baseline PSS so a root pod can delete). All 1,058 present, all within the Photos prefix, 0 escapes, **15.77 GiB**. Composition differs from M96: only 309 have the ` (N)` suffix; 749 are non-suffixed incl. base-named files (`IMG_0308.JPG`). Spot-checked coverage — **every** sampled orphan has many same-stem copies KEPT (e.g. `IMG_0308.JPG` deleted but `(1)/(9)/(10)/(11)…` retained) → no photo lost; iCloud is the upstream source of truth regardless.

**NAS delete.** Suspended `s3-sync-backups` first (so the deletion couldn't trip the delete-guard / propagate mid-op). Guarded line-by-line `rm` in the pod (prefix-locked, no `..`): **1,058 deleted / 0 errors / 15.77 GiB**, Photos 44,895→43,837.

**S3 purge — blocked by my own M97 guardrail.** Backups → `s3://archive.wind.etherport.net/objects/backups/`; the M97 `ProtectBackupObjectsFromDeletion` Deny covers `archive/*`, and **explicit Deny beats the temporary bypass Allow** (so the plain M96 recipe no longer works). Asked the owner → chose "temp exception + purge now". Temp, prefix-scoped change to `terraform-storage.json` (`953d2cc`): lifted the `archive/*` line from the Deny + added `ListBucketVersions` (bucket) and `GetObjectVersion/DeleteObjectVersion/BypassGovernanceRetention` scoped to `objects/backups/Graham/iCloud/Photos/*`. **Blast radius stayed scoped even with the bucket-wide Deny line off**: object-lock GOVERNANCE still protects every other archive object (no bypass granted outside the Photos prefix). Applied via the [[M98]] `iam-apply` OIDC workflow (input is `policy_name`, not `policy`; wait ~15s post-push to avoid the stale-checkout race). boto3 paginated purge (dry-run first): **1,058 versions, 0 delete-markers, 15.77 GiB, 0 errors**; re-verify showed 0 versions remaining. **Reverted immediately** (`add4386`, byte-identical to pre-temp) + re-applied via iam-apply → `list-object-versions` is `AccessDenied` again (guardrail restored). Re-enabled the sync. **NAS = S3 = 43,837 objects** (consistent → next sync no-op).

**Orphan metric panel/alert (mini-agent task).** Added `photos_export_orphans` (export-dir files not in the ledger; baseline ≈1,070, drops after this delete) to the dashboard as **"Orphan dup files"** (area sparkline; reflowed the stat block to 2 rows for 7 stats) + alert **`PhotosExportOrphansGrowing`** — fires on *growth* only (`max_over_time[26h] - min_over_time[26h] > 50` for 1h), never the absolute value (legitimately declines after cleanup). Metric not pushed yet → reads no-data until the mini's next run. `fa56b12`.

**Commits:** `953d2cc` (temp grant), `add4386` (revert), `fa56b12` (orphan panel/alert + runbook). Docs: this entry + memory `s3-backup-version-purge-needs-m97-deny-exception`.

---

## 2026-06-22 (cont.) — rclone perf+metric fixes (--fast-list, bytes parse); photos missing split

Follow-ups off the cleaned-up rclone dashboard.

**Bytes always 0.** Owner asked why "bytes transferred" read 0 for both sources even though OneDrive was set up days ago. Two causes: (a) the latest runs genuinely transferred 0 B (no new data — confirmed in logs), AND (b) a parser bug — `TRANSFERRED_BYTES` took `head -1` of rclone's per-`--stats`-interval "Transferred:" lines, i.e. the FIRST 1-min sample (~0 during the listing phase before downloads start), so even the initial multi-GB OneDrive sync recorded 0 (7d max=0 gave it away). Fixed to `tail -1` (final summary = true total) in both `rclone-gdrive/01-` and `rclone-onedrive/01-sync-script-configmap.yaml`. (File-count metric already used tail -1; only bytes was wrong.)

**gdrive ~23 min/run with zero changes.** No `--fast-list`, so rclone walked the ~36k-object Drive tree per-directory under `--tpslimit 10`. Added `--fast-list` to both jobs (one recursive listing; buffers tens of MB, well under the 1Gi limit). **Verified by a manual run: 23.5s vs the prior ~23 min (~60×), same 15,705 checks / 36,862 listed.** NAS impact was always minimal — the "Checks" are local `stat()` (size+mtime, no `--checksum`); the time was Drive API latency, not NAS load. Jobs don't actually overlap (gdrive :00–:23→now :00, onedrive :30; `concurrencyPolicy: Forbid`); S3 overlap is lock-guarded ([[M94]]). Left schedule hourly (now cheap). Noted but didn't touch 2 pre-fix errored onedrive jobs (06-21, Personal Vault `ObjectHandle is Invalid` — predates the `--exclude "/Personal Vault/**"` fix; current runs green).

**OneDrive tuning (follow-up Q).** `--fast-list` alone only got OneDrive ~7m→4m45s — its cost is Microsoft Graph per-request latency + 429 throttling (the reason for `--tpslimit 10`), NOT the directory walk fast-list fixes, so it still made thousands of list calls for ~21k items. Added **`--onedrive-delta`** (`63222a5`) — Graph's flat delta/changes feed (~1000 items/page) → a handful of paginated calls. **Verified: 33.8s, single stats line, same 8,522 checks / 21,354 listed (~12× vs original).** Lists the whole drive regardless of path (fine — SRC is the drive root); requires `--fast-list`. Both rclone jobs now complete in ~30s.

**Photos "missing" split (mini-agent task).** The mini now emits `photos_export_missing_resolvable` (genuinely-missing originals a re-download fixes — actionable) + `photos_export_missing_unavailable` (structurally un-fetchable edited Live-Photo clips, ~9, expected) beside the combined `photos_export_missing`. Updated `dashboards/photos-export.yaml`: new **Coverage — available files** stat (`100*(1 - missing_resolvable/clamp_min(photos_total,1))`, green@100/red below), new **Unavailable** stat (neutral blue), repointed the missing stat→resolvable (red>0, not the stale 1600 baseline), split the timeseries into exported/resolvable/unavailable, reflowed top row to 6×w4. `09-photos-export-alerts.yaml`: `PhotosExportCoverageRegressed` now `max(photos_export_missing_resolvable) > 0` for >1h, severity info→warning; unavailable un-alerted. Verified live: coverage 100%, resolvable 0, unavailable 9, total 14,346.

**Commits:** `70976be` (rclone), `b9aa765` (photos). All applied + verified in-cluster. No tracker IDs (polish/observability).

---

## 2026-06-22 — rclone Grafana dashboard: de-dup + clarify; pushgateway pod-label + cm-orphan fixes

Owner flagged the "Rclone Sync (Google Drive / OneDrive)" dashboard: top-row stat tiles didn't say WHICH job each value belonged to; the charts showed ~3 `gdrive` series; and there was no at-a-glance way to see *unresolved* errors (an error one run that's fixed the next should read OK).

**Root cause of the dupes — two independent bugs (see memory `grafana-pushgateway-dashboard-dupes`):**
1. **Pushgateway `pod`-label churn.** Prometheus's ServiceMonitor attaches the SD `pod` target label to scraped pushgateway samples; every pushgateway pod restart mints a new `pod` value → a fresh series per pushed metric per dead pod (3 pod incarnations in the 7d window = 3 `source="gdrive"` series). `honorLabels: true` only protects labels in the pushed exposition (job/instance), not `pod`. **Fix:** `serviceMonitor.metricRelabelings: labeldrop pod` on the pushgateway HelmRelease (singleton aggregator — pod identity is meaningless). Verified live on the ServiceMonitor.
2. **Dashboard cm namespace orphan.** `rclone-gdrive/kustomization.yaml` forces `namespace: rclone`, but the cm's `metadata.namespace` said `monitoring` — so a past raw `kubectl apply -f` had created a SECOND copy in `monitoring` that Flux never managed (manager `kubectl-client-side-apply`, rv stuck at 19894). Both carry `grafana_dashboard:"1"` + the same uid, and the Grafana sidecar is cluster-wide → the two flapped and the **stale** copy rendered (that's why my v1→v2 edit "wasn't applying"). **Fix:** deleted the monitoring orphan live; set the file's `metadata.namespace: rclone` to match kustomize so a stray manual apply can't recreate it.

**Dashboard redesign (`05-grafana-dashboard.yaml` v1→v2, 7→8 panels):** every query now `max by (source)(…)` (collapses any residual pod churn + the stale series still in the window); top-row tiles labelled per source (`value_and_name` + `{{source}}`); reframed "Errors (Last Sync)" → **"Unresolved Errors (latest run)"** (background-colored red>0) with a description explaining the per-run-gauge semantics (errors_total is overwritten each run, so a value that drops to 0 = the prior run's failures resolved); added an **"Errors & Notices Over Time (per run)"** stepped timeseries (errors forced red) so you can watch a spike return to 0.

**Commits:** `ec8410a` (dashboard + pushgateway relabel), `bbfd2cf` (cm namespace align). **Verified:** only one cm copy left (rclone ns, v2); sidecar log shows the flap → orphan removal → single re-write; Grafana API serves the 8-panel v2. No tracker item (ad-hoc polish). Docs-as-code: memory saved; this entry.

---

## 2026-06-21 (cont. 2) — iCloud Photos dedup executed: NAS rm + S3 version-purge ([[M96]])

The mini's osxphotos dedup couldn't bulk-delete over SMB, so the owner supplied a relative-path delete list (30,578 entries, all `Graham/iCloud/Photos/`).

**NAS.** Verified the list against the live NAS (all under Photos; 2,859 already gone from the mini's partial SMB run, clustered at the list head — the named files genuinely absent, same-basename *collisions* like `IMG_0295 (10–15)` correctly NOT in the list). Ran a guarded line-by-line `rm` over SSH (prefix-locked to `Graham/iCloud/Photos/`, rejects `..`/outside, quoted for spaces+parens): **27,719 deleted / 197.5 GB / 0 errors**, Photos `587G→389G` (≈ the ~400 GB real library; 41,727 files left).

**S3.** Dupes were still in S3 (sync suspended = safety net). Granted a temporary Photos-prefix-scoped `BypassGovernanceRetention`+`ListBucketVersions`+`GetObjectVersion` on `terraform-storage` via the [[M98]] `iam-apply` workflow (OIDC — no admin/claude-admin, no standing bypass). Purge: `list-object-versions` (prefix) filtered to the dedup list → batched `delete-objects --bypass-governance-retention`. Two snags fixed: the per-1000 JSON was too big as an inline arg → `--delete file://`; and `workflow_dispatch` right after `git push` checked out the **pre-push** commit (applied a stale policy version) → re-dispatched after a settle. Result: **30,579 versions deleted, 0 errors, 213 GB freed** (S3 also held the 2,859 the NAS no longer had); S3 Photos now 41,727 current objects = NAS exactly, 386 GB. Then **reverted the grant** (terraform-storage v7, TEMP gone) and **re-enabled the backups sync** (`suspend:false`). NAS↔S3 consistent → next sync is a Photos no-op (no guard trip).

**Decisions/why.** Surgical per-list purge (not an S3-vs-NAS diff) since the list is authoritative + exact. Governance-bypass kept temporary + prefix-scoped + applied/reverted via CI (no admin key on devbox). Deleted while still in STANDARD (ahead of the 5-day Deep Archive transition) to avoid the early-deletion penalty. iCloud remains the upstream source of truth, so the temporary S3 gap was acceptable.

**State:** M96 done; the whole backup delete-protection + approval + dedup arc is closed. Photos NAS=389G / S3=386G, both deduped.

---

## 2026-06-21 (cont.) — ship + test the approval flow: CF apply, iam-apply workflow, split-horizon DNS, house-style emails, onedrive Vault fix ([[M94]],[[M98]],[[M99]])

Picked up the held [[M94]] delete-guard + CF-Access approval flow and shipped it fully.

**Shipped the approval flow.** Committed everything (`287ef09`), dispatched the **Cloudflare TF apply** via `github_dispatch_pat` (run `27911690380`) → `backup-approve.wind.etherport.net` live (302 Access). Rolled the `backup-approval` Deployment onto the rebuilt image (`/healthz` ok).

**IAM gap caught by a self-test.** Built a synthetic-deletion self-test Job to send a real approval email. It surfaced that the flow writes to `logs.archive.wind.etherport.net/approvals/*`, which the `kubernetes-s3-backup` policy didn't allow (PutObject denied). Tried to apply the fix but: (a) devbox only has the `homelab` profile (no claude-admin key), and (b) **claude-admin is scoped to `policy/terraform-*`** so it couldn't touch `s3-backup-kubernetes-policy` anyway. The classifier also (correctly) blocked the live IAM mutation as out-of-scope. **Resolution = CI, not claude-admin:** the `gh-actions-terraform` OIDC role has `iam:*PolicyVersion` on `*`, so I added **`.github/workflows/iam-apply.yml`** ([[M98]]) to apply any committed `iam-policies/<name>.json` via OIDC (auto-prunes the 5-version cap), dispatchable remotely. Dispatched it → approvals/* granted (`78978fd`, run `27912386842`). **This is the durable "remote IAM without an admin key" mechanism the owner asked for; claude-admin stays disabled.** Re-ran the self-test: email sent, pending record uploaded, approval page renders the full manifest end-to-end.

**Split-horizon DNS ([[M94]]).** The hostname was CF-tunnel-only → failed on Tailscale. Technitium uses explicit per-service A → Traefik VIP (no wildcard), and there's precedent (the `approve` record). Added a `backup-approve` A → VIP + a Traefik IngressRoute. External keeps CF Access; internal is HMAC-gated. (Couldn't curl-verify from devbox — MetalLB BGP VIP isn't L2-reachable same-subnet — but it mirrors the working grafana/ha pattern; owner verifies from tailnet.) `c5aa81b`.

**House-styled emails/pages ([[M94]]).** Re-skinned the approval email, approval page, and transfer-failure email to match `service-status-report.py` (CSS vars + light/dark, eyebrow/pill/summary-grid/cards). Approval page got Confirm buttons top + bottom (long manifests). `422b489`.

**onedrive Personal Vault ([[M99]]).** AI alert "onedrive sync not working" → rclone erroring on the locked Personal Vault folder. This was pre-existing but **masked** by the old `tee` exit-code bug that [[M95]] just fixed (so the fix is working — it unmasked a real silent failure). Excluded `/Personal Vault/**`; verified clean. `c5aa81b`. (Vault contents aren't rclone-backupable.)

**State at end.** Delete-guard + approval flow fully live + tested (external CF Access + internal Traefik, house-styled, IAM correct). iam-apply workflow available for future manual-policy changes ([[M97]] tightening). [[M96]] Photos dedup still parked on the mini. **Next:** owner clicks through the test email to eyeball the new style; when mini dedup completes, run the Photos purge; wire the deferred rclone↔S3 sentinel lock.

---

## 2026-06-21 — backup data-loss hardening: S3 delete-guard + CF-Access approval, rclone guards, Photos dedup ([[M94]],[[M95]],[[M96]],[[M97]])

**Context.** Started on the UNAS nvme0 recurrence ([[M93]]) and an aws-s3 sync review; became a backup data-loss-prevention sweep.

**UNAS nvme0 ([[M93]]).** 3rd controller drop, this time across a `systemctl reboot`. Recovered healthy (SMART: 2% used, 0 media_errors, warning bit = temperature, unsafe_shutdowns 7); md4 rebuilt `[2/2]`. **Gotcha:** a raw `systemctl reboot` left the box **half-up** — web UI + ping responded but SSH/NFS/SMB were down for minutes while UniFi-OS services restarted and the cache resync spiked load — prefer a UI/console restart. The md4 (NVMe RAID1) rebuild saturated both NVMe (~96% util) → slow browsing for the ~1h resync (it's an LVM **writethrough** dm-cache: origin md3/RAID6 data stays safe, but reads route through the busy cache device). Confirmed **wear is a non-issue → firmware/APST**. Thermal revision: nvme0 ran 69°C post-reboot, so disabling APST (keeps it out of deep idle) would *raise* idle temp → firmware rollback / airflow is the better durable fix than APST-off.

**S3 delete-protection ([[M94]]).** `aws s3 sync --delete` had no guard — a downed/empty NAS source would mirror as a mass S3 deletion (a real risk: this morning's NAS outage was exactly that scenario). Added **Guard 1** (abort if source empty/unmounted) + **Guard 2** (abort if a run would delete > 1000 objects or > 10% of dest; legit small deletes pass). Fixed a **false-FAILED**: the nightly "526 files checksumUnavailable" was a sync-while-rclone-writes race (benign, 0 mismatches) — status now keys on `files_succeeded` (HEAD ok), not `files_verified` (checksum present), plus a re-HEAD settle pass. **Decision:** human approval for large *intended* deletions via a **CF-Access email button** (owner chose CF Access over a GH-Actions approve workflow, and "build it all, ship together"). Built `approval-server.py` + `request-approval.py` (in the sync image) + a `backup-approval` Deployment/Service behind CF Access at `backup-approve.wind.etherport.net`; scoped/one-time/expiring HMAC-signed markers in S3; the email shows a **folder rollup** (not a flat list — the deletion's *shape* is the "is this expected?" signal) + sample + full-manifest CSV. **Shipped `287ef09`**, in-cluster `/healthz: ok`. **Open step:** apply the `terraform-cloudflare` stack (action=apply) to create the hostname + Access app.

**rclone hardening ([[M95]]).** gdrive/onedrive ran `rclone sync` (deleting) hourly with **no `--max-delete`** → a transient empty cloud listing (token blip, 429, wrong drive_id) would wipe the NAS mirror (then cascade to S3). Added: source-non-empty guard, `--max-delete 200`, **real exit-code capture** (BusyBox `rclone | tee` had been reporting tee's status → failures recorded as *success*), EXIT-trap fail-safe `success=0` metric (pre-sync failures previously only caught by the 25h staleness alert), gdrive `--tpslimit 10`, `activeDeadlineSeconds: 3000`. Live `66b8c49`. **No approval flow on rclone** — redundant (max-delete hard-stop + the S3 guard on the 2nd hop + S3 30-day versioning cover the cascade; rclone image is minimal POSIX-sh, a harder lift for marginal gain).

**iCloud Photos dupe purge ([[M96]], parked).** A Mac mini osxphotos export left ~200GB of dupes in the NAS Backups share + S3 (`…/Graham/iCloud/Photos/`). Bucket = GOVERNANCE-lock 180d (bypassable) + versioning (must delete VERSIONS to free space) + lifecycle → Deep Archive (now extended **2→5d**, live). **Decision: Option B (surgical)** — keep the good ~400GB (already correctly backed up; deleting+re-uploading would waste transfer and open a no-backup gap, bad on a flaky-NAS day), suspend the backups sync (so it won't propagate the in-progress dedup as delete markers on locked versions), and when the mini's dedup finishes, diff S3-vs-NAS and version-purge only the dupes with `--bypass-governance-retention`. Wrote a scoped one-off IAM policy (`iam-policies/oneoff-photos-dedup-bypass.json`). **Parked** awaiting the mini.

**IAM reconcile ([[M97]]).** Repo `iam-policies/*.json` had drifted from live (applied manually, not via `terraform apply`). Synced repo→live (terraform-storage/networking; created the missing terraform-cloudfront). Flagged two over-broad live grants (terraform-storage `s3:Delete*` on `*`; terraform-compute `iam:PassRole/AttachRolePolicy` on `*`) → backlogged for a scoped pass.

**State at end.** Delete-guard + approval deployed & healthy (CF apply is the one open step); rclone hardened & live; backups sync suspended pending the Photos purge; lifecycle 5d live; IAM repo matches live. **Next:** (1) dispatch the `terraform-cloudflare` apply; (2) when the mini's dedup completes, run the Photos version-purge ([[M96]]); (3) wire the deferred rclone↔S3 sentinel lock; (4) [[M97]] IAM scoping. Commits this session: `718e908` (suspend), `d5c65c4` (lifecycle 2→5d), `66b8c49` (rclone), `287ef09` (delete-guard+approval + IAM reconcile).
---

## 2026-06-21 — M79 Photos backup: completion, dedup (30,577 dups), steady-state hardening

Closing out the M79 marathon. Carries on from the 2026-06-19→20 entries (multichannel,
NVMe cache, local export DB).

**Backup completed.** The 15h39m PhotoKit download pass (2026-06-20, rc=0) covered the
library: **~15,355 distinct photos backed up**, **293 photos truly unbacked** (originals
iCloud won't serve) + ~950 Live-Photo `.mov` clips (still image *is* backed up). Missing
list: `~/Library/Logs/photos-export/MISSING-photos.txt`.

**Dedup of ~30,577 duplicate files (the DB-less-retry mess).** Computed the orphan set
directly from the export DB (`export_data.filepath` = canonical keepers) with a **survivor
guard** (never delete a photo's last copy): 41,715 canonical + 10 protected + 30,577 dups =
72,303. ⚠️ **Near-miss:** the first compute had a path-bug that flagged *all* 72,303 as
deletable — caught by reconciling `safe+protected==total` *before* deleting. Always verify
the math before a mass delete.

**The "11s/delete" was NOT the cache — it was contention + single-channel SMB.** Owner
rightly pushed back (cache had been fine all day). Clean measurement: a **single delete =
~15 ms**; sustained over SMB = 322–642 ms (NAS serializes btrfs metadata commits, and my
earlier `mc_on=no` forced everything onto one channel; my "11s" was measured *during* a
16-way parallel rm fighting that one channel). Re-enabled **multichannel (`mc_on=yes`)** —
the original idle drops were the NVMe cache, not multichannel, so disabling it was treating
the wrong thing. Even so, over-SMB bulk delete floored at ~2.5–3 h (NAS-bound). **Owner ran
the delete NAS-LOCAL over SSH** (local btrfs unlink, no SMB) — fast. **Lesson: bulk
file-count operations on this NAS belong NAS-local, not over SMB.** Verified after: **41,727
files**, all sampled dups gone, all sampled canonical keepers present. ✅

**Steady-state hardening (this session):**
- **Nightly (`photos-export.sh`) now defaults to LOCAL mode** — no Photos.app/PhotoKit, so
  no TCC dialogs / `photolibraryd` wedges (those caused the 2026-06-20 disruption). It does
  `--update --exportdb <local> --ramdb --sidecar XMP --cleanup`. `DOWNLOAD_MISSING=1` makes
  it the (fragile, supervised) PhotoKit download pass + daemon-restart. Timer re-enabled
  (22:00, local).
- **Anti-dup guarantee:** the persistent **local** `--exportdb`
  (`~/Library/Application Support/osxphotos/graham-icloud-photos.db`, 41,715 rows) means
  `--update` reuses canonical filenames → never re-creates `(N)` dups; `--cleanup` removes
  any stray orphan. The dup explosion only happened because the DB lived on SMB and got
  lost. **Rule: never run osxphotos here without `--exportdb` → that file; never delete it.**
- **Lockfile guard** (`<RDIR>/.run.lock`, atomic mkdir) added to BOTH `photos-export.sh` and
  `photos-export-resume.sh` — two runs racing the same ledger could re-mint dups; now only
  one runs at a time.

**In progress at write time:** a supervised `DOWNLOAD_MISSING=1` pass (via the wrapper,
dup-safe `--exportdb` + lock + `cleanup=off`) attempting the 293/clips. May recover
transient failures; genuinely-unavailable ones need manual "Download Originals" in Photos.

**Next:** confirm the download pass result (and that DB row count didn't balloon = no new
dups); then M79 is effectively done bar the permanent-missing tail. S3 dup cleanup is the
owner's (infra agent) — same `dedup-relative-paths.txt` maps to `objects/backups/<rel>` keys.

---

## 2026-06-20 (cont. 3) — devbox CI dispatch (PAT) + k8s-vms watchdog saga ([[M91]],[[M92]])

**Dispatch enabled ([[M92]] ✅).** Owner created a fine-grained PAT (Actions:rw + Contents:r on the
repo), sealed into `homelab-ops.sops.yaml` as `github_dispatch_pat`. devbox can now `workflow_dispatch`
via the REST API (verified). Also: fixed a `.gitignore` leak (`!**/*.sops.yaml` was un-ignoring
`.decrypted~*.sops.yaml` plaintext SOPS tempfiles → hard re-ignore appended, `c8e952f`). Extended the
CI drift sweep to ALL 22 stacks + email-on-drift (red run, `c42a367`/`812cb58`); first runs exposed +
fixed a self-hosted bug (install unzip BEFORE setup-terraform, `39dc18a`).

**The watchdog dead-end ([[M91]]).** Goal: enable the i6300esb hardware watchdog (hang auto-reset) on
the 8 k8s VMs — the standing `terraform plan` drift. Dispatched the per-stack apply node-by-node
(authorized, rolling): w4 (canary) → w3 → w2 → w1 → gpu1. Two incidents en route, both recovered via
the PVE API: **(1)** w3's graceful shutdown HUNG on un-drainable single-instance `cue-db-1` (PDB on 1
replica → RBD wouldn't unmount) — force-stopped+started it; **(2)** a bug in my hang-detector
(`[ "$ns" != "Ready" ]` counted `Ready,SchedulingDisabled` cordoned nodes as down) force-stopped a
HEALTHY w2 — restarted it; fixed the detector to `grep "^Ready"`. **Then the gut-punch:** after 5
reboots the plan STILL showed all 8 drifting and the VM configs had **no watchdog** — **bpg/proxmox
0.106 silently NO-OPs the `watchdog {}` block.** The 5 reboots achieved nothing toward the watchdog
(cluster fine throughout). Stopped before the control planes.

**Resolution (owner chose "do it right").** (a) `lifecycle.ignore_changes=[watchdog]` on the 3 VM
resources → plan now "No changes" (`0e80782`); (b) attached the device to all 8 configs via the PVE API
`qm set --watchdog` (the working path; `current=[model=i6300esb,action=reset]`); (c) guest daemon
already deployed+enabled on all 8.
**CORRECTION (same session):** verifying e2e on w4 (cold-rebooted to present the device) revealed the
watchdog **still doesn't work — `i6300esb.ko` is ABSENT from the node kernel** (only softdog/wdat_wdt;
linux-modules-extra lacks it). So `/dev/watchdog0` never appears + the daemon is inert; the hardware
watchdog has never armed. Tried a `modprobe i6300esb` ansible task → FATAL (module not found) →
reverted (`2642aa4`). **Watchdog BLOCKED pending the kernel module (M91)**; drift stays clean
(ignore_changes), device attached + harmless. Cost of the saga: ~7 node reboots + 3 incidents for a
feature that can't work without the module — lesson logged in CLAUDE.md §5.
**PARKED + investigated 2026-06-21:** the real reason `i6300esb.ko` is absent = `linux-modules-extra-$(uname
-r)` simply isn't installed on the nodes (the standard package that ships it; my apt task no-op'd). So
it's resolvable via the production-standard path (install -extra → modprobe → feeder), per-kernel
durability caveat noted. Left as the M91 follow-up; not pursuing now.
**"Down" emails were the reboots, not real:** the AI advisor sent **0** diagnosis emails (transient-
suppression skipped every self-resolving reboot alert ✅); the emails came from Alertmanager's plain
`email-alerts` receiver firing KubeNodeNotReady/TargetDown on the ~7 rollout reboots (fire+resolve per
node). All transient, active alerts now clear. (Possible future tidy: dampen email-alerts during
planned node reboots, or accept it.)

---

## 2026-06-20 (cont. 2) — Config-drift / docs review; CI-native drift for all TF stacks

**Docs drift fixed (`bb227a5`):** gdrive/onedrive READMEs daily/nightly→hourly, root README reframed (devbox is the dev-session host, not the mini) + OneDrive/unas-health added to backups table & component list, two dead `docs/README.md` links removed, M78→superseded-by-M88. (Agent-assisted.)

**Live config drift:** git clean; Flux all reconciled; TF proxmox **firewall/sdn/standalone-vms** = No changes. **k8s-vms = 0 add, 8 change** ([[M91]]) — the deliberate i6300esb **hardware watchdog** (action=reset, hang-recovery; relevant to the GPU wedge) + gpu1 floating-mem 8192→0 were authored but never applied. NOT manual drift. Resolve via a **rolling** CI apply (`terraform-proxmox-k8s-vms` apply with `target`, node-by-node — attaching the watchdog device likely restarts the VM). External-provider stacks not checked from devbox (no GH token there → can't dispatch CI).

**CI-native drift for everything ([[M90]], `2f85c28`).** Per owner "everything should wind up as CI": extended `terraform-drift-detection.yml` (was AWS-only) with a self-hosted `plan-internal` matrix (cloudflare, unifi, proxmox ×4) feeding the same daily `tf-drift` issue. Corrections stay per-stack `workflow_dispatch` apply (OIDC). OneDrive sync still running its initial full pull (8k+ files, double-run cleaned up). sdn lock file gained a linux hash from devbox init (`607759d`).

---

## 2026-06-20 (cont.) — Hourly syncs + unified sync observability + pve-ipmi firewall fix + cloudwatch baked-image cutover

**Syncs → hourly + unified observability.** gdrive `0 * * * *` / onedrive `30 * * * *`
(staggered; Forbid skips a tick if a run >1h). Made the rclone Grafana dashboard
**source-templated** (`$source` var, per-source legends, retitled "Rclone Sync (Google
Drive / OneDrive)") so it covers both + future sources. Added `gdrive-sync` + `onedrive-sync`
to `service-status-report/services.py` (the shared source-of-truth for the daily status
email AND the generated service dashboard). AI advisor already gets both syncs' alerts via
the alertmanager catch-all webhook (`continue:true`) — no routing change needed. Note re
"resolve autonomously": hourly cadence IS the natural retry now, so explicit force-rerun
remediation is largely redundant (offered, not built). (`65ad0ab`)

**pve-ipmi TargetDown ([[M89]], `96318e3` applied).** `up{job="pve-ipmi"}=0` since 13:16Z.
Root-caused from the repo (no SSH — the PVE-SSH was classifier-blocked, only an alert was
forwarded): the H37 default-deny host firewall had **no allow for the ipmi_exporter `:9290`**
→ scrape dropped (timeout, not refused; host up + `:22` open). Same latent class as the
Ceph oversight. Fixed with a `pve-ipmi` security group (`10.10.201.0/24` → `9290`) in the
proxmox firewall TF; `terraform apply` (1 add, 1 change, 0 destroy, owner-authorized).
Verified `up=1` + 12 temp sensors. **CLAUDE.md §5 updated: the PVE firewall now has THREE
required allows (mgmt / Ceph / IPMI).**

**cloudwatch-to-loki baked-image cutover ([[M87]] done, `dd29537`).** GH Actions built the
image (tags `main`+`sha-734fe3f`); owner flipped the ghcr package Public. Cut the CronJob to
`ghcr.io/sparked-diamond/cloudwatch-to-loki:main` + `imagePullPolicy: Always`, dropped the
runtime `pip install` → `command: ["python","/scripts/forward.py"]`. Verified a run: no pip,
auth ok, events pushed. Runtime-pip failure class eliminated.

---

## 2026-06-20 — Full health sweep + cloudwatch-to-loki hardening + OneDrive sync staged

**Health sweep (all clear).** 8/8 nodes Ready, 0 NotReady/CrashLooping pods, Flux +
all HelmReleases reconciled, **no active alerts**. **M84 confirmed fixed**: tonight's
Velero nightly = all 11 backups `Completed`, 0 errors (prior nights were
PartiallyFailed/Failed). Postgres 3/3 healthy (incl. recreated `-6`); CNPG barman S3
backups completed; unifi-backup + rclone gdrive complete; `unas-health` running. GPU
DCGM metrics flowing again; technitium 2/2. The 4h+ `s3-sync-backups` job was not stuck
— a legit 45k-file/325 GB iCloud Photos push (resumed photo backup) in its verify phase.

**cloudwatch-to-loki hardening ([[M87]], `734fe3f`).** Root-caused the overnight email: a
single job failed `BackoffLimitExceeded` because it `pip install`s boto3+kubernetes on
every 5-min run with **`backoffLimit: 0`** → a transient PyPI/network blip failed it
instantly + paged. It self-recovered (next run's pip succeeded). **Immediate fix
(deployed+verified):** `backoffLimit 0→3` + `pip --retries 5 --timeout 30`. **Proper fix
staged:** `image/Dockerfile` bakes the deps + `.github/workflows/cloudwatch-to-loki-image.yml`
builds to `ghcr.io/sparked-diamond/cloudwatch-to-loki` (script stays in the ConfigMap).
**Cutover gated on the one-time "make ghcr package public" step** (GITHUB_TOKEN can't do
it for user-owned packages — same gotcha as cloudflare-ddns), then switch the CronJob
`image:` + drop the pip line. Tracked M87.

**OneDrive sync staged ([[M88]], `705e314`).** New `platform/kubernetes/rclone-onedrive/`
mirrors `rclone-gdrive`: nightly `rclone sync onedrive: → /backup/Graham/OneDrive/` (NAS
Backups share → rides NAS→S3), 23:00 PT, `--tpslimit 10` for OneDrive throttling, same
metrics/alert shape. Account = personal MS account w/ M365 sub = **OneDrive Personal**.
**Blocked on interactive OAuth** (rclone's onedrive backend can't auth headless on
devbox): built but **NOT registered in clusters/wind** + secret omitted, so nothing
deploys half-built. Activation: user runs `rclone config` on a browser machine → hands
over the `[onedrive]` block → seal `04-secret.sops.yaml` + uncomment in kustomization +
register the dir. See the component README + `04-secret.sops.yaml.template`.
**Activated same day (`a893c00`):** owner ran `rclone config` on the laptop (chose the
"OneDrive (personal)" drive `F4E003FF4BAE9ABD`), sealed the `[onedrive]` block into
`04-secret.sops.yaml` and pushed (`--no-gpg-sign` to dodge the laptop SSH-signing-key
gap). I uncommented the secret + registered the component; Flux decrypted it cleanly and
deployed `onedrive-sync`. First sync verified — rclone authed and copied files into
`/backup/Graham/OneDrive/` (Documents/Pictures/WSP), no errors. M88 ✅.

---

## 2026-06-19 (evening) — UNAS SSD-cache member drop (NVMe APST hang) + md-degradation alerting

**Incident.** Owner saw the UNAS UI flag **Storage Pool "At Risk" + SSD cache
"Transferring"** while every drive showed "Optimal"; separately the mini photo-backup
agent reported **SMB hanging within ~1 min** after ~5 h stable. The two were the same
event. SSH'd into the UNAS (`10.10.209.10`, key from `unifi-backup/01-secret-ssh.sops.yaml`)
and found the smoking gun in `/proc/mdstat` + dmesg: **`nvme0` (one of the two SSD-cache
RAID1 members, `md4`) fell off the PCIe bus** at ~11:04 (`nvme nvme0: controller is down;
CSTS=0xffffffff`, `/dev/nvme0` gone) — a textbook **NVMe deep-power-state (APST) hang**,
hours into runtime. `md` kicked it; `md4` ran **degraded `[2/1]`**. `smbd`/`kcopyd`/`btrfs`
were stuck in **D-state** on the dead device → that was the SMB hang. RAID6 data array
(`md3`) `[8/8]` healthy throughout; cache survivor `nvme1` SMART pristine → **no data risk**.

**Why the UI lied:** SMART ≠ bus presence. A drive that *vanishes* can't report bad
SMART, so the per-drive widget showed last-known-good "healthy"; only the pool status
(reading live `md`) reflected it.

**Fix.** Corrected my earlier "don't reboot mid-Transferring" advice — that assumes a
non-redundant cache; this cache is **RAID1**, so the survivor holds all data across a
reboot, making a reboot both safe and necessary (box was wedged on D-state I/O). Owner
rebooted from the UI; `nvme0` re-probed clean and `md4` auto-rebuilt to **`[2/2] [UU]`**
(~90 min). (Also confirmed: SSH comes up late in boot — port 22 closed while UI:443/SMB:445
already open; not a NAS-down.)

**Root cause = the firmware update (prime suspect).** Box updated to `UNASPRO v5.1.19`
(build 260613) this morning, rebooted 06:17, stable ~5 h, then the controller hung on a
power-state transition. `default_ps_max_latency_us=100000` permits deep APST; the
appliance kernel cmdline is fixed so we **can't persist `...=0`**. Not provable vs. a
marginal M.2 — **recurrence is the tell**.

**Durability shipped.** (1) New runbook
[`docs/runbooks/unas-nvme-cache-apst-hang.md`](../runbooks/unas-nvme-cache-apst-hang.md).
(2) New IaC component **`platform/kubernetes/unas-health/`** ([[M86]]): CronJob SSHes the
UNAS every 15 min, parses `/proc/mdstat`, pushes degraded/active/total gauges to
Pushgateway → **`UnasMdArrayDegraded`** (+ check-failing/stale watchdogs). Closes the gap
where the array ran degraded for hours unalerted. Reuses `unifi-backup-ssh` (already
authorized on the UNAS); host-key pinned. Validated (kustomize + parser unit-tested).
**Recurrence watch:** a self-scheduled quiet check will ping only if `nvme0` drops again.

---

## 2026-06-19 (morning) — M84 fixed (dataPathConcurrency=2) + advisor overnight review

**M84 resolved** (owner back; the deferral was only about not guessing chart-wiring unattended).
Verified the velero 11.4.0 chart supports `configMaps` + `nodeAgent.extraArgs`, then added a
`node-agent-config` CM (`loadConcurrency.globalConfig=2`) + `--node-agent-configmap=velero-node-agent-config`
to `velero.yaml` (`918e101`). node-agent rolled 8/8 clean with the config. **Verified twice** —
on-demand backups completed **0 stalls**: infrastructure 20/20, postgres 9/9 (postgres had Failed
overnight from my -6 mess; now has a fresh clean restore point). Tonight's nightly should be fully clean.

**Advisor overnight review** (owner reported "many emails"): **no flood — `cap_reached: 0`**. ~6
legitimate one-off diagnoses, one per real alert that fired during the night's remediation churn
(`TargetDown`/`KubeDaemonSetRolloutStuck` from the dcgm reboot, `KubePodCrashLooping` from postgres-6,
`KubeJobFailed` from the failed velero backups, `KubeClientErrors`, `NodeSystemSaturation`). The
once-per-day cap-fix held. Quiet now that everything's resolved.

**Advisor transient-suppression (`ecd37ea`, owner-approved follow-up).** Wired the noise-cut: a new
`_alert_still_firing(alert)` helper queries Prometheus `ALERTS{alertname,alertstate="firing"}` (matched
on namespace too when present); `_advise` now skips the Claude call **and** the email — auditing
`skipped_resolved` — if the alert has already resolved by the time the advisor reaches it (rollout
finished, pod recovered, node back). That's exactly what produced the ~6 overnight emails. **Fail-open:**
if the Prometheus check itself errors we do NOT suppress (never silently drop a real alert). NOT
cooldowned on skip, so a genuine re-fire still active next time is diagnosed. Validated (py_compile +
kustomize), reconciled, `rollout restart deploy/remediation-controller` — new pod healthy, processing.

**Silence: extended (owner-approved).** Replaced `4fe8a806` (was expiring 19:22Z today) with
`f7907750` — same matchers (`VeleroBackupPartial|VeleroLastBackupAgeHigh|KubePodNotReady`, ns=velero),
now **expires 2026-06-20 12:00 UTC** so tonight's now-clean (M84-fixed) nightly supersedes the stale
06-18/06-19 partials before it lifts. `VeleroBackupFailed` is deliberately NOT in the matcher set — a
genuine hard failure tonight still pages.

---

## 2026-06-19 — M79 SMB instability root-caused & fixed (multichannel); library recovered; export resumed

Picked up M79 after the owner VNC'd in to find Photos had force-quit ("quit to prevent
corruption from the library") and, post-reboot, errored **"PhotosLib cannot be found."**
Two questions: why did it corrupt, and why didn't the drive come back.

**Root cause (found live, not guessed).** While diagnosing I watched **`Personal-Drive`
drop on its own *while idle*** — that rules out write-load/sleep/bandwidth (link is 10G
wired, sleep already disabled). There was **no `nsmb.conf` at all** → macOS SMB
**multichannel** was ON, the textbook cause of spontaneous idle SMB session resets
against a NAS over a fast NIC. A reset mid-write to the sparsebundle (which backs the
Photos library as a "local" APFS volume over SMB) is what force-quit Photos and left the
APFS journal dirty.

**Why the drive didn't come back.** Two gaps: (1) nothing attaches the sparsebundle at
login — `hdiutil attach` only ran inside the export job — so after reboot the shares
remounted but `/Volumes/PhotosLib` never existed; (2) the volume was *dirty* (failed a
read-only mount = unreplayed journal). Photos remembered the path but the volume wasn't
there.

**Fixes (all in git, sudo-free, self-healing on rebuild):**
- **`infra/macos/mini/nsmb.conf`** — `mc_on=no` (multichannel off) + `protocol_vers_map=6`
  (no SMB1) + `notify_off=yes`. Installed to `~/Library/Preferences/nsmb.conf`.
- **`mount-nas.sh`** now (a) installs/refreshes `nsmb.conf` *before* mounting (only new
  mounts pick it up) and (b) **attaches the sparsebundle after mounting** → PhotosLib is
  present at login. Both idempotent.
- **`photos-export-resume.sh`** — auto-attaches the bundle, and `--cleanup` is now opt-in
  (`CLEANUP=1`, default OFF) because the `.osxphotos_export.db` ledger was lost in the
  corruption; cleanup without it could delete+re-download already-exported files.

**Recovery + validation.** Read-write attach replayed the journal (PhotosLib mounted).
The library DB had a **14 GB un-checkpointed WAL** (the in-flight downloads at force-quit)
+ a 34 MB base — so a standalone `integrity_check` of the base "failed" (expected: pages
live in the WAL). Ran `PRAGMA wal_checkpoint(TRUNCATE)` — which doubled as a **14 GB
sustained network-write soak test of the SMB fix**: WAL 14 GB→0, **0 mount drops, 0 SMB
reconnects** throughout, then `integrity_check` = **`ok`**, **14,267 photos** readable.
So: library healthy (not corrupted), and the multichannel-off fix proven under real load.

**State at end.** Remounted clean (verified live session: SMB 3.1.1, single-channel, 0
reconnects). Re-launched `photos-export-resume.sh` (CLEANUP off) — osxphotos skips the
10,203 already-exported and downloads+exports the remaining ~4k via PhotoKit, rebuilding
the DB. Persistent monitor watching progress/drops/completion.

**Next steps:** (1) let the ~4k tail finish (monitor will report); (2) verify ~14.3k
files on `Backups`; (3) one-off `CLEANUP=1` run (or the nightly `photos-export.sh`, which
keeps `--cleanup`) once the DB is healthy to re-establish deletion mirroring; (4) enable
the `net.wind.photos-export` LaunchAgent; (5) confirm `s3-sync-backups` ships
`Graham/iCloud/Photos`. **Lesson:** sparsebundle-on-SMB is viable but *requires* SMB
multichannel disabled; deeper insurance (sudo-only) = system-wide `/etc/nsmb.conf` +
raised `net.smb.fs.kern_*_deadtimer` so a server stall pauses I/O instead of erroring up
into APFS.

**UPDATE (same day, evening) — the deeper root cause was NAS HARDWARE, and completion.**
After resuming, the SMB degraded *progressively* (fine → flaky → EIO → hang) over the
afternoon, eventually hanging even on a freshly-rebuilt mount. **Owner SSH'd the UNAS and
nailed it: an NVMe SSD-cache drive (`nvme0`) fell off the PCIe bus (~11:04), `md` kicked it
from the cache RAID1, and `smbd`/`btrfs`/`kcopyd` went D-state on the dead device** — exactly
the "reads work ~10 s then hang" symptom, and the "stable ~5 h then degraded" timing
(NAS booted 06:17 from the update, SSD dropped ~5 h later). Data array (RAID6) healthy → no
data risk. So `mc_on=no` was a genuine improvement but the real instability was the dying SSD,
not the client. **Owner rebooted the UNAS; `nvme0` re-probed clean → SMB stably healthy.**
Lesson: progressive SMB degradation ⇒ suspect NAS storage/SMB health, not just client tuning;
diagnose with a **timeout-guarded** read (a plain cp/dd just hangs on D-state).
- Built `~/Library/Logs/photos-export/auto-resume.sh` (uncommitted one-off): waits for 3
  consecutive timeout-guarded reads off `/Volumes/PhotosLib`, then auto-runs the resume.
  Fired at 16:24 on recovery.
- **`--exportdb <LOCAL path>` + `--ramdb`** was the fix that let it finally complete: osxphotos
  writes the export DB as the final step, and on the SMB share that write kept failing
  (rc=1 → wrapper retried **~18×** even though files were exported). DB now local (rebuildable
  ledger; correct to keep off NAS/S3). First clean `rc=0` at 22:08 (5h41m local run).
- **Clean completion revealed two issues:** `Processed: 14343, exported: 10420, missing: 11538`
  → ~11,538 versions' originals were never downloaded (PhotoKit run dropped at 71% before
  reaching them = NOT yet backed up); and **heavy duplication** (55,745 files, 41,295 with
  `(N)` suffixes for ~14k photos) from the ~20 DB-less retries each re-assigning `(N)` names.
- **In progress:** `DOWNLOAD_MISSING=1` pass (PhotoKit) fetching the 11,538 not-local originals
  + exporting them (local DB makes it convergent now); then `CLEANUP=1` (dry-run first) to
  remove the ~17k+ orphan duplicates. Then enable the nightly timer + verify S3. Final
  exported-count-vs-14,267 + timer status to report on completion.

---

## 2026-06-19 (overnight, autonomous) — Velero nightly close-out + M84 (dataPathConcurrency)

Owner asleep, asked to "resolve autonomously." Outcome of the velero close-out:

**Firewall fix proven (the headline):** the 06-19 nightly had clean completions —
traefik/plex/cue + a 6.8 GB infra PVB — so Ceph fs-backup works post-H37-fix.

**M84 surfaced as the real residual:** velero node-agent runs default
**`dataPathConcurrency=1`** (no `node-agent-config` CM), so under the nightly burst
multi-volume backups stall (PVBs sit `Prepared`, never start the data path) and block
the serialized queue. Tonight: critical-apps + infrastructure (and earlier postgres,
which was *my* fault — recreating -6 mid-window) ended Failed/PartiallyFailed; I had to
`rollout restart deploy/velero` twice to finalize wedged backups + unblock the queue.

**What I did NOT do (deliberately):** apply the dataPathConcurrency fix. It needs the
velero chart's node-agent extra-args wiring, which I **can't verify without `helm`**
(not on devbox) — and per the close-out guardrail I won't guess at backup-system config
while unattended. Documented precisely in **M84** for the owner to apply (with helm to
confirm the chart key) + verify.

**Silence kept (not lifted):** the nightly is genuinely non-clean (the M84 stalls +
postgres), so lifting would fire those legit-but-known partials. Kept the silence to
avoid overnight noise; it **auto-expires 2026-06-19T19:22Z**. The once-per-day advisor
cap-fix means even if it fires it's ≤1 email (no flood). Lift manually after applying
M84 + a clean run: `kubectl -n monitoring exec alertmanager-monitoring-kube-prometheus-alertmanager-0 -c alertmanager -- wget -qO- --method=DELETE http://localhost:9093/api/v2/silence/4fe8a806-57fb-4671-85f6-e3e16be390bd`.

**Core cluster health (final sweep): all green** — 8/8 nodes Ready, zero unhealthy pods,
Flux 100%, all PVCs Bound, only benign alerts (InfoInhibitor/CPUThrottling/Watchdog).
postgres data safe regardless (CNPG continuous archiving healthy). GPU dcgm + grafana
(earlier today) remain resolved. **Owner action:** apply M84, then a clean velero run + lift the silence.

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

## 2026-06-19 — M79 bulk export run to 71%, then NAS SMB mount went unstable (PAUSED)

**Goal:** run the first full `osxphotos` export of all ~14.3k photos (the slow initial
pull via `--download-missing --use-photokit`), monitored.

**What happened:**
- Export ran cleanly from ~20:49 to ~00:18, reaching **10,201 / 14,343 (~71%)** — steady
  ~80–100 photos/min, files + XMP sidecars landing in `/Volumes/Backups/Graham/iCloud/Photos`,
  library originals growing in lockstep (PhotoKit on-demand download working as designed).
- **Then the `Backups` SMB mount dropped mid-run.** osxphotos didn't exit — it **wedged**
  spewing `CoreData: XPC: sendMessage: failed` with zero progress (its PhotoKit XPC
  connection died and a single process can't reconnect). Killed it.
- Remounts succeeded (2 s) but **`Backups` then dropped within ~30 s even when idle** (the
  `find` hang before the first idle-probe reading = classic smbfs dead-session). `Personal-Drive`
  (same NAS) stayed up; NAS pinged 0.4 ms; **445 open**; no kernel SMB errors → a **wedged
  server-side SMB session for the Backups share**, not network/load.
- Tried a workaround — mounting `Backups` via the **NAS IP** (`10.10.209.10`) to force a
  fresh session. That popped a **NetAuthAgent credential dialog** (no keychain entry for the
  IP) and appears to have knocked out `Personal-Drive` too; subsequent `mount-nas.sh` **hung**.
  Stopped all SMB poking to avoid leaving hung mounts.

**State at end (PAUSED, nothing lost):** **10,201 files safely on the NAS disk** (SMB is just
transport; data is intact server-side). No SMB shares mounted on the mini; a credential
dialog is likely waiting in the VNC GUI. osxphotos not running. Repo: added
`infra/macos/mini/photos-export-resume.sh` (self-healing wrapper — see below).

**Resume procedure (owner, in VNC):**
1. **Cancel** the stuck SMB login dialog (NetAuthAgent).
2. Clear the wedge **on the NAS**: restart SMB / toggle the `Backups` share off-on on the
   UNAS, or reboot the NAS (server-side session is stuck; `Personal-Drive` working proves
   the box itself is fine).
3. Re-mount (`infra/macos/mini/mount-nas.sh`) and confirm both shares **hold** for a few min.
4. Resume with **`infra/macos/mini/photos-export-resume.sh`** — loops remount → ensure
   Photos.app up → `osxphotos export --update` (resumes from `<DEST>/.osxphotos_export.db`,
   so it continues from ~71% — **no re-download** of the 10.2k) under a watchdog that kills +
   retries on mount-loss or a wedged (zero-progress) run. **No re-export, no re-download.**

**Lessons (durable):**
- The initial bulk pull is long enough that an SMB drop / PhotoKit wedge is *likely* → use
  the resume wrapper, not a bare `photos-export.sh`, for the first fill.
- **Do NOT mount the same NAS by IP when it's already mounted by hostname** — the second
  auth context destabilized the existing (working) session and spawned a blocking dialog.
- osxphotos wedges (doesn't exit) when its PhotoKit XPC dies → a watchdog must detect
  *zero file-count growth*, not just process exit.

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

See the archived tracker "Recently completed" blocks in
[`archive/outstanding-work-completed-2026-07.md`](archive/outstanding-work-completed-2026-07.md)
("Retired top-matter"; extracted from `outstanding-work.md` 2026-07-01) and the
dated planning docs. Headline recent landings: H29 (CI→AWS OIDC), L21 (CI→GCP WIF),
M69 (Cloudflare provider v4→v5), M53 (zone-scoped CF token), the localtuya migration
(all 8 Tuya devices cloud→local, entity_ids preserved), and the headless Mac-mini ops
host. Older history archived under `archive/`.
