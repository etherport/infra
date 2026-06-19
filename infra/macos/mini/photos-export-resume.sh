#!/bin/bash
# Self-healing wrapper around the osxphotos export for the INITIAL bulk pull (~14k
# photos). That run is long enough (hours) that two failure modes are likely, and both
# were hit on 2026-06-19:
#   1. The Backups SMB mount drops mid-run (heavy rapid small-file writes appear to trip
#      macOS smbfs into a force-unmount under load — Backups takes the write traffic
#      while Personal-Drive, which only holds the read-mostly sparsebundle, stays up).
#   2. osxphotos keeps running but WEDGES on repeating "CoreData: XPC: sendMessage:
#      failed" and makes zero progress — once its PhotoKit XPC connection dies it can't
#      reconnect; only a fresh process recovers.
#
# Strategy: loop — remount the NAS, ensure Photos.app is up (PhotoKit needs it), run
# `osxphotos export --update` (resumes from <DEST>/.osxphotos_export.db, so each restart
# continues where the last left off) under a WATCHDOG that kills the run if the Backups
# mount disappears or file progress flatlines, then retries. Exits when a run completes
# cleanly. Because --update is resumable, forward progress is guaranteed as long as each
# attempt does *some* work before dropping.
#
# Once the initial pull is complete and the mount proves stable, the steady-state nightly
# job is plain photos-export.sh (this wrapper is for the bulk fill / any future re-pull).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/Volumes/Backups/Graham/iCloud/Photos"
SPARSEBUNDLE="/Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle"
ATTACH_VOL="/Volumes/PhotosLib"
LIB="/Volumes/PhotosLib/Photos Library (NAS).photoslibrary"
OSXPHOTOS="${HOME}/.local/bin/osxphotos"
RDIR="${HOME}/Library/Logs/photos-export"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-60}"
STALL_TICKS="${STALL_TICKS:-4}"    # 4 × 120s = 8 min of zero file growth ⇒ wedged
# --cleanup deletes DEST files no longer in the library. SKIP it (CLEANUP unset) when the
# export DB (<DEST>/.osxphotos_export.db) is missing — without that ledger, cleanup can
# misjudge already-exported files and delete+re-download them. Set CLEANUP=1 once the DB
# is healthy and you want deletions mirrored. Default: off (pure additive, safe).
CLEANUP="${CLEANUP:-}"
# --download-missing --use-photokit fetches not-yet-local originals on demand, but it drives
# PhotoKit, which needs Photos.app + a live CoreData/XPC link to the library daemon. On the
# SMB-backed library that link is FRAGILE: any SMB blip makes Photos.app quit ("library moved
# or corrupt" dialog) and wedges osxphotos on "CoreData: XPC: failed after N attempts" (0
# progress). So this is OPT-IN (DOWNLOAD_MISSING=1). Default OFF = a robust pure-LOCAL export
# (reads the library files directly, no PhotoKit/Photos.app) — exports everything already
# downloaded and just reports anything still not-local as "missing". Use the local pass for
# the bulk fill, then a short DOWNLOAD_MISSING=1 pass for the few genuinely-missing originals.
DOWNLOAD_MISSING="${DOWNLOAD_MISSING:-}"
# Keep the export DB on LOCAL disk, not in DEST on the SMB share. osxphotos writes the DB
# as the final step of every run; when it lived on the (blip-prone) Backups share, that
# write kept getting interrupted by SMB reconnects → osxphotos exited rc=1 with no clean
# "Processed" line → the wrapper retried forever (saw 18 cycles 2026-06-19) even though the
# files were all exported. Local DB + --ramdb makes that final write reliable; only the
# photo files go over SMB. The DB is just a rebuildable ledger, so local (not in S3) is fine.
EXPORTDB="${EXPORTDB:-${HOME}/Library/Application Support/osxphotos/graham-icloud-photos.db}"
mkdir -p "$RDIR" "$(dirname "$EXPORTDB")"

log(){ echo "$(date '+%F %T') resume: $*"; }
count(){ find "$DEST" -type f ! -name '.osxphotos_export.db' ! -name '*.DS_Store' 2>/dev/null | wc -l | tr -d ' '; }
mounted(){ mount | grep -qF " on /Volumes/Backups "; }
# Attach the library sparsebundle if it isn't already a mounted volume. Nothing else
# attaches it after a reboot, so without this the export (and Photos.app) can't find the
# library — exactly the "PhotosLib cannot be found" failure seen 2026-06-19.
attach_lib(){
  [ -d "$ATTACH_VOL" ] && return 0
  [ -e "$SPARSEBUNDLE" ] || { log "sparsebundle missing at $SPARSEBUNDLE"; return 1; }
  log "attaching sparsebundle → $ATTACH_VOL"
  hdiutil attach "$SPARSEBUNDLE" -mountpoint "$ATTACH_VOL" >/dev/null 2>&1
}

for a in $(seq 1 "$MAX_ATTEMPTS"); do
  "${HERE}/mount-nas.sh" >/dev/null 2>&1 || true
  attach_lib || { log "attempt ${a}: cannot attach library; retry in 15s"; sleep 15; continue; }
  # Only run (and depend on) Photos.app when actually downloading missing originals.
  [ -n "$DOWNLOAD_MISSING" ] && { open -ga Photos 2>/dev/null || true; }
  sleep 5
  if [ ! -d "$DEST" ]; then log "attempt ${a}: DEST not present after remount; retry in 15s"; sleep 15; continue; fi

  out="${RDIR}/resume-run-${a}.out"
  flags=(--update --sidecar XMP --retry 3 --exportdb "$EXPORTDB" --ramdb)
  [ -n "$DOWNLOAD_MISSING" ] && flags+=(--download-missing --use-photokit)
  [ -n "$CLEANUP" ] && flags+=(--cleanup)
  log "attempt ${a}: starting export (have $(count) files; mode=$([ -n "$DOWNLOAD_MISSING" ] && echo photokit || echo local); cleanup=${CLEANUP:-off})"
  "$OSXPHOTOS" export "$DEST" --library "$LIB" \
    "${flags[@]}" \
    --report "${RDIR}/resume-${a}.csv" >"$out" 2>&1 &
  pid=$!

  last=-1; stall=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 120
    if ! mounted; then log "Backups mount lost — killing run ${a}"; kill "$pid" 2>/dev/null; break; fi
    n=$(count)
    if [ "$n" -le "$last" ]; then stall=$((stall+1)); else stall=0; fi
    last="$n"
    if [ "$stall" -ge "$STALL_TICKS" ]; then
      log "no progress ${STALL_TICKS}×120s (stuck at ${n}) — killing wedged run ${a}"
      kill "$pid" 2>/dev/null; break
    fi
  done
  wait "$pid" 2>/dev/null; rc=$?

  if [ "$rc" -eq 0 ] && grep -q "Processed: [0-9]* photos" "$out" 2>/dev/null; then
    log "✓ completed cleanly on attempt ${a}: $(grep 'Processed:' "$out" | tail -1)"
    echo "RESUME_LOOP_DONE rc=0 files=$(count)"
    exit 0
  fi
  log "attempt ${a} ended (rc=${rc}, have $(count) files); remount+retry in 15s"
  sleep 15
done

log "✗ gave up after ${MAX_ATTEMPTS} attempts (have $(count) files)"
echo "RESUME_LOOP_DONE rc=1 files=$(count)"
exit 1
