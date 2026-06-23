#!/bin/bash
# Shared primitives for the headless-mini backup scripts (M79/M80). Sourced by
# photos-export.sh, photos-export-resume.sh, icloud-dav-backup.sh. Pure helpers, no side
# effects on source. Written for the adversarial-review HIGH findings:
#   - lock stale-recovery race + bare-PID trust  -> mini_acquire_lock
#   - count()/rsync hang forever on a dead SMB mount -> mini_run_timeout
#   - watchdog SIGTERM-vs-SIGKILL inconsistency + orphaned children -> mini_kill_tree

# Prefer a real timeout binary if present (coreutils gtimeout, or GNU timeout).
_MINI_TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"

# nas_readable <dir> — true iff <dir>'s contents are READABLE from THIS process context.
# CRITICAL (macOS, 2026-06-23): background/launchd processes need Full Disk Access to read
# NETWORK volumes (/Volumes/<smb>). `ls`/`find`/`test` have no FDA, so they return EPERM under
# launchd even on a perfectly healthy mount — which made the old `ls` liveness probe false-fail
# under launchd and (worse) force-unmount good mounts. `rsync` IS the FDA-granted binary, so it
# reads network volumes fine under launchd AND interactively; it also genuinely fails on a
# stale/unmounted share, so it's an accurate liveness probe in BOTH contexts. Depth-limited
# (--exclude '/*/*') so it's instant even on huge shares; openrsync's -d returns rc=23, hence
# the --exclude trick rather than -d.
nas_readable(){ mini_run_timeout 15 /usr/bin/rsync -n --exclude='/*/*' "$1/" "${TMPDIR:-/tmp}/.nasprobe/" >/dev/null 2>&1; }

# mini_run_timeout <secs> <cmd...> — run cmd with a wall-clock cap, stdout passed through so
# `out="$(mini_run_timeout 30 find ...)"` works. Returns the command's rc, or non-zero
# (124 via timeout(1), or 143/137 via the fallback) if it was killed for exceeding <secs>.
# macOS has no timeout(1) by default; the fallback backgrounds the cmd (stdout inherited)
# and TERM->KILL escalates it. Use to bound any operation that touches the blip-prone NAS.
mini_run_timeout() {
  local t="$1"; shift
  if [ -n "${_MINI_TIMEOUT_BIN}" ]; then
    "${_MINI_TIMEOUT_BIN}" -k 5 "$t" "$@"; return $?
  fi
  "$@" & local p=$!
  ( sleep "$t"; kill -0 "$p" 2>/dev/null && { kill -TERM "$p" 2>/dev/null; sleep 3; kill -KILL "$p" 2>/dev/null; }; ) & local w=$!
  wait "$p" 2>/dev/null; local r=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return "$r"
}

# mini_kill_tree <pid> — terminate a (possibly wedged) process AND its direct children,
# escalating SIGTERM -> SIGTERM -> SIGKILL with a grace period. A osxphotos/vdirsyncer
# process stuck in uninterruptible SMB I/O often ignores SIGTERM; a bare `kill` then leaves
# an orphan still holding the ledger/mount. pkill -P also reaps PhotoKit/ffmpeg/rsync children.
mini_kill_tree() {
  local pid="$1" sig
  for sig in TERM TERM KILL; do
    kill -0 "$pid" 2>/dev/null || return 0
    pkill -"${sig}" -P "$pid" 2>/dev/null || true
    kill -"${sig}" "$pid" 2>/dev/null || true
    sleep 2
  done
}

# mini_acquire_lock <lockdir> <cmd_substring> — atomic single-run lock with a TRUSTWORTHY
# liveness check. Returns 0 and leaves the lock held (caller MUST set the EXIT trap to remove
# it) if acquired; returns 1 if another genuinely-live run of this script holds it.
#
# Fixes the prior `mkdir || (read pid; kill -0; rm -rf; mkdir)` pattern, which:
#   (a) trusted a BARE pid — after a crash+pid-reuse an unrelated process holding the recycled
#       pid made every run think "another run active" and exit forever (silent backup outage);
#   (b) raced on the un-checked `rm -rf; mkdir` recovery, letting two runs proceed against one
#       --exportdb (the ledger race the lock exists to prevent).
# Liveness now requires BOTH `kill -0` AND that the pid's command matches <cmd_substring>, and
# the stale re-take re-checks `mkdir` succeeded AND that we actually own the pid file.
mini_acquire_lock() {
  local lock="$1" want="$2" opid
  if mkdir "$lock" 2>/dev/null; then
    echo "$$" > "$lock/pid"; return 0
  fi
  opid="$(cat "$lock/pid" 2>/dev/null || true)"
  if [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null && ps -p "$opid" -o command= 2>/dev/null | grep -qF "$want"; then
    return 1   # a real, live sibling run holds it
  fi
  # stale (dead pid, or pid reused by an unrelated process): re-take, but verify we won the race
  rm -rf "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || return 1
  echo "$$" > "$lock/pid"
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ] || return 1
  return 0
}
