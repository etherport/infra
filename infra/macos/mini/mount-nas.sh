#!/bin/bash
# Ensure the NAS "Personal-Drive" SMB share is mounted at /Volumes/Personal-Drive
# (the standard macOS path — same as a Finder "Connect to Server"). Idempotent.
#
# Uses `open smb://` rather than `mount_smbfs` to a custom path: macOS auto-mounts
# SMB shares under /Volumes/<share>, and mounting the *same* share a second time at
# a different path fails with "File exists" (EEXIST). `open` mounts to the standard
# /Volumes path the system already uses, so it never conflicts. The password is
# resolved non-interactively from the login keychain (nothing secret committed).
#
# Part of the iCloud Photos backup pipeline (M79): the Photos library lives in an
# APFS sparsebundle at /Volumes/Personal-Drive/Photos/. The osxphotos export job
# re-runs this in its preflight, so a dropped mount self-heals. See README.md.
set -uo pipefail

VOL="/Volumes/Personal-Drive"
URL="smb://graham@sequoia.wind.etherport.net/Personal-Drive"

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') mount-nas: $*"; }

if mount | grep -qF " on ${VOL} "; then
  log "already mounted at ${VOL}; nothing to do"
  exit 0
fi

log "mounting ${URL} via open (keychain password)"
open "$URL"

# `open` is async — poll for the volume to appear (~40s).
for i in $(seq 1 20); do
  sleep 2
  if mount | grep -qF " on ${VOL} "; then
    log "mounted at ${VOL} (after $((i * 2))s)"
    exit 0
  fi
done

log "ERROR: ${VOL} not mounted after ~40s (NAS down? keychain entry missing?)"
exit 1
