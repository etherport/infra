# mini macOS automation

Mac-native automation that runs **on the Mac mini** (`graham@`, the headless ops
host) — things that can't live in k8s/Flux because they need macOS APIs (Photos,
SMB/keychain, `launchd`, tmux). Version-controlled here; installed into the user's
`~/Library/LaunchAgents` on the mini.

## `net.wind.mount-nas` — keep the NAS shares mounted across logins

Ensures the NAS shares the iCloud backup needs are mounted at login:
- **`/Volumes/Personal-Drive`** — holds the Photos library APFS sparsebundle (M79).
- **`/Volumes/Backups`** — the **export target**; the k8s `aws-s3-sync` `backups`
  share reads this same NAS share over NFS and ships it to S3. iCloud exports
  (photos, and later Drive/Contacts/Messages from M80) land here under `iCloud/`.

Edit the `SHARES=(...)` array in `mount-nas.sh` to add/remove shares.

**Why `/Volumes/Personal-Drive` (not a custom `~/NAS`):** macOS auto-mounts SMB
shares under `/Volumes/<share>`, and the shares are already connected there via
Finder. Trying to mount the *same* share a second time at a custom path fails with
`mount_smbfs: ... : File exists` (EEXIST). So the script uses **`open smb://…`** —
exactly what Finder does — which targets the standard `/Volumes` path and never
conflicts. It's **idempotent** (no-op if already mounted) and the password is
resolved non-interactively from the **login keychain** (nothing secret committed).

> A network share is fine here even though "Photos dislikes network storage" —
> the Photos *library* lives in an **APFS sparsebundle** that mounts as a *local*
> APFS volume; the underlying SMB path is irrelevant to Photos.

**Why a LaunchAgent (user), not a LaunchDaemon (root):** it mounts in your login
session with your keychain + correct ownership for Photos/`osxphotos`. Photos +
`osxphotos` need a GUI (Aqua) session anyway → **auto-login must be on** → "at
login" ≈ "at boot."

### Install (run on the mini, as graham)

