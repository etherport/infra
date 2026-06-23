#!/bin/bash
# M80 — back up iMessage/SMS history (chat.db + Attachments) to the NAS, where the existing
# s3-sync-backups pipeline ships it offsite. Restorable to a Mac (drop chat.db + Attachments
# back into ~/Library/Messages). Lands under the consistent master: /Volumes/Backups/Graham/iCloud/Messages/.
#
# DESIGN (why each step):
#   1. rsync the live chat.db (+ -wal/-shm) → LOCAL staging. rsync is the ONLY binary that needs
#      Full Disk Access here (it reads the TCC-protected ~/Library/Messages). See README "M80
#      Messages → Full Disk Access".
#   2. sqlite3 `.backup` on the STAGED copy (NOT the live DB, so NO FDA needed) → a clean,
#      WAL-checkpointed standalone chat.db, then `integrity_check`. A live SQLite DB can be
#      torn by a file-copy; .backup+integrity_check turns the staged copy into a verified,
#      self-contained snapshot and FAILS the run if it's corrupt (so a bad copy never overwrites
#      a good NAS backup; the next run retries).
#   3. Guarded mirror staged chat.db + live Attachments → NAS. The mirror REFUSES to run if the
#      source is empty (would wipe the master) and caps deletions with --max-delete — the same
#      delete-protection the contacts/calendars + s3-sync pipelines use.
#   4. Push messages_backup_* metrics to Pushgateway (auto-covered by the iCloud-backups
#      dashboard + ICloudBackup{Stale,Failed,Empty} alerts).
#
# PREREQ (one-time, interactive via VNC): Messages.app signed into iMessage, AND Full Disk
# Access granted to /usr/bin/rsync (System Settings → Privacy & Security → Full Disk Access →
# +, ⌘⇧G, /usr/bin/rsync). Without FDA the reads fail "Operation not permitted" and the run
# aborts with a clear message (no silent empty backup).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MSG_SRC="${HOME}/Library/Messages"
DEST_BASE="/Volumes/Backups/Graham/iCloud/Messages"
STAGING="${HOME}/.local/share/messages-backup"
LOGDIR="${HOME}/Library/Logs/messages-backup"
SQLITE3="${SQLITE3:-/usr/bin/sqlite3}"
MAX_RUNTIME="${MAX_RUNTIME:-3600}"   # 60 min watchdog for the read/copy phase
mkdir -p "${LOGDIR}" "${STAGING}"
# shellcheck source=mini-backup-metrics.sh
source "${HERE}/mini-backup-metrics.sh"   # push_backup_metrics (non-fatal)
# shellcheck source=mini-common.sh
source "${HERE}/mini-common.sh"           # mini_acquire_lock / mini_run_timeout / mini_kill_tree
START="$(date +%s)"

log(){ echo "$(date '+%F %T') messages: $*"; }
fail(){ # <reason-label>  — push a failure metric + exit 1
  log "✗ $1"
  push_backup_metrics messages_backup 1 "$(( $(date +%s) - START ))" 0 "$1"
  exit 1
}

# Single-run lock (own lock; pid+command verified so a reused pid can't double-run or wedge us out).
LOCK="${LOGDIR}/.run.lock"
if ! mini_acquire_lock "${LOCK}" "messages-backup.sh"; then
  log "another messages-backup run is active — exiting"; exit 0
fi
trap 'rm -rf "${LOCK}"' EXIT

# --- 0. preflight: source readable (FDA), NAS mounted+responsive ---
[ -f "${MSG_SRC}/chat.db" ] || fail "chat.db-missing"
# Prove rsync/this process can actually READ the TCC-protected DB before doing anything — a
# missing FDA grant shows as a read failure here, not a silent empty backup.
if ! mini_run_timeout 20 dd if="${MSG_SRC}/chat.db" of=/dev/null bs=1m count=1 >/dev/null 2>&1; then
  fail "no-FDA-or-unreadable-source"   # grant Full Disk Access to /usr/bin/rsync (see README)
fi
"${HERE}/mount-nas.sh" >/dev/null 2>&1 || true
if ! mini_run_timeout 15 ls /Volumes/Backups >/dev/null 2>&1; then
  fail "nas-unavailable"
fi
mkdir -p "${DEST_BASE}"

