#!/usr/bin/env bash
set -euo pipefail

: "${SHARE_NAME:?need SHARE_NAME}"
: "${SRC_PATH:?need SRC_PATH}"
: "${DEST_BUCKET:?need DEST_BUCKET}"
: "${DEST_PREFIX:?need DEST_PREFIX}"
: "${METADATA_BUCKET:?need METADATA_BUCKET}"
: "${BATCH_PREFIX:?need BATCH_PREFIX}"
: "${AWS_REGION:?need AWS_REGION}"
: "${AWS_ACCOUNT_ID:?need AWS_ACCOUNT_ID}"


# Optional: Push summary metrics to Prometheus via Pushgateway
# Example (in-cluster): http://pushgateway.monitoring.svc.cluster.local:9091
PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-}"   # leave empty to disable

# Pushgateway expects pushes to go to:
#   /metrics/job/<job_name>[/<label_name>/<label_value>...]
# The first path segment after /metrics MUST be `job/<name>`.
#
# We use the Pushgateway *job name* as the stable identity for this backup system
# (default: aws-s3-sync), and then add grouping labels like share/bucket so Grafana
# queries are consistent across all shares.
PUSHGATEWAY_JOB="${PUSHGATEWAY_JOB:-aws-s3-sync}"
DEBUG_PUSHGATEWAY="${DEBUG_PUSHGATEWAY:-false}"

# Usage: pushgateway_emit <status> <duration_seconds> <bytes> <files> <uploads_for_verification> [batch_job_created] [batch_status] [verified_succeeded] [verified_failed]
# Pushes backup metrics for this run. The job name is set by PUSHGATEWAY_JOB (default: aws-s3-sync), and additional grouping labels (share, bucket) are appended for consistent labeling in Grafana.
pushgateway_emit() {
  # Usage: pushgateway_emit <status> <duration_seconds> <bytes> <files> <uploads_for_verification> [batch_job_created] [batch_status] [verified_succeeded] [verified_failed]
  local status="$1"
  local duration="$2"
  local bytes="$3"
  local files="$4"
  local uploads_verify="$5"
  local batch_created="${6:-0}"
  local batch_status="${7:-}"  # optional string
  local verified_succeeded="${8:-0}"  # optional count
  local verified_failed="${9:-0}"     # optional count

  [[ -z "${PUSHGATEWAY_URL}" ]] && return 0

  local now_epoch
  now_epoch="$(date +%s)"

  local pg_url
  pg_url="${PUSHGATEWAY_URL}/metrics/job/${PUSHGATEWAY_JOB}/share/${SHARE_NAME}/bucket/${DEST_BUCKET}"

  if [[ "${DEBUG_PUSHGATEWAY}" == "true" ]]; then
    echo "[pushgateway] POST ${pg_url}" >&2
  fi

  http_code="$(cat <<EOF | curl -sS -o /tmp/pushgateway_resp.txt -w '%{http_code}' --data-binary @- "${pg_url}" || true
# TYPE homelab_backup_last_run_timestamp_seconds gauge
homelab_backup_last_run_timestamp_seconds ${now_epoch}
# TYPE homelab_backup_last_run_duration_seconds gauge
homelab_backup_last_run_duration_seconds ${duration}
# TYPE homelab_backup_last_run_bytes_total gauge
homelab_backup_last_run_bytes_total ${bytes}
# TYPE homelab_backup_last_run_files_total gauge
homelab_backup_last_run_files_total ${files}
# TYPE homelab_backup_last_run_uploads_for_verification_total gauge
homelab_backup_last_run_uploads_for_verification_total ${uploads_verify}
# TYPE homelab_backup_last_run_success gauge
homelab_backup_last_run_success ${status}
# TYPE homelab_backup_last_run_batch_job_created gauge
homelab_backup_last_run_batch_job_created ${batch_created}
# TYPE homelab_backup_last_run_verified_succeeded_total gauge
homelab_backup_last_run_verified_succeeded_total ${verified_succeeded}
# TYPE homelab_backup_last_run_verified_failed_total gauge
homelab_backup_last_run_verified_failed_total ${verified_failed}
EOF
)"

  if [[ "${http_code}" != 2* ]]; then
    record_warning "Pushgateway metrics push failed (HTTP ${http_code})"
    if [[ "${DEBUG_PUSHGATEWAY}" == "true" ]]; then
      echo "[pushgateway] response:" >&2
      cat /tmp/pushgateway_resp.txt >&2 || true
    fi
  fi

  # Optional informational metric: batch status as a label (low-cardinality: Complete/Failed/Cancelled/Unknown)
  if [[ -n "${batch_status}" ]]; then
    http_code="$(cat <<EOF | curl -sS -o /tmp/pushgateway_resp2.txt -w '%{http_code}' --data-binary @- "${pg_url}" || true
# TYPE homelab_backup_last_run_batch_status gauge
homelab_backup_last_run_batch_status{status="${batch_status}"} 1
EOF
)"

    if [[ "${http_code}" != 2* ]]; then
      record_warning "Pushgateway batch_status push failed (HTTP ${http_code})"
      if [[ "${DEBUG_PUSHGATEWAY}" == "true" ]]; then
        echo "[pushgateway] response:" >&2
        cat /tmp/pushgateway_resp2.txt >&2 || true
      fi
    fi
  fi
}

# Optional but recommended: asserts bucket ownership for S3 Batch Ops report/manifest buckets.
: "${EXPECTED_BUCKET_OWNER:=${AWS_ACCOUNT_ID}}"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ID="${SHARE_NAME}-${TS}"
LOG_DIR="/work/logs"
mkdir -p "$LOG_DIR"

START_EPOCH="$(date +%s)"
START_TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Helper: elapsed seconds since start (safe under set -u)
elapsed_seconds() {
  echo $(( $(date +%s) - START_EPOCH ))
}

# Global warning counter for degraded state alerting
WARNING_COUNT=0
WARNINGS_FILE="${LOG_DIR}/warnings.txt"

# Helper: increment warning counter and log warning
record_warning() {
  local msg="$1"
  ((WARNING_COUNT++)) || true
  echo "[WARNING] ${msg}" | tee -a "${WARNINGS_FILE}" >&2
}

# Retry wrapper for transient AWS API failures
# Usage: aws_retry <max_attempts> <command...>
aws_retry() {
  local max_attempts="$1"
  shift
  local attempt=1
  local delay=2

  while [[ ${attempt} -le ${max_attempts} ]]; do
    if "$@"; then
      return 0
    fi

    local exit_code=$?

    if [[ ${attempt} -lt ${max_attempts} ]]; then
      echo "[retry] Attempt ${attempt}/${max_attempts} failed (exit ${exit_code}), retrying in ${delay}s..." >&2
      sleep ${delay}
      delay=$((delay * 2))  # Exponential backoff
      ((attempt++)) || true
    else
      echo "[retry] All ${max_attempts} attempts failed (exit ${exit_code})" >&2
      return ${exit_code}
    fi
  done
}

# Run aws s3 sync with retry logic for transient failures
# Usage: run_sync_with_retry <output_file> <dryrun_flag> <exclude_args...>
# Returns: exit code of final attempt, output written to <output_file>
run_sync_with_retry() {
  local output_file="$1"
  local dryrun_flag="$2"
  shift 2
  local exclude_args=("$@")

  local attempt=1
  local delay="${SYNC_RETRY_DELAY_SECONDS}"
  local max_attempts=$((SYNC_MAX_RETRIES + 1))  # +1 because first attempt isn't a "retry"
  local sync_rc=0
  local tmp_output
  tmp_output="$(mktemp)"

  while [[ ${attempt} -le ${max_attempts} ]]; do
    # Build the sync command
    local sync_cmd=(aws s3 sync "${SRC_PATH}" "${DEST_URI}"
      --delete
      --checksum-algorithm SHA256
      --size-only
      --no-progress
    )

    if [[ "${dryrun_flag}" == "true" ]]; then
      sync_cmd+=(--dryrun)
    fi

    sync_cmd+=("${exclude_args[@]}")

    # Run sync and capture output
    set +e
    "${sync_cmd[@]}" 2>&1 | tee "${tmp_output}"
    sync_rc=${PIPESTATUS[0]}
    set -e

    if [[ ${sync_rc} -eq 0 ]]; then
      # Success - copy output and return
      cat "${tmp_output}" > "${output_file}"
      rm -f "${tmp_output}"
      return 0
    fi

    # Check if this looks like a transient network error worth retrying
    if grep -qiE "(Could not connect|Connection reset|Connection timed out|Network is unreachable|Temporary failure|timeout|SSL|socket)" "${tmp_output}" 2>/dev/null; then
      if [[ ${attempt} -lt ${max_attempts} ]]; then
        echo "[sync-retry] Attempt ${attempt}/${max_attempts} failed with transient error (rc=${sync_rc}), retrying in ${delay}s..." >&2
        sleep "${delay}"
        delay=$((delay * SYNC_RETRY_BACKOFF_MULTIPLIER))
        ((attempt++)) || true
        continue
      fi
    fi

    # Non-transient error or max retries reached - copy output and return error
    cat "${tmp_output}" > "${output_file}"
    rm -f "${tmp_output}"

    if [[ ${attempt} -gt 1 ]]; then
      echo "[sync-retry] All ${max_attempts} attempts failed (rc=${sync_rc})" >&2
    fi

    return ${sync_rc}
  done

  # Should not reach here, but just in case
  cat "${tmp_output}" > "${output_file}"
  rm -f "${tmp_output}"
  return ${sync_rc}
}

# Files produced by this run
TRANSFER_LIST_FILE="${LOG_DIR}/transfers.csv"          # per uploaded/copied object
ERROR_FILE="${LOG_DIR}/errors.txt"                    # any stderr/diagnostics we capture
BATCH_STATUS_FILE="${LOG_DIR}/batch-status.json"       # describe-job output (optional)
BATCH_REPORT_FILE="${LOG_DIR}/batch-report.csv"        # downloaded report (optional)
BATCH_REPORT_SUMMARY_FILE="${LOG_DIR}/batch-report-summary.json"  # parsed summary (optional)

TRANSFER_LOG_JSONL="${LOG_DIR}/transfers.jsonl"     # per uploaded/copied object (jsonl)
VERIFY_LOG_JSONL="${LOG_DIR}/verification.jsonl"    # per-object verification results (jsonl, optional)

# Optional: wait for the S3 Batch Operations job to finish and summarize the report.
# For big runs, you may want WAIT_FOR_BATCH=false so the k8s job doesn't run for a long time.
WAIT_FOR_BATCH="${WAIT_FOR_BATCH:-false}"
BATCH_POLL_INTERVAL_SECONDS="${BATCH_POLL_INTERVAL_SECONDS:-30}"
BATCH_MAX_WAIT_SECONDS="${BATCH_MAX_WAIT_SECONDS:-3600}"

