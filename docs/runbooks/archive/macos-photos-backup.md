# Runbook — macOS iCloud Photos backup (M79, the mini pipeline)

> ⚠️ **SUPERSEDED 2026-06-26 by cairn (M103).** The bash `photos-export*.sh` pipeline this runbook
> describes was retired; iCloud Photos (and all other categories) now run on **cairn** — see
> [`cairn-deployment.md`](cairn-deployment.md) and the cairn repo README. Kept for the M79 history
> (sparsebundle rationale, the download-missing/SMB saga) which still informs the cairn photos source.

**What:** backs up the iCloud Photos library as individual files + XMP sidecars to the NAS
`Backups` share (→ S3 via the existing `s3-sync-backups` CronJob), with Prometheus metrics +
Loki logs for observability. Runs **on a macOS host** (currently the Mac mini,
`graham@`, `10.10.202.101`) because it needs Photos/PhotoKit/SMB-keychain/launchd.

This runbook is the **operational + replication** guide. Component-level detail lives in
[`infra/macos/mini/README.md`](../../infra/macos/mini/README.md); durable cross-session
gotchas are in the agent memory. Narrative history: `docs/planning/session-log.md`
(2026-06-18 → 22).

---

## Architecture

```
iCloud Photos
   │  (library lives in an APFS sparsebundle on the NAS, mounted as a *local* volume)
   ▼
/Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle  ──hdiutil attach──▶  /Volumes/PhotosLib/…photoslibrary
   │
   │  osxphotos export --update --exportdb <LOCAL .db> --sidecar XMP --cleanup [--download-missing --use-photokit]
   ▼
/Volumes/Backups/Graham/iCloud/Photos/   (individual files + .xmp sidecars; the canonical export)
   │                                   └─ export DB (ledger) is LOCAL: ~/Library/Application Support/osxphotos/graham-icloud-photos.db
   │  k8s CronJob s3-sync-backups (01:00 PT) reads /var/nfs/shared/Backups over NFS
   ▼
s3://archive.wind.etherport.net/objects/backups/Graham/iCloud/Photos/…  (Object-Lock + Deep Archive)

Observability (off-cluster host → cluster):
   photos-export.sh / photos-export-resume.sh ──push metrics──▶ https://pushgateway.wind.etherport.net  ──scrape──▶ Prometheus ─▶ Grafana/Alertmanager
   Grafana Alloy (net.wind.alloy) ──ship logs──▶ https://loki.wind.etherport.net/loki/api/v1/push        ──▶ Grafana
```

## Components (all in `infra/macos/mini/`, version-controlled)

| File | Role |
|---|---|
| `create-photos-sparsebundle.sh` | one-time: create the 2 TB sparse APFS sparsebundle |
| `mount-nas.sh` | login agent target: install nsmb.conf, mount SMB shares, **attach the sparsebundle** |
| `nsmb.conf` | SMB client hardening (installed to `~/Library/Preferences/nsmb.conf`) |
| `photos-export.sh` | nightly export (LOCAL mode by default); `DOWNLOAD_MISSING=1` = supervised PhotoKit download pass |
| `photos-export-resume.sh` | self-healing wrapper for bulk fills / supervised download passes (watchdog + retries) |
| `photos-metrics.sh` | shared: `push_photos_metrics` → Pushgateway (non-fatal) |
| `alloy-config.alloy` | Grafana Alloy config: tail the pipeline logs → Loki |
| `net.wind.mount-nas.plist` | LaunchAgent: run mount-nas.sh at login |
| `net.wind.photos-export.plist` | LaunchAgent: nightly 22:00 PT |
| `net.wind.alloy.plist` | LaunchAgent: keep Alloy running |

## Key invariants (do not break these)

- **Export DB is LOCAL and persistent.** `--exportdb ~/Library/Application Support/osxphotos/graham-icloud-photos.db`.
  `--update` reuses the canonical filenames it records, so it never re-creates `(N)`
  duplicates. **Never run osxphotos against the export dir without `--exportdb` → that file,
  and never delete it.** A lost/absent DB caused a ~30k-file duplicate explosion (osxphotos
  re-assigns `(N)` collision suffixes from scratch each run).
