# iCloud Backup Agent — design (working name: `arc`)

> Status: **DRAFT for review.** Replaces the per-category bash suite on the mini
> (`infra/macos/mini/*-backup.sh`). Decision (2026-06-24): **Swift, macOS-native** app that
> backs up iCloud data to network storage, schedules it, verifies completion, and reports.
> Name `arc` is a placeholder.

## 1. Why this shape

The backups only run where the data lives — **a Mac** signed into iCloud. The only thing that
needs to be "networked" is the **destination** (the NAS), and that's just a mounted SMB/NFS path.
So the app is **Mac-native**, not cross-platform.

Going native (Swift + Apple frameworks instead of shelling to `osxphotos`/`vdirsyncer`/`sops`)
**removes the exact failures we fought** in the bash suite:

| Bash-suite pain | Native fix |
|---|---|
| iCloud CalDAV/CardDAV **rate-limiting** (the 31 h calendars outage) | **EventKit / Contacts** read the *local synced store*, not iCloud endpoints — no throttling |
| iCloud **app-specific password** + `sops`-PATH/env bugs | EventKit/Contacts/PhotoKit use the **logged-in account** — no password, no sops-for-DAV |
| `osxphotos` wedging / `--download-missing` flakiness | **PhotoKit** directly |
| `vdirsyncer` discover failures | gone (native) |
| FDA-on-`/bin/bash` hack, per-job env | **Per-app TCC** grants (Photos/Calendars/Contacts/Full-Disk) + one controlled process env |

What native does **not** change: there's no public API for **Notes / Safari / iCloud Drive**, so
those stay file/SQLite reads (native file I/O, no subprocess). And `rsync` stays the mirror
engine (below).

### Goals
- One **signed Swift binary** (packaged as a headless `.app` for stable TCC + signing), driven by
  a YAML config: which categories to back up, the destination, schedules, and how to be notified.
- **Native sources** where an API exists (PhotoKit, EventKit, Contacts); SQLite/file for the rest.
- Export to **standard, restorable formats** on the NAS (vCard `.vcf`, iCalendar `.ics`, photo
  originals + sidecars, `chat.db`, files) so the existing `s3-sync` ships them offsite unchanged.
- Uniform **guards** (refuse-empty, max-delete, integrity/verify, count-regression) and
  **observability** (Prometheus metrics + heartbeat + structured logs + `arc status`/`report`).
- Four notifiers, selectable per-job + globally: **Prometheus/Pushgateway, email (SES),
  phone push (ntfy/Pushover), webhook**.
- Runs **one-shot** (`arc run`) and as a **daemon** (`arc daemon`, in-process scheduler);
  `arc install` writes the launchd unit.
- "Redeploy" = copy the signed app + `arc.yaml` to another **Mac**, grant TCC, `arc install`.

### Non-goals (v1)
- Not a block-level/dedup engine — it orchestrates `rsync` mirrors + native exports, like today.
- Offsite shipping stays the existing `s3-sync` (reads the NAS). An `s3` destination is a clean
  later add.
- No restore UI (a guided `arc restore` is a v2 candidate — though native re-import via
  EventKit/Contacts is feasible later).

## 2. Concepts

- **Job** — one backup unit: a `source`, a `destination`, a `schedule`, `guards`, `notify`.
- **Source** — produces a verified tree/file to mirror. Native: `photos` (PhotoKit), `calendars`
  + `reminders` (EventKit), `contacts` (Contacts). File/DB: `messages`, `notes`, `safari`,
  `drive`, plus generic `dir` / `sqlite` / `command` for extensibility. Each declares the **TCC
  permission** it needs; the agent verifies/requests it and fails with a clear message if denied.
- **Destination** — `path` (a local or mounted SMB/NFS dir) in v1; `s3` later. Owns the guarded
  mirror + mount-readiness self-heal.
