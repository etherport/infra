#!/bin/bash
# Resume the Claude Code tmux sessions on the mini (e.g. after a reboot).
#
# Re-creates one detached tmux session per project — mirroring the live layout
# (separate sessions: infra / cue / personal-web) — each running
# `claude --continue` (resume the most recent conversation) in the project dir.
#
# Idempotent: a project whose tmux session is already running is left untouched,
# so this is safe to re-run any time.
#
#   Restore any missing sessions:  resume-claude-sessions.sh
#   Attach:                        tmux attach -t infra   (or cue / personal-web)
#   Detach (leave it running):     Ctrl-b d
set -uo pipefail

# tmux-session-name : working directory
SESSIONS=(
  "infra:/Users/grahamsmith/code/infra"
  "cue:/Users/grahamsmith/code/cue"
  "personal-web:/Users/grahamsmith/code/personal-web"
)

for entry in "${SESSIONS[@]}"; do
  name="${entry%%:*}"
  dir="${entry#*:}"

  # `=name` = exact match (don't prefix-match other sessions)
  if tmux has-session -t "=${name}" 2>/dev/null; then
    echo "✓ ${name}: already running — leaving as-is"
    continue
  fi
  if [ ! -d "$dir" ]; then
    echo "✗ ${name}: dir ${dir} missing — skipping"
    continue
  fi

  tmux new-session -d -s "$name" -n claude -c "$dir"
  # Run in the window's interactive shell so fnm/PATH resolves `claude`
  # (same way the live sessions do). `--continue` resumes the latest convo;
  # swap to `--resume` if you'd rather pick a specific session.
  tmux send-keys -t "${name}:claude" 'claude --continue' Enter
  echo "▶ ${name}: started 'claude --continue' in ${dir}"
done

echo
echo "Sessions now running:"
tmux ls 2>/dev/null || echo "(none)"
echo "Attach with: tmux attach -t <infra|cue|personal-web>"
