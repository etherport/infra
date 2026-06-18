#!/bin/bash
# Mount the NAS "Personal-Drive" SMB share at ~/NAS on the mini.
#
# Runs as the `graham` user via the net.wind.mount-nas LaunchAgent (fires when
# the Aqua/login session starts — i.e. at auto-login). Idempotent + retries
# while the network/NAS comes up. The SMB password is resolved NON-interactively
# from the login keychain (the entry Finder created when you connected with
# "Remember this password in my keychain"), so nothing secret lives in this repo.
#
# Part of the iCloud Photos backup pipeline (M79): the Photos library lives in
# an APFS sparsebundle under ~/NAS/Photos/. The osxphotos export job re-runs this
# (idempotently) in its preflight, so a dropped mount self-heals. See README.md.
set -uo pipefail

SERVER="sequoia.wind.etherport.net"
SHARE="Personal-Drive"
SMB_USER="graham"
MOUNTPOINT="${HOME}/NAS"
RETRIES=12          # ~1 min of attempts per launchd invocation
SLEEP_SECS=5

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') mount-nas: $*"; }

mkdir -p "$MOUNTPOINT"

# Already mounted? (macOS `mount` prints "...//graham@server/Share on /Users/grahamsmith/NAS (smbfs...")
if /sbin/mount | grep -qF " on ${MOUNTPOINT} "; then
  log "already mounted at ${MOUNTPOINT}; nothing to do"
  exit 0
fi

i=0
while [ "$i" -lt "$RETRIES" ]; do
  i=$((i + 1))
  # //user@server/share — mount_smbfs pulls the password from the login keychain.
  if out=$(/sbin/mount_smbfs "//${SMB_USER}@${SERVER}/${SHARE}" "$MOUNTPOINT" 2>&1); then
    log "mounted //${SERVER}/${SHARE} at ${MOUNTPOINT} (attempt ${i})"
    exit 0
  fi
  log "attempt ${i}/${RETRIES} failed (${out}); retrying in ${SLEEP_SECS}s — network/NAS may not be up yet"
  sleep "$SLEEP_SECS"
done

log "ERROR: could not mount //${SERVER}/${SHARE} after ${RETRIES} attempts"
exit 1
