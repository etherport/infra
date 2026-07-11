#!/bin/bash
# Ensure the NAS SMB shares needed by the iCloud backup pipeline are mounted at
# their standard /Volumes/<share> paths. Idempotent — safe to re-run any time.
#
#   /Volumes/Personal-Drive  — holds the Photos library APFS sparsebundle (M79)
#   /Volumes/Backups         — export target; the k8s aws-s3-sync "backups" share
#                              reads this same NAS share over NFS and ships it to S3
#
# Uses `open smb://` (what Finder does) rather than `mount_smbfs` to a custom path:
# macOS auto-mounts SMB shares under /Volumes/<share>, and mounting the same share
# again at a different path fails with "File exists" (EEXIST). The password is
# resolved non-interactively from the login keychain (nothing secret committed).
#
# The osxphotos export job re-runs this in its preflight, so a dropped mount
# self-heals. See README.md.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="sequoia.wind.etherport.net"
SMB_USER="graham"
SHARES=(Personal-Drive Backups)
# The Photos library sparsebundle lives on Personal-Drive; attach it after mounting so
# /Volumes/PhotosLib is present at login (without this, Photos/osxphotos can't find the
# library after a reboot — the "PhotosLib cannot be found" failure, 2026-06-19).
SPARSEBUNDLE="/Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle"
ATTACH_VOL="/Volumes/PhotosLib"

# shellcheck source=mini-common.sh
source "${HERE}/mini-common.sh"   # mini_run_timeout (bounded liveness probe)

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') mount-nas: $*"; }

# A share is "ready" only if it's mounted AND its contents are readable. A stale SMB mount
# (server dropped during idle) still shows in `mount` but hangs/EPERMs on I/O. nas_readable
# probes via rsync (the FDA-granted binary) so this is accurate under launchd too — `ls` here
# would EPERM on the network volume from a background context even when the mount is healthy
# (background procs need Full Disk Access for net vols), causing false force-remounts.
nas_share_ready(){ mount | grep -qF " on $1 " && nas_readable "$1"; }

# SMB-hardening config check. The KERNEL SMB client (which `open smb://` drives) reads
# /etc/nsmb.conf — NOT ~/Library/Preferences/nsmb.conf. The old code wrote the user file, so
# the tuning (notify_off/mc_on/SMB2-3-only) was a SILENT NO-OP (adversarial review C-3). /etc
# needs root, so it's installed by the net.wind.nsmb-install LaunchDaemon (install-nsmb-conf.sh).
# Here we can't sudo — so we DETECT and warn loudly if /etc/nsmb.conf is missing or stale, so
# the gap is visible instead of silently un-applied. See README "SMB tuning (/etc/nsmb.conf)".
if [ -f "${HERE}/nsmb.conf" ]; then
  if ! cmp -s "${HERE}/nsmb.conf" /etc/nsmb.conf 2>/dev/null; then
    log "⚠ /etc/nsmb.conf is MISSING or STALE — SMB tuning is NOT applied to kernel mounts."
    log "⚠ Install the LaunchDaemon (one-time sudo): see infra/macos/mini/README.md → SMB tuning."
  else
    log "✓ /etc/nsmb.conf current"
  fi
fi

# Reachability + AUTH pre-check (2026-07-09). This script now runs periodically (net.wind.mount-nas
# StartInterval) so a mid-session SMB drop self-heals within minutes instead of persisting until the
# next login (the 2026-07-03→09 outage: mount dropped, the login-only agent never re-ran, backups
# were down 6 days). But `open smb://` on a REJECTED credential pops a NetAuth GUI prompt that hangs
# forever headless and piles up stuck NetAuthAgent processes. So before touching `open`, probe auth
# cheaply with `smbutil` (keychain-based, no GUI): if the SERVER rejects auth, log it distinctly and
# BAIL — don't spam prompts. This turns a silent 6-day outage into a precise, self-clearing signal
# (mini-health reads mount_nas rc; the moment the NAS SMB auth is restored, the next tick mounts).
smb_reachable(){ nc -z -G3 "${SERVER}" 445 >/dev/null 2>&1; }
# true=auth ok, 1=auth REJECTED (server up, creds refused), 2=unreachable/other
smb_auth_state(){
  smb_reachable || return 2
  local out; out="$(mini_run_timeout 15 smbutil view "//${SMB_USER}@${SERVER}" 2>&1)"
  case "$out" in
    *"rejected the authentication"*|*"Authentication error"*) return 1 ;;
    *) return 0 ;;   # listed shares (or a benign non-auth error) → creds accepted
  esac
}

