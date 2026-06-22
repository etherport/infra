#!/bin/bash
# M80 — back up iCloud Contacts (CardDAV) + Calendars (CalDAV) to the NAS as individual
# .vcf / .ics files, where the existing s3-sync-backups pipeline ships them offsite.
# One-way / read-only (see vdirsyncer-config): vdirsyncer can never modify iCloud.
#
# Lands under the consistent master location: /Volumes/Backups/Graham/iCloud/<Service>/
# Pushes per-category metrics to Pushgateway exactly like the photos pipeline.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="sequoia.wind.etherport.net"; SMB_USER="graham"
DEST_BASE="/Volumes/Backups/Graham/iCloud"
VDIRSYNCER="${VDIRSYNCER:-${HOME}/.local/bin/vdirsyncer}"
export VDIRSYNCER_CONFIG="${VDIRSYNCER_CONFIG:-${HERE}/vdirsyncer-config}"
LOGDIR="${HOME}/Library/Logs/icloud-dav"
MAX_RUNTIME="${MAX_RUNTIME:-1800}"   # 30 min watchdog (a normal DAV sync is a few minutes)
mkdir -p "${LOGDIR}"
# shellcheck source=mini-backup-metrics.sh
source "${HERE}/mini-backup-metrics.sh"   # push_backup_metrics (non-fatal)
START="$(date +%s)"

log(){ echo "$(date '+%F %T') icloud-dav: $*"; }

# Single-run lock (own lock — independent of the photos pipeline; different data, safe to
# run concurrently with photos, but not two DAV runs at once).
LOCK="${LOGDIR}/.run.lock"
if ! mkdir "${LOCK}" 2>/dev/null; then
  opid="$(cat "${LOCK}/pid" 2>/dev/null)"
  if [ -n "${opid}" ] && kill -0 "${opid}" 2>/dev/null; then log "another run active (pid ${opid}) — exiting"; exit 0; fi
  rm -rf "${LOCK}"; mkdir "${LOCK}"
fi
echo "$$" > "${LOCK}/pid"; trap 'rm -rf "${LOCK}"' EXIT

# Ensure the Backups share is mounted (DAV needs only Backups — not the photos sparsebundle).
if ! mount | grep -qF " on /Volumes/Backups "; then
  log "mounting Backups"; open "smb://${SMB_USER}@${SERVER}/Backups"
  for i in $(seq 1 20); do sleep 2; mount | grep -qF " on /Volumes/Backups " && break; done
fi
if ! mount | grep -qF " on /Volumes/Backups "; then
  log "✗ Backups not mounted — aborting"
  push_backup_metrics contacts_backup 1 "$(( $(date +%s) - START ))" 0 nas-unavailable
  push_backup_metrics calendars_backup 1 "$(( $(date +%s) - START ))" 0 nas-unavailable
  exit 1
fi
mkdir -p "${DEST_BASE}/Contacts" "${DEST_BASE}/Calendars"

# Sync (read-only pull) under a runtime watchdog. NOTE: run `vdirsyncer discover` once at
# setup (interactive) before the first sync; re-run discover if you add an address book/calendar.
RUNOUT="${LOGDIR}/sync-$(date '+%Y%m%d-%H%M%S').out"
log "vdirsyncer sync → ${DEST_BASE}/{Contacts,Calendars} (watchdog=${MAX_RUNTIME}s)"
"${VDIRSYNCER}" sync > "${RUNOUT}" 2>&1 &
vpid=$!
( sleep "${MAX_RUNTIME}"; kill -0 "$vpid" 2>/dev/null && { echo "$(date '+%F %T') WATCHDOG: vdirsyncer exceeded ${MAX_RUNTIME}s — killing"; kill -9 "$vpid" 2>/dev/null; } ) & wpid=$!
wait "$vpid" 2>/dev/null; rc=$?
kill "$wpid" 2>/dev/null

dur="$(( $(date +%s) - START ))"
contacts_items="$(find "${DEST_BASE}/Contacts" -type f -name '*.vcf' 2>/dev/null | wc -l | tr -d ' ')"
calendars_items="$(find "${DEST_BASE}/Calendars" -type f -name '*.ics' 2>/dev/null | wc -l | tr -d ' ')"
push_backup_metrics contacts_backup  "${rc}" "${dur}" "${contacts_items}"
push_backup_metrics calendars_backup "${rc}" "${dur}" "${calendars_items}"

if [ "${rc}" -eq 0 ]; then
  log "✓ sync complete (contacts=${contacts_items} vcf, calendars=${calendars_items} ics)"
else
  log "✗ vdirsyncer exited rc=${rc} (see ${RUNOUT})"
fi
exit "${rc}"
