# mini macOS automation

Mac-native automation that runs **on the Mac mini** (`graham@`, the headless ops
host) — things that can't live in k8s/Flux because they need macOS APIs (Photos,
SMB/keychain, `launchd`, tmux). Version-controlled here; installed into the user's
`~/Library/LaunchAgents` on the mini.

> **iCloud backups now run on [`cairn`](https://github.com/sparked-diamond/cairn)**, not the bash
> scripts that used to live here. The per-category bash suite (`*-backup.sh`, `photos-export*.sh`,
> the `net.wind.{icloud-dav,icloud-files,messages-backup,photos-export}` agents, vdirsyncer) was
> **retired 2026-06-26** (M103 cutover) and removed from this dir. What remains here is the
> **shared mini infrastructure** cairn depends on (NAS mounts, SMB tuning, the Photos sparsebundle,
> log shipping, the host heartbeat). cairn deployment is documented in
> [`../../../docs/runbooks/cairn-deployment.md`](../../../docs/runbooks/cairn-deployment.md); its
> install/config/metrics are in the cairn repo `README.md`.

## `net.wind.mount-nas` — keep the NAS shares mounted across logins

Ensures the NAS shares the iCloud backup needs are mounted at login:
- **`/Volumes/Personal-Drive`** — holds the Photos library APFS sparsebundle.
- **`/Volumes/Backups`** — the **export target**; the k8s `aws-s3-sync` `backups` share reads this
  same NAS share over NFS and ships it to S3. cairn's exports land here under `iCloud/`.

Edit the `SHARES=(...)` array in `mount-nas.sh` to add/remove shares.

**Why `/Volumes/<share>` + `open smb://` (not `mount_smbfs` to a custom path):** macOS auto-mounts SMB
shares under `/Volumes/<share>` and removes that (root-owned) dir on unmount, so `mount_smbfs` to it
fails (`could not find mount point` / `File exists`). `open smb://…` — what Finder does — lets the
system automounter create the mountpoint as root and mount with the **login-keychain** password
(nothing secret committed). Idempotent. **cairn now self-heals its own SMB mounts the same way**
(`open smb://` in `MountHealth`), so a mid-day mount drop is recovered by the next cairn run; this
login-time agent is the baseline that gets them up after a reboot.

**Why a LaunchAgent (user), not a LaunchDaemon (root):** it mounts in your login session with your
keychain + correct ownership for Photos/`osxphotos`. (Photos needs a GUI/Aqua session → **auto-login
must be on** → "at login" ≈ "at boot.")

### Install (run on the mini, as graham)
```bash
# Save the SMB password in the login keychain once (Finder → Connect to Server → smb://… → "Remember").
ln -sf /Users/grahamsmith/code/infra/infra/macos/mini/net.wind.mount-nas.plist ~/Library/LaunchAgents/net.wind.mount-nas.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/net.wind.mount-nas.plist
```
Verify: `mount | grep -F -e ' on /Volumes/Personal-Drive ' -e ' on /Volumes/Backups '` · `tail ~/Library/Logs/mount-nas.log`.
Reload after editing the plist: `launchctl bootout gui/$(id -u)/net.wind.mount-nas` then bootstrap again.

### Prereqs / caveats
- **Auto-login** must be on, or the agent won't fire until someone logs in via Screen Sharing.
- **FileVault** is ON: after a reboot/power-loss the mini sits at the unlock screen and nothing
  auto-starts (auto-login, this agent, cairn) until unlock is entered. Gates the whole headless pipeline.
- Runs at login, exits 0 once mounted, doesn't keep polling. If a mount later drops, **cairn's own
  `open smb://` self-heal** remounts it before each run (no longer dependent on this agent's timing).

## `net.wind.nfs-backups` — Backups over NFS (Phase 1, 2026-07-11)

`/Volumes/Backups` is mounted over **NFS** by a ROOT LaunchDaemon (`nfs-mount-backups.sh`,
RunAtLoad + every 3 min), replacing the SMB mount. Why: SMB's failure mode is *interactive* —
after any abnormal session end (UNAS Samba wedge, NAS reboot), macOS NetAuth demands a console
click to reuse the saved password, which on a headless box means a dead mount until a human
shows up (the 2026-07-03→09 and 07-10→11 outages). NFS auth is **host-based** (the mini's IP
in the UNAS export ACL — already present) — no keychain, no NetAuth, no dialogs, ever. The
k8s s3-sync read this same export over NFS through every SMB outage without a hiccup.

- Export: `sequoia:/var/nfs/shared/Backups` (rw, `all_squash,anonuid=977` → uid mapping moot;
  `secure` → mount needs `resvport`, hence root). Fallback path in the script if the friendly
  path stops resolving: the literal `/volume/<uuid>/.srv/.unifi-drive/Backups/.data`.
- Mount opts: `soft,intr,nolocks` — a NAS outage FAILS I/O rather than hanging cairn on its
  run lock (cairn's rsync writes are temp+rename, resumable; no byte-range locks needed).
- The script never leaves a bare `/Volumes/Backups` dir behind (an empty local dir would pass
  cairn's dest gate and mirror onto the mini's disk) — mkdir just before mount, rmdir on fail.
- **One-time install (sudo):** `sudo infra/macos/mini/install-nfs-backups.sh` — installs the
  plist, replaces any SMB mount, verifies. Rollback steps in the installer header.
- Log: `~/Library/Logs/nfs-backups.log` (silent when healthy). mini-health gauges it as
  `mini_health_check{check="nfs_daemon"}` once the plist is installed.
- `mount-nas.sh` now handles **Personal-Drive only** (sparsebundle backing — Phase 2 will
  evaluate moving it too).

## SMB tuning (`/etc/nsmb.conf`) — one-time root install

The kernel SMB client tuning ([`nsmb.conf`](nsmb.conf): `notify_off`, SMB2/3-only) **must** live at
`/etc/nsmb.conf` — the macOS *kernel* SMB client reads only that path for `open smb://` mounts
(`~/Library/Preferences/nsmb.conf` is a silent no-op for them). `/etc` needs root, so a root
**LaunchDaemon** installs it at every boot. One-time setup (sudo, in the VNC Terminal):
```bash
cd /Users/grahamsmith/code/infra
sudo cp infra/macos/mini/net.wind.nsmb-install.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/net.wind.nsmb-install.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/net.wind.nsmb-install.plist
sudo bash infra/macos/mini/install-nsmb-conf.sh          # immediate effect (no reboot)
diskutil unmount force /Volumes/Backups; diskutil unmount force /Volumes/Personal-Drive
infra/macos/mini/mount-nas.sh
smbutil statshares -a | grep -E 'SMB_VERSION|SIGN'        # verify
```
Background: a failing NVMe cache SSD (not multichannel) caused the 2026-06-19 idle SMB drops; the
`nsmb.conf` tuning + SMB1-off + `notify_off` is the durable hardening. Bulk file-count ops over SMB
are NAS-metadata-bound (~300–650 ms/file) — do them NAS-local (SSH), not over SMB.

## Photos library sparsebundle (`create-photos-sparsebundle.sh`) — one-time setup

cairn's `photos` job (osxphotos) reads a **local** Photos library, but the mini has only ~15 GB free.
The library lives in a 2 TB APFS **sparsebundle on the NAS**
(`/Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle`) that mounts as a *local* APFS volume
(`/Volumes/PhotosLib`); only osxphotos's *export* (individual files + XMP sidecars) is backed up — the
sparsebundle itself is never uploaded. `create-photos-sparsebundle.sh` is the **one-time, idempotent**
creator (already run — the bundle exists). `mount-nas.sh` attaches it at login; cairn re-attaches it
(via `hdiutil`) in its photos stack-heal if it's dropped. The owner-side library setup (create the
library inside the volume, "Use as System Photo Library", "Download Originals to this Mac") is the
one-time prerequisite — see the cairn deploy runbook.

## `net.wind.claude-session` — auto-start/auto-resume the Claude Code session

The mini's dev session (tmux **`cairn`**, working dir `~/code/cairn`; the infra repo is an
additional directory in its settings) is kept alive by a LaunchAgent running
`resume-claude-sessions.sh` every 2 min: recreates a missing tmux session at login/boot and
re-sends `claude --continue` into a pane whose claude crashed (pane sitting at a bare shell).
Attach: `tmux attach -t cairn` · detach: `Ctrl-b d` · log: `~/Library/Logs/claude-session.log`.
Install: `cp net.wind.claude-session.plist ~/Library/LaunchAgents/ && launchctl bootstrap
gui/$(id -u) ~/Library/LaunchAgents/net.wind.claude-session.plist`. Never migrate a session by
copying .jsonl files (RC session-UUID collision). Old manual use ('restore after reboot') still
works: just run the script.

## `resume-claude-sessions.sh` — (legacy heading; see net.wind.claude-session above)

Re-creates the Claude Code tmux sessions on the mini after a reboot (separate sessions per project,
each running `claude --continue`). **Idempotent** — skips any session already running.
```bash
/Users/grahamsmith/code/infra/infra/macos/mini/resume-claude-sessions.sh
tmux attach -t infra      # or cue / personal-web   (detach: Ctrl-b d)
```

## `net.wind.mini-health` — host heartbeat

`mini-health.sh` (every 15 min) pushes `mini_health_*` to Pushgateway: agents loaded vs expected
(now the **cairn** agents — `net.wind.cairn`, `cairn.health` — plus `mount-nas`/`alloy`), NAS
readable, `nsmb.conf` applied, disk free. A stale `mini_health_last_check_timestamp_seconds` =
the mini is down or can't reach Pushgateway. (Backup-job health is separate — cairn's own
`cairn_health` rollup + the per-job `cairn_backup_*` metrics.)

## `net.wind.alloy` — ship the mini's logs to Loki (`alloy-config.alloy`)

Grafana **Alloy** tails the mini's logs and pushes them to the cluster **Loki** so this off-cluster
host's logs are searchable/alertable in Grafana. Tails **cairn's logs**
(`~/Library/Logs/cairn/{cairn,health}.log`) plus `mini-health.log`, `mount-nas.log`, `alloy.log`
(labels `host="mini"`, `job=` — the photos-export dashboard's `{host="mini"}` Loki panel reads these).
Buffers to a local WAL and retries, so it's harmless before Loki is reachable.

### Install (run on the mini, as graham)
```bash
brew install grafana-alloy                                    # binary: /opt/homebrew/bin/alloy
ln -sf /Users/grahamsmith/code/infra/infra/macos/mini/net.wind.alloy.plist ~/Library/LaunchAgents/net.wind.alloy.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/net.wind.alloy.plist
```
Reload after editing: `launchctl bootout gui/$(id -u)/net.wind.alloy` then bootstrap again
(`alloy fmt alloy-config.alloy` validates syntax). **Loki endpoint** = `LOKI_URL` env in the plist.
