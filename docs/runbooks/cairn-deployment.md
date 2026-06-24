# Deploying `cairn` on the Mac mini

`cairn` is the native macOS iCloud → NAS backup agent that replaces the bash backup suite
(`infra/macos/mini/*.sh`). **Design + code live in its own repo** —
[`sparked-diamond/cairn`](https://github.com/sparked-diamond/cairn) (cloned at `~/code/cairn`);
see [`cairn/DESIGN.md`](https://github.com/sparked-diamond/cairn/blob/main/DESIGN.md). This runbook
is infra's part only: **how cairn is built, signed, permissioned, scheduled, and monitored on the
mini**, and how to cut over from the bash suite. Tracker: M103 in
[`../planning/outstanding-work.md`](../planning/outstanding-work.md).

> Why a separate app: the bash suite's failure classes were CardDAV/CalDAV rate-limiting,
> app-password/sops-in-launchd env bugs, and per-script drift. cairn uses native frameworks
> (Contacts) + osxphotos + consistent SQLite snapshots, **no secrets** (reporting is
> Pushgateway-only; Alertmanager routes), and one consistent, supervised, self-healing engine.

## 1. Architecture on the mini (what cairn drives)

- **Sources:** `contacts` (Contacts framework → vCards), `notes`/`calendars`/`reminders`
  (`store`: consistent `sqlite3 .backup` + companion mirror, auto-discovers the SQLite),
  `messages` (in-place chat.db snapshot + ~48 GB Attachments), `photos` (osxphotos wrapper,
  in-place), `drive` (plain dir mirror).
- **Photos is network-backed (the fragile bit):** the library lives on a **sparsebundle on the NAS**
  (`/Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle`) attached as APFS `/Volumes/PhotosLib`;
  the export target `/Volumes/Backups/Graham/iCloud/Photos` is SMB too. cairn **health-gates + self-heals
  the whole SMB→sparsebundle→APFS stack** before each run, runs osxphotos **supervised** (hard timeout +
  stall-watchdog + process-group kill), and **resumes via `--update`**. It **quits Photos.app before every
  run** to avoid the contention that produced Photos' "library could not be opened (-1)" dialogs.
- **Offsite:** unchanged — the export dirs sit under the `Backups` share, which the k8s
  `s3-sync-backups` CronJob ships to `s3://archive.wind.etherport.net` (Glacier Deep Archive). cairn
  writes the **same layout** as the bash suite → **no S3 re-upload churn** on cutover.

## 2. Build + sign (on the mini — has full Xcode)

```bash
cd ~/code/cairn
swift test                 # must be green
scripts/package.sh         # builds release + assembles + SIGNS dist/cairn.app
```
`package.sh` signs with the self-signed **`cairn-codesign`** identity in the login Keychain (see the
cairn README "Code signing" for one-time cert creation). **A stable signature is essential** — TCC
grants are keyed to it, so an ad-hoc/changing signature resets permissions on every rebuild.

## 3. Grant privacy permissions (TCC) — one-time, from a VNC GUI session

cairn's sources read TCC-protected data, keyed to `cairn.app`'s signature. **Run from the VNC
Terminal** (prompts can't display headlessly):

```bash
dist/cairn.app/Contents/MacOS/cairn tcc            # report current status
dist/cairn.app/Contents/MacOS/cairn tcc --request  # prompt for Contacts/Calendars/Reminders/Photos
```
- **Contacts / Calendars / Reminders / Photos** → approve the prompts.
- **Full Disk Access** (needed for messages, notes, calendars, reminders stores) has **no request
  API** — add `cairn.app` manually: System Settings → Privacy & Security → Full Disk Access. `cairn
  tcc` prints the deep-link and re-probes after.

## 4. Configure

Copy the example and edit (no secrets — SMB creds come from the Keychain):
```bash
mkdir -p ~/.config/cairn && cp ~/code/cairn/examples/cairn.example.yaml ~/.config/cairn/cairn.yaml
~/code/cairn/dist/cairn.app/Contents/MacOS/cairn validate
```
The example already encodes the mini's real photos stack (SMB shares + sparsebundle) and schedules.

## 5. Schedule (launchd)

```bash
dist/cairn.app/Contents/MacOS/cairn install --bin "$PWD/dist/cairn.app/Contents/MacOS/cairn"
```
Generates + loads two LaunchAgents in `~/Library/LaunchAgents/`:
- **`net.wind.cairn`** — fires `cairn run --due` at each distinct `schedule:` time (launchd owns the
  schedule; survives reboot). `--due` runs only jobs whose time has passed today and that haven't
  already run today → idempotent + self-catching-up after sleep.
- **`net.wind.cairn.health`** — `cairn health` every 900 s (pushes the heartbeat).

`--dry-run` prints the plists without loading. Logs: `~/Library/Logs/cairn/`.

## 6. Monitor

`cairn` pushes drop-in-compatible metrics to Pushgateway. Per job: `<job>_last_run_timestamp_seconds`,
`_last_rc`, `_last_success_timestamp_seconds`, `_items`, `_bytes`, plus source-specific gauges
(`photos_missing`, `photos_exported`, `photos_stalled`, …). Agent liveness rollup (job
`cairn_health`): `cairn_up`, `cairn_heartbeat_timestamp_seconds`, `cairn_jobs_total/ok/failing/
missing`, `cairn_healthy`, `cairn_oldest_success_age_seconds`. Alert on a stale heartbeat or
`cairn_jobs_failing > 0` (Alertmanager → existing routes). `cairn status` prints a local table.

## 7. Cutover from the bash suite (incremental, reversible)

Per category, one at a time: point cairn at a **staging dest**, run, **diff against the bash output**
(same layout → should match), then flip the schedule to the real dest and **disable the matching bash
LaunchAgent** (`launchctl unload`). Keep the bash script in git until parity is confirmed for all
categories. Photos last (longest seed). Reverse = unload cairn's agents + re-enable the bash ones.

## 8. Gotchas (mini-specific)

- **Never keep Photos.app open on the `(NAS)` library** — it's a sparsebundle on SMB; an interactive
  Photos session is exposed to every network hiccup → `(-1)` / "must quit" dialogs. Let cairn own it
  (it quits Photos first). This is *why* the seed is moving to cairn.
- **osxphotos export DB stays on LOCAL disk** (cairn defaults `~/Library/Application Support/osxphotos/
  cairn-photos.db`) — writing it on the SMB dest fails on reconnects. Don't move it to the NAS.
- **`--cleanup` is off by default** — enumerating ~45k files over SMB wedges; deletions don't mirror
  (a backup that only grows is safe). Turn on only deliberately.
- **15 GB free on the mini** — photos/messages are **in-place** (never stage the 448 GB / 48 GB);
  don't add staged variants for them.
- SMB creds live in the login Keychain (`graham@sequoia…`); `cairn` remounts headlessly with them.
