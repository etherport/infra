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
# shellcheck source=mini-common.sh
source "${HERE}/mini-common.sh"           # mini_acquire_lock / mini_run_timeout / mini_kill_tree
START="$(date +%s)"

log(){ echo "$(date '+%F %T') icloud-dav: $*"; }

# Single-run lock (own lock — independent of the photos pipeline; different data, safe to
# run concurrently with photos, but not two DAV runs at once). mini_acquire_lock verifies the
# holder is a genuinely-live icloud-dav run (pid + command match) so pid reuse can neither
# double-run nor wedge us out forever.
LOCK="${LOGDIR}/.run.lock"
if ! mini_acquire_lock "${LOCK}" "icloud-dav-backup.sh"; then
  log "another icloud-dav run is active — exiting"; exit 0
fi
trap 'rm -rf "${LOCK}"' EXIT

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
# Liveness probe: a stale/dead SMB mount still appears in `mount` but hangs on I/O. A bounded
# stat proves the mount actually responds before we touch it (else every later find/rsync hangs).
if ! mini_run_timeout 15 ls /Volumes/Backups >/dev/null 2>&1; then
  log "✗ Backups mount is listed but UNRESPONSIVE (stale) — aborting"
  push_backup_metrics contacts_backup 1 "$(( $(date +%s) - START ))" 0 nas-unresponsive
  push_backup_metrics calendars_backup 1 "$(( $(date +%s) - START ))" 0 nas-unresponsive
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
# pipeline. We capture discover's OWN rc via PIPESTATUS and treat only 141 (SIGPIPE, expected)
# or 0 as OK; a REAL discover failure (auth/network) fails the run so the destructive mirror is
# never reached on a half-broken pull. The subshell's exit = sync's rc unless discover failed.
(
  set +o pipefail
  yes | "${VDIRSYNCER}" discover
  drc=${PIPESTATUS[1]}
  if [ "${drc}" -ne 0 ] && [ "${drc}" -ne 141 ]; then
    echo "discover failed rc=${drc}" >&2; exit "${drc}"
  fi
  "${VDIRSYNCER}" sync
) > "${RUNOUT}" 2>&1 &
vpid=$!
( sleep "${MAX_RUNTIME}"; kill -0 "$vpid" 2>/dev/null && { echo "$(date '+%F %T') WATCHDOG: vdirsyncer exceeded ${MAX_RUNTIME}s — killing"; mini_kill_tree "$vpid"; } ) & wpid=$!
wait "$vpid" 2>/dev/null; rc=$?
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null   # reap the watchdog (avoid orphan sleeper / pid reuse)

# Count staging FIRST (local, fast) — needed to guard the destructive mirror BEFORE it runs.
contacts_items="$(find "${STAGING}/Contacts" -type f -name '*.vcf' 2>/dev/null | wc -l | tr -d ' ')"
calendars_items="$(find "${STAGING}/Calendars" -type f -name '*.ics' 2>/dev/null | wc -l | tr -d ' ')"

# Guarded mirror: staging -> Backups master. `rsync --delete` mirrors iCloud deletions, but an
# EMPTY or PARTIAL staging + --delete would WIPE the master (the only offsite-bound backup) —
# the project's signature data-loss mode. So we REFUSE to mirror unless (a) vdirsyncer exited
# clean AND (b) staging is non-empty, and we cap deletions with --max-delete (half the current
# master, floor 25) so an unexpected mass-shrink ABORTS (rsync rc=25) instead of completing.
# Causes that would otherwise wipe: app-password expiry, watchdog kill, iCloud empty-collection,
# sops failure → all leave staging empty/partial and must NOT propagate as a deletion.
# args: <svc> <staging-items> <staging-dir> <dest-dir> ; echoes 0 (ok) / 1 (skipped|failed)
# NB: only the final `echo 0|1` may go to stdout (it's captured via $(...)); all log lines are
# routed to stderr so they don't pollute the captured rc.
mirror_service(){
  local svc="$1" items="$2" src="$3" dst="$4"
  if [ "${rc}" -ne 0 ]; then
    log "✗ ${svc}: NOT mirroring — vdirsyncer failed (rc=${rc}); master left intact" >&2; echo 1; return
  fi
  if [ "${items}" -eq 0 ]; then
    log "✗ ${svc}: NOT mirroring — staging EMPTY (would wipe master); master left intact" >&2; echo 1; return
  fi
  # Bound the master-side find AND the rsync with a wall-clock cap — a dead-but-listed SMB mount
  # would otherwise hang either forever, wedging the run + holding the lock (H2/H3).
  local have; have="$(mini_run_timeout 60 find "${dst}" -type f 2>/dev/null | wc -l | tr -d ' ')"
  local maxdel=$(( have / 2 )); [ "${maxdel}" -lt 25 ] && maxdel=25
  mini_run_timeout "${RSYNC_TIMEOUT:-600}" rsync -a --delete --max-delete="${maxdel}" "${src}/" "${dst}/" >> "${RUNOUT}" 2>&1
  local r=$?
  if [ "${r}" -eq 25 ]; then
    log "✗ ${svc}: rsync hit --max-delete=${maxdel} (master had ${have}, staging ${items}) — ABORTED to protect backup" >&2; echo 1; return
  fi
  if [ "${r}" -ne 0 ]; then
    log "✗ ${svc}: rsync failed rc=${r}" >&2; echo 1; return
  fi
  echo 0
}
log "rsync staging → ${DEST_BASE}/{Contacts,Calendars} (guarded)"
c_rc="$(mirror_service contacts  "${contacts_items}"  "${STAGING}/Contacts"  "${DEST_BASE}/Contacts")"
v_rc="$(mirror_service calendars "${calendars_items}" "${STAGING}/Calendars" "${DEST_BASE}/Calendars")"

dur="$(( $(date +%s) - START ))"
push_backup_metrics contacts_backup  "${c_rc}" "${dur}" "${contacts_items}"
push_backup_metrics calendars_backup "${v_rc}" "${dur}" "${calendars_items}"

if [ "${c_rc}" -eq 0 ] && [ "${v_rc}" -eq 0 ]; then
  log "✓ sync complete (contacts=${contacts_items} vcf, calendars=${calendars_items} ics)"
  exit 0
fi
log "✗ failed (vdirsyncer rc=${rc}, contacts_rc=${c_rc} calendars_rc=${v_rc}; see ${RUNOUT})"
exit 1
