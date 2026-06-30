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
# Scoped permissions (NOT --dangerously-skip-permissions): the agent can read anything, write
# only docs/READMEs/CLAUDE.md + the log dir, and mutate nothing but a GitHub workflow_dispatch.
# The deny list (doc-drift-audit-permissions.json) hard-blocks terraform/ansible apply, kubectl
# mutations, rm/destructive-git, and sops-encrypt. Exporting SOPS_AGE_KEY_FILE lets the agent run
# plain `sops -d <file>` (the matcher rejects the `VAR=x sops -d` env-prefix form). --add-dir lets
# the Write tool create last-summary.md/last-status under the (out-of-repo) log dir.
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
claude -p "$(cat "$PROMPT_FILE")" \
  --permission-mode default \
  --settings "$REPO/infra/devbox/doc-drift-audit-permissions.json" \
  --add-dir "$LOG_DIR" \
  >>"$LOG" 2>&1
rc=$?
echo "[$(date -Is)] doc-drift audit finished (rc=$rc) -> $LOG" | tee -a "$LOG"

# --- Prometheus textfile metric (scraped by node_exporter --collector.textfile). Lets the
# monitoring stack alert on a FAILED *or MISSED* run from off-box (DocDriftAudit* in
# 02-external-alerts.yaml). last_success_timestamp is stamped only on rc==0, and the prior
# marker is preserved on a failed run, so a failure can't refresh the staleness clock. ---
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
prom="$TEXTFILE_DIR/doc_drift_audit.prom"
if [ -d "$TEXTFILE_DIR" ] && [ -w "$TEXTFILE_DIR" ]; then
  tmp="$(mktemp "$prom.XXXX")"
  {
    echo '# HELP doc_drift_audit_last_rc Exit code of the most recent doc-drift audit run.'
    echo '# TYPE doc_drift_audit_last_rc gauge'
    echo "doc_drift_audit_last_rc $rc"
    echo '# HELP doc_drift_audit_last_success_timestamp_seconds Unix time of the last successful (rc=0) run.'
    echo '# TYPE doc_drift_audit_last_success_timestamp_seconds gauge'
    if [ "$rc" -eq 0 ]; then
      echo "doc_drift_audit_last_success_timestamp_seconds $(date +%s)"
    elif [ -f "$prom" ]; then
      grep '^doc_drift_audit_last_success_timestamp_seconds ' "$prom" 2>/dev/null || true
    fi
  } > "$tmp"
  mv -f "$tmp" "$prom"
  echo "[metric] wrote $prom (rc=$rc)" >>"$LOG"
else
  echo "[metric] $TEXTFILE_DIR missing/unwritable — skipped textfile metric (run base.yml on devbox)" | tee -a "$LOG"
fi

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
