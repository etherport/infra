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
# Access granted to /bin/bash — macOS attributes TCC file access to the "responsible process"
# (the launchd job's program = /bin/bash), NOT the leaf binary, so granting rsync alone is
# ignored. With /bin/bash granted, the job + its children (rsync, sqlite3) can read Messages.
# Without it the reads fail "Operation not permitted" and the run aborts (no silent empty backup).
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

# --- 0. preflight: source present, NAS mounted+readable ---
# (chat.db existence is a stat — works without FDA. nas_readable probes via rsync, the
# FDA-granted binary: `ls`/`find` EPERM on the network volume from a launchd context even on a
# healthy mount — background processes need Full Disk Access for net vols — so they'd false-fail.)
[ -f "${MSG_SRC}/chat.db" ] || fail "chat.db-missing"
"${HERE}/mount-nas.sh" >/dev/null 2>&1 || true
nas_readable /Volumes/Backups || fail "nas-unavailable"
mkdir -p "${DEST_BASE}"

# --- 1. rsync live DB files → staging. This is ALSO the FDA/read gate: rsync is the binary
# granted Full Disk Access, so a missing grant fails here with "Operation not permitted" and we
# abort with a clear message — never a silent empty backup. (Explicit /usr/bin/rsync = the
# FDA-granted binary, not a Homebrew rsync that PATH might prefer.) ---
RUNOUT="${LOGDIR}/run-$(date '+%Y%m%d-%H%M%S').out"
rm -f "${STAGING}/chat.db" "${STAGING}/chat.db-wal" "${STAGING}/chat.db-shm"
log "copying chat.db (+wal/shm) → staging"
mini_run_timeout "${MAX_RUNTIME}" /usr/bin/rsync -a \
      "${MSG_SRC}/chat.db" "${MSG_SRC}/chat.db-wal" "${MSG_SRC}/chat.db-shm" \
      "${STAGING}/" >"${RUNOUT}" 2>&1 || true   # -wal/-shm may not exist; only chat.db is required
if [ ! -f "${STAGING}/chat.db" ]; then
  if grep -qiE 'permission denied|operation not permitted|denied' "${RUNOUT}" 2>/dev/null; then
    fail "no-FDA-rsync-cannot-read-Messages"     # grant Full Disk Access to /usr/bin/rsync (README)
  fi
  fail "db-copy-failed"
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

# --- 2b. message-count regression guard — the closest we can get to "is the local cache fully
# synced from iCloud?". There is NO Apple API to assert local chat.db == iCloud; with "Messages
# in iCloud" ON (it is here) the local DB is a SYNCED CACHE that can be mid-resync or trimmed.
# So: refuse to overwrite a good NAS backup with one whose message count fell >10% below the
# last success — a partial/incomplete sync FAILS LOUDLY instead of silently shrinking the
# backup. First run (no baseline) proceeds; the baseline is recorded only after a clean run. ---
CNT_STATE="${STAGING}/.last_msg_count"
last_cnt="$(cat "${CNT_STATE}" 2>/dev/null || echo 0)"
if [ "${last_cnt}" -gt 0 ] 2>/dev/null && [ "${msg_count}" -lt "$(( last_cnt * 9 / 10 ))" ]; then
  fail "message-count-regressed(${msg_count}<90%_of_${last_cnt})"
fi

# --- 3. mirror to NAS. rsync ONLY (it has FDA, so it reads ~/Library/Messages AND writes the
# network volume from launchd; ls/find can't). Deletions are capped with --max-delete so a mass
# local-cache eviction (Messages-in-iCloud offload) ABORTS + alerts rather than shrinking the
# NAS copy. ---
# 3a. DB: a single clean checkpointed file, copied directly (no --delete → cannot endanger the
#     sibling Attachments/ dir).
log "mirror chat.db → NAS"
if mini_run_timeout "${MAX_RUNTIME}" /usr/bin/rsync -a "${STAGING}/chat-clean.db" "${DEST_BASE}/chat.db" >>"${RUNOUT}" 2>&1; then
  db_rc=0
