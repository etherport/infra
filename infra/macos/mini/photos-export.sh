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
# → rc=1, no clean completion. LOCAL DB makes that write reliable; only photo files go over
# SMB. Rebuildable ledger, so keeping it off the NAS/S3 is fine. (M79, 2026-06-19.) NOTE: do
# NOT add --ramdb — with the DB local it's unnecessary, and it only persists on a *clean*
# finish, so a watchdog-killed run loses its record of what it exported (dup/cleanup risk).
EXPORTDB="${EXPORTDB:-${HOME}/Library/Application Support/osxphotos/graham-icloud-photos.db}"

# shellcheck source=photos-metrics.sh
source "${HERE}/photos-metrics.sh"   # provides push_photos_metrics (non-fatal)
START="$(date +%s)"

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') photos-export: $*"; }

# Default = robust LOCAL export (no Photos.app/PhotoKit) — exports whatever originals are
# already downloaded, dedup-safe via the persistent --exportdb. Set DOWNLOAD_MISSING=1 for a
# *supervised* pass that fetches not-yet-local originals via PhotoKit (fragile: needs TCC,
# wedges photolibraryd, pops dialogs). The nightly runs LOCAL; downloads are done by hand.
DOWNLOAD_MISSING="${DOWNLOAD_MISSING:-}"

# --cleanup is OPT-IN (default OFF). It makes osxphotos enumerate ALL ~45k DEST files over SMB
# before exporting, which WEDGES at 0% CPU on this NAS's slow metadata (observed 2026-06-22 —
# two runs hung indefinitely). It's NOT needed for dup-safety: the persistent --exportdb +
# --update already prevent new (N) dups. --cleanup only removes orphans / mirrors library
# deletions — do that NAS-local (the survivor-guarded list), or set CLEANUP=1 and accept it's
# slow/wedge-prone over SMB. The runtime watchdog below bounds a wedge either way.
CLEANUP="${CLEANUP:-}"

# Single-run lock. Two osxphotos runs against the same --exportdb (e.g. the nightly firing
# during a manual download pass) race on the ledger and can re-introduce duplicate (N)
# names — the exact failure we just cleaned up. mkdir is atomic ⇒ only one run at a time.
LOCK="${REPORT_DIR}/.run.lock"; mkdir -p "${REPORT_DIR}"
if ! mkdir "${LOCK}" 2>/dev/null; then
  opid="$(cat "${LOCK}/pid" 2>/dev/null)"
  if [ -n "${opid}" ] && kill -0 "${opid}" 2>/dev/null; then
    log "another photos-export run is active (pid ${opid}) — exiting to avoid ledger race"; exit 0
  fi
  rm -rf "${LOCK}"; mkdir "${LOCK}"   # stale lock from a crashed run
fi
echo "$$" > "${LOCK}/pid"; trap 'rm -rf "${LOCK}"' EXIT

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

# Only when downloading: restart the Photos daemon stack first (PhotoKit/photolibraryd
# wedges over time on the SMB library; a fresh daemon is what lets downloads work). Skipped
# in LOCAL mode — that's why local runs are quiet (no Photos.app, no dialogs, no wedges).
if [ -n "${DOWNLOAD_MISSING}" ]; then
  osascript -e 'tell application "Photos" to quit' >/dev/null 2>&1; sleep 2
  pkill -9 -f 'Photos.app/Contents/MacOS/Photos' >/dev/null 2>&1
  killall -9 photolibraryd photoanalysisd >/dev/null 2>&1; sleep 3
  open -ga Photos >/dev/null 2>&1 || true
fi

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
# --exportdb (LOCAL) + --update = reuse canonical filenames → never re-creates (N) dups.
# --cleanup removes any stray orphan not in the ledger (dup safety net). --download-missing
# /--use-photokit added only when DOWNLOAD_MISSING is set.
flags=(--update --exportdb "${EXPORTDB}" --sidecar XMP --retry 3)
[ -n "${CLEANUP}" ] && flags+=(--cleanup)
[ -n "${DOWNLOAD_MISSING}" ] && flags+=(--download-missing --use-photokit)
MODE="$([ -n "${DOWNLOAD_MISSING}" ] && echo photokit || echo local)"
RUNOUT="${REPORT_DIR}/run-$(date '+%Y%m%d-%H%M%S').out"
# Runtime watchdog: a single transient NAS I/O stall can wedge osxphotos at 0% CPU forever
# (observed 2026-06-22). Without this the nightly would hang indefinitely holding the lock.
# A normal run is well under an hour; cap it and let the next night retry.
MAX_RUNTIME="${MAX_RUNTIME:-5400}"   # 90 min
log "exporting → ${DEST} (mode=${MODE}; watchdog=${MAX_RUNTIME}s; report: ${REPORT})"
"${OSXPHOTOS}" export "${DEST}" --library "${LIBRARY}" "${flags[@]}" --report "${REPORT}" > "${RUNOUT}" 2>&1 &
opid=$!
( sleep "${MAX_RUNTIME}"; kill -0 "$opid" 2>/dev/null && { echo "$(date '+%F %T') WATCHDOG: exceeded ${MAX_RUNTIME}s — killing osxphotos (likely a wedged NAS I/O)"; kill -9 "$opid" 2>/dev/null; } ) & wpid=$!
wait "$opid" 2>/dev/null; rc=$?
kill "$wpid" 2>/dev/null   # cancel watchdog if the run finished on its own

# Parse osxphotos' summary ("Processed: N photos, exported: X, ..., missing: Y, ...") for
# metrics (-a: treat as text, the progress bar uses \r), and split missing into structurally-
# unavailable (edited Live-Photo motion) vs resolvable (genuinely fetchable; target 0).
summ="$(grep -aE 'Processed: [0-9]+ photos' "${RUNOUT}" 2>/dev/null | tail -1)"
m_photos="$(printf '%s' "$summ"   | sed -nE 's/.*Processed: ([0-9]+) photos.*/\1/p')"
m_exported="$(printf '%s' "$summ" | sed -nE 's/.*exported: ([0-9]+).*/\1/p')"
m_missing="$(printf '%s' "$summ"  | sed -nE 's/.*missing: ([0-9]+).*/\1/p')"
read -r m_unavail m_resolv < <(classify_missing "${REPORT}")
push_photos_metrics "${rc}" "$(( $(date +%s) - START ))" "${m_photos:-0}" "${m_exported:-0}" "${m_missing:-0}" "${m_unavail:-0}" "${m_resolv:-0}" "${MODE}"

if [ "${rc}" -eq 0 ]; then
  log "✓ export complete (photos=${m_photos:-?} exported=${m_exported:-?} missing=${m_missing:-?}: unavailable=${m_unavail:-?} resolvable=${m_resolv:-?})"
else
  log "✗ export exited rc=${rc} (see ${REPORT} / ${RUNOUT})"
fi
exit "${rc}"
