#!/usr/bin/env bash
# Weekly live-anchored doc/IaC drift audit. Runs ON THE DEVBOX because the audit needs LIVE
# access (kubectl cluster-admin, UDM API via SOPS, on-host `ip route`) that a cloud-scheduled
# run can't reach. Headless `claude` does the audit, AUTO-FIXES high-confidence DOC drift
# (commit+push), and posts a summary (auto-changes + manual-review items) to the `doc-drift`
# GitHub issue. IaC drift is reported, never auto-applied. Deployed + enabled by devbox.yml
# (doc-drift-audit.service/.timer). Prompt + safety rules: doc-drift-audit-prompt.md.
set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REPO="/home/ubuntu/code/infra"
PROMPT_FILE="$REPO/infra/devbox/doc-drift-audit-prompt.md"
LOG_DIR="$HOME/.local/state/doc-drift-audit"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"

cd "$REPO" || { echo "repo missing"; exit 1; }
git pull --rebase origin main >>"$LOG" 2>&1 || true

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not installed — cannot run the audit" | tee -a "$LOG" >&2
  exit 1
fi

echo "[$(date -Is)] starting doc-drift audit" >>"$LOG"
# --dangerously-skip-permissions: this is an unattended run; the prompt's hard rules constrain it
# to docs-only edits + read-only live checks (no terraform/ansible apply, no secret/file deletion).
claude -p "$(cat "$PROMPT_FILE")" --dangerously-skip-permissions >>"$LOG" 2>&1
rc=$?
echo "[$(date -Is)] doc-drift audit finished (rc=$rc) -> $LOG" | tee -a "$LOG"
# Keep the last ~12 logs.
ls -1t "$LOG_DIR"/*.log 2>/dev/null | tail -n +13 | xargs -r rm -f
exit "$rc"