- **Notifier** — `prometheus | email | push | webhook`, fired `always | on-failure | on-change`.
- **Secret** — resolved from macOS **Keychain** (native) or **SOPS/age** (homelab standard) or env.
- **Run** — lock → check/req TCC + mount → produce source → guarded mirror → verify → record →
  notify → emit metrics.

## 3. Architecture (Swift)

Swift Package, built as a **headless `.app` bundle** (so it carries an `Info.plist` with TCC usage
strings + a stable code signature) whose executable is also the `arc` CLI.

```
Package.swift
Sources/arc/
  main.swift                 # CLI: run | daemon | validate | status | report | install | tcc
  Config/                    # YAML load + validate (Yams), defaults/inheritance, ${secret:…}
  Engine/                    # run loop: lock, prereq/TCC, produce, mirror, verify, notify, metrics
  Sources/                   # SourceProvider protocol + providers:
      PhotosSource.swift     #   PhotoKit  → originals + edited + XMP sidecars
      CalendarSource.swift   #   EventKit  → .ics per calendar (+ reminders/VTODO)
      ContactsSource.swift   #   Contacts  → .vcf (CNContactVCardSerialization)
      MessagesSource.swift   #   chat.db (GRDB) snapshot+integrity + Attachments/
      NotesSource.swift      #   NoteStore.sqlite snapshot+integrity + media
      SafariSource.swift     #   Bookmarks.plist
      DriveSource.swift      #   ~/Library/Mobile Documents/CloudDocs (+ .icloud stub count)
      DirSource / SqliteSource / CommandSource    # generic
  Mirror/                    # rsync-subprocess engine: parallel sharding (TaskGroup), --delete,
                             #   --max-delete, resume/retry, output parsing → counts/bytes
  Guard/                     # refuse-empty, max-delete, sqlite integrity, count-regression
  Dest/                      # Destination protocol + PathDest (mount probe/heal) ; S3Dest later
  Notify/                    # Notifier protocol + Prometheus, EmailSES, Push(ntfy/pushover), Webhook
  Secret/                    # Keychain, SOPS (Process), env
  Schedule/                  # HH:MM + cron parser; daemon scheduler; serialize NAS writers
  Platform/                  # TCC request/verify, mount readiness, launchd install, signing notes
  State/                     # run history (embedded SQLite via GRDB), last-success baselines, locks
```

Protocol sketch:
```swift
protocol SourceProvider {
    var requiredTCC: [TCCPermission] { get }          // .photos, .calendars, .contacts, .fullDisk
    func produce(into work: URL) async throws -> Staged   // native export OR verified file/dir
}
protocol Destination {
    func ensureReady() async throws                   // mount probe + self-heal
    func mirror(_ staged: Staged, guards: Guards) async throws -> MirrorResult  // counts + bytes
}
protocol Notifier { func send(_ run: RunResult) async throws }
```

### The mirror engine (why `rsync` stays)
`rsync` ships with macOS and is the proven, resumable, delta mirror. We **do not reimplement** it.
Swift orchestrates it with structured concurrency — equivalent to the old `xargs -P` sharding:
```swift
try await withThrowingTaskGroup(of: ShardResult.self) { group in
    for shard in topLevelShards {                     // e.g. 256 hashed Attachments dirs
        group.addTask { try await self.rsyncShard(shard, maxDelete: 200) }   // Process
    }
    // collect, retry failed/timed-out shards, enforce a concurrency cap (default 6)
}
```
Hard-won behaviors become typed config: **refuse-empty-source**, **`--max-delete` cap**,
**resume-on-SMB-drop with remount**, **rsync-stat mount probe** (background procs need FDA for net
vols), **count/coverage regression guard**. Small jobs (a single DB/plist) skip sharding.

## 4. Sources — native, per category

- **photos** — PhotoKit (`PHAsset`/`PHAssetResource`): export originals + edited renditions +
  an XMP/JSON sidecar (albums, keywords, faces, GPS, captions) → individual files. Replaces
  osxphotos; we control eviction/missing handling. Coverage = exported vs total (the 100%
  metric we already report).
