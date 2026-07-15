#!/bin/bash
# Keep the mini's Claude Code tmux session(s) alive — auto-START at login and
# auto-RESUME after a crash. Driven by the net.wind.claude-session LaunchAgent
# (RunAtLoad + StartInterval=120), and idempotent, so also safe to run by hand.
#
# Two failure modes covered each tick:
#   1. tmux session missing (fresh boot, tmux server died)  → create it + launch claude
#   2. tmux session alive but claude EXITED (crash → pane sits at a bare shell)
#      → re-send `claude --continue` into the existing pane
#
# `claude --continue` resumes the most recent conversation in the project dir;
# `|| claude` falls back to a fresh session the first time a project has none.
# NB: never copy session .jsonl files between machines/projects to "migrate" a
# conversation — two live sessions sharing a UUID fight over Remote Control
# (memory: rc_session_uuid_collision). Fresh/--continue only.
#
# 2026-07-11: the mini's dev session moved to ~/code/cairn (cairn is the primary
# work here; the infra repo is whitelisted as an additional directory in the cairn
# session's settings). infra/cue/personal-web sessions live on the DEVBOX (M81).
set -uo pipefail

# tmux-session-name : working directory
SESSIONS=(
  "cairn:/Users/grahamsmith/code/cairn"
)

log(){ echo "$(date '+%Y-%m-%dT%H:%M:%S') claude-session: $*"; }

for entry in "${SESSIONS[@]}"; do
  name="${entry%%:*}"
  dir="${entry#*:}"
  [ -d "$dir" ] || { log "✗ ${name}: dir ${dir} missing — skipping"; continue; }

  # 1. session missing → create + start claude
  if ! tmux has-session -t "=${name}" 2>/dev/null; then
    tmux new-session -d -s "$name" -n claude -c "$dir"
    tmux send-keys -t "${name}:claude" 'claude --continue || claude' Enter
    log "▶ ${name}: session created, claude starting in ${dir}"
    continue
  fi

  # 2. session alive — is claude still running in the pane? A crashed claude
  #    leaves the pane at a bare shell (pane_current_command = zsh/bash/sh).
  cmd="$(tmux display-message -pt "${name}:claude" '#{pane_current_command}' 2>/dev/null || echo '?')"
  case "$cmd" in
    zsh|bash|sh)
      tmux send-keys -t "${name}:claude" 'claude --continue || claude' Enter
      log "▶ ${name}: pane was idle (${cmd}) — resumed claude"
      ;;
    *)
      : # claude (shows as claude/node) or something intentional — leave it alone
      ;;
  esac
done