- **Do NOT use `--ramdb`.** It keeps the DB in memory and only writes on a *clean* finish, so
  a killed run loses its record → orphan dupes + risk of `--cleanup` deleting unrecorded files.
  The local DB persists incrementally without it.
- **Single-run lock** (`~/Library/Logs/photos-export/.run.lock`, atomic mkdir) in both scripts —
  two runs racing the same DB can re-mint dupes. Concurrent runs exit early by design.
- **SMB multichannel ON** (`mc_on=yes` in nsmb.conf). The earlier idle drops were a failing
  NVMe cache SSD on the UNAS, not multichannel; disabling it throttled bulk throughput onto
  one channel (made parallel deletes pathologically slow).
- **Bulk file-count ops (deleting tens of thousands) MUST be done NAS-local (SSH), not over
  SMB.** Single delete ≈ 15 ms, but *sustained* bulk delete is NAS-metadata-bound
  (~300–650 ms/file) — hours for 30k over SMB. Generate the list on the mini, delete on the NAS.
- **Nightly runs LOCAL mode** (no Photos.app/PhotoKit → no TCC dialogs, no `photolibraryd`
  wedges). PhotoKit (`DOWNLOAD_MISSING=1`) is only needed to *download not-yet-local
  originals* and is fragile (wedges, dialogs) — run it **supervised**, not in the nightly.

## Replicating on a new macOS host

Prereqs: the host signed into the same iCloud account; SMB password for the NAS in the login
keychain; auto-login ON; (FileVault is a choice — see persistence below).

```bash
# 1. tools
brew install pipx grafana-alloy && pipx install osxphotos
#    (osxphotos → ~/.local/bin/osxphotos; alloy → /opt/homebrew/bin/alloy)

# 2. clone the repo (so the plists/scripts resolve)
git clone git@github.com:sparked-diamond/infra.git ~/code/infra

# 3. one-time library setup (interactive, see infra/macos/mini/README.md "Owner one-time setup"):
#    create the sparsebundle, create a Photos library inside it, sign into iCloud,
#    set "Download Originals to this Mac", grant osxphotos Photos + Full Disk Access (TCC).

# 4. install the LaunchAgents (symlink so `git pull` keeps them current, then bootstrap)
for a in net.wind.mount-nas net.wind.photos-export net.wind.alloy; do
  ln -sf ~/code/infra/infra/macos/mini/$a.plist ~/Library/LaunchAgents/$a.plist
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$a.plist
done
# mount-nas.sh installs nsmb.conf itself on first run.

# 5. seed the export DB (first full export — long; resumable). Supervised, because the first
#    pull downloads originals via PhotoKit:
DOWNLOAD_MISSING=1 ~/code/infra/infra/macos/mini/photos-export-resume.sh
```
Paths are currently hard-coded to `/Users/grahamsmith` + `/Volumes/Personal-Drive|Backups`;
adjust the scripts' config blocks for a different user/share. The cluster side (Pushgateway
+ Loki exposure, PrometheusRule, dashboard) is in `platform/kubernetes/monitoring/` — see
"Monitoring" below; nothing host-specific there.

## Reboot / persistence

- **Persists:** all three LaunchAgents auto-load from `~/Library/LaunchAgents` at login;
  `nsmb.conf`, the export DB, and the `alloy` binary live on local disk; Alloy buffers logs
  to a WAL and retries. At login, `mount-nas.sh` re-mounts the shares and **re-attaches the
  sparsebundle** (it is NOT auto-attached otherwise), Alloy resumes, the nightly timer arms.
- **The gate: FileVault is ON.** A cold reboot sits at the unlock screen — *nothing* starts
  until the disk is unlocked at the console/VNC. After unlock, **auto-login** must be on for
  the agents to start without a manual login. This is unavoidable (FileVault by design) and
  is the one manual step after a power loss.

## Monitoring

