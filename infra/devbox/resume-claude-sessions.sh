#!/bin/bash
# Resume Claude Code tmux sessions on devbox (Linux) after reboot/login.
#
# For each repo: ensure the clone exists (auto-clone if missing), then start a
# detached tmux session running `claude --continue` IN that repo dir. With
# RC-enabled-by-default the sessions become controllable from claude.ai without
# attaching. Idempotent — skips a session already running.
#
# Invoked at boot by the `claude-sessions.service` systemd *user* unit
# (requires `loginctl enable-linger ubuntu`), and runnable by hand.
#
# Notes learned the hard way:
#  - `tmux -c <dir>` silently falls back to $HOME if <dir> doesn't exist, which
#    puts claude in the wrong project. So we (a) ensure the dir exists and
#    (b) `cd` explicitly in the launched command, not just rely on -c.
#  - `claude --continue` only resumes a session previously run on THIS machine
#    (it keys off lastSessionId). Each migrated session must be resumed once via
#    `claude --resume` (picker) first; after that --continue follows it. cue +
#    personal-web were primed that way during the mini->devbox migration.
set -uo pipefail

# One tmux session per repo (each is a SEPARATE session/window, not a combined name).
SESSIONS=(
  cue
  personal-web
  infra        # migrated off the mini 2026-06-18
)
CODE="${HOME}/code"
GH="git@github.com:sparked-diamond"

log() { echo "$(date '+%FT%T') resume: $*"; }

for s in "${SESSIONS[@]}"; do
  dir="${CODE}/${s}"

  # Self-heal: auto-clone the repo if it's missing (so a vanished dir can't
  # silently send claude to the wrong project).
  if [ ! -d "${dir}/.git" ]; then
    log "${s}: repo missing — cloning"
    git clone "${GH}/${s}.git" "${dir}" || { log "${s}: clone FAILED, skip"; continue; }
  fi

  if tmux has-session -t "=${s}" 2>/dev/null; then
    log "${s}: already running"
    continue
  fi

  tmux new-session -d -s "${s}" -c "${dir}"
  # Explicit cd belt-and-suspenders vs the -c fallback-to-HOME footgun.
  tmux send-keys -t "${s}" "cd '${dir}' && claude --continue" Enter
  log "${s}: started (claude --continue in ${dir})"
done

tmux ls 2>/dev/null || true
