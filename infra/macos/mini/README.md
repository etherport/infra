# mini macOS automation

Mac-native automation that runs **on the Mac mini** (`graham@`, the headless ops
host) — things that can't live in k8s/Flux because they need macOS APIs (Photos,
SMB/keychain, `launchd`, tmux). Version-controlled here; installed into the user's
`~/Library/LaunchAgents` on the mini.

## `net.wind.mount-nas` — keep `/Volumes/Personal-Drive` mounted across logins

Ensures the NAS **`Personal-Drive`** share is mounted at **`/Volumes/Personal-Drive`**
whenever the login session starts. Backs the iCloud **Photos** backup (M79): the
Photos library lives in an APFS sparsebundle at `/Volumes/Personal-Drive/Photos/`.

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
mount | grep -F ' on /Volumes/Personal-Drive '
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

## Coming next (M79)
- `osxphotos` export script + its `launchd` timer: sparsebundle attach (at
  `/Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle`) → export originals
  + XMP sidecars to `/Volumes/Personal-Drive/Photos/export/` → new S3-sync share
  (Glacier Instant Retrieval). Preflight calls `mount-nas.sh` first. Tracked as
  M79 in `docs/planning/outstanding-work.md`.