```bash
# 1. Save the SMB password in the login keychain (once): Finder → Go → Connect to
#    Server → smb://sequoia.wind.etherport.net/Personal-Drive → tick "Remember
#    this password in my keychain". (Already done if Personal-Drive is mounted.)

# 2. Symlink the plist into LaunchAgents (symlink so `git pull` keeps it current):
ln -sf /Users/grahamsmith/code/infra/infra/macos/mini/net.wind.mount-nas.plist ~/Library/LaunchAgents/net.wind.mount-nas.plist

# 3. Load it:
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/net.wind.mount-nas.plist
```
Verify (run each on its own line — don't paste comments):
```bash
launchctl print gui/$(id -u)/net.wind.mount-nas | grep -E 'state|last exit'
mount | grep -F -e ' on /Volumes/Personal-Drive ' -e ' on /Volumes/Backups '
tail ~/Library/Logs/mount-nas.log
```
Reload after editing the plist: `launchctl bootout gui/$(id -u)/net.wind.mount-nas`
then bootstrap again. (Re-bootstrapping an already-loaded agent returns a benign
`Bootstrap failed: 5: Input/output error` — that just means it's already loaded.)

### Prereqs / caveats
- **Auto-login** must be on, or the agent won't fire until someone logs in via
  Screen Sharing.
- **FileVault** is ON: after a real reboot/power-loss the mini sits at the unlock
  screen and **nothing auto-starts** (auto-login, this agent, the osxphotos timer)
  until the unlock is entered. Gates the whole headless pipeline; not specific to
  this mount.
- Agent runs at login, exits 0 once mounted, and does **not** keep polling. If the
  mount later drops, the **osxphotos export job's preflight** re-runs this script
  (idempotent) and remounts, so the backup self-heals.

## SMB tuning (`/etc/nsmb.conf`) — one-time root install

The SMB client tuning ([`nsmb.conf`](nsmb.conf): `notify_off`, `mc_on`, SMB2/3-only)
**must** be installed at `/etc/nsmb.conf` — the macOS *kernel* SMB client reads only that
path for `open smb://` mounts. `~/Library/Preferences/nsmb.conf` is **not** honored for them
(it was written there for months as a silent no-op — adversarial review C-3). `/etc` needs
root, so a root **LaunchDaemon** installs it at every boot. **One-time setup (sudo, run in
the VNC Terminal — agent bash has no sudo):**

```bash
cd /Users/grahamsmith/code/infra
sudo cp infra/macos/mini/net.wind.nsmb-install.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/net.wind.nsmb-install.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/net.wind.nsmb-install.plist
sudo bash infra/macos/mini/install-nsmb-conf.sh          # immediate effect (no reboot)
# then remount so the new mount negotiates the tuning:
diskutil unmount force /Volumes/Backups; diskutil unmount force /Volumes/Personal-Drive
infra/macos/mini/mount-nas.sh
smbutil statshares -a | grep -E 'SMB_VERSION|SIGN'        # verify
```

`mount-nas.sh` warns at runtime (`⚠ /etc/nsmb.conf is MISSING or STALE`) until this is done,
and logs SMB signing state post-mount. Optional latency lever for the small-file/metadata
path (trusted LAN only, security tradeoff): add `signing_required=no` to `nsmb.conf` if the
NAS doesn't *require* signing.

## `resume-claude-sessions.sh` — restore the Claude Code tmux sessions

Re-creates the three Claude Code tmux sessions on the mini after a reboot,
mirroring the live layout (separate sessions `infra` / `cue` / `personal-web`,
each running `claude --continue` in its project dir). **Idempotent** — skips any
session already running.

```bash
/Users/grahamsmith/code/infra/infra/macos/mini/resume-claude-sessions.sh
tmux attach -t infra      # or cue / personal-web   (detach: Ctrl-b d)
```

- `claude --continue` resumes the **most recent** conversation per directory; use
  `--resume` to pick a specific session.
- **Not auto-run by default** — resuming all three immediately re-starts Claude
  (and re-arms anything like the infra session's `/loop`). To auto-resume at
  login, wire it to a `RunAtLoad` LaunchAgent like `net.wind.mount-nas`.

## M79 — iCloud Photos backup (`create-photos-sparsebundle.sh`, `photos-export.sh`, `net.wind.photos-export`)

Backs up the **iCloud Photos** library as **individual files + XMP sidecars** (albums,
keywords, faces, GPS, captions) to the NAS, where the existing offsite pipeline ships
them to S3.

**Data flow:**
```
iCloud ─(Download Originals)→ Photos library in APFS sparsebundle on the NAS
        /Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle  (attaches as /Volumes/PhotosLib)
   │
   │  osxphotos export --update --sidecar XMP   (read-only re: Photos/iCloud)
   ▼
/Volumes/Backups/Graham/iCloud/Photos          (individual files + .xmp sidecars)
   │
   │  k8s CronJob  s3-sync-backups  (01:00 PT) reads /var/nfs/shared/Backups over NFS
   ▼
s3://archive.wind.etherport.net/objects/backups/...   (Glacier Deep Archive)
```

**Design note — no dedicated bucket/share.** The export target is a subtree of the
**`Backups`** NAS share, which the existing `s3-sync-backups` CronJob already syncs to
the **`archive`** bucket (Glacier **Deep Archive**). So photos ride that existing
pipeline — *no* new S3 bucket, IAM, NFS export, or s3-sync share. (This supersedes the
earlier plan for a separate Glacier-Instant-Retrieval `photos` bucket — owner accepted
Deep Archive's ~12 h retrieval for photos, 2026-06-18.)

**Why the sparsebundle:** `osxphotos` reads a *local* Photos library, but the mini has
only ~11–40 GB free — nowhere near a full "Download Originals" library. The library
lives in an APFS **sparsebundle on the NAS** (bands allocated on demand, bits on the
NAS, mounts as a *local* APFS volume). The sparsebundle itself is the working library
and is **never** uploaded (it's not in the export dir) — only the exported files are.

### Files
- **`create-photos-sparsebundle.sh`** — one-time: creates the 2 TB (sparse) APFS
  sparsebundle. Idempotent; refuses to clobber. **Already run** (bundle exists).
- **`photos-export.sh`** — the nightly job: `mount-nas.sh` → `hdiutil attach` the
  sparsebundle → `osxphotos export --update --download-missing --use-photokit
  --sidecar XMP --cleanup` → the Backups share. Exits **0 with a "not ready" message**
  until a `*.photoslibrary` exists in the attached volume, so it's safe to schedule
  before the owner finishes setup.
  - **`--download-missing --use-photokit` is load-bearing.** iCloud's background
    "Download Originals" **stalls on this headless mini even with Photos open** (observed
    2026-06-18: stuck at ~192/14,267 originals for hours, `cloudphotod` idle at 0% CPU,
    no progress; killing/restarting the daemon didn't revive it). So we do **not** rely
    on the whole library being pre-downloaded — the export fetches each missing original
    **on demand via PhotoKit** as it exports it. Once fetched, the original stays in the
    library (we're on "Download Originals to this Mac", so macOS never re-evicts it) →
    **one-time download per photo, not per run.** Steady state: nothing missing → no
    downloads, and `--update` skips already-exported files → fast no-op.
  - **Permissions:** the PhotoKit path needs the runner to have **Photos Library access
    + Full Disk Access**. Verified working from bash on the mini 2026-06-18 (a forced
    `--missing --download-missing --use-photokit` run downloaded + exported with no TCC
    prompt). If a future macOS/permissions reset breaks it, grant the controlling
    process (Terminal, or whatever runs `launchd` jobs) those TCC permissions via
    System Settings → Privacy & Security, then re-run.
- **`photos-export-resume.sh`** — **self-healing wrapper for the INITIAL bulk pull** (and
  any future full re-pull). The first export of ~14k photos is long enough that an SMB
  drop or an osxphotos PhotoKit-XPC wedge is likely (both hit 2026-06-19 — see the
  session-log). It loops: remount NAS → ensure Photos.app up → `osxphotos export --update`
  (resumes from `<DEST>/.osxphotos_export.db`) under a watchdog that kills + retries the
  run if the `Backups` mount disappears or file progress flatlines (zero growth for 8 min
  = wedged). Use this — not bare `photos-export.sh` — to do the first fill. Steady-state
  nightly runs use the plain script via the LaunchAgent.
- **`net.wind.photos-export.plist`** — LaunchAgent, daily **22:00 PT** (before the
  01:00 PT s3-sync so each night's export ships same-day). **Not loaded yet** — enable
  after the initial bulk pull is complete and the mount has proven stable.

### Owner one-time setup (interactive, via VNC) — the long pole
The backup **cannot delete or modify** your photos: `osxphotos` is read-only toward
Photos/iCloud; `--cleanup` only prunes the NAS *export copy*; `aws s3 sync --delete`
only affects the *S3 copy*. iCloud holds the masters, so the sparsebundle is just a
disposable mirror. Steps:

1. **Safety gate:** in Photos with your *current* library, Settings → iCloud → confirm
   photos are **uploaded / nothing pending**. Only proceed once iCloud holds every master.
2. Attach the bundle (the export job does this too, but for setup):
   `hdiutil attach /Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle`
3. **Option-launch Photos** (hold ⌥, click Photos) → "Choose Library…" → **Create
   New…** → save it *inside* `/Volumes/PhotosLib/`. Photos opens an empty library.
4. Settings → General → **"Use as System Photo Library."**
5. Settings → iCloud → **enable iCloud Photos** → **Download Originals to this Mac**
   (not Optimize — "Download Originals" mode is what keeps fetched masters from being
   re-evicted). iCloud repopulates the new library into the NAS sparsebundle. Note: the
   background download is **unreliable here** (see `--download-missing` above) — you do
   **not** need to wait for it to finish; the first export run pulls every missing
   original itself via PhotoKit. Sleep is already disabled (`pmset sleep 0`).
   Your **old library stays untouched** as a fallback.
6. **Seed the first export + enable the nightly timer.** The first run downloads all
   ~14k originals via PhotoKit (slow — hours, but resumable: `--update` records progress
   in `<DEST>/.osxphotos_export.db`, so a re-run continues where it left off):
   ```bash
   ln -sf /Users/grahamsmith/code/infra/infra/macos/mini/net.wind.photos-export.plist ~/Library/LaunchAgents/net.wind.photos-export.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/net.wind.photos-export.plist
   ```
   Then run once to seed the first export: `./photos-export.sh` (or `launchctl kickstart
   gui/$(id -u)/net.wind.photos-export`). Logs: `~/Library/Logs/photos-export.log` +
   per-run reports in `~/Library/Logs/photos-export/`.

### Caveats
- **Apple 2FA** sessions expire (weeks→months) → periodic interactive re-auth via VNC.
- **Sparsebundle-over-network corruption** if the SMB link drops mid-write (Time-Machine
  risk model). Hit hard 2026-06-19: the mounts dropped repeatedly — including
  `Personal-Drive` dropping *while idle* on the 10G link — force-quitting Photos ("quit to
  prevent corruption") and leaving a dirty APFS journal. **Root cause: macOS SMB
  *multichannel* was on** (no `nsmb.conf` existed); it's the classic cause of spontaneous
  idle SMB resets against a NAS on a fast NIC (not write-load/sleep/bandwidth). **Fix:
  [`nsmb.conf`](nsmb.conf)** (`mc_on=yes` — multichannel was later cleared, the real 6-19
  culprit was a failing NVMe cache SSD — + SMB1 off + `notify_off`). **⚠️ The tuning MUST
  live at `/etc/nsmb.conf`** — the kernel SMB client (`open smb://`) reads only that path,
  NOT `~/Library/Preferences/nsmb.conf`. Writing the user file was a **silent no-op**
  (adversarial review C-3, 2026-06-22: live `smbutil statshares -a` showed defaults). See
  the **SMB tuning** section below for the (root) install.
- **`mount-nas.sh` now attaches the sparsebundle at login** (installs `nsmb.conf`, mounts
  the shares, then `hdiutil attach`es the bundle) — before this, nothing attached it after
  a reboot, so Photos errored "PhotosLib cannot be found" until the export job ran.
- **`photos-export-resume.sh` `--cleanup` is opt-in** (`CLEANUP=1`): skip it (default)
  whenever `<DEST>/.osxphotos_export.db` is missing, or cleanup may delete+re-download
  already-exported files. The nightly `photos-export.sh` keeps `--cleanup` (DB is healthy
  in steady state).
- **`photos-export-resume.sh` defaults to a pure-LOCAL export; `--download-missing` is
  opt-in** (`DOWNLOAD_MISSING=1`). `--download-missing --use-photokit` drives PhotoKit,
  which needs Photos.app + a live CoreData/XPC link to the library daemon — and on the
  SMB-backed library that link is **fragile**: any SMB blip makes Photos.app quit (the
  "library moved or corrupt" dialog) and **wedges** osxphotos on `CoreData: XPC: failed
  after N attempts` (0 progress until the watchdog kills it). So do the bulk fill in
  **local mode** (reads the library files directly — no PhotoKit, no Photos.app, no
  dialogs; exports everything already downloaded, reports the rest as "missing"), then a
  short **`DOWNLOAD_MISSING=1`** pass for just the genuinely-not-local originals.
- **Steady state (since 2026-06-21): the nightly `photos-export.sh` runs LOCAL by default**
  (no PhotoKit/Photos.app → no TCC dialogs, no `photolibraryd` wedges). `DOWNLOAD_MISSING=1`
  turns it into the supervised PhotoKit download pass (restarts the daemon stack first). Do
  downloads supervised, not unattended.
- **No-new-duplicates guarantee — the rule that matters most.** osxphotos uses `(N)` suffixes
  for filename collisions; if it runs **without** the persistent export DB it re-assigns those
  numbers every run and re-exports the same photos under new names (this is what produced
  ~30k orphan dups). Both scripts now pin **`--exportdb` to a LOCAL file**
  (`~/Library/Application Support/osxphotos/graham-icloud-photos.db`) so `--update` reuses
  canonical names, plus `--cleanup` (orphan net) and an atomic **`.run.lock`** (no two runs
  racing the ledger). **Never run osxphotos against this export dir without `--exportdb` →
  that file, and never delete it.**
- **Bulk file-count ops (e.g. deleting tens of thousands of dups) must be done NAS-LOCAL
  (SSH), not over SMB.** A single delete over SMB is ~15 ms, but *sustained* bulk delete is
  NAS-metadata-bound (~300–650 ms/file; hours for 30k) and far worse if parallelized — that's
  not the cache, and not fixable from the Mac. (`mc_on=yes`/multichannel is back on; the
  original idle drops were the NVMe cache, not multichannel.)
- **FileVault** (see the mount-nas caveat) gates the whole pipeline after a reboot.

### Monitoring (Prometheus Pushgateway)
Both `photos-export.sh` and `photos-export-resume.sh` push run metrics to the cluster
**Pushgateway** after each run via `photos-metrics.sh` (`push_photos_metrics`) — always
**non-fatal** (a monitoring outage never blocks a backup). Override the endpoint with
`PUSHGATEWAY=` (default `https://pushgateway.wind.etherport.net`). Metrics (job
`photos_export`, resume job `photos_export_resume`, `instance="mini"`):
`*_last_run_timestamp_seconds`, `*_last_success_timestamp_seconds` (own group so a failed
run can't wipe it — the staleness alert keys on this), `*_last_rc`, `*_duration_seconds`,
`*_photos_total`, `*_exported`, `*_missing`, `*_info{mode}`. **Cluster side (expose
pushgateway via Traefik + PrometheusRule + Grafana) is set up by the infra agent.** Until
then the pushes just log "push failed" and no-op.

## M80 — iCloud Contacts + Calendars (`icloud-dav-backup.sh`, `net.wind.icloud-dav`)
Backs up iCloud **Contacts** (CardDAV) + **Calendars** (CalDAV) to individual `.vcf` / `.ics`
files under the consistent master location **`/Volumes/Backups/Graham/iCloud/{Contacts,Calendars}/`**,
via **`vdirsyncer`** (pipx). The iCloud storages are **`read_only = true`** in `vdirsyncer-config`,
so it can only ever pull iCloud → NAS — it can **never modify/delete** your real contacts or
calendars. Per-category metrics (`contacts_backup_*`, `calendars_backup_*`) push to Pushgateway
via `mini-backup-metrics.sh` (same mechanism as photos); logs ship to Loki via Alloy
(`job="icloud-dav"`). Run-lock + 30-min watchdog like the photos nightly.

**Credential:** an Apple **app-specific password** (appleid.apple.com), stored in the SOPS
bundle as `icloud_app_password` and fetched at runtime by `icloud-app-password.sh` (nothing
secret in the repo).

### One-time setup (run on the mini, as graham)
```bash
brew install pipx 2>/dev/null; pipx install vdirsyncer       # vdirsyncer → ~/.local/bin
# 1. add the app-specific password to SOPS (value never touches the repo):
sops infra/ansible/playbooks/secrets/homelab-ops.sops.yaml   # add: icloud_app_password: xxxx-xxxx-xxxx-xxxx
# 2. discover collections (interactive once; re-run if you add an address book/calendar):
VDIRSYNCER_CONFIG=infra/macos/mini/vdirsyncer-config ~/.local/bin/vdirsyncer discover
# 3. first sync + load the nightly (21:00) agent:
infra/macos/mini/icloud-dav-backup.sh
ln -sf "$PWD/infra/macos/mini/net.wind.icloud-dav.plist" ~/Library/LaunchAgents/net.wind.icloud-dav.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/net.wind.icloud-dav.plist
```

## M80 — iMessage backup (`messages-backup.sh`, `net.wind.messages-backup`)
Backs up the Messages history — `chat.db` + `Attachments/` — to **`/Volumes/Backups/Graham/iCloud/Messages/`**
(restorable to a Mac), nightly at **20:00** (staggered before DAV 21:00 / photos 22:00; ships
offsite via the 01:00 s3-sync). Pushes `messages_backup_*` to Pushgateway (auto-covered by the
iCloud-backups dashboard + `ICloudBackup{Stale,Failed,Empty}` alerts).

**How it stays consistent + safe:** `rsync` copies the live `chat.db` (+`-wal`/`-shm`) to LOCAL
staging, then `sqlite3 .backup` on the **staged** copy checkpoints the WAL into a clean
standalone `chat.db` and runs `integrity_check` — a torn/corrupt copy FAILS the run (it never
overwrites the good NAS copy; next run retries). The staged DB + live `Attachments/` are then
**guarded-mirrored** to the NAS (refuse-if-source-empty + `--max-delete` cap — same
delete-protection as the other pipelines). Reuses `mini-common.sh` (lock/timeout/self-heal) +
`mount-nas.sh` (stale-mount self-heal).

**⚠️ Prereq — Full Disk Access (the one blocker).** `~/Library/Messages` is TCC-protected. macOS
attributes file access to the **"responsible process"**, not the leaf binary — under launchd
that's the job's program **`/bin/bash`** (interactively it's `Terminal.app`). So **grant Full
Disk Access to `/bin/bash`** (NOT just rsync — a leaf-binary grant on rsync is ignored, since
rsync runs as a child of bash). With bash granted, the launchd job + all its children (rsync,
sqlite3) can read Messages. Without it the run aborts cleanly with `no-FDA-rsync-cannot-read-Messages`
(rc=1, no silent empty backup). Messages.app must also be signed into iMessage (it is — 2026-06-23).
NB: network volumes (/Volumes/<smb>) ALSO need FDA from a background context — covered by the
same bash grant; the NAS probe uses `rsync -n` (stat-only) so it works regardless.

### One-time setup (run on the mini, as graham)
```bash
# 1. Grant Full Disk Access to /bin/bash (interactive, VNC): System Settings → Privacy & Security
#    → Full Disk Access → + → ⌘⇧G → /bin/bash → enable. (This is the launchd responsible process;
#    granting only rsync does NOT work. /bin/bash with FDA = any bash script gets FDA — acceptable
#    on this dedicated ops mini.)
# 2. Manual first run (verifies FDA + ships the first copy):
infra/macos/mini/messages-backup.sh
# 3. Load the nightly (20:00) agent once the manual run is green:
ln -sf "$PWD/infra/macos/mini/net.wind.messages-backup.plist" ~/Library/LaunchAgents/net.wind.messages-backup.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/net.wind.messages-backup.plist
```

## M80 — Notes / Safari / iCloud Drive (`icloud-files-backup.sh`, `net.wind.icloud-files`)
Backs up the "file-shaped" iCloud categories to `/Volumes/Backups/Graham/iCloud/{Notes,Safari,Drive}/`,
nightly at **19:30** (staggered first). One script, three guarded rsync mirrors, each with its
own metric (`notes_backup` / `safari_backup` / `icloud_drive_backup`):
- **Notes** — the whole `group.com.apple.notes` container (NoteStore.sqlite + Accounts/ media);
  the DB is `integrity_check`ed read-only before mirroring so a corrupt DB never propagates.
- **Safari** — `Bookmarks.plist` (bookmarks + reading list).
- **iCloud Drive** — `~/Library/Mobile Documents/com~apple~CloudDocs`; logs the `.icloud`
  evicted-stub count (Optimize-Storage placeholders mirror as stubs, not real data).

Same prereq as Messages: **Full Disk Access on `/bin/bash`** (covers all three + the network
volume). All NAS access via rsync; guarded with `--max-delete`; mount self-heals via `mount-nas.sh`.
**Reminders need no separate job** — they're CalDAV (VTODO) and already ride the Calendars sync.
Load: `ln -sf "$PWD/infra/macos/mini/net.wind.icloud-files.plist" ~/Library/LaunchAgents/` then
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/net.wind.icloud-files.plist`.

## `net.wind.alloy` — ship the mini's logs to Loki (`alloy-config.alloy`)
Grafana **Alloy** tails the backup-pipeline logs and pushes them to the cluster **Loki** so
this off-cluster macOS host's logs are searchable in Grafana (and alertable via the Loki
ruler). Tails `photos-export.log`, `photos-export/*.out|*.log`, `icloud-dav*`, `messages-backup*`, `mount-nas.log`, `alloy.log`
(labels `host="mini"`, `job=`). Buffers to a local WAL and retries, so it's harmless before
Loki is reachable — nothing lost.

**Loki endpoint** = `LOKI_URL` env in the plist (default
`https://loki.wind.etherport.net/loki/api/v1/push`) — the infra agent exposes
`loki.wind.etherport.net → svc/loki:3100` via Traefik + a Technitium A record.

### Install (run on the mini, as graham)
```bash
brew install grafana-alloy                                    # binary: /opt/homebrew/bin/alloy
ln -sf /Users/grahamsmith/code/infra/infra/macos/mini/net.wind.alloy.plist ~/Library/LaunchAgents/net.wind.alloy.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/net.wind.alloy.plist
```
Verify: `launchctl print gui/$(id -u)/net.wind.alloy | grep state` · `tail ~/Library/Logs/alloy.log`.
Reload after editing: `launchctl bootout gui/$(id -u)/net.wind.alloy` then bootstrap again.
(`alloy fmt alloy-config.alloy` validates config syntax.)
