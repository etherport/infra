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
# The audit writes these for the email step; clear stale ones so we never re-send last week's.
SUMMARY_FILE="$LOG_DIR/last-summary.md"
STATUS_FILE="$LOG_DIR/last-status"
rm -f "$SUMMARY_FILE" "$STATUS_FILE"

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

# --- Email the summary EVERY run (clean or drift) via SES SMTP. The devbox has no in-cluster
# IRSA, so it sends over SMTP with creds decrypted from the alertmanager SES secret (it holds
# the age key). Best-effort: a send failure must never fail the audit. ---
email_summary() {
  local sec creds status subject body tmpbody=""
  status="$(tr -dc 'a-zA-Z' < "$STATUS_FILE" 2>/dev/null | tr 'A-Z' 'a-z')"
  [ "$rc" -ne 0 ] && status="error"
  [ -z "$status" ] && status="ran"
  case "$status" in
    clean) subject="Homelab doc/IaC drift — ✅ clean this week" ;;
    drift) subject="Homelab doc/IaC drift — ⚠️ review needed" ;;
    error) subject="Homelab doc/IaC drift — ❗ audit error (rc=$rc)" ;;
    *)     subject="Homelab doc/IaC drift — audit ran" ;;
  esac

  body="$SUMMARY_FILE"
  if [ ! -s "$SUMMARY_FILE" ]; then
    tmpbody="$LOG_DIR/.email-body.$$"
    { echo "The weekly doc/IaC drift audit ran but wrote no summary file (rc=$rc)."
      echo; echo "Last 60 log lines:"; echo '----'; tail -n 60 "$LOG"; } > "$tmpbody"
    body="$tmpbody"
  fi

  sec="$REPO/platform/kubernetes/monitoring/alertmanager-secret.sops.yaml"
  if ! creds="$(SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" sops -d "$sec" 2>>"$LOG")"; then
    echo "[email] could not decrypt SES SMTP creds — skipping email" | tee -a "$LOG"
    [ -n "$tmpbody" ] && rm -f "$tmpbody"; return 0
  fi
  get() { printf '%s' "$creds" | python3 -c "import sys,yaml;print(yaml.safe_load(sys.stdin)['stringData']['$1'])"; }
  export SMTP_HOST="$(get smtp_smarthost)"
  export SMTP_USER="$(get smtp_auth_username)"
  export SMTP_PASS="$(get smtp_auth_password)"
  export MAIL_FROM="Doc/IaC Drift Audit <service-status@wind.etherport.net>"
  MAIL_TO="$(grep -E '^EMAIL_TO=' "$REPO/platform/kubernetes/monitoring/service-status-report/email.env" 2>/dev/null | cut -d= -f2-)"
  export MAIL_TO="${MAIL_TO:-graham.m.smith@me.com}"

  if python3 "$REPO/infra/devbox/send-audit-email.py" "$status" "$subject" "$body" >>"$LOG" 2>&1; then
    echo "[email] summary emailed to $MAIL_TO ($status)" | tee -a "$LOG"
  else
    echo "[email] send FAILED — see log (GitHub doc-drift issue is still the system of record)" | tee -a "$LOG"
  fi
  unset SMTP_HOST SMTP_USER SMTP_PASS MAIL_FROM MAIL_TO
  [ -n "$tmpbody" ] && rm -f "$tmpbody"
}
email_summary

# Keep the last ~12 logs.
ls -1t "$LOG_DIR"/*.log 2>/dev/null | tail -n +13 | xargs -r rm -f
exit "$rc"