- **calendars / reminders** — EventKit: enumerate `EKCalendar`s + `EKEvent`/`EKReminder`,
  serialize to `.ics` per collection (VEVENT/VTODO). Reads the local synced store → **no
  CalDAV throttling**.
- **contacts** — Contacts framework: `CNContactStore` → `CNContactVCardSerialization` → `.vcf`.
- **messages** — GRDB snapshot of `chat.db` (`.backup` + `PRAGMA integrity_check`) + mirror
  `Attachments/` (parallel sharded). Needs Full-Disk TCC.
- **notes** — `NoteStore.sqlite` snapshot/verify + `Accounts/` media (no public API).
- **safari** — `Bookmarks.plist`.
- **drive** — mirror CloudDocs; count `.icloud` evicted stubs for the report.
- Generic **dir / sqlite / command** for anything else (and an escape hatch, e.g. still calling
  osxphotos if ever needed).

All native exports write to a **local staging dir**, are **verified**, then the **Destination**
mirrors staging → NAS under guards (decouples the iCloud read from slow SMB — our staging lesson).

## 5. Destination & guards

- **PathDest**: a base dir on a mounted share. `ensureReady()` mounts if needed and probes
  readability via an **rsync-stat** (the FDA-safe net-vol probe); self-heals a stale mount
  (force-unmount + remount) before writing.
