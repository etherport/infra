#!/usr/bin/env bash
# Weekly live-anchored doc/IaC drift audit. Runs ON THE DEVBOX because it needs LIVE access
# (kubectl cluster-admin, UDM API via the helper, on-host `ip route`) a cloud run can't reach.
#
# SECURITY MODEL (hardened after the 2026-06-30 adversarial review): a prefix allowlist CANNOT
# enforce "docs-only write / no exfil" for an unattended agent — shell redirection (`> file`),
# write-flags on allowed tools (`sort -o`, `curl -o`), `git restore`, and `git push` all bypass it.
# So the agent's allowlist (doc-drift-audit-permissions.json) grants NO git, NO curl, NO sops, NO
# dispatch — only reads + Edit/Write to docs + the helper (GET-only). The WRAPPER (this script,
# trusted) owns ALL mutation: it stages ONLY doc paths, secret-scans before publishing, and does
# the commit/push + issue-dispatch + email itself. A prompt-injected agent therefore cannot push to
# the Flux-reconciled `main`, nor exfiltrate (its only outbound is the helper's UDM/GitHub GETs and
# a wrapper-scanned summary). See doc-drift-audit-prompt.md. Deployed by devbox.yml.
set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REPO="/home/ubuntu/code/infra"
# ⚠️ PIN the model. Without --model, `claude -p` inherits the interactive default
# (~/.claude.json), which flipped to `claude-fable-5[1m]` in early July — whose usage
# cap is exhausted, so EVERY weekly run since ~2026-07-06 died with "You've reached your
# Fable 5 limit" (rc=1) and emailed an "(error)" summary instead of a real drift report.
# Sonnet 5 = capable for drift analysis + generous limits + doesn't compete with the
# operator's interactive Opus quota. Override via AUDIT_MODEL if desired.
AUDIT_MODEL="${AUDIT_MODEL:-claude-sonnet-5}"
PROMPT_FILE="$REPO/infra/devbox/doc-drift-audit-prompt.md"
HELPER="$REPO/infra/devbox/audit-helpers.sh"
LOG_DIR="$HOME/.local/state/doc-drift-audit"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"
# The agent writes these (for the email/issue) via the Write tool, into an in-repo gitignored dir
# (the Write tool is denied for out-of-repo paths). Cleared so we never re-send last week's.
ARTIFACT_DIR="$REPO/infra/devbox/.audit-state"
SUMMARY_FILE="$ARTIFACT_DIR/last-summary.md"
STATUS_FILE="$ARTIFACT_DIR/last-status"
mkdir -p "$ARTIFACT_DIR"
rm -f "$SUMMARY_FILE" "$STATUS_FILE"

# High-signal secret markers — used to (a) redact the published summary and (b) block a doc commit
# if the agent somehow wrote a secret into a doc or the summary.
SECRET_RE='AGE-SECRET-KEY-1|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gh[opsu]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-ant-[A-Za-z0-9_-]{20,}|aws_secret_access_key'

cd "$REPO" || { echo "repo missing"; exit 1; }
git pull --rebase origin main >>"$LOG" 2>&1 || true

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not installed — cannot run the audit" | tee -a "$LOG" >&2
  exit 1
fi

echo "[$(date -Is)] starting doc-drift audit" >>"$LOG"
# The agent has NO git/curl/sops in its allowlist (the matcher can't keep them safe — see header).
# SOPS_AGE_KEY_FILE is NOT exported to the agent; only the helper (which it runs) decrypts, and only
# returns UDM/GitHub GET results — never raw secrets.
claude -p "$(cat "$PROMPT_FILE")" \
  --model "$AUDIT_MODEL" \
  --permission-mode default \
  --settings "$REPO/infra/devbox/doc-drift-audit-permissions.json" \
  >>"$LOG" 2>&1
rc=$?
echo "[$(date -Is)] doc-drift audit finished (rc=$rc) -> $LOG" | tee -a "$LOG"

# Resolve the run status once (from the agent's status artifact + rc).
status="$(tr -dc 'a-zA-Z' < "$STATUS_FILE" 2>/dev/null | tr 'A-Z' 'a-z')"
[ "$rc" -ne 0 ] && status="error"
[ -z "$status" ] && status="ran"