# --- 1. rsync live DB files → staging (rsync needs FDA to read the source) ---
RUNOUT="${LOGDIR}/run-$(date '+%Y%m%d-%H%M%S').out"
log "copying chat.db (+wal/shm) → staging"
if ! mini_run_timeout "${MAX_RUNTIME}" rsync -a \
      "${MSG_SRC}/chat.db" "${MSG_SRC}/chat.db-wal" "${MSG_SRC}/chat.db-shm" \
      "${STAGING}/" >"${RUNOUT}" 2>&1; then
  # -wal/-shm may legitimately not exist (DB checkpointed) — only chat.db is required.
  [ -f "${STAGING}/chat.db" ] || fail "db-copy-failed"
fi

# --- 2. checkpoint + verify on the STAGED copy (no FDA: reads staging, not ~/Library) ---
log "sqlite3 .backup (checkpoint WAL) + integrity_check on staged copy"
rm -f "${STAGING}/chat-clean.db"
if ! "${SQLITE3}" "${STAGING}/chat.db" ".backup '${STAGING}/chat-clean.db'" >>"${RUNOUT}" 2>&1; then
  fail "sqlite-backup-failed"
fi
integ="$("${SQLITE3}" "${STAGING}/chat-clean.db" "PRAGMA integrity_check;" 2>>"${RUNOUT}" | head -1)"
if [ "${integ}" != "ok" ]; then
  fail "integrity-check-failed(${integ:-empty})"   # do NOT overwrite the good NAS copy with a torn DB
fi
msg_count="$("${SQLITE3}" "${STAGING}/chat-clean.db" "SELECT count(*) FROM message;" 2>/dev/null | tr -d ' ')"
[ -n "${msg_count}" ] || msg_count=0
log "✓ staged DB verified (integrity=ok, messages=${msg_count})"

# --- 3. guarded mirror: refuse to mirror an empty source (would wipe master); cap deletions ---
# args: <label> <src-dir> <dst-dir> <items-present> [extra rsync args] ; echoes 0 ok / 1 fail.
# All log lines to stderr so only the rc is captured via $(...).
mirror(){
  local label="$1" src="$2" dst="$3" items="$4"; shift 4
  if [ "${items}" -le 0 ]; then
    log "✗ ${label}: source EMPTY (would wipe master) — skipping" >&2; echo 1; return
  fi
  mkdir -p "${dst}"
  local have maxdel
  have="$(mini_run_timeout 60 find "${dst}" -type f 2>/dev/null | wc -l | tr -d ' ')"
  maxdel=$(( have / 2 )); [ "${maxdel}" -lt 25 ] && maxdel=25
  mini_run_timeout "${MAX_RUNTIME}" rsync -a --delete --max-delete="${maxdel}" "$@" "${src}/" "${dst}/" >>"${RUNOUT}" 2>&1
  local r=$?
  [ "${r}" -eq 25 ] && { log "✗ ${label}: hit --max-delete=${maxdel} (have=${have}) — ABORTED to protect backup" >&2; echo 1; return; }
  [ "${r}" -ne 0 ]  && { log "✗ ${label}: rsync rc=${r}" >&2; echo 1; return; }
  echo 0
}

# 3a. the DB: ship the clean checkpointed copy as chat.db (single self-contained file). Stage a
#     one-file dir so the mirror's --delete only ever manages the DB, never Attachments.
DBSTAGE="${STAGING}/db"; mkdir -p "${DBSTAGE}"; cp -f "${STAGING}/chat-clean.db" "${DBSTAGE}/chat.db"
db_rc="$(mirror "db" "${DBSTAGE}" "${DEST_BASE}" 1)"

# 3b. Attachments: rsync the live dir straight to the NAS (rsync FDA reads the source). Items>0
#     guard uses a bounded source count; if FDA/source is broken this is 0 → skip (no wipe).
att_items="$(mini_run_timeout 120 find "${MSG_SRC}/Attachments" -type f 2>/dev/null | wc -l | tr -d ' ')"
[ -n "${att_items}" ] || att_items=0
log "attachments in source: ${att_items}"
att_rc="$(mirror "attachments" "${MSG_SRC}/Attachments" "${DEST_BASE}/Attachments" "${att_items}")"

dur="$(( $(date +%s) - START ))"
if [ "${db_rc}" -eq 0 ] && [ "${att_rc}" -eq 0 ]; then
  push_backup_metrics messages_backup 0 "${dur}" "${msg_count}"
  log "✓ backup complete (messages=${msg_count}, attachments=${att_items})"
  exit 0
fi
push_backup_metrics messages_backup 1 "${dur}" "${msg_count}" "mirror-failed"
log "✗ mirror failed (db_rc=${db_rc} att_rc=${att_rc}; see ${RUNOUT})"
exit 1
