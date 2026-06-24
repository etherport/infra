#!/bin/bash
# M80 — back up the "file-shaped" iCloud categories from the mini to the NAS, where the existing
# s3-sync-backups pipeline ships them offsite. Each is an independent guarded mirror with its own
# metric, all under the consistent master /Volumes/Backups/Graham/iCloud/<Category>/:
#   • Notes   — the whole Notes group container (NoteStore.sqlite + Accounts/ media). The DB is
#               integrity-checked (source, read-only) before mirroring so a corrupt DB never
#               propagates.
#   • Safari  — Bookmarks.plist (bookmarks + reading list).
#   • Drive   — ~/Library/Mobile Documents/com~apple~CloudDocs (iCloud Drive). NB "Optimize Mac
#               Storage" can leave `.icloud` placeholder stubs for evicted files — those mirror as
#               tiny stubs, not real data; the run logs how many stubs it saw.
#
# Like the other mini pipelines: rsync is the FDA-reliant reader, so the LaunchAgent's responsible
# process /bin/bash needs Full Disk Access (covers Notes/Safari/Drive + the network volume). All
# NAS access is via rsync (ls/find EPERM on net vols from a launchd context); guarded with
# --max-delete; mount self-heals via mount-nas.sh; metrics + logs flow to Pushgateway + Loki.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_BASE="/Volumes/Backups/Graham/iCloud"
LOGDIR="${HOME}/Library/Logs/icloud-files"
SQLITE3="${SQLITE3:-/usr/bin/sqlite3}"
MAX_RUNTIME="${MAX_RUNTIME:-3600}"
NOTES_SRC="${HOME}/Library/Group Containers/group.com.apple.notes"
SAFARI_SRC="${HOME}/Library/Safari/Bookmarks.plist"
DRIVE_SRC="${HOME}/Library/Mobile Documents/com~apple~CloudDocs"
mkdir -p "${LOGDIR}"
# shellcheck source=mini-backup-metrics.sh
source "${HERE}/mini-backup-metrics.sh"
# shellcheck source=mini-common.sh
source "${HERE}/mini-common.sh"
START="$(date +%s)"
RUNOUT="${LOGDIR}/run-$(date '+%Y%m%d-%H%M%S').out"
log(){ echo "$(date '+%F %T') icloud-files: $*"; }

LOCK="${LOGDIR}/.run.lock"
if ! mini_acquire_lock "${LOCK}" "icloud-files-backup.sh"; then log "another run active — exiting"; exit 0; fi
trap 'rm -rf "${LOCK}"' EXIT

# Ensure NAS mounted + readable (rsync probe — ls/find EPERM on net vols under launchd).
"${HERE}/mount-nas.sh" >/dev/null 2>&1 || true
if ! nas_readable /Volumes/Backups; then
  log "✗ NAS unavailable — aborting"
  for j in notes_backup safari_backup icloud_drive_backup; do push_backup_metrics "$j" 1 0 0 nas-unavailable; done
  exit 1
fi

# Guarded mirror: refuse to mirror a MISSING source (would wipe master); cap deletions. Reads
# source-present via rsync (FDA). Returns 0 ok / 1 fail. <maxdel> caps --delete.
overall=0
mirror_dir(){  # <job> <src-dir> <dst-dir> <maxdel> <item-count>
  local job="$1" src="$2" dst="$3" maxdel="$4" items="$5" dur
  if [ ! -e "${src}" ]; then log "… ${job}: source ${src} absent — skipping"; return 0; fi
  mkdir -p "${dst}"
  log "mirror ${job}: ${src} → ${dst}"
  if mini_run_timeout "${MAX_RUNTIME}" /usr/bin/rsync -a --delete --max-delete="${maxdel}" "${src}/" "${dst}/" >>"${RUNOUT}" 2>&1; then
    dur="$(( $(date +%s) - START ))"; BACKUP_BYTES="$(nas_du_bytes "${dst}")" push_backup_metrics "${job}" 0 "${dur}" "${items}"; log "✓ ${job} (${items} items)"; return 0
  fi
  local r=$?; dur="$(( $(date +%s) - START ))"
  push_backup_metrics "${job}" 1 "${dur}" "${items}" "rsync-rc${r}"; log "✗ ${job} rsync rc=${r}"; overall=1; return 1
}

# --- Notes ---
if [ -f "${NOTES_SRC}/NoteStore.sqlite" ]; then
  integ="$("${SQLITE3}" "file:${NOTES_SRC}/NoteStore.sqlite?mode=ro&immutable=1" "PRAGMA integrity_check;" 2>>"${RUNOUT}" | head -1)"
  if [ "${integ}" = "ok" ]; then
    ncount="$("${SQLITE3}" "file:${NOTES_SRC}/NoteStore.sqlite?mode=ro&immutable=1" "SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZNOTEDATA IS NOT NULL;" 2>/dev/null | tr -d ' ')"
    [ -n "${ncount}" ] || ncount=0
    mirror_dir notes_backup "${NOTES_SRC}" "${DEST_BASE}/Notes" 50 "${ncount}"
  else
    log "✗ notes_backup: source DB integrity=${integ:-?} — NOT mirroring"
    push_backup_metrics notes_backup 1 "$(( $(date +%s) - START ))" 0 "integrity-${integ:-fail}"; overall=1
  fi
else
  log "… notes: NoteStore.sqlite absent — skipping"
fi

# --- Safari bookmarks (single file → mirror its parent-scoped copy) ---
if [ -f "${SAFARI_SRC}" ]; then
  mkdir -p "${DEST_BASE}/Safari"
  if mini_run_timeout 120 /usr/bin/rsync -a "${SAFARI_SRC}" "${DEST_BASE}/Safari/Bookmarks.plist" >>"${RUNOUT}" 2>&1; then
    BACKUP_BYTES="$(nas_du_bytes "${DEST_BASE}/Safari" 60)" push_backup_metrics safari_backup 0 "$(( $(date +%s) - START ))" 1; log "✓ safari_backup (Bookmarks.plist)"
  else
    push_backup_metrics safari_backup 1 "$(( $(date +%s) - START ))" 0 rsync-failed; log "✗ safari_backup"; overall=1
  fi
else
  log "… safari: Bookmarks.plist absent — skipping"
fi

# --- iCloud Drive (CloudDocs). Count real files + .icloud stubs (evicted) for visibility. ---
if [ -d "${DRIVE_SRC}" ]; then
  stubs="$(mini_run_timeout 120 find "${DRIVE_SRC}" -name '*.icloud' 2>/dev/null | wc -l | tr -d ' ')"
  files="$(mini_run_timeout 180 find "${DRIVE_SRC}" -type f ! -name '*.icloud' 2>/dev/null | wc -l | tr -d ' ')"
  [ -n "${stubs}" ] || stubs=0; [ -n "${files}" ] || files=0
  log "icloud_drive: ${files} local files, ${stubs} evicted (.icloud stubs — back up as stubs only)"
  mirror_dir icloud_drive_backup "${DRIVE_SRC}" "${DEST_BASE}/Drive" 1000 "${files}"
else
  log "… icloud_drive: CloudDocs absent — skipping"
fi

exit "${overall}"
