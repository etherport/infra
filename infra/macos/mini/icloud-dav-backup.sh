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
# Sync to LOCAL staging first (vdirsyncer), then rsync staging -> Backups master location.
# Why: writing many small files straight to the SMB share stalls the iCloud connection until
# it drops ("Server disconnected"). Staging locally decouples the iCloud fetch from slow SMB.
STAGING="${HOME}/.local/share/icloud-dav"
mkdir -p "${STAGING}/Contacts" "${STAGING}/Calendars" "${DEST_BASE}/Contacts" "${DEST_BASE}/Calendars"
RUNOUT="${LOGDIR}/sync-$(date '+%Y%m%d-%H%M%S').out"

log "vdirsyncer discover+sync → ${STAGING}/{Contacts,Calendars} (watchdog=${MAX_RUNTIME}s)"
# discover auto-confirms new/known collections (yes-piped) so new address books/calendars are
# picked up automatically; then sync (read-only pull from iCloud).
# NB: `set +o pipefail` inside the subshell is REQUIRED — with pipefail on, `yes | discover`
# returns 141 (yes gets SIGPIPE when discover closes the pipe), which would falsely fail the
# pipeline and skip the sync. We don't gate sync on discover's rc; sync surfaces real errors.
(
  set +o pipefail
  yes | "${VDIRSYNCER}" discover
  "${VDIRSYNCER}" sync
) > "${RUNOUT}" 2>&1 &
vpid=$!
( sleep "${MAX_RUNTIME}"; kill -0 "$vpid" 2>/dev/null && { echo "$(date '+%F %T') WATCHDOG: vdirsyncer exceeded ${MAX_RUNTIME}s — killing"; kill -9 "$vpid" 2>/dev/null; } ) & wpid=$!
wait "$vpid" 2>/dev/null; rc=$?
kill "$wpid" 2>/dev/null

# Mirror staging -> Backups master (/Backups/Graham/iCloud/{Contacts,Calendars}). Decoupled
# from iCloud, so SMB slowness here can't drop the upstream connection. --delete mirrors
# iCloud deletions; staging is the authoritative local copy.
log "rsync staging → ${DEST_BASE}/{Contacts,Calendars}"
rsync -a --delete "${STAGING}/Contacts/"  "${DEST_BASE}/Contacts/"  >> "${RUNOUT}" 2>&1; rc_c=$?
rsync -a --delete "${STAGING}/Calendars/" "${DEST_BASE}/Calendars/" >> "${RUNOUT}" 2>&1; rc_v=$?

dur="$(( $(date +%s) - START ))"
contacts_items="$(find "${STAGING}/Contacts" -type f -name '*.vcf' 2>/dev/null | wc -l | tr -d ' ')"
calendars_items="$(find "${STAGING}/Calendars" -type f -name '*.ics' 2>/dev/null | wc -l | tr -d ' ')"
# overall rc = vdirsyncer AND both rsyncs
c_rc=$([ "${rc}" -eq 0 ] && [ "${rc_c}" -eq 0 ] && echo 0 || echo 1)
v_rc=$([ "${rc}" -eq 0 ] && [ "${rc_v}" -eq 0 ] && echo 0 || echo 1)
push_backup_metrics contacts_backup  "${c_rc}" "${dur}" "${contacts_items}"
push_backup_metrics calendars_backup "${v_rc}" "${dur}" "${calendars_items}"

if [ "${rc}" -eq 0 ] && [ "${rc_c}" -eq 0 ] && [ "${rc_v}" -eq 0 ]; then
  log "✓ sync complete (contacts=${contacts_items} vcf, calendars=${calendars_items} ics)"
  exit 0
fi
log "✗ failed (vdirsyncer rc=${rc}, rsync contacts=${rc_c} calendars=${rc_v}; see ${RUNOUT})"
exit 1