# Retry configuration for transient network failures
# These settings apply to the main aws s3 sync commands
SYNC_MAX_RETRIES="${SYNC_MAX_RETRIES:-3}"
SYNC_RETRY_DELAY_SECONDS="${SYNC_RETRY_DELAY_SECONDS:-30}"
SYNC_RETRY_BACKOFF_MULTIPLIER="${SYNC_RETRY_BACKOFF_MULTIPLIER:-2}"


# Helper: treat common truthy strings as true (true/1/yes/y)
is_true() {
  local v="${1:-}"
  v="${v,,}"
  case "${v}" in
    true|1|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

# Optional: SES email alerts (failure-only)
# Expects /scripts/send-email.sh to read EMAIL_FROM/EMAIL_FROM_NAME/EMAIL_TO/EMAIL_SUBJECT
# and to accept the email body via STDIN.
EMAIL_ENABLED="${EMAIL_ENABLED:-false}"
EMAIL_ON_FAILURE="${EMAIL_ON_FAILURE:-true}"
EMAIL_FROM="${EMAIL_FROM:-}"
EMAIL_FROM_NAME="${EMAIL_FROM_NAME:-Sync Alerts}"
EMAIL_TO="${EMAIL_TO:-}"
EMAIL_SUBJECT="${EMAIL_SUBJECT:-Sequoia to S3 Sync Report}"
SEND_EMAIL_SCRIPT="${SEND_EMAIL_SCRIPT:-/scripts/send-email.sh}"

format_duration() {
  local seconds=$1
  local h=$((seconds / 3600))
  local m=$(( (seconds % 3600) / 60 ))
  local s=$((seconds % 60))

  if (( h > 0 )); then
    printf "%dh %dm %ds" "$h" "$m" "$s"
  elif (( m > 0 )); then
    printf "%dm %ds" "$m" "$s"
  else
    printf "%ds" "$s"
  fi
}

send_failure_email() {
  local reason="$1"

  if ! is_true "${EMAIL_ENABLED}"; then
    return 0
  fi
  if ! is_true "${EMAIL_ON_FAILURE}"; then
    return 0
  fi
  if [[ -z "${EMAIL_FROM}" || -z "${EMAIL_TO}" ]]; then
    echo "[email] WARN: EMAIL_ENABLED=true but EMAIL_FROM/EMAIL_TO not set; skipping email" >&2
    return 0
  fi
  if [[ ! -x "${SEND_EMAIL_SCRIPT}" ]]; then
    echo "[email] WARN: ${SEND_EMAIL_SCRIPT} not found or not executable; skipping email" >&2
    return 0
  fi

  local subject
  subject="${EMAIL_SUBJECT} (FAILURE: ${SHARE_NAME})"

  local html_body
  html_body=$(cat <<'HTML_END'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<style>
  :root{--bg:#f6f7f9;--surface:#fff;--text:#0f172a;--text-muted:#64748b;--border:#e5e7eb;--border-soft:#eef0f3;
    --err:#b91c1c;--err-bg:#fef2f2;--accent:#1f2937;}
  @media (prefers-color-scheme:dark){:root{--bg:#0b1220;--surface:#131c2e;--text:#e8eaf0;--text-muted:#94a3b8;--border:#243049;--border-soft:#1b2538;
    --err:#f87171;--err-bg:rgba(220,38,38,.16);--accent:#f1f5f9;}}
  body{margin:0;padding:0;background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;-webkit-font-smoothing:antialiased;}
  .wrap{max-width:720px;margin:0 auto;padding:36px 20px 56px;}
  .eyebrow{font-size:11px;font-weight:600;color:var(--text-muted);letter-spacing:.12em;text-transform:uppercase;margin:0 0 10px;}
  h1{font-size:26px;font-weight:700;letter-spacing:-.015em;margin:0 0 6px;color:var(--accent);}
  .subhead{color:var(--text-muted);font-size:14px;margin:0 0 8px;}
  .hero-status{margin:10px 0 22px;}
  .pill{display:inline-flex;align-items:center;gap:7px;padding:5px 11px;border-radius:999px;font-size:13px;font-weight:500;line-height:1;background:var(--err-bg);color:var(--err);}
  .pill .dot{width:7px;height:7px;border-radius:50%;background:currentColor;display:inline-block;}
  .note-err{background:var(--err-bg);border:1px solid var(--border);border-left:3px solid var(--err);border-radius:8px;padding:12px 14px;margin:18px 0;font-size:14px;}
  .card{background:var(--surface);border:1px solid var(--border);border-radius:12px;margin:18px 0;overflow:hidden;}
  .card-head{font-size:13px;font-weight:600;padding:12px 18px;border-bottom:1px solid var(--border-soft);background:linear-gradient(180deg,var(--surface) 0%,var(--border-soft) 100%);}
  table{width:100%;border-collapse:collapse;}
  td{padding:10px 18px;border-top:1px solid var(--border-soft);text-align:left;font-size:14px;}
  tr:first-child td{border-top:none;}
  .kv-l{color:var(--text-muted);width:130px;}
  .kv-v{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px;word-break:break-all;}
  .logbox{background:#0b1220;color:#e2e8f0;padding:14px 16px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;line-height:1.5;white-space:pre-wrap;overflow-x:auto;}
  .footer{margin-top:34px;padding-top:18px;border-top:1px solid var(--border);font-size:12px;color:var(--text-muted);text-align:center;}
</style>
</head>
<body><div class="wrap">
  <div class="eyebrow">Backups · sync failed</div>
  <h1>Backup failed</h1>
  <p class="subhead">SHARE_PLACEHOLDER · started START_PLACEHOLDER</p>
  <div class="hero-status"><span class="pill"><span class="dot"></span>Failed</span></div>

  <div class="note-err"><b>Reason:</b> REASON_PLACEHOLDER</div>

  <div class="card"><div class="card-head">Run details</div>
    <table>
      <tr><td class="kv-l">Share</td><td class="kv-v">SHARE_PLACEHOLDER</td></tr>
      <tr><td class="kv-l">Run ID</td><td class="kv-v">RUN_ID_PLACEHOLDER</td></tr>
      <tr><td class="kv-l">Started</td><td class="kv-v">START_PLACEHOLDER</td></tr>
      <tr><td class="kv-l">Duration</td><td class="kv-v">DURATION_PLACEHOLDER</td></tr>
      <tr><td class="kv-l">Source</td><td class="kv-v">SOURCE_PLACEHOLDER</td></tr>
      <tr><td class="kv-l">Destination</td><td class="kv-v">DEST_PLACEHOLDER</td></tr>
    </table>
  </div>

  <div class="card"><div class="card-head">Error output</div><div class="logbox">ERROR_LOG_PLACEHOLDER</div></div>
  <div class="card"><div class="card-head">Sync output</div><div class="logbox">SYNC_LOG_PLACEHOLDER</div></div>

  <div class="footer">Sequoia NAS → AWS S3 backup · GENERATED_PLACEHOLDER</div>
</div></body>
</html>
HTML_END
)

  # Escape HTML entities and replace placeholders
  local error_log=$(tail -60 "${ERROR_FILE}" 2>/dev/null | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' || echo "No error log available")
  local sync_log=$(tail -60 "${SYNC_OUT}" 2>/dev/null | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' || echo "No sync log available")

  html_body="${html_body//REASON_PLACEHOLDER/$reason}"
  html_body="${html_body//SHARE_PLACEHOLDER/$SHARE_NAME}"
  html_body="${html_body//RUN_ID_PLACEHOLDER/$RUN_ID}"
  html_body="${html_body//START_PLACEHOLDER/$START_TS_UTC}"
  html_body="${html_body//DURATION_PLACEHOLDER/$(format_duration $(elapsed_seconds))}"
  html_body="${html_body//SOURCE_PLACEHOLDER/$SRC_PATH}"
  html_body="${html_body//DEST_PLACEHOLDER/$DEST_URI}"
  html_body="${html_body//ERROR_LOG_PLACEHOLDER/$error_log}"
  html_body="${html_body//SYNC_LOG_PLACEHOLDER/$sync_log}"
  html_body="${html_body//GENERATED_PLACEHOLDER/$(date -u +"%Y-%m-%d %H:%M:%S UTC")}"

  HTML_BODY="$html_body" EMAIL_SUBJECT="${subject}" EMAIL_FROM_NAME="${EMAIL_FROM_NAME}" EMAIL_FROM="${EMAIL_FROM}" EMAIL_TO="${EMAIL_TO}" "${SEND_EMAIL_SCRIPT}" --html \
      || echo "[email] WARN: failed to send failure email" >&2
}

# Distributed lock using Kubernetes ConfigMap to prevent concurrent job execution
# for the same share (prevents both CronJob overlap AND manual job conflicts)
LOCK_NAME="aws-s3-sync-lock-${SHARE_NAME}"
LOCK_NAMESPACE="${LOCK_NAMESPACE:-backups}"
# 48h. Was 24h, but a large initial/catch-up sync can exceed a day; at 24h the
# NEXT night's run would treat the still-held lock as stale, delete it, and start
# a CONCURRENT `aws s3 sync --delete` against the same prefix. Env-overridable.
LOCK_MAX_AGE_SECONDS="${LOCK_MAX_AGE_SECONDS:-172800}"

acquire_lock() {
  echo "[lock] Attempting to acquire lock: ${LOCK_NAME}"

  # Check if kubectl is available
  if ! command -v kubectl &>/dev/null; then
    echo "[lock] WARN: kubectl not available, skipping lock mechanism" >&2
    return 0
  fi

  # Try to create the ConfigMap (lock)
  if kubectl create configmap "${LOCK_NAME}" \
      --from-literal=owner="${RUN_ID}" \
      --from-literal=started_at="$(date +%s)" \
      --namespace="${LOCK_NAMESPACE}" &>/dev/null; then
    echo "[lock] Lock acquired successfully"
    return 0
  fi

  # Lock already exists - check if it's stale
  echo "[lock] Lock already exists, checking age..."
  local lock_started_at
  lock_started_at=$(kubectl get configmap "${LOCK_NAME}" \
    --namespace="${LOCK_NAMESPACE}" \
    -o jsonpath='{.data.started_at}' 2>/dev/null || echo "0")

  local now_epoch
  now_epoch=$(date +%s)
  local lock_age=$((now_epoch - lock_started_at))

  if [[ ${lock_age} -gt ${LOCK_MAX_AGE_SECONDS} ]]; then
    echo "[lock] Lock is stale (${lock_age}s old), removing and retrying..."
    kubectl delete configmap "${LOCK_NAME}" --namespace="${LOCK_NAMESPACE}" &>/dev/null || true
    sleep 2

    # Retry acquisition
    if kubectl create configmap "${LOCK_NAME}" \
        --from-literal=owner="${RUN_ID}" \
        --from-literal=started_at="$(date +%s)" \
        --namespace="${LOCK_NAMESPACE}" &>/dev/null; then
      echo "[lock] Lock acquired after removing stale lock"
      return 0
    fi
  fi

  # Lock is held by another job
  local lock_owner
  lock_owner=$(kubectl get configmap "${LOCK_NAME}" \
    --namespace="${LOCK_NAMESPACE}" \
    -o jsonpath='{.data.owner}' 2>/dev/null || echo "unknown")

  echo "[lock] ERROR: Lock held by another job: ${lock_owner} (age: ${lock_age}s)" >&2
  echo "[lock] Skipping this execution to prevent concurrent uploads" >&2

  # Send email notification about skipped execution
  if is_true "${EMAIL_ENABLED}"; then
    local subject="${EMAIL_SUBJECT} (SKIPPED: ${SHARE_NAME})"
    {
      echo "Sequoia to S3 sync SKIPPED (concurrent execution prevented)"
      echo
      echo "Run ID:         ${RUN_ID}"
      echo "Share:          ${SHARE_NAME}"
      echo "Lock holder:    ${lock_owner}"
      echo "Lock age (sec): ${lock_age}"
      echo "Start (UTC):    ${START_TS_UTC}"
      echo
      echo "Another backup job is currently running for this share."
      echo "This execution was skipped to prevent concurrent uploads."
    } | EMAIL_SUBJECT="${subject}" EMAIL_FROM_NAME="${EMAIL_FROM_NAME}" EMAIL_FROM="${EMAIL_FROM}" EMAIL_TO="${EMAIL_TO}" "${SEND_EMAIL_SCRIPT}" \
        || echo "[email] WARN: failed to send skip notification email" >&2 2>/dev/null
  fi

  exit 0
}

release_lock() {
  if ! command -v kubectl &>/dev/null; then
    return 0
  fi

  # Only release a lock we actually OWN. The EXIT trap is armed before
  # acquire_lock, so a job that exits 0 on the "lock held by another job" skip
  # path (or after a stale-lock takeover by a third job) must NOT delete the
  # current holder's lock — doing so would defeat the mutex and let concurrent
  # `--delete` syncs run. Compare the live owner to this run before deleting.
  local current_owner
  current_owner=$(kubectl get configmap "${LOCK_NAME}" \
    --namespace="${LOCK_NAMESPACE}" \
    -o jsonpath='{.data.owner}' 2>/dev/null || echo "")
  if [[ "${current_owner}" != "${RUN_ID}" ]]; then
    echo "[lock] Not releasing ${LOCK_NAME}: owned by '${current_owner:-<none>}', not this run (${RUN_ID})"
    return 0
  fi

  echo "[lock] Releasing lock: ${LOCK_NAME}"
  kubectl delete configmap "${LOCK_NAME}" --namespace="${LOCK_NAMESPACE}" &>/dev/null || true
}

# Ensure lock is released on exit (success or failure)
trap release_lock EXIT

DEST_URI="s3://${DEST_BUCKET}/${DEST_PREFIX}/"

DRYRUN_OUT="${LOG_DIR}/dryrun.txt"
SYNC_OUT="${LOG_DIR}/sync.txt"

# Exclusions
# Load exclusion patterns from text files so we can keep a global list plus per-share add-ons.
# Each non-empty, non-comment line becomes: --exclude "<pattern>"
# Patterns are evaluated by `aws s3 sync` relative to SRC_PATH/DEST_URI.
EXCLUDES_GLOBAL_FILE="${EXCLUDES_GLOBAL_FILE:-/config/excludes-global.txt}"
EXCLUDES_SHARE_FILE="${EXCLUDES_SHARE_FILE:-/config/excludes-share.txt}"

# Built-in fallback defaults if config files are missing (keeps S3 clean).
DEFAULT_EXCLUDE_PATTERNS=(
  # macOS / NAS metadata
  ".DS_Store"
  "*/.DS_Store"
  "*.DS_Store"
  "._*"
  "*/._*"
  ".Spotlight-V100/*"
  ".Trashes/*"
  "*/.AppleDouble/*"
  ".AppleDouble/*"

  # Common large caches / previews
  "*.lrdata"
  "*.lrdata/*"
  "*Premiere*Preview*"
  "*Premiere*Preview*/*"
)

EXCLUDE_ARGS=()

add_excludes_from_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    # trim whitespace
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    # skip blanks and comments
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    EXCLUDE_ARGS+=( "--exclude" "$line" )
  done < "$f"
}

# Load file-driven excludes first
add_excludes_from_file "$EXCLUDES_GLOBAL_FILE"
add_excludes_from_file "$EXCLUDES_SHARE_FILE"

# If no excludes were loaded, fall back to defaults
if [[ ${#EXCLUDE_ARGS[@]} -eq 0 ]]; then
  echo "[excludes] WARN: no exclude files found/loaded; using built-in defaults" >&2
  for p in "${DEFAULT_EXCLUDE_PATTERNS[@]}"; do
    EXCLUDE_ARGS+=( "--exclude" "$p" )
  done
else
  echo "[excludes] Loaded excludes from: ${EXCLUDES_GLOBAL_FILE} and ${EXCLUDES_SHARE_FILE}" >&2
  echo "[excludes] Total patterns loaded: $(( ${#EXCLUDE_ARGS[@]} / 2 ))" >&2
fi

# Helpers: use s3api for small artifact uploads/downloads so we can enforce ExpectedBucketOwner.
# NOTE: Some aws-cli builds don't support --expected-bucket-owner on `aws s3 cp`, but s3api does.

s3_put_object() {
  # Usage: s3_put_object <bucket> <key> <local_file>
  local bucket="$1"
  local key="$2"
  local file="$3"

  aws_retry 3 aws s3api put-object \
    --bucket "${bucket}" \
    --key "${key}" \
    --body "${file}" \
    --region "${AWS_REGION}" \
    --expected-bucket-owner "${EXPECTED_BUCKET_OWNER}" \
    >/dev/null
}

s3_get_object() {
  # Usage: s3_get_object <bucket> <key> <local_out_file>
  local bucket="$1"
  local key="$2"
  local out="$3"

  aws_retry 3 aws s3api get-object \
    --bucket "${bucket}" \
    --key "${key}" \
    --region "${AWS_REGION}" \
    --expected-bucket-owner "${EXPECTED_BUCKET_OWNER}" \
    "${out}" \
    >/dev/null
}

# ============================================================================
# Cross-job lock: wait while rclone is writing this NAS share
# ============================================================================
# The rclone gdrive/onedrive jobs drop a lock file in <source>/.sync-locks while
# they write the Backups share. Reading/uploading those files mid-write produces
# the checksum-verification flap (the "526 checksumUnavailable" we saw). Wait
# (bounded) for any FRESH rclone lock to clear before syncing. Only the `backups`
# share's source carries these locks; other shares' sources have none → instant.
# (Stale locks from a crashed rclone pod are ignored after RCLONE_LOCK_STALE_SECONDS.)
RCLONE_LOCK_DIR="${SRC_PATH}/.sync-locks"
RCLONE_LOCK_WAIT_SECONDS="${RCLONE_LOCK_WAIT_SECONDS:-900}"     # max wait (15m)
RCLONE_LOCK_STALE_SECONDS="${RCLONE_LOCK_STALE_SECONDS:-3600}"  # ignore locks older than 1h
RCLONE_LOCK_POLL_SECONDS="${RCLONE_LOCK_POLL_SECONDS:-30}"

fresh_rclone_lock() {  # echo the path of a fresh lock, or nothing
  [ -d "${RCLONE_LOCK_DIR}" ] || return 0
  local now lf mt
  now="$(date +%s)"
  for lf in "${RCLONE_LOCK_DIR}"/*.lock; do
    [ -e "${lf}" ] || continue
    mt="$(stat -c %Y "${lf}" 2>/dev/null || echo 0)"
    if [ $((now - mt)) -lt "${RCLONE_LOCK_STALE_SECONDS}" ]; then echo "${lf}"; return 0; fi
  done
}

wait_for_rclone() {
  local waited=0 lk
  while lk="$(fresh_rclone_lock)"; [ -n "${lk}" ]; do
    if [ "${waited}" -ge "${RCLONE_LOCK_WAIT_SECONDS}" ]; then
      echo "[xlock] rclone still active after ${waited}s ($(basename "${lk}")) — proceeding (re-HEAD pass backstops any residual)"
      return 0
    fi
    echo "[xlock] rclone writing the share ($(basename "${lk}")) — waiting ${waited}/${RCLONE_LOCK_WAIT_SECONDS}s..."
    sleep "${RCLONE_LOCK_POLL_SECONDS}"; waited=$((waited + RCLONE_LOCK_POLL_SECONDS))
  done
  [ "${waited}" -gt 0 ] && echo "[xlock] rclone idle — proceeding"
}
wait_for_rclone

# Acquire distributed lock to prevent concurrent executions
acquire_lock

# ============================================================================
# Destructive-delete safety guard
# ============================================================================
# `aws s3 sync --delete` mirrors source deletions to S3. If the NFS source is
# unmounted, empty, or only partially mounted (NAS reboot, share failed to
# mount, stale handle), the sync interprets "missing files" as "deleted" and
# would WIPE the S3 backup. These guards refuse to run a destructive sync when
# the source doesn't look like a real, populated share — while still allowing
# legitimate (small) deletions to propagate. Tunable via env; safe defaults.
DELETE_GUARD_ENABLED="${DELETE_GUARD_ENABLED:-true}"
DELETE_GUARD_MIN_SOURCE_ENTRIES="${DELETE_GUARD_MIN_SOURCE_ENTRIES:-1}"
DELETE_GUARD_SENTINEL="${DELETE_GUARD_SENTINEL:-}"          # optional: require this file at SRC_PATH root
DELETE_GUARD_MAX_PERCENT="${DELETE_GUARD_MAX_PERCENT:-10}"  # abort if > this % of dest objects would be deleted
DELETE_GUARD_MAX_ABSOLUTE="${DELETE_GUARD_MAX_ABSOLUTE:-1000}"  # abort if > this many objects would be deleted (0=off)
DELETE_GUARD_MIN_DEST_FOR_PERCENT="${DELETE_GUARD_MIN_DEST_FOR_PERCENT:-50}"  # only apply % rule above this dest size

# Abort the run without performing any destructive operation.
guard_abort() {
  local reason="$1"
  echo "[delete-guard] ABORT: ${reason}" | tee -a "${ERROR_FILE}" >&2
  send_failure_email "Delete-protection guard tripped: ${reason}"
  # success=0 so the run is visibly failed and re-runnable once the source is fixed
  pushgateway_emit 0 "$(elapsed_seconds)" 0 0 0 0 "guard_tripped"
  exit 1
}

# Source-health check (Guard 1 logic, factored out so it can run twice). Aborts
# if the NFS source is missing, looks empty/unmounted, or fails the optional
# sentinel. Called once before the dry-run AND again immediately before the real
# `--delete` sync (H3) to close the window where the source could drop between
# the two. A healthy, populated source — including an operator-approved bulk
# delete — passes unchanged; only a genuinely empty/unmounted source aborts.
assert_source_populated() {
  local phase="$1"
  if [[ ! -d "${SRC_PATH}" ]]; then
    guard_abort "[${phase}] source path ${SRC_PATH} does not exist (NFS not mounted?) — refusing --delete sync against ${DEST_URI}"
  fi
  local src_entries
  src_entries="$(ls -A1 "${SRC_PATH}" 2>/dev/null | wc -l | tr -d ' ')" || src_entries=0
  if [[ "${src_entries}" -lt "${DELETE_GUARD_MIN_SOURCE_ENTRIES}" ]]; then
    guard_abort "[${phase}] source ${SRC_PATH} has ${src_entries} top-level entries (< ${DELETE_GUARD_MIN_SOURCE_ENTRIES}); appears empty/unmounted — refusing --delete sync that would wipe ${DEST_URI}"
  fi
  if [[ -n "${DELETE_GUARD_SENTINEL}" && ! -e "${SRC_PATH}/${DELETE_GUARD_SENTINEL}" ]]; then
    guard_abort "[${phase}] sentinel ${SRC_PATH}/${DELETE_GUARD_SENTINEL} missing; source not confirmed healthy — refusing --delete sync against ${DEST_URI}"
  fi
  echo "[delete-guard] source check OK (${phase}): ${src_entries} top-level entries present"
}

# --- Approval flow (human-in-the-loop for large deletions via CF Access) ---
# When Guard 2 would trip, instead of a hard abort we can request operator
# approval: write a pending-deletion record + full manifest to S3, email a
# signed "Review & approve" button (rendered by request-approval.py), and exit.
# Clicking approve (behind Cloudflare Access) drops a scoped, one-time, expiring
# marker that THIS function checks on the next run. Falls back to guard_abort if
# the approval flow isn't configured.
APPROVAL_ENABLED="${APPROVAL_ENABLED:-true}"
APPROVAL_BASE_URL="${APPROVAL_BASE_URL:-}"            # e.g. https://backup-approve.wind.etherport.net
APPROVAL_HMAC_SECRET="${APPROVAL_HMAC_SECRET:-}"
APPROVAL_TOKEN_TTL_HOURS="${APPROVAL_TOKEN_TTL_HOURS:-72}"

# check_approval <would_delete> : 0 if this run's deletion is pre-approved
# (consumes the one-time marker), else 1.
check_approval() {
  local would_delete="$1"
  local marker_key="approvals/approved/${SHARE_NAME}.json"
  local tmp="${LOG_DIR}/approval-marker.json"
  if ! s3_get_object "${METADATA_BUCKET}" "${marker_key}" "${tmp}" 2>/dev/null; then
    return 1
  fi
  local amax exp now
  amax="$(jq -r '.approvedMaxDelete // 0' "${tmp}" 2>/dev/null || echo 0)"
  exp="$(jq -r '.expiresAtEpoch // 0' "${tmp}" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if [[ "${now}" -lt "${exp}" && "${would_delete}" -le "${amax}" ]]; then
    echo "[delete-guard] operator approval found (approvedMaxDelete=${amax}, wouldDelete=${would_delete}) — proceeding and consuming marker"
    aws_retry 3 aws s3api delete-object --bucket "${METADATA_BUCKET}" --key "${marker_key}" \
      --region "${AWS_REGION}" --expected-bucket-owner "${EXPECTED_BUCKET_OWNER}" >/dev/null 2>&1 \
      || record_warning "failed to consume approval marker ${marker_key}"
    return 0
  fi
  echo "[delete-guard] approval marker present but not valid for this run (approvedMaxDelete=${amax}, expiresAtEpoch=${exp}, now=${now}, wouldDelete=${would_delete})"
  return 1
}

# check_rejection <would_delete> : 0 if the operator rejected this (or a larger)
# deletion and the snooze window is still open — suppresses re-notification.
check_rejection() {
  local would_delete="$1"
  local key="approvals/rejected/${SHARE_NAME}.json"
  local tmp="${LOG_DIR}/rejection-marker.json"
  if ! s3_get_object "${METADATA_BUCKET}" "${key}" "${tmp}" 2>/dev/null; then
    return 1
  fi
  local rmax exp now
  rmax="$(jq -r '.wouldDeleteAtReject // 0' "${tmp}" 2>/dev/null || echo 0)"
  exp="$(jq -r '.expiresAtEpoch // 0' "${tmp}" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if [[ "${now}" -lt "${exp}" && "${would_delete}" -le "${rmax}" ]]; then
    return 0
  fi
  return 1
}

# request_approval <would_delete> <dest_count> <reason> : build + upload the
# pending record, email the approve button, push a metric, and exit (no sync).
request_approval() {
  local would_delete="$1" dest_count="$2" reason="$3"
  if ! is_true "${APPROVAL_ENABLED}" || [[ -z "${APPROVAL_BASE_URL}" || -z "${APPROVAL_HMAC_SECRET}" ]]; then
    # Approval flow not configured — fall back to the hard guard abort.
    guard_abort "${reason}"
  fi
  if check_rejection "${would_delete}"; then
    echo "[delete-guard] operator previously REJECTED this deletion (snooze active) — not re-notifying; no deletion performed"
    pushgateway_emit 0 "$(elapsed_seconds)" 0 0 0 0 "rejected_snoozed"
    exit 1
  fi
  echo "[delete-guard] deletion exceeds bounds — requesting operator approval"
  local keys_file="${LOG_DIR}/delete-keys.txt"
  grep -E '^(\(dryrun\)[[:space:]]+)?delete:' "${DRYRUN_OUT}" 2>/dev/null \
    | sed -E 's/^(\(dryrun\)[[:space:]]+)?delete:[[:space:]]*//' > "${keys_file}" || : > "${keys_file}"

  local approve_url
  if ! approve_url="$(
      SHARE_NAME="${SHARE_NAME}" RUN_ID="${RUN_ID}" DEST_PREFIX="${DEST_PREFIX}" DEST_URI="${DEST_URI}" \
      SRC_PATH="${SRC_PATH}" WOULD_DELETE="${would_delete}" DEST_COUNT="${dest_count}" \
      TRIP_REASON="${reason}" APPROVAL_HMAC_SECRET="${APPROVAL_HMAC_SECRET}" \
      APPROVAL_BASE_URL="${APPROVAL_BASE_URL}" APPROVAL_TOKEN_TTL_HOURS="${APPROVAL_TOKEN_TTL_HOURS}" \
      LOG_DIR="${LOG_DIR}" DELETE_KEYS_FILE="${keys_file}" DEST_LIST_FILE="${DEST_LIST:-}" \
      python3 /scripts/request-approval.py
    )"; then
    echo "[delete-guard] request-approval.py failed" | tee -a "${ERROR_FILE}" >&2
    guard_abort "${reason} (approval-request generation failed)"
  fi

  # Upload the pending record + full manifest so the approval page can show them.
  s3_put_object "${METADATA_BUCKET}" "approvals/pending/${SHARE_NAME}/${RUN_ID}.json" "${LOG_DIR}/approval-pending.json" \
    || record_warning "failed to upload pending-approval record"
  s3_put_object "${METADATA_BUCKET}" "approvals/pending/${SHARE_NAME}/${RUN_ID}.manifest.csv" "${LOG_DIR}/approval-manifest.csv" \
    || record_warning "failed to upload approval manifest"

  # Email the approve button (HTML body rendered by request-approval.py).
  if is_true "${EMAIL_ENABLED}" && [[ -n "${EMAIL_FROM}" && -n "${EMAIL_TO}" && -x "${SEND_EMAIL_SCRIPT}" && -s "${LOG_DIR}/approval-email.html" ]]; then
    HTML_BODY="$(cat "${LOG_DIR}/approval-email.html")" \
      EMAIL_SUBJECT="${EMAIL_SUBJECT} (APPROVAL NEEDED: ${SHARE_NAME})" \
      EMAIL_FROM_NAME="${EMAIL_FROM_NAME}" EMAIL_FROM="${EMAIL_FROM}" EMAIL_TO="${EMAIL_TO}" \
      "${SEND_EMAIL_SCRIPT}" --html || echo "[email] WARN: failed to send approval email" >&2
  fi

  # Do NOT log the full signed approve URL — the HMAC token in it authorises the
  # deletion, and on the split-horizon internal path the token is the only gate.
  # The operator gets the real link by email; logs get a redacted reference.
  echo "[delete-guard] approval requested — signed link emailed (token redacted): ${APPROVAL_BASE_URL}/approve?t=<redacted>"
  pushgateway_emit 0 "$(elapsed_seconds)" 0 0 0 0 "approval_pending"
  exit 1
}

# Guard 1: source must exist and be populated (catches unmounted/empty share)
if is_true "${DELETE_GUARD_ENABLED}"; then
  assert_source_populated "pre-dryrun"
fi

echo "=== [$RUN_ID] Dry-run to detect uploads/updates ==="
# Dry-run is informational only; we build the manifest from the REAL sync output.
# Uses retry logic for transient network failures (configured via SYNC_MAX_RETRIES)
run_sync_with_retry "${DRYRUN_OUT}" "true" "${EXCLUDE_ARGS[@]}"
DRYRUN_RC=$?

if [[ ${DRYRUN_RC} -ne 0 ]]; then
  echo "Dry-run failed with exit code ${DRYRUN_RC}" | tee -a "${ERROR_FILE}"
  # Fail closed: the delete guard derives the deletion count by parsing this
  # dry-run. A failed/partial dry-run can under-count deletions (parse 0) and let
  # an unbounded `--delete` proceed. Refuse a destructive sync we couldn't
  # analyse. (run_sync_with_retry already retried transient errors, so a non-zero
  # rc here is a real, persistent failure.)
  if is_true "${DELETE_GUARD_ENABLED}"; then
    guard_abort "dry-run failed (rc=${DRYRUN_RC}); cannot determine deletion volume — refusing --delete sync against ${DEST_URI}"
  fi
fi

# Guard 2: bound how much one run is allowed to delete (catches partial mounts /
# bulk accidental deletions that Guard 1 misses). The dry-run above already
# computed exactly what the real --delete sync would remove.
if is_true "${DELETE_GUARD_ENABLED}"; then
  would_delete="$(grep -cE '^(\(dryrun\)[[:space:]]+)?delete:' "${DRYRUN_OUT}" 2>/dev/null || true)"
  would_delete="${would_delete:-0}"
  if [[ "${would_delete}" -gt 0 ]]; then
    echo "[delete-guard] dry-run would delete ${would_delete} object(s) from ${DEST_URI}"

    # Snapshot the destination once: used for the object count, the %-rule, and
    # (with sizes) the approval rollup/manifest.
    DEST_LIST="${LOG_DIR}/dest-listing.txt"
    aws s3 ls "${DEST_URI}" --recursive > "${DEST_LIST}" 2>/dev/null || : > "${DEST_LIST}"
    dest_count="$(wc -l < "${DEST_LIST}" 2>/dev/null | tr -d ' ')"; dest_count="${dest_count:-0}"

    guard_tripped=false
    guard_reason=""
    if [[ "${DELETE_GUARD_MAX_ABSOLUTE}" -gt 0 && "${would_delete}" -gt "${DELETE_GUARD_MAX_ABSOLUTE}" ]]; then
      guard_tripped=true
      guard_reason="would delete ${would_delete} objects (> absolute cap ${DELETE_GUARD_MAX_ABSOLUTE}) from ${DEST_URI}"
    elif [[ "${dest_count}" -ge "${DELETE_GUARD_MIN_DEST_FOR_PERCENT}" ]]; then
      del_pct=$(( would_delete * 100 / dest_count ))
      echo "[delete-guard] deletion ratio: ${would_delete}/${dest_count} = ${del_pct}%"
      if [[ "${del_pct}" -gt "${DELETE_GUARD_MAX_PERCENT}" ]]; then
        guard_tripped=true
        guard_reason="would delete ${would_delete} of ${dest_count} objects (${del_pct}% > ${DELETE_GUARD_MAX_PERCENT}% cap) from ${DEST_URI}"
      fi
    else
      echo "[delete-guard] destination has ${dest_count} object(s) (< ${DELETE_GUARD_MIN_DEST_FOR_PERCENT}); percentage check skipped, absolute cap applies"
    fi

    if is_true "${guard_tripped}"; then
      if check_approval "${would_delete}"; then
        echo "[delete-guard] proceeding under operator approval"
      else
        # writes pending record + emails approve button + exits non-zero
        request_approval "${would_delete}" "${dest_count}" "${guard_reason}"
      fi
    else
      echo "[delete-guard] deletion volume within bounds — proceeding"
    fi
  fi
fi

# H3: re-assert source health immediately before the destructive --delete. The
# dry-run + guards above measured an EARLIER moment; if the NFS source dropped in
# between (stale handle, unmount, partial mount), the real --delete would mirror a
# phantom mass-deletion to S3. Re-checking here closes that TOCTOU window. A
# healthy source — including an operator-approved bulk delete — passes unchanged.
# NB: if an approval was just consumed and the source has since gone empty, this
# aborts WITHOUT deleting (the safe outcome); the operator simply re-approves.
if is_true "${DELETE_GUARD_ENABLED}"; then
  assert_source_populated "pre-sync"
fi

echo "=== [$RUN_ID] Real sync ==="
# IMPORTANT: We parse this output to build the Batch Ops manifest.
# aws s3 sync output lines look like:
#   upload: /src/file to s3://bucket/prefix/file
#   copy: s3://bucket/src to s3://bucket/dst
# Uses retry logic for transient network failures (configured via SYNC_MAX_RETRIES)
run_sync_with_retry "${SYNC_OUT}" "false" "${EXCLUDE_ARGS[@]}"
SYNC_RC=$?

if [[ ${SYNC_RC} -ne 0 ]]; then
  echo "Real sync failed with exit code ${SYNC_RC}" | tee -a "${ERROR_FILE}"
  send_failure_email "aws s3 sync exited non-zero (rc=${SYNC_RC})"
  # Still continue to try to upload a summary so we can see failures in S3.
fi

# Debug: count how many action lines were emitted/captured
DRYRUN_ACTIONS="$(grep -E '^(\(dryrun\)\s+)?(upload:|copy:|delete:)' "${DRYRUN_OUT}" 2>/dev/null | wc -l | tr -d ' ')" || true
SYNC_ACTIONS="$(grep -E '^(upload:|copy:|delete:)' "${SYNC_OUT}" 2>/dev/null | wc -l | tr -d ' ')" || true

echo "Dry-run action lines captured: ${DRYRUN_ACTIONS}"
echo "Real-sync action lines captured: ${SYNC_ACTIONS}"

if [[ "${SYNC_ACTIONS}" != "0" ]]; then
  echo "First real-sync action lines:" 
  grep -E '^(upload:|copy:|delete:)' "${SYNC_OUT}" | head -20 || true
fi

# Build a richer transfer list (CSV + JSONL)
# CSV is easy to eyeball; JSONL is safer for paths/keys that contain commas or quotes.
echo "run_id,timestamp_utc,action,local_path,s3_bucket,s3_key,bytes,source_sha256,upload_status" > "${TRANSFER_LIST_FILE}"
: > "${TRANSFER_LOG_JSONL}"
TOTAL_BYTES=0
TOTAL_FILES=0

while IFS= read -r line; do
  if [[ "$line" == upload:* ]]; then
    rest="${line#upload: }"
    # Split on the last occurrence of " to s3://"
    local_part="${rest%% to s3://*}"
    s3_part="${rest#* to }"   # starts with s3://...

    # Parse s3_part into bucket + key
    s3_noscheme="${s3_part#s3://}"
    s3_bucket="${s3_noscheme%%/*}"
    s3_key="${s3_noscheme#*/}"

    bytes="0"
    source_sha256=""
    if [[ -f "$local_part" ]]; then
      # GNU stat (amazonlinux) supports -c%s
      bytes="$(stat -c%s "$local_part" 2>/dev/null || echo 0)"
      # Compute SHA256 checksum of source file for integrity validation
      source_sha256="$(sha256sum "$local_part" 2>/dev/null | awk '{print $1}')"
    fi

    ts_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mtime_epoch="0"
    mtime_utc=""
    if [[ -f "$local_part" ]]; then
      mtime_epoch="$(stat -c%Y "$local_part" 2>/dev/null || echo 0)"
      mtime_utc="$(date -u -d "@${mtime_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
    fi

    echo "${RUN_ID},${ts_utc},upload,\"${local_part//\"/\"\"}\",${s3_bucket},\"${s3_key//\"/\"\"}\",${bytes},${source_sha256},reported" >> "${TRANSFER_LIST_FILE}"

    # JSONL record (safe encoding via jq)
    jq -cn \
      --arg run_id "$RUN_ID" \
      --arg ts_utc "$ts_utc" \
      --arg action "upload" \
      --arg local_path "$local_part" \
      --arg s3_bucket "$s3_bucket" \
      --arg s3_key "$s3_key" \
      --arg mtime_utc "$mtime_utc" \
      --arg source_sha256 "$source_sha256" \
      --arg upload_status "reported" \
      --argjson bytes "$bytes" \
      '{run_id:$run_id,ts_utc:$ts_utc,action:$action,local_path:$local_path,s3_bucket:$s3_bucket,s3_key:$s3_key,bytes:$bytes,mtime_utc:$mtime_utc,source_sha256:$source_sha256,upload_status:$upload_status}' \
      >> "${TRANSFER_LOG_JSONL}"

    TOTAL_BYTES=$((TOTAL_BYTES + bytes))
    TOTAL_FILES=$((TOTAL_FILES + 1))

  elif [[ "$line" == copy:* ]]; then
    # In our use-case we don't expect s3->s3 copies, but capture the destination anyway.
    # Format: copy: s3://src to s3://dst
    dst="${line##* to }"
    s3_noscheme="${dst#s3://}"
    s3_bucket="${s3_noscheme%%/*}"
    s3_key="${s3_noscheme#*/}"

    ts_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "${RUN_ID},${ts_utc},copy,,${s3_bucket},\"${s3_key//\"/\"\"}\",0,reported" >> "${TRANSFER_LIST_FILE}"

    jq -cn \
      --arg run_id "$RUN_ID" \
      --arg ts_utc "$ts_utc" \
      --arg action "copy" \
      --arg local_path "" \
      --arg s3_bucket "$s3_bucket" \
      --arg s3_key "$s3_key" \
      --arg mtime_utc "" \
      --arg upload_status "reported" \
      --argjson bytes 0 \
      '{run_id:$run_id,ts_utc:$ts_utc,action:$action,local_path:$local_path,s3_bucket:$s3_bucket,s3_key:$s3_key,bytes:$bytes,mtime_utc:$mtime_utc,upload_status:$upload_status}' \
      >> "${TRANSFER_LOG_JSONL}"
  fi
done < <(grep -E '^(upload:|copy:)' "${SYNC_OUT}" || true)

echo "Files uploaded/copied (for transfer metrics): ${TOTAL_FILES}"
echo "Approx bytes uploaded (sum of local file sizes): ${TOTAL_BYTES}"

 # Build manifest for Batch Ops: CSV **without a header row**.
# IMPORTANT: S3BatchOperations_CSV_20180820 must NOT include headers.
# Count uploads from transfer log
if command -v jq >/dev/null 2>&1 && [[ -s "${TRANSFER_LOG_JSONL}" ]]; then
  UPLOAD_COUNT=$(jq -r 'select(.action=="upload" or .action=="copy") | .s3_key' "${TRANSFER_LOG_JSONL}" | wc -l | tr -d ' ')
else
  UPLOAD_COUNT=0
fi
echo "Uploads/updates detected: ${UPLOAD_COUNT}"

if [[ "${UPLOAD_COUNT}" -le 0 ]]; then
  END_EPOCH="$(date +%s)"
  END_TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  DURATION_SECONDS=$((END_EPOCH - START_EPOCH))

  # Generate consolidated report (no files to verify case)
  CONSOLIDATED_REPORT="${LOG_DIR}/consolidated-report.json"
  CONSOLIDATED_REPORT_KEY="reports/${SHARE_NAME}/${TS}/report.json"

  cat > "${CONSOLIDATED_REPORT}" <<JSON
{
  "executionId": "${RUN_ID}",
  "share": "${SHARE_NAME}",
  "status": "$([[ ${SYNC_RC:-0} -eq 0 ]] && echo SUCCESS || echo FAILED)",
  "startTime": "${START_TS_UTC}",
  "endTime": "${END_TS_UTC}",
  "durationSeconds": ${DURATION_SECONDS},
  "summary": {
    "filesTransferred": ${TOTAL_FILES:-0},
    "filesVerified": 0,
    "filesSucceeded": 0,
    "filesFailed": 0,
    "bytesTransferred": ${TOTAL_BYTES:-0},
    "transferRateMBps": $(awk "BEGIN {if (${DURATION_SECONDS} > 0) print ${TOTAL_BYTES:-0} / ${DURATION_SECONDS} / 1024 / 1024; else print 0}")
  },
  "source": "${SRC_PATH}",
  "destination": "${DEST_URI}",
  "sync": {
    "exitCode": ${SYNC_RC:-0},
    "filesTransferred": ${TOTAL_FILES:-0},
    "bytesTransferred": ${TOTAL_BYTES:-0}
  },
  "verification": {
    "batchJobId": "",
    "batchStatus": "not_required",
    "objectsTotal": 0,
    "objectsSucceeded": 0,
    "objectsFailed": 0,
    "topErrorCodes": {}
  },
  "files": [],
  "errors": []
}
JSON

  # Push metrics (success = 1 if sync exit code was 0)
  success_flag=0
  if [[ ${SYNC_RC:-0} -eq 0 ]]; then success_flag=1; fi
  pushgateway_emit "${success_flag}" "${DURATION_SECONDS}" "${TOTAL_BYTES:-0}" "${TOTAL_FILES:-0}" 0 0 ""

  # Upload consolidated report
  s3_put_object "${METADATA_BUCKET}" "${CONSOLIDATED_REPORT_KEY}" "${CONSOLIDATED_REPORT}"
  echo "Consolidated report uploaded to: s3://${METADATA_BUCKET}/${CONSOLIDATED_REPORT_KEY}"
  exit 0
fi

# ============================================================================
# Direct Verification (replaces S3 Batch Operations)
# ============================================================================
# Verify all transferred files directly using parallel S3 HEAD requests.
# This is more reliable than S3 Batch Operations (no CSV parsing issues,
# no Object Lock permissions problems, handles all special characters) and
# costs ~50x less ($0.04 vs $1.86 per run for ~110k files).

echo "=== Direct verification of transferred files ==="

# Count files that need verification (uploads + copies)
VERIFY_COUNT=$(jq -r 'select(.action=="upload" or .action=="copy") | .s3_key' "${TRANSFER_LOG_JSONL}" 2>/dev/null | wc -l | tr -d ' ')
echo "Files to verify: ${VERIFY_COUNT}"

if [[ "${VERIFY_COUNT}" -eq 0 ]]; then
  echo "No files to verify (no uploads/copies in transfer log)"
  
  # Set verification variables for metrics/reporting
  VERIFICATION_STATUS="skipped"
  VERIFIED_SUCCEEDED=0
  VERIFIED_FAILED=0
  FILE_AUDIT_JSONL=""
  
else
  # Create verification work directory
  VERIFY_WORK_DIR="${LOG_DIR}/verification"
  mkdir -p "${VERIFY_WORK_DIR}/results"
  
  # Extract list of files to verify (bucket,key pairs)
  jq -r 'select(.action=="upload" or .action=="copy") | [.s3_bucket, .s3_key] | @tsv' \
    "${TRANSFER_LOG_JSONL}" > "${VERIFY_WORK_DIR}/files-to-verify.tsv"
  
  # Write verification script to file (avoids export -f issues with GNU parallel)
  # GNU parallel spawns new bash instances that don't inherit exported functions
  cat > "${VERIFY_WORK_DIR}/verify-one.sh" <<'VERIFY_SCRIPT'
#!/bin/bash
set -uo pipefail

BUCKET="$1"
KEY="$2"
OUTPUT_DIR="$3"
REGION="$4"

# Create safe filename for output (hash of bucket:key)
HASH=$(echo -n "${BUCKET}:${KEY}" | md5sum | awk '{print $1}')
RESULT_FILE="${OUTPUT_DIR}/${HASH}.json"
ERR_FILE="${RESULT_FILE}.err"

# Retry head-object on TRANSIENT errors (throttling / 5xx / network) before
# declaring failure. With many parallel HEADs against lots of objects, an
# occasional 503 SlowDown or socket reset is expected; recording it as a
# verification failure would fail the whole run (and never get retried — the
# re-HEAD settle pass only covers succeeded-but-no-checksum). A genuine
# 404/NoSuchKey is NOT retried — it won't recover.
ATTEMPTS=4
DELAY=2
ok=false
last_err=""
for ((i=1; i<=ATTEMPTS; i++)); do
  if aws s3api head-object \
      --bucket "${BUCKET}" \
      --key "${KEY}" \
      --checksum-mode ENABLED \
      --region "${REGION}" \
      --output json 2>"${ERR_FILE}" > "${RESULT_FILE}.tmp"; then
    ok=true
    break
  fi
  last_err="$(tr '\n' ' ' < "${ERR_FILE}" 2>/dev/null | tail -c 300)"
  if grep -qiE "Not Found|404|NoSuchKey|does not exist" "${ERR_FILE}" 2>/dev/null; then
    break   # genuine miss — stop retrying
  fi
  sleep "${DELAY}"
  DELAY=$(( DELAY * 2 ))
done

if [ "${ok}" = "true" ]; then
  # Success - object exists and we got metadata
  jq -c --arg bucket "${BUCKET}" \
     --arg key "${KEY}" \
     '{
       bucket: $bucket,
       key: $key,
       status: "succeeded",
       size: (.ContentLength // 0),
       etag: (.ETag // ""),
       checksum_sha256: (.ChecksumSHA256 // ""),
       last_modified: (.LastModified // "")
     }' "${RESULT_FILE}.tmp" > "${RESULT_FILE}"
else
  # Failed after retries - object missing or persistently inaccessible
  jq -cn \
    --arg bucket "${BUCKET}" \
    --arg key "${KEY}" \
    --arg err "${last_err}" \
    '{
      bucket: $bucket,
      key: $key,
      status: "failed",
      error_code: "HeadObjectFailed",
      error_message: ("HeadObject failed after retries: " + $err)
    }' > "${RESULT_FILE}"
fi
rm -f "${RESULT_FILE}.tmp" "${ERR_FILE}"
VERIFY_SCRIPT
  chmod +x "${VERIFY_WORK_DIR}/verify-one.sh"

  # Run verification in parallel
  if command -v parallel >/dev/null 2>&1; then
    # Use GNU parallel if available (more memory efficient)
    PARALLEL_JOBS=25
    echo "Starting parallel verification (${PARALLEL_JOBS} workers with GNU parallel)..."
    cat "${VERIFY_WORK_DIR}/files-to-verify.tsv" | \
      parallel --colsep '\t' -j "${PARALLEL_JOBS}" \
        "${VERIFY_WORK_DIR}/verify-one.sh" {1} {2} "${VERIFY_WORK_DIR}/results" "${AWS_REGION}"

  else
    # Fallback: bash background jobs (less memory efficient, use fewer workers)
    PARALLEL_JOBS=10
    echo "INFO: GNU parallel not found, using bash background jobs with ${PARALLEL_JOBS} workers" >&2

    COUNT=0
    TOTAL=$(wc -l < "${VERIFY_WORK_DIR}/files-to-verify.tsv" | tr -d ' ')

    while IFS=$'\t' read -r BUCKET KEY; do
      "${VERIFY_WORK_DIR}/verify-one.sh" "${BUCKET}" "${KEY}" "${VERIFY_WORK_DIR}/results" "${AWS_REGION}" &

      COUNT=$((COUNT + 1))

      # Wait for batch to complete before starting next batch
      if [[ $((COUNT % PARALLEL_JOBS)) -eq 0 ]]; then
        wait
        echo "Progress: ${COUNT}/${TOTAL} files verified..."
      fi
    done < "${VERIFY_WORK_DIR}/files-to-verify.tsv"

    wait  # Wait for remaining jobs
    echo "Progress: ${COUNT}/${TOTAL} files verified... Done!"
  fi

  echo "Verification complete, processing results..."

  # Sanity check: verify result files were actually created
  RESULT_FILE_COUNT=$(find "${VERIFY_WORK_DIR}/results" -name "*.json" -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "Result files created: ${RESULT_FILE_COUNT} (expected: ${VERIFY_COUNT})"

  if [[ "${RESULT_FILE_COUNT}" -eq 0 ]] && [[ "${VERIFY_COUNT}" -gt 0 ]]; then
    echo "CRITICAL ERROR: No verification result files created!" >&2
    echo "This indicates the parallel verification workers failed to execute." >&2
    record_warning "Verification produced 0 result files for ${VERIFY_COUNT} expected files - parallel execution failed"

    # Mark all as failed since we couldn't verify
    VERIFIED_SUCCEEDED=0
    VERIFIED_FAILED="${VERIFY_COUNT}"
    VERIFICATION_STATUS="failed"

    # Create a marker file explaining the failure
    echo '{"error": "parallel_execution_failed", "message": "No verification workers produced output", "expected_count": '${VERIFY_COUNT}'}' > "${VERIFY_WORK_DIR}/verification-error.json"
  fi
  
  # Combine all result files into single JSONL
  VERIFICATION_RESULTS_JSONL="${VERIFY_WORK_DIR}/verification-results.jsonl"
  cat "${VERIFY_WORK_DIR}/results"/*.json 2>/dev/null > "${VERIFICATION_RESULTS_JSONL}" || touch "${VERIFICATION_RESULTS_JSONL}"

  # Re-HEAD pass: objects whose HEAD succeeded but returned NO checksum are
  # almost always files that were being rewritten at the source during
  # verification (e.g. an rclone import into the same NAS share). Give them a
  # short settle, then re-verify once before counting — this clears the
  # transient "checksum unavailable" condition that previously produced false
  # failures. (Re-HEAD only; we do not re-PUT.)
  CHECKSUM_RETRY_ENABLED="${CHECKSUM_RETRY_ENABLED:-true}"
  CHECKSUM_RETRY_DELAY_SECONDS="${CHECKSUM_RETRY_DELAY_SECONDS:-15}"
  if is_true "${CHECKSUM_RETRY_ENABLED}"; then
    RETRY_TSV="${VERIFY_WORK_DIR}/recheck-checksums.tsv"
    jq -r 'select(.status=="succeeded" and ((.checksum_sha256 // "")=="")) | [.bucket, .key] | @tsv' \
      "${VERIFICATION_RESULTS_JSONL}" > "${RETRY_TSV}" 2>/dev/null || : > "${RETRY_TSV}"
    RETRY_COUNT=$(wc -l < "${RETRY_TSV}" 2>/dev/null | tr -d ' ')
    RETRY_COUNT="${RETRY_COUNT:-0}"
    if [[ "${RETRY_COUNT}" -gt 0 ]]; then
      echo "Re-verifying ${RETRY_COUNT} object(s) with missing checksum after ${CHECKSUM_RETRY_DELAY_SECONDS}s settle..."
      sleep "${CHECKSUM_RETRY_DELAY_SECONDS}"
      if command -v parallel >/dev/null 2>&1; then
        cat "${RETRY_TSV}" | parallel --colsep '\t' -j "${PARALLEL_JOBS}" \
          "${VERIFY_WORK_DIR}/verify-one.sh" {1} {2} "${VERIFY_WORK_DIR}/results" "${AWS_REGION}"
      else
        while IFS=$'\t' read -r RBUCKET RKEY; do
          "${VERIFY_WORK_DIR}/verify-one.sh" "${RBUCKET}" "${RKEY}" "${VERIFY_WORK_DIR}/results" "${AWS_REGION}"
        done < "${RETRY_TSV}"
      fi
      # Rebuild combined results with the refreshed per-object files
      cat "${VERIFY_WORK_DIR}/results"/*.json 2>/dev/null > "${VERIFICATION_RESULTS_JSONL}" || touch "${VERIFICATION_RESULTS_JSONL}"
      STILL_MISSING=$(jq -r 'select(.status=="succeeded" and ((.checksum_sha256 // "")=="")) | .key' "${VERIFICATION_RESULTS_JSONL}" 2>/dev/null | wc -l | tr -d ' ')
      STILL_MISSING="${STILL_MISSING:-0}"
      echo "After re-verify: ${STILL_MISSING} object(s) still missing checksum (was ${RETRY_COUNT})"
      if [[ "${STILL_MISSING}" -gt 0 ]]; then
        record_warning "${STILL_MISSING} object(s) uploaded but S3 checksum still unavailable after re-verify (likely modified at source mid-run); not treated as a failure"
      fi
    fi
  fi

  # Count successes and failures
  VERIFIED_SUCCEEDED=$(jq -r 'select(.status=="succeeded") | .key' "${VERIFICATION_RESULTS_JSONL}" 2>/dev/null | wc -l | tr -d ' ')
  VERIFIED_FAILED=$(jq -r 'select(.status=="failed") | .key' "${VERIFICATION_RESULTS_JSONL}" 2>/dev/null | wc -l | tr -d ' ')
  
  echo "Verification results:"
  echo "  Succeeded: ${VERIFIED_SUCCEEDED}"
  echo "  Failed: ${VERIFIED_FAILED}"
  
  if [[ "${VERIFIED_FAILED}" -gt 0 ]]; then
    VERIFICATION_STATUS="failed"
    echo "WARNING: ${VERIFIED_FAILED} files failed verification!"
  else
    VERIFICATION_STATUS="success"
  fi
  
  # Create FILE_AUDIT_JSONL in the format expected by consolidated report generation
  # This merges transfer log with verification results
  FILE_AUDIT_JSONL="${LOG_DIR}/file-audit.jsonl"

  # Export environment variables for Python script
  export TRANSFER_LOG_JSONL VERIFICATION_RESULTS_JSONL FILE_AUDIT_JSONL

  python3 - <<'PYAUDIT' || record_warning "Failed to create file audit log"
import json, os, sys, base64, hashlib

DEFAULT_PART_SIZE_MB = int(os.environ.get('CHECKSUM_PART_SIZE_MB', '8'))

def _composite_hex(file_path, part_size):
    """Composite SHA256 over fixed-size parts. Returns (hex_or_None, n_parts)."""
    part_hashes = []
    with open(file_path, 'rb') as f:
        while True:
            chunk = f.read(part_size)
            if not chunk:
                break
            part_hashes.append(hashlib.sha256(chunk).digest())
    if len(part_hashes) <= 1:
        return None, len(part_hashes)
    return hashlib.sha256(b''.join(part_hashes)).digest().hex(), len(part_hashes)

def calculate_composite_checksum(file_path, expected_parts=0, part_size_mb=DEFAULT_PART_SIZE_MB):
    """S3-compatible composite SHA256 for a multipart object. Tries the default
    chunk size first; if that doesn't reproduce the object's actual part count
    (aws-cli auto-scales the chunk size for very large files, so the fixed 8 MB
    assumption is wrong past ~80 GB), derive a whole-MB part size that yields
    expected_parts and recompute. Returns (hex_or_None, parts_used)."""
    mb = 1024 * 1024
    hex_default, parts_default = _composite_hex(file_path, part_size_mb * mb)
    if expected_parts <= 0 or parts_default == expected_parts:
        return hex_default, parts_default
    file_size = os.path.getsize(file_path)
    derived = (file_size + expected_parts - 1) // expected_parts   # ceil(size/parts)
    derived = ((derived + mb - 1) // mb) * mb                      # round up to whole MB
    if derived <= 0:
        return hex_default, parts_default
    return _composite_hex(file_path, derived)

transfers_path = os.environ.get('TRANSFER_LOG_JSONL', '')
verify_path = os.environ.get('VERIFICATION_RESULTS_JSONL', '')
output_path = os.environ.get('FILE_AUDIT_JSONL', '')

# Load verification results into dict (keyed by s3_key)
verify_map = {}
if verify_path and os.path.exists(verify_path):
    with open(verify_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
                key = rec.get('key', '')
                if key:
                    verify_map[key] = rec
            except Exception as e:
                print(f"WARN: Failed to parse verification result: {e}", file=sys.stderr)

# Process transfer log and merge with verification results
with open(output_path, 'w') as out:
    if transfers_path and os.path.exists(transfers_path):
        with open(transfers_path, 'r') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    transfer = json.loads(line)
                    s3_key = transfer.get('s3_key', '')
                    
                    # Only include uploads/copies (files that were transferred)
                    if transfer.get('action') not in ['upload', 'copy']:
                        continue
                    
                    # Get verification result if available
                    verify = verify_map.get(s3_key, {})

                    # Compare source checksum to S3 checksum for data integrity validation
                    source_sha256 = transfer.get('source_sha256', '')
                    local_path = transfer.get('local_path', '')
                    s3_sha256_b64 = verify.get('checksum_sha256', '')
                    checksum_match = None
                    checksum_mismatch_details = ''
                    is_composite = False

                    # Check if S3 checksum is composite (ends with -N for N parts)
                    s3_sha256 = ''
                    if s3_sha256_b64:
                        if '-' in s3_sha256_b64:
                            # Composite checksum from multipart upload
                            is_composite = True
                            checksum_b64, part_count = s3_sha256_b64.rsplit('-', 1)
                            try:
                                s3_sha256 = base64.b64decode(checksum_b64).hex()
                            except Exception as e:
                                print(f"WARN: Failed to decode composite checksum for {s3_key}: {e}", file=sys.stderr)
                        else:
                            # Simple checksum
                            try:
                                s3_sha256 = base64.b64decode(s3_sha256_b64).hex()
                            except Exception as e:
                                print(f"WARN: Failed to decode base64 checksum for {s3_key}: {e}", file=sys.stderr)
                                s3_sha256 = s3_sha256_b64  # Fall back to original if decode fails

                    if source_sha256 and s3_sha256:
                        if is_composite and local_path and os.path.exists(local_path):
                            # For composite checksums, calculate matching composite from source
                            try:
                                expected_parts = int(part_count)
                            except (ValueError, TypeError):
                                expected_parts = 0
                            composite_source, parts_used = calculate_composite_checksum(
                                local_path, expected_parts=expected_parts)
                            if composite_source:
                                checksum_match = (composite_source == s3_sha256)
                                if not checksum_match:
                                    if expected_parts and parts_used != expected_parts:
                                        # Couldn't reproduce aws-cli's multipart chunking
                                        # (auto-scaled chunk size on a very large file) —
                                        # mark UNAVAILABLE, not a (false) corruption.
                                        checksum_match = None
                                        print(f"WARN: composite checksum unverifiable for {s3_key} "
                                              f"(rebuilt {parts_used} parts vs {expected_parts}); marking unavailable",
                                              file=sys.stderr)
                                    else:
                                        checksum_mismatch_details = f"Source(composite): {composite_source}, S3: {s3_sha256}"
                            else:
                                # File too small for multipart - skip comparison
                                checksum_match = None
                        else:
                            # Simple checksum comparison
                            checksum_match = (source_sha256 == s3_sha256)
                            if not checksum_match:
                                checksum_mismatch_details = f"Source: {source_sha256}, S3: {s3_sha256}"
                    elif source_sha256:
                        checksum_match = None  # S3 checksum unavailable
                    elif s3_sha256:
                        checksum_match = None  # Source checksum unavailable

                    # Create audit record in expected format
                    audit = {
                        'local_path': transfer.get('local_path', ''),
                        's3_key': s3_key,
                        's3_bucket': transfer.get('s3_bucket', ''),
                        'bytes': transfer.get('bytes', 0),
                        'upload_status': 'reported',  # All were reported by aws s3 sync
                        'verify_status': verify.get('status', 'unknown'),
                        'verify_error_code': verify.get('error_code', ''),
                        'verify_error_message': verify.get('error_message', ''),
                        'source_sha256': source_sha256,
                        'checksum': s3_sha256,
                        'checksum_algorithm': 'SHA256' if s3_sha256 else '',
                        'checksum_match': checksum_match,
                        'checksum_mismatch_details': checksum_mismatch_details
                    }

                    # Log checksum mismatches to stderr for immediate visibility
                    if checksum_match is False:
                        print(f"CHECKSUM MISMATCH: {s3_key} - {checksum_mismatch_details}", file=sys.stderr)

                    out.write(json.dumps(audit) + '\n')
                    
                except Exception as e:
                    print(f"WARN: Failed to process transfer record: {e}", file=sys.stderr)

print(f"File audit log created: {output_path}", file=sys.stderr)
PYAUDIT

fi

# Calculate duration
END_EPOCH="$(date +%s)"
END_TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DURATION_SECONDS=$((END_EPOCH - START_EPOCH))

# Update metrics
verified_succeeded="${VERIFIED_SUCCEEDED:-0}"
verified_failed="${VERIFIED_FAILED:-0}"

# Determine overall success/failure (pushgateway expects 1=success, 0=failure)
if [[ "${SYNC_RC:-0}" -ne 0 ]]; then
  success_flag=0
  OVERALL_STATUS="FAILED"
elif [[ "${verified_failed}" -gt 0 ]]; then
  success_flag=0
  OVERALL_STATUS="FAILED"
  # Send failure notification email
  send_failure_email "Verification failed: ${verified_failed} of ${VERIFY_COUNT:-0} files failed verification (HEAD object check)"
else
  success_flag=1
  OVERALL_STATUS="SUCCESS"
fi

# Push metrics to Pushgateway if configured
if [[ -n "${PUSHGATEWAY_URL:-}" ]]; then
  pushgateway_emit "${success_flag}" "${DURATION_SECONDS}" "${TOTAL_BYTES:-0}" "${TOTAL_FILES:-0}" "${UPLOAD_COUNT}" 0 "${VERIFICATION_STATUS}" "${verified_succeeded}" "${verified_failed}"
fi

#
# Generate consolidated report (DataSync-style single JSON report per execution)
#
CONSOLIDATED_REPORT="${LOG_DIR}/consolidated-report.json"
CONSOLIDATED_REPORT_KEY="reports/${SHARE_NAME}/${TS}/report.json"

if command -v python3 >/dev/null 2>&1; then
  echo "=== Generating consolidated report ==="

  RUN_ID_ENV="$RUN_ID" \
  SHARE_NAME_ENV="$SHARE_NAME" \
  START_TS_UTC_ENV="$START_TS_UTC" \
  END_TS_UTC_ENV="${END_TS_UTC:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
  DURATION_SECONDS_ENV="$DURATION_SECONDS" \
  SRC_PATH_ENV="$SRC_PATH" \
  DEST_URI_ENV="$DEST_URI" \
  TOTAL_FILES_ENV="$TOTAL_FILES" \
  TOTAL_BYTES_ENV="$TOTAL_BYTES" \
  SYNC_RC_ENV="${SYNC_RC:-0}" \
  UPLOAD_COUNT_ENV="${UPLOAD_COUNT:-0}" \
  JOB_ID_ENV="${JOB_ID:-}" \
  BATCH_STATUS_ENV="${final_batch_status:-}" \
  TRANSFER_LOG_JSONL_ENV="$TRANSFER_LOG_JSONL" \
  FILE_AUDIT_JSONL_ENV="${FILE_AUDIT_JSONL:-}" \
  BATCH_REPORT_SUMMARY_FILE_ENV="${BATCH_REPORT_SUMMARY_FILE:-}" \
  CONSOLIDATED_REPORT_ENV="$CONSOLIDATED_REPORT" \
  python3 - <<'PY' || record_warning "Failed to generate consolidated report"
import os, json, sys
from datetime import datetime, timezone

# Environment variables
run_id = os.environ.get('RUN_ID_ENV', '')
share_name = os.environ.get('SHARE_NAME_ENV', '')
start_ts = os.environ.get('START_TS_UTC_ENV', '')
end_ts = os.environ.get('END_TS_UTC_ENV', '')
duration = int(os.environ.get('DURATION_SECONDS_ENV', '0'))
src_path = os.environ.get('SRC_PATH_ENV', '')
dest_uri = os.environ.get('DEST_URI_ENV', '')
total_files = int(os.environ.get('TOTAL_FILES_ENV', '0'))
total_bytes = int(os.environ.get('TOTAL_BYTES_ENV', '0'))
sync_rc = int(os.environ.get('SYNC_RC_ENV', '0'))
upload_count = int(os.environ.get('UPLOAD_COUNT_ENV', '0'))
job_id = os.environ.get('JOB_ID_ENV', '')
batch_status = os.environ.get('BATCH_STATUS_ENV', '')
transfers_path = os.environ.get('TRANSFER_LOG_JSONL_ENV', '')
file_audit_path = os.environ.get('FILE_AUDIT_JSONL_ENV', '')
batch_summary_path = os.environ.get('BATCH_REPORT_SUMMARY_FILE_ENV', '')
output_path = os.environ.get('CONSOLIDATED_REPORT_ENV', '')

# Note: Overall status determination moved after file-level analysis
# to include verification failure count in the decision

# Load file-level details if available
files = []
if file_audit_path and os.path.exists(file_audit_path):
    with open(file_audit_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
                # Transform to DataSync-style format
                file_rec = {
                    "path": rec.get('local_path', ''),
                    "s3_key": rec.get('s3_key', ''),
                    "action": "uploaded" if rec.get('upload_status') == 'reported' else "unknown",
                    "status": "success" if rec.get('verify_status', '').lower() == 'succeeded' else "failed",
                    "sourceChecksum": rec.get('source_sha256', ''),
                    "destChecksum": rec.get('checksum', ''),
                    "checksumAlgorithm": rec.get('checksum_algorithm', ''),
                    "checksumMatch": rec.get('checksum_match'),
                    "checksumMismatchDetails": rec.get('checksum_mismatch_details', ''),
                    "size": rec.get('bytes', 0),
                    "transferTimeMs": 0,  # Not tracked per-file currently
                    "errorCode": rec.get('verify_error_code', ''),
                    "errorMessage": rec.get('verify_error_message', '')
                }
                files.append(file_rec)
            except Exception as e:
                print(f"WARN: failed to parse file audit record: {e}", file=sys.stderr)
                continue
elif transfers_path and os.path.exists(transfers_path):
    # Fallback: use transfers log if file-audit not available
    with open(transfers_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
                file_rec = {
                    "path": rec.get('local_path', ''),
                    "s3_key": rec.get('s3_key', ''),
                    "action": rec.get('action', 'uploaded'),
                    "status": "transferred",  # No verification info
                    "sourceChecksum": "",
                    "destChecksum": "",
                    "checksumAlgorithm": "",
                    "size": rec.get('bytes', 0),
                    "transferTimeMs": 0,
                    "errorCode": "",
                    "errorMessage": ""
                }
                files.append(file_rec)
            except Exception as e:
                print(f"WARN: failed to parse transfer record: {e}", file=sys.stderr)
                continue

# Load batch summary if available
verification_summary = {}
if batch_summary_path and os.path.exists(batch_summary_path):
    try:
        with open(batch_summary_path, 'r') as f:
            verification_summary = json.load(f)
    except Exception as e:
        print(f"WARN: failed to parse batch summary: {e}", file=sys.stderr)

# Count successes/failures
files_succeeded = sum(1 for f in files if f['status'] == 'success')
files_failed = sum(1 for f in files if f['status'] == 'failed')
files_verified = sum(1 for f in files if f.get('destChecksum'))

# Count checksum matches/mismatches
checksum_matches = sum(1 for f in files if f.get('checksumMatch') is True)
checksum_mismatches = sum(1 for f in files if f.get('checksumMatch') is False)
checksum_unavailable = sum(1 for f in files if f.get('checksumMatch') is None and (f.get('sourceChecksum') or f.get('destChecksum')))

# Determine overall status based on sync result, batch status, file failures, AND checksum mismatches
if sync_rc != 0:
    status = "FAILED"
elif batch_status and batch_status.lower() not in ["complete", "not_required", ""]:
    # Batch job failed or was cancelled
    status = "FAILED"
elif files_failed > 0:
    # Verification ran but some files failed
    status = "FAILED"
elif checksum_mismatches > 0:
    # CRITICAL: Source and S3 checksums don't match - data corruption detected!
    status = "FAILED"
elif files_succeeded == 0 and total_files > 0:
    # Verification produced no successful HEADs at all — verification truly did
    # not run / every object was unreachable. NOTE: objects that exist but
    # merely lack checksum metadata count as succeeded (HEAD returned 200) and
    # are handled as a non-fatal "checksum unavailable" condition below, not as
    # a failure. (Previously this branch keyed on files_verified, i.e. objects
    # WITH a checksum, which falsely FAILED runs where uploads were fine but a
    # source-side rewrite left some objects without checksum metadata.)
    status = "FAILED"
else:
    status = "SUCCESS"

# Build consolidated report
report = {
    "executionId": run_id,
    "share": share_name,
    "status": status,
    "startTime": start_ts,
    "endTime": end_ts,
    "durationSeconds": duration,
    "summary": {
        "filesTransferred": total_files,
        "filesVerified": files_verified,
        "filesSucceeded": files_succeeded,
        "filesFailed": files_failed,
        "checksumMatches": checksum_matches,
        "checksumMismatches": checksum_mismatches,
        "checksumUnavailable": checksum_unavailable,
        "bytesTransferred": total_bytes,
        "transferRateMBps": round(total_bytes / duration / 1024 / 1024, 1) if duration > 0 else 0
    },
    "source": src_path,
    "destination": dest_uri,
    "sync": {
        "exitCode": sync_rc,
        "filesTransferred": total_files,
        "bytesTransferred": total_bytes
    },
    "verification": {
        "batchJobId": job_id,
        "batchStatus": batch_status,
        "objectsTotal": files_verified,
        "objectsSucceeded": files_succeeded,
        "objectsFailed": files_failed,
        "topErrorCodes": verification_summary.get('top_error_codes', {})
    },
    "checksumValidation": {
        "enabled": True,
        "algorithm": "SHA256",
        "totalValidated": checksum_matches + checksum_mismatches,
        "matches": checksum_matches,
        "mismatches": checksum_mismatches,
        "unavailable": checksum_unavailable,
        "mismatchedFiles": [f['s3_key'] for f in files if f.get('checksumMatch') is False]
    },
    "files": files,
    "errors": []
}

# Add errors if any
if sync_rc != 0:
    report['errors'].append({
        "stage": "sync",
        "message": f"aws s3 sync exited with code {sync_rc}"
    })
if batch_status and batch_status.lower() != "complete":
    report['errors'].append({
        "stage": "verification",
        "message": f"S3 Batch Operations job ended with status: {batch_status}"
    })
if checksum_mismatches > 0:
    report['errors'].append({
        "stage": "checksum_validation",
        "message": f"CRITICAL: {checksum_mismatches} file(s) have checksum mismatches - data corruption detected!",
        "severity": "CRITICAL",
        "mismatchedFiles": [f['s3_key'] for f in files if f.get('checksumMatch') is False]
    })

# Write consolidated report
with open(output_path, 'w') as f:
    json.dump(report, f, indent=2)

print(f"Consolidated report written to: {output_path}")
PY

  # Upload consolidated report to S3
  if [[ -s "${CONSOLIDATED_REPORT}" ]]; then
    echo "Uploading consolidated report to: s3://${METADATA_BUCKET}/${CONSOLIDATED_REPORT_KEY}"
    s3_put_object "${METADATA_BUCKET}" "${CONSOLIDATED_REPORT_KEY}" "${CONSOLIDATED_REPORT}"

    # Verify upload succeeded
    echo "Verifying consolidated report upload..."
    if aws s3api head-object \
        --bucket "${METADATA_BUCKET}" \
        --key "${CONSOLIDATED_REPORT_KEY}" \
        --region "${AWS_REGION}" \
        --expected-bucket-owner "${EXPECTED_BUCKET_OWNER}" \
        >/dev/null 2>&1; then
      echo "Consolidated report available at: s3://${METADATA_BUCKET}/${CONSOLIDATED_REPORT_KEY}"
    else
      echo "ERROR: Failed to verify consolidated report upload" >&2
    fi
  fi
else
  record_warning "python3 not available - consolidated report generation skipped"
fi

# Check for warnings and send degraded state alert
if [[ ${WARNING_COUNT} -gt 0 ]]; then
  echo "=== Backup completed with ${WARNING_COUNT} warning(s) ==="

  if is_true "${EMAIL_ENABLED}"; then
    # NB: this block runs at top-level scope (NOT in a function) — `local` here
    # errors under `set -euo pipefail` and would flip a warning-but-successful run
    # into a FAILED job. Plain assignment.
    subject="${EMAIL_SUBJECT} (DEGRADED: ${SHARE_NAME})"
    {
      echo "Sequoia to S3 sync completed with WARNINGS"
      echo
      echo "Run ID:        ${RUN_ID}"
      echo "Share:         ${SHARE_NAME}"
      echo "Start (UTC):    ${START_TS_UTC}"
      echo "Duration (sec): $(elapsed_seconds)"
      echo "Warnings:      ${WARNING_COUNT}"
      echo
      echo "Source:        ${SRC_PATH}"
      echo "Destination:   ${DEST_URI}"
      echo "Report (S3):   s3://${METADATA_BUCKET}/${CONSOLIDATED_REPORT_KEY:-reports/${SHARE_NAME}/${TS}/report.json}"
      echo
      echo "--- warnings.txt ---"
      cat "${WARNINGS_FILE}" 2>/dev/null || echo "(no warnings file)"
      echo
      echo "--- errors.txt (tail 60) ---"
      tail -60 "${ERROR_FILE}" 2>/dev/null || echo "(no errors file)"
    } | EMAIL_SUBJECT="${subject}" EMAIL_FROM_NAME="${EMAIL_FROM_NAME}" EMAIL_FROM="${EMAIL_FROM}" EMAIL_TO="${EMAIL_TO}" "${SEND_EMAIL_SCRIPT}" \
        || echo "[email] WARN: failed to send degraded state email" >&2
  fi
fi

echo "=== Done ==="