- **Metrics** (Pushgateway, job `photos_export` / resume `photos_export_resume`,
  `instance="mini"`): `*_last_run_timestamp_seconds`, `*_last_success_timestamp_seconds`
  (own group `*_lastsuccess` so a failed run can't wipe it), `*_last_rc`, `*_duration_seconds`,
  `*_photos_total`, `*_exported`, `*_missing`, `*_missing_unavailable` (structurally
  unavailable — edited Live-Photo motion clips), `*_missing_resolvable` (genuinely missing,
  should be 0), `*_info{mode}`. Endpoint `https://pushgateway.wind.etherport.net` (https —
  the web:80 entrypoint 301-redirects and breaks POSTs). Cluster: alerts in
  `platform/kubernetes/monitoring/09-photos-export-alerts.yaml`, dashboard in
  `platform/kubernetes/monitoring/dashboards/photos-export.yaml`.
- **Logs** (Loki, `{host="mini"}`): Alloy ships `photos-export.log`, `photos-export/*.out|*.log`,
  `mount-nas.log`, `alloy.log`. Endpoint `https://loki.wind.etherport.net/loki/api/v1/push`.

## Coverage / what "100%" means

A complete backup is **`missing_resolvable == 0`** — every photo whose original iCloud will
serve is backed up. `missing_unavailable` (edited Live-Photo *motion clips*, `*_edited*.mov`)
is a separate, expected residual: Apple doesn't expose that derivative for download, but the
still + the original motion + the edited still ARE backed up, so no image content is lost.
Track `missing_resolvable` for things actually worth fixing (re-run a supervised
`DOWNLOAD_MISSING=1` pass, or manually "Download Originals" in Photos via VNC).

## Troubleshooting

- **`hdiutil attach` fails "Resource temporarily unavailable":** a force-killed `hdiutil
  attach` orphans its `diskimages-helper`, which keeps holding the sparsebundle lock. Fix:
  `pgrep -f diskimages-helper` → `kill -9` it (detaching stale `/dev/diskN` alone is not
  enough), then re-attach. Confirm with `lsof <sparsebundle>`.
- **`hdiutil attach` hangs (minutes):** SMB/NAS slowness; if the NVMe cache is degraded,
  reads/metadata stall. Check the UNAS (`dmesg`/`mdstat` for `nvme0`).
- **SMB reads work but writes/deletes crawl or EIO:** NVMe cache-SSD issue on the UNAS, not
  the Mac. Reboot/repair the NAS; bulk deletes belong NAS-local meanwhile.
- **Photos "library could not be opened" / corruption dialog:** transient SMB blip during a
  PhotoKit run; the library is a disposable iCloud cache. Recover by re-attaching (read-write
  attach replays the APFS journal); `PRAGMA wal_checkpoint` if a large WAL is outstanding.
- **Nightly wedges at 0% CPU under launchd (but the same command is CPU-active from a
  terminal) — TCC / Full Disk Access:** this is the #1 gotcha for the *unattended* nightly.
  An interactive shell inherits the user's TCC grants; the **launchd LaunchAgent context does
  not**, so when osxphotos accesses the Photos library it blocks on a TCC prompt that can
  never appear headlessly → 0% CPU forever (the runtime watchdog now bounds it). **Fix (one
  time, in the GUI via VNC): System Settings → Privacy & Security → Full Disk Access → `+` →
  add `/Users/grahamsmith/.local/pipx/venvs/osxphotos/bin/python`** (the osxphotos
  interpreter; ⌘⇧G to paste the path), toggle it on. If it still wedges, also add `/bin/bash`
  (the LaunchAgent's launcher). Both LOCAL and PhotoKit modes need this — earlier notes that
  "local mode doesn't need TCC" were WRONG; local mode reads the library files directly,
  which is exactly what FDA protects. Verify: `launchctl kickstart -k
  gui/$(id -u)/net.wind.photos-export` then `ps -o %cpu` on osxphotos should be >5% and the
  report CSV should grow. (The old `could not get authorization to access Photos library`
  error was the PhotoKit variant of the same missing grant.)
- **`--cleanup` wedges at 0% CPU:** it enumerates all ~45k DEST files over SMB before
  exporting; the NAS's slow metadata makes that hang. It's opt-in (`CLEANUP=1`) for this
  reason — default off is dup-safe. Remove orphans NAS-local instead.
- **Duplicate `(N)` files appearing:** something ran osxphotos without `--exportdb` → the
  local DB, or two runs raced. Dedup = compute orphans as files-on-disk not in
  `export_data.filepath` (survivor-guard: only delete if a canonical copy of that photo
  survives), delete NAS-local.