# Stale-mount cleanup MUST precede the auth probe (2026-07-11 incident). A dead kernel SMB
# session — held alive by mounted-but-unresponsive shares (e.g. after a NAS wedge/reboot) —
# poisons smbutil, which then reports "Authentication error" WITHOUT a single session-setup
# reaching the NAS (verified server-side at smbd debug3: TCP connects, zero auth attempts).
# The old order (auth gate first) therefore DEADLOCKED: the gate bailed on the phantom
# rejection every tick, and the force-unmount that would have cleared the wedge sat
# unreachable below it. Unmount stale shares FIRST so the probe runs on a fresh session;
# a rejection AFTER this cleanup is then genuinely server-side (NAS SMB / credential).
for share in "${SHARES[@]}"; do
  vol="/Volumes/${share}"
  if mount | grep -qF " on ${vol} " && ! nas_share_ready "${vol}"; then
    log "⚠ ${share}: mounted but UNRESPONSIVE (stale) — force-unmounting BEFORE the auth probe"
    [ "${share}" = "Personal-Drive" ] && hdiutil detach -force "${ATTACH_VOL}" >/dev/null 2>&1
    diskutil unmount force "${vol}" >/dev/null 2>&1 || true
  fi
done

smb_auth_state; auth=$?
if [ "$auth" = 2 ]; then
  log "✗ ${SERVER} unreachable on 445 (NAS down / network) — not attempting mounts"
  exit 1
elif [ "$auth" = 1 ]; then
  log "✗ ${SERVER} SMB AUTH REJECTED for ${SMB_USER} (port 445 open, creds refused, and stale mounts"
  log "  were already cleared this tick — so this is a REAL server-side rejection). Fix NAS-side (restart the UNAS"
  log "  SMB service / reboot the UNAS) or re-save the keychain password; do NOT retry \`open\` (it"
  log "  spawns headless NetAuth prompts). Skipping mount attempts this tick."
  exit 1
fi

rc=0
for share in "${SHARES[@]}"; do
  vol="/Volumes/${share}"
  if nas_share_ready "${vol}"; then
    log "✓ ${share}: already mounted + responsive at ${vol}"
    continue
  fi
  # Listed but unresponsive (stale) → force-unmount so the mount below re-establishes it. If it's
  # Personal-Drive, detach the sparsebundle first (PhotosLib is backed by a file on it).
  if mount | grep -qF " on ${vol} "; then
    log "⚠ ${share}: mounted but UNRESPONSIVE (stale) — force-remounting"
    [ "${share}" = "Personal-Drive" ] && hdiutil detach -force "${ATTACH_VOL}" >/dev/null 2>&1
    diskutil unmount force "${vol}" >/dev/null 2>&1 || true
  fi

  log "mounting ${share} via open smb://${SERVER}/${share}"
  open "smb://${SMB_USER}@${SERVER}/${share}"

  mounted=false
  for i in $(seq 1 20); do            # `open` is async — poll ~40s
    sleep 2
    if nas_share_ready "${vol}"; then
      log "▶ ${share}: mounted + responsive at ${vol} (after $((i * 2))s)"
      mounted=true
      break
    fi
  done
  if [ "$mounted" = false ]; then
    log "✗ ${share}: NOT mounted after ~40s (NAS down? keychain entry missing?)"
    rc=1
  fi
done

# Attach the Photos library sparsebundle (idempotent) so /Volumes/PhotosLib exists.
if [ -d "${ATTACH_VOL}" ]; then
  log "✓ sparsebundle already attached at ${ATTACH_VOL}"
elif [ -e "${SPARSEBUNDLE}" ]; then
  if hdiutil attach "${SPARSEBUNDLE}" -mountpoint "${ATTACH_VOL}" >/dev/null 2>&1; then
    log "▶ attached sparsebundle at ${ATTACH_VOL}"
  else
    log "✗ failed to attach sparsebundle ${SPARSEBUNDLE}"; rc=1
  fi
else
  log "… sparsebundle not present at ${SPARSEBUNDLE} (owner setup incomplete?) — skipping attach"
fi

# Post-mount verify (informational): signing still active is a tell that /etc/nsmb.conf tuning
# isn't in play (kernel on defaults). Closes the "trusted the copy, never checked" gap (C-3).
if command -v smbutil >/dev/null 2>&1 && mount | grep -qF " on /Volumes/Backups "; then
  sign="$(smbutil statshares -a 2>/dev/null | awk '/SMB_CURR_SIGN_ALGORITHM/{print $2; exit}')"
  [ -n "${sign}" ] && [ "${sign}" != "OFF" ] && \
    log "ℹ SMB signing active (${sign}) — expected if the NAS requires it; if not, consider the signing lever in nsmb.conf"
fi

exit "$rc"