# --- Secret-scan the agent-authored summary; redact rather than publish a leaked secret. ---
if [ -s "$SUMMARY_FILE" ] && grep -aEq "$SECRET_RE" "$SUMMARY_FILE"; then
  echo "[security] ⚠ last-summary.md matched a secret pattern — REDACTING (not publishing it)" | tee -a "$LOG"
  printf '## Summary withheld\n\nThe audit summary matched a secret pattern and was NOT published. Inspect the run log on the devbox: `%s`\n' "$LOG" > "$SUMMARY_FILE"
  status="error"
fi

# --- Prometheus textfile metric (node_exporter --collector.textfile). Off-box alert on a FAILED
# *or MISSED* run (DocDriftAudit* in 02-external-alerts.yaml). success-ts stamped only on rc==0; the
# prior marker is preserved on failure so a fail can't refresh the staleness clock. ---
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
  chmod 0644 "$tmp"   # mktemp makes 0600; node_exporter (uid node_exporter) must be able to READ it
  mv -f "$tmp" "$prom"
  echo "[metric] wrote $prom (rc=$rc)" >>"$LOG"
else
  echo "[metric] $TEXTFILE_DIR missing/unwritable — skipped textfile metric (run base.yml on devbox)" | tee -a "$LOG"
fi

# --- WRAPPER owns git: stage ONLY doc paths (the agent has no git), flag any non-doc modification
# as a write-boundary violation (injection signal), secret-scan the staged diff, then commit+push. ---
commit_doc_fixes() {
  local f doc=() nondoc=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      docs/*|CLAUDE.md|README.md|*/README.md) doc+=("$f") ;;
      *) nondoc+=("$f") ;;
    esac
  done < <(git status --porcelain --untracked-files=all | cut -c4-)

  if [ "${#nondoc[@]}" -gt 0 ]; then
    echo "[git] ⚠ write-boundary: agent touched NON-doc paths — NOT committing them:" | tee -a "$LOG"
    printf '   %s\n' "${nondoc[@]}" | tee -a "$LOG"
  fi
  [ "${#doc[@]}" -eq 0 ] && { echo "[git] no doc changes to commit" >>"$LOG"; return 0; }

  local p; for p in "${doc[@]}"; do git add -- "$p" 2>>"$LOG" || true; done
  git diff --cached --quiet && { echo "[git] nothing staged" >>"$LOG"; return 0; }

  if git diff --cached | grep -aEq "$SECRET_RE"; then
    echo "[security] ⚠ staged doc diff matched a secret pattern — ABORTING commit/push" | tee -a "$LOG"
    git reset -q; return 0
  fi
  git commit -q -m "docs: weekly doc/IaC drift audit auto-fixes

Automated doc fixes from the weekly live-anchored audit (committed by the wrapper, not the agent).
Details: the doc-drift GitHub issue + ~/.local/state/doc-drift-audit/ on the devbox.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" >>"$LOG" 2>&1
  git pull --rebase origin main >>"$LOG" 2>&1 || true
  if git push origin main >>"$LOG" 2>&1; then
    echo "[git] pushed doc fixes (${#doc[@]} file(s))" | tee -a "$LOG"
  else
    echo "[git] push FAILED — see log" | tee -a "$LOG"
  fi
}
commit_doc_fixes

# --- Publish to the doc-drift GitHub issue (WRAPPER dispatches via the helper; AUDIT_WRAPPER=1
# unlocks the helper's POST path, which the scoped agent cannot set). ---
if [ "$status" = drift ] && [ -s "$SUMMARY_FILE" ]; then
  AUDIT_WRAPPER=1 "$HELPER" dispatch-issue drift "$SUMMARY_FILE" >>"$LOG" 2>&1 \
    && echo "[issue] posted doc-drift issue" | tee -a "$LOG" || echo "[issue] dispatch failed" | tee -a "$LOG"
else
  AUDIT_WRAPPER=1 "$HELPER" dispatch-issue clean >>"$LOG" 2>&1 \
    && echo "[issue] clean — closed any open doc-drift issue" | tee -a "$LOG" || echo "[issue] dispatch failed" | tee -a "$LOG"
fi

# --- Email the summary EVERY run (clean or drift) via SES SMTP (creds from the alertmanager SOPS
# secret — the devbox has no in-cluster IRSA). Best-effort: a send failure never fails the audit. ---
email_summary() {
  local sec creds subject body tmpbody=""
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