else
  db_rc=1; log "✗ db: rsync to NAS failed (see ${RUNOUT})"
fi
# 3b. Attachments: PARALLEL + RESILIENT mirror. The tree is 256 hashed top-level dirs (00–ff),
#     each an independent rsync, so we shard them across ATT_PAR concurrent workers (xargs -P) —
#     SMB multichannel carries the concurrent streams, ~PAR× the serial per-file rate (the
#     bottleneck is per-file round-trip latency, not bandwidth). Heavy sustained SMB write load
#     can still trip a session drop (SESSION_RECONNECT) and wedge workers, so wrap the whole
#     parallel pass in a retry loop: each pass resumes (rsync -a skips done files), remounting
#     between attempts, until a clean pass. --max-delete per shard caps a mass-deletion.
ATT_SRC="${MSG_SRC}/Attachments"
PAR="${ATT_PAR:-6}"
SHARDS="${STAGING}/att-shards.txt"
mkdir -p "${DEST_BASE}/Attachments"
mini_run_timeout 60 find "${ATT_SRC}" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort > "${SHARDS}"
nshards="$(wc -l < "${SHARDS}" | tr -d ' ')"
# guard: empty enumeration = couldn't read the source (FDA/mount) → don't let an empty xargs
# run report success (which would also let --delete wipe the NAS attachments).
[ "${nshards}" -gt 0 ] 2>/dev/null || fail "attachments-enum-failed(0-shards)"
log "attachments: ${nshards} shards × ${PAR}-way parallel"
att_rc=1
for att in $(seq 1 "${ATT_ATTEMPTS:-8}"); do
  nas_readable /Volumes/Backups || "${HERE}/mount-nas.sh" >/dev/null 2>&1
  log "mirror Attachments → NAS (attempt ${att}, ${PAR}-way)"
  # one rsync per top-level shard ({} = shard name, into both src and dst). The `< SHARDS`
  # redirect is DIRECTLY on the backgrounded xargs (always honored) — NOT via mini_run_timeout,
  # which lost xargs's stdin (empty input → 0 work → false rc=0). Own watchdog kills xargs + its
  # rsync children on timeout.
  xargs -P "${PAR}" -I{} \
    /usr/bin/rsync -a --delete --max-delete=200 "${ATT_SRC}/{}/" "${DEST_BASE}/Attachments/{}/" \
    < "${SHARDS}" >>"${RUNOUT}" 2>&1 &
  xpid=$!
  ( sleep "${ATT_TIMEOUT:-2400}"; kill -0 "$xpid" 2>/dev/null && { pkill -9 -P "$xpid" 2>/dev/null; kill -9 "$xpid" 2>/dev/null; } ) & wd=$!
  wait "$xpid" 2>/dev/null; r=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  pkill -9 -f "rsync.*Messages/Attachments" 2>/dev/null   # reap any workers the timeout orphaned
  if [ "${r}" -eq 0 ]; then att_rc=0; log "✓ attachments mirror clean (attempt ${att})"; break; fi
  log "attachments attempt ${att} had failures/timeout (rc=${r}) — remount + resume"
  "${HERE}/mount-nas.sh" >/dev/null 2>&1
done

dur="$(( $(date +%s) - START ))"
if [ "${db_rc}" -eq 0 ] && [ "${att_rc}" -eq 0 ]; then
  echo "${msg_count}" > "${CNT_STATE}"   # record baseline for the regression guard (only on a clean run)
  push_backup_metrics messages_backup 0 "${dur}" "${msg_count}"
  log "✓ backup complete (messages=${msg_count})"
  exit 0
fi
push_backup_metrics messages_backup 1 "${dur}" "${msg_count}" "mirror-failed"
log "✗ mirror failed (db_rc=${db_rc} att_rc=${att_rc}; see ${RUNOUT})"
exit 1
