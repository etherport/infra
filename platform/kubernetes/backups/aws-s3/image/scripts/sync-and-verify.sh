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
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; }
  .header { background: #dc3545; color: white; padding: 20px; border-radius: 8px 8px 0 0; margin: -20px -20px 20px -20px; }
  .header h1 { margin: 0; font-size: 24px; }
  .status { display: inline-block; background: #721c24; color: white; padding: 4px 12px; border-radius: 4px; font-size: 14px; font-weight: bold; margin-top: 8px; }
  .info-grid { display: grid; grid-template-columns: 140px 1fr; gap: 12px; margin: 20px 0; padding: 20px; background: #f8f9fa; border-radius: 8px; }
  .info-label { font-weight: 600; color: #666; }
  .info-value { color: #333; font-family: 'SF Mono', Consolas, monospace; font-size: 13px; }
  .section { margin: 24px 0; }
  .section-title { font-size: 16px; font-weight: 600; color: #495057; margin-bottom: 12px; border-bottom: 2px solid #dee2e6; padding-bottom: 8px; }
  .log-box { background: #2d2d2d; color: #f8f8f2; padding: 16px; border-radius: 6px; overflow-x: auto; font-family: 'SF Mono', Consolas, monospace; font-size: 12px; line-height: 1.5; }
  .reason-box { background: #f8d7da; border-left: 4px solid #dc3545; padding: 16px; border-radius: 4px; margin: 20px 0; }
  .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #dee2e6; font-size: 12px; color: #6c757d; }
</style>
</head>
<body>
  <div class="header">
    <h1>⚠️ Backup Failure</h1>
    <div class="status">FAILED</div>
  </div>

  <div class="reason-box">
    <strong>Failure Reason:</strong><br>
    REASON_PLACEHOLDER
  </div>

  <div class="info-grid">
    <div class="info-label">Share:</div><div class="info-value">SHARE_PLACEHOLDER</div>
    <div class="info-label">Run ID:</div><div class="info-value">RUN_ID_PLACEHOLDER</div>
    <div class="info-label">Started:</div><div class="info-value">START_PLACEHOLDER</div>
    <div class="info-label">Duration:</div><div class="info-value">DURATION_PLACEHOLDER</div>
    <div class="info-label">Source:</div><div class="info-value">SOURCE_PLACEHOLDER</div>
    <div class="info-label">Destination:</div><div class="info-value">DEST_PLACEHOLDER</div>
  </div>

  <div class="section">
    <div class="section-title">Error Output</div>
    <div class="log-box">ERROR_LOG_PLACEHOLDER</div>
  </div>

  <div class="section">
    <div class="section-title">Sync Output</div>
    <div class="log-box">SYNC_LOG_PLACEHOLDER</div>
  </div>

  <div class="footer">
    Sequoia NAS → AWS S3 Backup System<br>
    Report generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
  </div>
</body>
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

  HTML_BODY="$html_body" EMAIL_SUBJECT="${subject}" EMAIL_FROM_NAME="${EMAIL_FROM_NAME}" EMAIL_FROM="${EMAIL_FROM}" EMAIL_TO="${EMAIL_TO}" "${SEND_EMAIL_SCRIPT}" --html \
      || echo "[email] WARN: failed to send failure email" >&2
}

# Distributed lock using Kubernetes ConfigMap to prevent concurrent job execution
# for the same share (prevents both CronJob overlap AND manual job conflicts)
LOCK_NAME="aws-s3-sync-lock-${SHARE_NAME}"
LOCK_NAMESPACE="${LOCK_NAMESPACE:-backups}"
LOCK_MAX_AGE_SECONDS=86400  # 24 hours - consider lock stale after this

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

# Acquire distributed lock to prevent concurrent executions
acquire_lock

echo "=== [$RUN_ID] Dry-run to detect uploads/updates ==="
# Dry-run is informational only; we build the manifest from the REAL sync output.
# Uses retry logic for transient network failures (configured via SYNC_MAX_RETRIES)
run_sync_with_retry "${DRYRUN_OUT}" "true" "${EXCLUDE_ARGS[@]}"
DRYRUN_RC=$?

if [[ ${DRYRUN_RC} -ne 0 ]]; then
  echo "Dry-run failed with exit code ${DRYRUN_RC}" | tee -a "${ERROR_FILE}"
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
set -euo pipefail

BUCKET="$1"
KEY="$2"
OUTPUT_DIR="$3"
REGION="$4"

# Create safe filename for output (hash of bucket:key)
HASH=$(echo -n "${BUCKET}:${KEY}" | md5sum | awk '{print $1}')
RESULT_FILE="${OUTPUT_DIR}/${HASH}.json"

# Try to get object metadata with checksum enabled
if aws s3api head-object \
    --bucket "${BUCKET}" \
    --key "${KEY}" \
    --checksum-mode ENABLED \
    --region "${REGION}" \
    --output json 2>/dev/null > "${RESULT_FILE}.tmp"; then

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
  rm -f "${RESULT_FILE}.tmp"

else
  # Failed - file doesn't exist or error occurred
  jq -cn \
    --arg bucket "${BUCKET}" \
    --arg key "${KEY}" \
    '{
      bucket: $bucket,
      key: $key,
      status: "failed",
      error_code: "NoSuchKey",
      error_message: "HeadObject failed - object may not exist or is inaccessible"
    }' > "${RESULT_FILE}"
  rm -f "${RESULT_FILE}.tmp"
fi
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

def calculate_composite_checksum(file_path, part_size_mb=8):
    """Calculate S3-compatible composite checksum for multipart upload."""
    part_size = part_size_mb * 1024 * 1024
    part_hashes = []

    with open(file_path, 'rb') as f:
        while True:
            chunk = f.read(part_size)
            if not chunk:
                break
            part_hash = hashlib.sha256(chunk).digest()
            part_hashes.append(part_hash)

    if len(part_hashes) <= 1:
        # Single part - return simple hash
        return None

    composite_hash = hashlib.sha256(b''.join(part_hashes)).digest()
    return composite_hash.hex()

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
                            composite_source = calculate_composite_checksum(local_path)
                            if composite_source:
                                checksum_match = (composite_source == s3_sha256)
                                if not checksum_match:
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
elif files_verified == 0 and total_files > 0:
    # Files were transferred but verification produced no results
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
    local subject="${EMAIL_SUBJECT} (DEGRADED: ${SHARE_NAME})"
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
      echo "Summary (S3):   ${RUN_SUMMARY_URI}"
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
