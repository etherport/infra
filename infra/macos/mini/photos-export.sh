#!/bin/bash
# M79 — export the iCloud Photos library to individual files (+ XMP sidecars) on the
# NAS, where the existing aws-s3-sync "backups" share ships them offsite to S3.
#
# PIPELINE (why each step):
#   1. mount-nas.sh        — ensure /Volumes/Personal-Drive (hosts the library
#                            sparsebundle) and /Volumes/Backups (export target) are
#                            mounted. Self-heals a dropped mount.
#   2. hdiutil attach      — attach the APFS sparsebundle so macOS sees the Photos
#                            library as a local volume (/Volumes/PhotosLib). Photos
#                            cannot read a library that lives only as a .sparsebundle.
#   3. osxphotos export    — export originals + edited + XMP sidecars (albums,
#                            keywords, faces, GPS, captions) as INDIVIDUAL files to
#                            /Volumes/Backups/Graham/iCloud/Photos. --update makes it
#                            incremental; --cleanup mirrors library deletions.
#
# OFFSITE: the k8s `s3-sync-backups` CronJob (1:00 AM PT) reads /var/nfs/shared/Backups
# over NFS and syncs it to s3://archive.wind.etherport.net (Glacier Deep Archive). The
# export target is a subtree of that share, so photos ride that existing pipeline — no
# dedicated bucket/share. So schedule this BEFORE 01:00 so each night's export ships same-day.
#
# The sparsebundle itself (the working library) is NOT in the export dir, so it is
# never uploaded — only the exported files are.
#
# OWNER PREREQUISITE (one-time, interactive via VNC): attach the sparsebundle, create
# a Photos library *inside* it, sign into iCloud, and "Download Originals" (long pole,
# can take days). Until a *.photoslibrary exists in the attached volume, this script
# exits 0 with a clear "not ready" message (no false launchd failures). See README.md.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- config ---
SPARSEBUNDLE="/Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle"
ATTACH_VOL="/Volumes/PhotosLib"                       # APFS volname from create-photos-sparsebundle.sh
DEST="/Volumes/Backups/Graham/iCloud/Photos"          # export target (on the NFS-exported Backups share)
OSXPHOTOS="${HOME}/.local/bin/osxphotos"              # pipx install location
REPORT_DIR="${HOME}/Library/Logs/photos-export"
# Export DB on LOCAL disk (not in DEST on SMB): osxphotos writes it as the final step of
# every run, and on the blip-prone SMB share that write fails (interrupted by reconnects)
# → rc=1, no clean completion. Local + --ramdb makes it reliable; only photo files go over
# SMB. Rebuildable ledger, so keeping it off the NAS/S3 is fine. (M79, 2026-06-19.)
EXPORTDB="${EXPORTDB:-${HOME}/Library/Application Support/osxphotos/graham-icloud-photos.db}"

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') photos-export: $*"; }

# --- 1. ensure NAS mounts ---
log "preflight: ensuring NAS mounts"
"${HERE}/mount-nas.sh" || { log "✗ NAS mount failed; aborting"; exit 1; }

# --- 2. attach the library sparsebundle (idempotent) ---
if [ ! -e "${SPARSEBUNDLE}" ]; then
  log "✗ sparsebundle missing at ${SPARSEBUNDLE}. Run create-photos-sparsebundle.sh."
  exit 1
fi
if [ ! -d "${ATTACH_VOL}" ]; then
  log "attaching ${SPARSEBUNDLE}"
  hdiutil attach "${SPARSEBUNDLE}" -mountpoint "${ATTACH_VOL}" || {
    log "✗ hdiutil attach failed"; exit 1; }
else
  log "✓ sparsebundle already attached at ${ATTACH_VOL}"
fi

# --- locate the Photos library inside the attached volume ---
LIBRARY="$(/bin/ls -d "${ATTACH_VOL}"/*.photoslibrary 2>/dev/null | head -1)"
if [ -z "${LIBRARY}" ]; then
  log "⏳ no *.photoslibrary in ${ATTACH_VOL} yet — owner setup incomplete."
  log "   (Create a library inside the attached volume + Download Originals; see README.md.)"
  exit 0   # not an error: nothing to export until the owner finishes one-time setup
fi
log "library: ${LIBRARY}"

# --- 3. export ---
mkdir -p "${DEST}" "${REPORT_DIR}" "$(dirname "${EXPORTDB}")"
REPORT="${REPORT_DIR}/export-$(date '+%Y%m%d-%H%M%S').csv"

# Restart the Photos daemon stack first. --download-missing --use-photokit drives PhotoKit
# via photolibraryd, which WEDGES (CoreData XPC dies, 0 downloads) once it's been running a
# while against the SMB-backed library. A fresh daemon is what lets downloads work (M79
# 2026-06-20). Harmless when there's nothing to download (daemons just relaunch on demand).
osascript -e 'tell application "Photos" to quit' >/dev/null 2>&1; sleep 2
pkill -9 -f 'Photos.app/Contents/MacOS/Photos' >/dev/null 2>&1
killall -9 photolibraryd photoanalysisd >/dev/null 2>&1; sleep 3
open -ga Photos >/dev/null 2>&1 || true

log "exporting → ${DEST} (report: ${REPORT})"
# --update            : incremental — only new/changed photos (tracked in
#                       <DEST>/.osxphotos_export.db, so nothing re-exports)
# --download-missing  : if an original isn't local in the library yet, have Photos
#                       fetch it on demand AT EXPORT TIME, rather than depending on
#                       iCloud's flaky background "Download Originals" queue (which
#                       stalls on this headless mini even with Photos open). Once
#                       fetched, the original stays in the library (we're on
#                       "Download Originals to this Mac", so macOS never re-evicts
#                       it) → it's a one-time download per photo, not per run.
# --use-photokit      : drive the download via PhotoKit (more reliable than the
#                       default AppleScript path). REQUIRES one-time TCC grants —
#                       see README "M79 → --download-missing permissions".
# --sidecar XMP       : albums/keywords/persons/GPS/captions as sidecars
# --cleanup           : delete files in DEST no longer in the library (mirror)
# --retry             : retry transient export errors
# (edited photos export BOTH original and an _edited copy by osxphotos default)
"${OSXPHOTOS}" export "${DEST}" \
  --library "${LIBRARY}" \
  --update \
  --exportdb "${EXPORTDB}" \
  --ramdb \
  --download-missing \
  --use-photokit \
  --sidecar XMP \
  --cleanup \
  --retry 3 \
  --report "${REPORT}"
rc=$?

if [ "${rc}" -eq 0 ]; then
  log "✓ export complete"
else
  log "✗ export exited rc=${rc} (see ${REPORT})"
fi
exit "${rc}"