- **Guards** (per-job, with safe defaults): refuse to mirror an empty/again-missing source over
  good data; `--max-delete` cap (abort a mass-deletion → alert, don't shrink the backup); sqlite
  `integrity_check` must pass; optional count/coverage regression (don't overwrite a good backup
  with a smaller one — the "is the local cache complete?" check).

## 6. Notifications (all four)

Native HTTP via `URLSession` (+ SMTP for email). Per-channel `on_success|on_failure|on_change`:
- **prometheus** — push `<job>_{last_rc,items,bytes,duration_seconds,last_run/ success_ts}` +
  `arc_health_*` heartbeat to Pushgateway. **Drop-in compatible** with the current dashboard/alerts.
- **email (SES)** — per-run failure mail and/or a **daily digest** (`arc report`): one HTML table,
  all jobs, all green — the consolidated tracking you wanted. SES via SMTP or the SES API.
- **push (ntfy / Pushover)** — short failure (optional success) push to your phone, cluster-independent.
- **webhook** — JSON POST of the run result to Slack/Discord/any endpoint.

## 7. Scheduling & runtime

- `arc run [job…] [--due]` — one-shot. For launchd/cron or manual.
- `arc daemon` — long-running; in-process scheduler (HH:MM + cron), **serializes NAS-writing jobs**
  (kills the contention failure mode), runs the health heartbeat on its own tick.
- `arc install [--daemon|--per-job]` — writes + loads the launchd unit(s). Default on the mini:
  one daemon LaunchAgent.
- `arc status` / `arc report` — local rollup (last run/result/age/items/size per job) for
  `ssh mini && arc status`, and the emailed digest.

## 8. TCC, entitlements, signing (the new must-dos)

- The app requests, with `Info.plist` usage strings: `NSPhotoLibraryUsageDescription`,
  `NSCalendarsFullAccessUsageDescription`, `NSRemindersFullAccessUsageDescription`,
  `NSContactsUsageDescription`, plus **Full Disk Access** (Messages/Notes/Drive + net volumes).
  `arc tcc` prints current grant status and triggers the prompts; denials fail loudly (no silent
  empty backup) — same principle as today, but granular per-permission.
- **Code signing**: sign with a stable identity (Developer ID if available, else a persistent
  ad-hoc cert) so TCC grants survive rebuilds. The `.app` bundle gives a stable code identity.
- Runs as a **LaunchAgent** in the user's GUI session (TCC prompts/grants attach to the app).

## 9. Secrets

- macOS **Keychain** (native, e.g. SES SMTP password) as the default, **or** **SOPS/age** to reuse
  the homelab bundle. `${secret:name}` in config resolves via the configured resolver. Native
  iCloud sources need **no** secret (logged-in account) — a big reduction in secret surface.

## 10. Config (YAML) — example

```yaml
agent:
  instance: mini
  staging_dir: ~/.local/state/arc/staging
  state_dir:   ~/.local/state/arc
defaults:
  destination: { type: path, base: /Volumes/Backups/Graham/iCloud,
                 mount: { kind: smb, probe: rsync }, guards: { refuse_empty: true, max_delete: 500 } }
  notify: { on_failure: [prometheus, email, push], on_success: [prometheus] }
notifiers:
  prometheus: { pushgateway: https://pushgateway.wind.etherport.net }
  email: { type: ses, smtp: { host: email-smtp.us-west-2.amazonaws.com, port: 587,
           user: "${secret:ses_user}", password: "${secret:ses_smtp_password}" },
           from: backups@wind.etherport.net, to: [4unsaved_candies@icloud.com], digest: "06:00" }
  push:  { type: ntfy, url: "${secret:ntfy_url}" }
  webhook: { type: generic, url: "${secret:backup_webhook_url}" }
secrets:
  default_resolver: keychain          # or: sops
jobs:
  - { name: photos,    source: { type: photos },                 destination: { dir: Photos },    schedule: "22:00" }
  - { name: messages,  source: { type: messages },               destination: { dir: Messages, parallel: 6 }, schedule: "20:00", notify: { on_success: [prometheus, push] } }
  - { name: calendars, source: { type: calendars, reminders: true }, destination: { dir: Calendars }, schedule: "21:00" }
  - { name: contacts,  source: { type: contacts },               destination: { dir: Contacts },  schedule: "21:00" }
  - { name: notes,     source: { type: notes },                  destination: { dir: Notes },     schedule: "19:30" }
  - { name: safari,    source: { type: safari },                 destination: { dir: Safari },    schedule: "19:30" }
  - { name: drive,     source: { type: drive },                  destination: { dir: Drive },     schedule: "19:30" }
```

## 11. Packaging, CI, repo

- Builds on a **macOS GitHub Actions runner** → signed `.app` + a tarball; pinned release.
- Lives at **`tools/arc/`** in this monorepo (keeps it with secrets/docs/CI), unless you'd prefer a
  dedicated repo.
- Redeploy: copy the signed app + `arc.yaml`, run `arc tcc` (grant prompts) + `arc install`.

## 12. Migration (incremental, reversible)

Build → run `arc` in parallel on the mini writing to a **staging** dest → diff against the bash
output per category → cut categories over one at a time, retiring each bash LaunchAgent only after
`arc` proves it. The bash suite + its dashboards stay until parity. Metrics are kept drop-in
compatible so the existing Grafana panels/alerts keep working through the cutover.

## 13. Build milestones

1. Skeleton + config + `dir` source + PathDest + Prometheus notifier + `arc run` (proves drive/safari).
2. Mirror engine: rsync sharding + guards + mount self-heal + state/locks (messages-attachments class).
3. Native sources: contacts (Contacts), calendars/reminders (EventKit), messages/notes (SQLite).
4. photos (PhotoKit) + coverage metric.
5. Notifiers: email/push/webhook + `arc report` digest + `arc_health` heartbeat + TCC/signing.
6. `daemon` + scheduler + `install` + `status`; CI signed release; cut over + retire bash.

## 14. Open questions
- Name (`arc`? something Mac-ier?).
- Phone push: self-hosted **ntfy** vs **Pushover** (paid, dead-simple).
- Secrets default: **Keychain** (most native) vs **SOPS** (homelab consistency) — can support both.
- Photos export depth: originals only vs originals+edited+sidecars (parity with current osxphotos output).
- `.app` bundle headless-via-launchd vs a optional menu-bar status UI (nice-to-have, later).
