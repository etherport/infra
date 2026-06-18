# mini macOS automation

Mac-native automation that runs **on the Mac mini** (`graham@`, the headless ops
host) — things that can't live in k8s/Flux because they need macOS APIs (Photos,
SMB/keychain, `launchd`). Version-controlled here; installed into the user's
`~/Library/LaunchAgents` on the mini.

## `net.wind.mount-nas` — persistent SMB mount of the NAS at `~/NAS`

Mounts `//graham@sequoia.wind.etherport.net/Personal-Drive` at
`/Users/grahamsmith/NAS` whenever the login session starts. Backs the iCloud
**Photos** backup (M79): the Photos library lives in an APFS sparsebundle under
`~/NAS/Photos/`.

**Why a LaunchAgent (user), not a LaunchDaemon (root):**
- The mount point is in the home dir and the consumers (Photos.app, `osxphotos`)
  run as `graham` → mounting **as the user** gives correct ownership (a root
  daemon mount causes permission friction for user processes).
- A LaunchAgent runs in the login session, so it can use the **login keychain**
  password (the one Finder saved) — no need to copy it to the System keychain.
- Photos/`osxphotos` need a GUI (Aqua) session anyway → **auto-login must be on**
  → "at login" effectively means "at boot."

`mount_smbfs` resolves the password **non-interactively from the login keychain**,
so no secret is committed here.

### Install (run on the mini, as graham)

```bash
# 1. Ensure the SMB password is in the login keychain: connect once in Finder
#    (Go → Connect to Server → smb://sequoia.wind.etherport.net/Personal-Drive),
#    tick "Remember this password in my keychain", then disconnect.
#    (mount-nas.sh relies on that keychain entry.)

# 2. Symlink the plist into LaunchAgents (symlink so `git pull` keeps it current):
ln -sf /Users/grahamsmith/code/infra/infra/macos/mini/net.wind.mount-nas.plist \
       ~/Library/LaunchAgents/net.wind.mount-nas.plist

# 3. Load it (modern launchctl):
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/net.wind.mount-nas.plist
#   (reload after edits: launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/net.wind.mount-nas.plist && bootstrap again)

# 4. Verify:
launchctl print gui/$(id -u)/net.wind.mount-nas | grep -E 'state|last exit'
mount | grep -F ' on /Users/grahamsmith/NAS '
tail -n 20 ~/Library/Logs/mount-nas.log
```

### Prerequisites / caveats
- **Auto-login** must be enabled (System Settings → Users & Groups → auto-login),
  or the agent won't fire until someone logs in via Screen Sharing.
- **FileVault** is ON: after a real reboot/power-loss the mini sits at the
  FileVault unlock screen and **nothing auto-starts** (auto-login, this agent, the
  osxphotos timer) until that unlock is entered. Not specific to this mount — it
  gates the whole headless pipeline.
- The agent mounts **at login and retries until success, then stops**. If the NAS
  later reboots and the mount drops, the **osxphotos export job's preflight**
  remounts it (idempotent — it re-runs this same script), so the backup self-heals
  without the agent needing to poll.
- Path assumption: the plist points at the repo checkout at
  `/Users/grahamsmith/code/infra`. Update `ProgramArguments` if that moves.

## Coming next (M79)
- `osxphotos` export script + its `launchd` timer (sparsebundle attach → export
  originals + XMP sidecars to `~/NAS/Photos/export/` → existing S3 sync). Tracked
  in `docs/planning/outstanding-work.md` (M79).
