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

: "${S3_BATCH_ROLE_ARN:?need S3_BATCH_ROLE_ARN}"

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

# Usage: pushgateway_emit <status> <duration_seconds> <bytes> <files> <uploads_for_verification> [batch_job_created] [batch_status]
# Pushes backup metrics for this run. The job name is set by PUSHGATEWAY_JOB (default: aws-s3-sync), and additional grouping labels (share, bucket) are appended for consistent labeling in Grafana.
pushgateway_emit() {
  # Usage: pushgateway_emit <status> <duration_seconds> <bytes> <files> <uploads_for_verification> [batch_job_created] [batch_status]
  local status="$1"
  local duration="$2"
  local bytes="$3"
  local files="$4"
  local uploads_verify="$5"
  local batch_created="${6:-0}"
  local batch_status="${7:-}"  # optional string

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
EOF
)"

  if [[ "${http_code}" != 2* ]]; then
    echo "[pushgateway] WARN: push failed (HTTP ${http_code})" >&2
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
      echo "[pushgateway] WARN: push (batch_status) failed (HTTP ${http_code})" >&2
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

  {
    echo "Sequoia to S3 sync FAILURE"
    echo
    echo "Run ID:        ${RUN_ID}"
    echo "Share:         ${SHARE_NAME}"
    echo "Start (UTC):    ${START_TS_UTC}"
    echo "Elapsed (sec):  $(elapsed_seconds)"
    echo "Reason:        ${reason}"
    echo "Source:        ${SRC_PATH}"
    echo "Destination:   ${DEST_URI}"
    echo "Summary (S3):   ${RUN_SUMMARY_URI}"
    echo
    echo "--- errors.txt (tail 120) ---"
    tail -120 "${ERROR_FILE}" 2>/dev/null || true
    echo
    echo "--- sync.txt (tail 120) ---"
    tail -120 "${SYNC_OUT}" 2>/dev/null || true
  } | EMAIL_SUBJECT="${subject}" EMAIL_FROM_NAME="${EMAIL_FROM_NAME}" EMAIL_FROM="${EMAIL_FROM}" EMAIL_TO="${EMAIL_TO}" "${SEND_EMAIL_SCRIPT}" \
      || echo "[email] WARN: failed to send failure email" >&2
}

DEST_URI="s3://${DEST_BUCKET}/${DEST_PREFIX}/"
MANIFEST_KEY="${BATCH_PREFIX}/manifests/${SHARE_NAME}/${RUN_ID}.csv"
MANIFEST_URI="s3://${METADATA_BUCKET}/${MANIFEST_KEY}"
 # NOTE: no trailing slash to avoid double-slash paths like ...Z//job-...
REPORT_PREFIX="${BATCH_PREFIX}/reports/${SHARE_NAME}/${RUN_ID}"
RUN_SUMMARY_KEY="${BATCH_PREFIX}/runs/${SHARE_NAME}/${RUN_ID}.json"
RUN_SUMMARY_URI="s3://${METADATA_BUCKET}/${RUN_SUMMARY_KEY}"

DRYRUN_OUT="${LOG_DIR}/dryrun.txt"
SYNC_OUT="${LOG_DIR}/sync.txt"
MANIFEST_FILE="${LOG_DIR}/manifest.csv"
SUMMARY_FILE="${LOG_DIR}/summary.json"

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

  aws s3api put-object \
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

  aws s3api get-object \
    --bucket "${bucket}" \
    --key "${key}" \
    --region "${AWS_REGION}" \
    --expected-bucket-owner "${EXPECTED_BUCKET_OWNER}" \
    "${out}" \
    >/dev/null
}

echo "=== [$RUN_ID] Dry-run to detect uploads/updates ==="
# Dry-run is informational only; we build the manifest from the REAL sync output.
set +e
aws s3 sync "${SRC_PATH}" "${DEST_URI}" \
  --delete \
  --checksum-algorithm SHA256 \
  --exact-timestamps \
  --no-progress \
  --dryrun \
  "${EXCLUDE_ARGS[@]}" \
  2>&1 | tee "${DRYRUN_OUT}"
DRYRUN_RC=${PIPESTATUS[0]}
set -e

if [[ ${DRYRUN_RC} -ne 0 ]]; then
  echo "Dry-run failed with exit code ${DRYRUN_RC}" | tee -a "${ERROR_FILE}"
fi

echo "=== [$RUN_ID] Real sync ==="
# IMPORTANT: We parse this output to build the Batch Ops manifest.
# aws s3 sync output lines look like:
#   upload: /src/file to s3://bucket/prefix/file
#   copy: s3://bucket/src to s3://bucket/dst
set +e
aws s3 sync "${SRC_PATH}" "${DEST_URI}" \
  --delete \
  --checksum-algorithm SHA256 \
  --exact-timestamps \
  --no-progress \
  "${EXCLUDE_ARGS[@]}" \
  2>&1 | tee "${SYNC_OUT}"
SYNC_RC=${PIPESTATUS[0]}
set -e

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
echo "run_id,timestamp_utc,action,local_path,s3_bucket,s3_key,bytes,upload_status" > "${TRANSFER_LIST_FILE}"
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
    if [[ -f "$local_part" ]]; then
      # GNU stat (amazonlinux) supports -c%s
      bytes="$(stat -c%s "$local_part" 2>/dev/null || echo 0)"
    fi

    ts_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mtime_epoch="0"
    mtime_utc=""
    if [[ -f "$local_part" ]]; then
      mtime_epoch="$(stat -c%Y "$local_part" 2>/dev/null || echo 0)"
      mtime_utc="$(date -u -d "@${mtime_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
    fi

    echo "${RUN_ID},${ts_utc},upload,\"${local_part//\"/\"\"}\",${s3_bucket},\"${s3_key//\"/\"\"}\",${bytes},reported" >> "${TRANSFER_LIST_FILE}"

    # JSONL record (safe encoding via jq)
    jq -cn \
      --arg run_id "$RUN_ID" \
      --arg ts_utc "$ts_utc" \
      --arg action "upload" \
      --arg local_path "$local_part" \
      --arg s3_bucket "$s3_bucket" \
      --arg s3_key "$s3_key" \
      --arg mtime_utc "$mtime_utc" \
      --arg upload_status "reported" \
      --argjson bytes "$bytes" \
      '{run_id:$run_id,ts_utc:$ts_utc,action:$action,local_path:$local_path,s3_bucket:$s3_bucket,s3_key:$s3_key,bytes:$bytes,mtime_utc:$mtime_utc,upload_status:$upload_status}' \
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
# We include only objects that were uploaded/copied in this run.
: > "${MANIFEST_FILE}"

# Prefer the structured JSONL we generated from aws s3 sync output.
# This also prevents the multi-bucket manifest problem (Batch Ops allows only 1 bucket per job).
if command -v jq >/dev/null 2>&1 && [[ -s "${TRANSFER_LOG_JSONL}" ]]; then
  jq -r --arg b "${DEST_BUCKET}" '
    select(.action=="upload" or .action=="copy")
    | select(.s3_bucket==$b)
    | [.s3_bucket, .s3_key] | @csv
  ' "${TRANSFER_LOG_JSONL}" \
  | sed 's/^"//;s/"$//;s/","/,/' \
  | sort -u \
  >> "${MANIFEST_FILE}" || true
else
  # Fallback: parse sync output directly (best-effort)
  awk -v forced_bucket="${DEST_BUCKET}" '
    /^(upload:|copy:)/ {
      uri="";
      for (i=1; i<=NF; i++) {
        if ($i ~ /^s3:\/\//) { uri=$i }
      }
      if (uri != "") {
        sub(/^s3:\/\//, "", uri);
        n=split(uri, a, "/");
        bucket=a[1];
        key=substr(uri, length(bucket)+2);
        if (key != "") print forced_bucket "," key;
      }
    }
  ' "${SYNC_OUT}" | sort -u >> "${MANIFEST_FILE}" || true
fi

 # No header row => count all non-empty lines
UPLOAD_COUNT="$(awk 'NF {c++} END {print c+0}' "${MANIFEST_FILE}")"
echo "Uploads/updates detected (for checksum job): ${UPLOAD_COUNT}"

if [[ "${UPLOAD_COUNT}" -le 0 ]]; then
  END_EPOCH="$(date +%s)"
  END_TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  DURATION_SECONDS=$((END_EPOCH - START_EPOCH))

  # Generate consolidated report (no files to verify case)
  CONSOLIDATED_REPORT="${LOG_DIR}/consolidated-report.json"
  CONSOLIDATED_REPORT_KEY="${SHARE_NAME}/${TS}/report.json"

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

echo "=== Upload manifest to S3 ==="
s3_put_object "${METADATA_BUCKET}" "${MANIFEST_KEY}" "${MANIFEST_FILE}"

# Need ETag for the manifest object for create-job
MANIFEST_ETAG="$(aws s3api head-object \
  --bucket "${METADATA_BUCKET}" \
  --key "${MANIFEST_KEY}" \
  --expected-bucket-owner "${EXPECTED_BUCKET_OWNER}" \
  --query ETag \
  --output text \
  --region "${AWS_REGION}" | tr -d '"')"

echo "=== Create S3 Batch Operations job: Compute checksum (SHA256 FULL_OBJECT) ==="
JOB_JSON="$(cat <<JSON
{
  "AccountId": "${AWS_ACCOUNT_ID}",
  "Operation": {
    "S3ComputeObjectChecksum": {
      "ChecksumAlgorithm": "SHA256",
      "ChecksumType": "FULL_OBJECT"
    }
  },
  "Manifest": {
    "Spec": {
      "Format": "S3BatchOperations_CSV_20180820",
      "Fields": ["Bucket","Key"]
    },
    "Location": {
      "ObjectArn": "arn:aws:s3:::${METADATA_BUCKET}/${MANIFEST_KEY}",
      "ETag": "${MANIFEST_ETAG}"
    }
  },
  "Report": {
    "Bucket": "arn:aws:s3:::${METADATA_BUCKET}",
    "Format": "Report_CSV_20180820",
    "Enabled": true,
    "Prefix": "${REPORT_PREFIX}",
    "ReportScope": "AllTasks",
    "ExpectedBucketOwner": "${EXPECTED_BUCKET_OWNER}"
  },
  "Priority": 10,
  "RoleArn": "${S3_BATCH_ROLE_ARN}",
  "ClientRequestToken": "${RUN_ID}",
  "ConfirmationRequired": false,
  "Description": "Checksum verify (SHA256) for ${SHARE_NAME} run ${RUN_ID}"
}
JSON
)"

JOB_ID="$(aws s3control create-job \
  --account-id "${AWS_ACCOUNT_ID}" \
  --region "${AWS_REGION}" \
  --cli-input-json "${JOB_JSON}" \
  --query JobId \
  --output text
)"

echo "Batch job created: ${JOB_ID}"

# Duration so far (used for in-progress metrics + summary)
END_EPOCH="$(date +%s)"
END_TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DURATION_SECONDS=$((END_EPOCH - START_EPOCH))

#
# If we're not waiting for batch completion, still emit a metrics point for the run.
# success = 1 if sync exit code was 0 (batch verification may still be in-progress)
if ! is_true "${WAIT_FOR_BATCH}"; then
  success_flag=0
  if [[ ${SYNC_RC:-0} -eq 0 ]]; then success_flag=1; fi
  pushgateway_emit "${success_flag}" "${DURATION_SECONDS}" "${TOTAL_BYTES:-0}" "${TOTAL_FILES:-0}" "${UPLOAD_COUNT}" 1 "InProgress"
fi

# NOTE: We no longer upload individual transfer logs/summaries to S3 to reduce object bloat.
# All data will be included in the final consolidated report generated at the end of the script.

if is_true "${WAIT_FOR_BATCH}"; then
  echo "=== Waiting for Batch job to complete (max ${BATCH_MAX_WAIT_SECONDS}s) ==="
  waited=0
  status="Unknown"

  while [[ ${waited} -lt ${BATCH_MAX_WAIT_SECONDS} ]]; do
    # Describe the job and capture status
    aws s3control describe-job \
      --account-id "${AWS_ACCOUNT_ID}" \
      --job-id "${JOB_ID}" \
      --region "${AWS_REGION}" \
      --query 'Job' \
      --output json > "${BATCH_STATUS_FILE}" || true

    status="$(jq -r '.Status // "Unknown"' "${BATCH_STATUS_FILE}" 2>/dev/null || echo "Unknown")"
    echo "Batch job status: ${status} (waited ${waited}s)"

    # Emit a heartbeat metric while waiting (optional) — update duration as we go
    DURATION_SECONDS="$(elapsed_seconds)"
    success_flag=0
    if [[ ${SYNC_RC:-0} -eq 0 ]]; then success_flag=1; fi
    pushgateway_emit "${success_flag}" "${DURATION_SECONDS}" "${TOTAL_BYTES:-0}" "${TOTAL_FILES:-0}" "${UPLOAD_COUNT}" 1 "${status}"

    if [[ "${status}" == "Complete" || "${status}" == "Failed" || "${status}" == "Cancelled" ]]; then
      if [[ "${status}" != "Complete" ]]; then
        echo "Batch job ended with status: ${status}" | tee -a "${ERROR_FILE}" || true
        send_failure_email "S3 Batch Operations job ${JOB_ID} ended with status ${status}"
      fi
      break
    fi

    sleep "${BATCH_POLL_INTERVAL_SECONDS}"
    waited=$((waited + BATCH_POLL_INTERVAL_SECONDS))
  done

  # Try to locate and download the report CSV for this run.
  # NOTE: Batch Ops reports are written under:
  #   ${REPORT_PREFIX}/job-${JOB_ID}/results/<hash>.csv
  # Some accounts/regions take a short time to materialize the report objects after status=Complete.

  REPORT_LIST_JSON="${LOG_DIR}/report-list.json"
  report_key=""
  final_report_key=""

  REPORT_JOB_PREFIX="${REPORT_PREFIX}/job-${JOB_ID}"
  REPORT_RESULTS_PREFIX="${REPORT_JOB_PREFIX}/results/"

  # Wait (briefly) for the results CSV to appear.
  REPORT_APPEAR_POLL_SECONDS="${REPORT_APPEAR_POLL_SECONDS:-10}"
  REPORT_APPEAR_MAX_WAIT_SECONDS="${REPORT_APPEAR_MAX_WAIT_SECONDS:-300}"
  report_waited=0

  while [[ ${report_waited} -le ${REPORT_APPEAR_MAX_WAIT_SECONDS} ]]; do
    aws s3api list-objects-v2 \
      --bucket "${METADATA_BUCKET}" \
      --prefix "${REPORT_RESULTS_PREFIX}" \
      --region "${AWS_REGION}" \
      --expected-bucket-owner "${EXPECTED_BUCKET_OWNER}" \
      --output json > "${REPORT_LIST_JSON}" || true

    report_key="$(jq -r '(
      (.Contents // [])
      | map(select(.Key | endswith(".csv")))
      | sort_by(.LastModified)
      | last
      | .Key
    ) // empty' "${REPORT_LIST_JSON}" 2>/dev/null || true)"

    if [[ -n "${report_key}" ]]; then
      break
    fi

    echo "No results CSV yet under ${REPORT_RESULTS_PREFIX} (waited ${report_waited}s); sleeping ${REPORT_APPEAR_POLL_SECONDS}s" 
    sleep "${REPORT_APPEAR_POLL_SECONDS}"
    report_waited=$((report_waited + REPORT_APPEAR_POLL_SECONDS))
  done

  # Fallback: if still no CSV found, list the job prefix (may contain non-results objects)
  if [[ -z "${report_key}" ]]; then
    aws s3api list-objects-v2 \
      --bucket "${METADATA_BUCKET}" \
      --prefix "${REPORT_JOB_PREFIX}/" \
      --region "${AWS_REGION}" \
      --expected-bucket-owner "${EXPECTED_BUCKET_OWNER}" \
      --output json > "${REPORT_LIST_JSON}" || true

    report_key="$(jq -r '(
      (.Contents // [])
      | map(select(.Key | endswith(".csv")))
      | sort_by(.LastModified)
      | last
      | .Key
    ) // empty' "${REPORT_LIST_JSON}" 2>/dev/null || true)"
  fi

  if [[ -n "${report_key}" ]]; then
    final_report_key="${report_key}"
    echo "Downloading batch report: s3://${METADATA_BUCKET}/${report_key}"
    s3_get_object "${METADATA_BUCKET}" "${report_key}" "${BATCH_REPORT_FILE}" || true

    # Parse batch report locally (no longer upload raw report to S3 to reduce bloat)
    if command -v python3 >/dev/null 2>&1; then
      echo "Parsing batch report into verification JSONL + summary (python3)"
      RUN_ID_ENV="$RUN_ID" \
      JOB_ID_ENV="$JOB_ID" \
      BATCH_STATUS_ENV="$status" \
      REPORT_KEY_ENV="$report_key" \
      BATCH_REPORT_FILE_ENV="$BATCH_REPORT_FILE" \
      VERIFY_LOG_JSONL_ENV="$VERIFY_LOG_JSONL" \
      BATCH_REPORT_SUMMARY_FILE_ENV="$BATCH_REPORT_SUMMARY_FILE" \
      python3 - <<'PY' || echo "WARN: failed to parse batch report; raw report still stored in S3." >&2
import os, csv, json, re
from collections import Counter

run_id = os.environ.get("RUN_ID_ENV", "")
job_id = os.environ.get("JOB_ID_ENV", "")
batch_status = os.environ.get("BATCH_STATUS_ENV", "Unknown")
report_key = os.environ.get("REPORT_KEY_ENV", "")
report_path = os.environ.get("BATCH_REPORT_FILE_ENV", "")
verify_out = os.environ.get("VERIFY_LOG_JSONL_ENV", "")
summary_out = os.environ.get("BATCH_REPORT_SUMMARY_FILE_ENV", "")

if not report_path or not verify_out or not summary_out:
    raise SystemExit("Missing report_path/verify_out/summary_out")


def _try_json(s: str):
    try:
        return json.loads(s)
    except Exception:
        return None


def parse_details(details: str) -> dict:
    """Parse the AWS Batch Ops 'details' field (CSV-embedded JSON) defensively.

    Variants observed/handled:
      - {"checksum_base64":"..."}
      - {""checksum_base64"":""...""}   (CSV escaped)
      - "{\"checksum_base64\":\"...\"}" (double-encoded JSON)
      - {checksum_base64:"..."}            (bare keys)
      - {'checksum_base64':'...'}           (single quotes)

    Returns {} if we can't parse.
    """
    if not details:
        return {}

    d = details.strip().lstrip("\ufeff").strip()

    # 1) Try as-is
    blob = _try_json(d)
    if isinstance(blob, dict):
        return blob

    # 2) If it's a JSON string that contains JSON
    if len(d) >= 2 and d[0] == '"' and d[-1] == '"':
        inner = d[1:-1].replace('\\"', '"')
        blob = _try_json(inner)
        if isinstance(blob, dict):
            return blob
        if '""' in inner:
            blob = _try_json(inner.replace('""', '"'))
            if isinstance(blob, dict):
                return blob

    # 3) CSV-style doubled quotes in an unwrapped fragment
    if '""' in d:
        blob = _try_json(d.replace('""', '"'))
        if isinstance(blob, dict):
            return blob

    # 4) Replace single quotes with double quotes (best-effort)
    if "'" in d and d.startswith('{') and d.endswith('}'):
        blob = _try_json(d.replace("'", '"'))
        if isinstance(blob, dict):
            return blob

    # 5) Quote bare keys: {checksum_base64:"..."} -> {"checksum_base64":"..."}
    if d.startswith('{') and ':' in d:
        fixed = re.sub(r'([{,])\s*([A-Za-z_][A-Za-z0-9_]*)\s*:', r'\1"\2":', d)
        blob = _try_json(fixed)
        if isinstance(blob, dict):
            return blob

        # Sometimes both problems exist (bare keys + doubled quotes)
        if '""' in fixed:
            blob = _try_json(fixed.replace('""', '"'))
            if isinstance(blob, dict):
                return blob

    return {}


def looks_like_header(row):
    cols = [c.strip().strip('"').lower() for c in row]
    s = set(cols)
    return ("bucket" in s and "key" in s and ("status" in s or "taskstatus" in s))


def safe_get(row, idx, default=""):
    return row[idx] if (idx is not None and idx < len(row)) else default


objects_total = 0
objects_succeeded = 0
objects_failed = 0
top_errors = Counter()

with open(report_path, newline="") as f, open(verify_out, "w") as out:
    r = csv.reader(f)
    first = next(r, None)
    if first is None:
        pass
    else:
        header_mode = looks_like_header(first)
        idx = {}
        if header_mode:
            cols = [c.strip().strip('"') for c in first]
            for i, c in enumerate(cols):
                idx[c.lower()] = i

        def get_named(row, name, default=""):
            return safe_get(row, idx.get(name.lower()), default).strip()

        def write_rec(rec):
            out.write(json.dumps(rec) + "\n")

        if header_mode:
            # Headered CSV
            for row in r:
                if not row:
                    continue
                status = (get_named(row, "status") or get_named(row, "taskstatus")).strip()
                err = (get_named(row, "errorcode") or "").strip()

                objects_total += 1
                if status.lower() == "succeeded":
                    objects_succeeded += 1
                else:
                    objects_failed += 1

                if err and err != "-":
                    top_errors[err] += 1

                rec = {
                    "run_id": run_id,
                    "bucket": (get_named(row, "bucket") or get_named(row, "Bucket")).strip(),
                    "key": (get_named(row, "key") or get_named(row, "Key")).strip(),
                    "version_id": (get_named(row, "versionid") or get_named(row, "versionId") or get_named(row, "version_id")).strip(),
                    "status": status,
                    "error_code": err,
                    "error_message": (get_named(row, "errormessage") or get_named(row, "errorMessage")).strip(),
                    "checksum_algorithm": (get_named(row, "checksumalgorithm") or get_named(row, "checksumAlgorithm")).strip(),
                    "checksum": (get_named(row, "checksum") or get_named(row, "checksumvalue") or get_named(row, "checksumValue") or get_named(row, "ChecksumValue")).strip(),
                    "checksum_hex": "",
                }
                write_rec(rec)

        else:
            # Headerless format we've seen:
            # 0 bucket, 1 key, 2 version_id, 3 status, 4 http_status, 5 error_code, 6 details-json
            def col(row, i):
                return (row[i] if i < len(row) else "").strip()

            for row in [first] + list(r):
                if not row:
                    continue

                status = col(row, 3)
                err = col(row, 5)

                objects_total += 1
                if status.lower() == "succeeded":
                    objects_succeeded += 1
                else:
                    objects_failed += 1

                if err and err != "-":
                    top_errors[err] += 1

                details = col(row, 6)
                try:
                    blob = parse_details(details)
                except Exception:
                    blob = {}

                rec = {
                    "run_id": run_id,
                    "bucket": col(row, 0),
                    "key": col(row, 1),
                    "version_id": col(row, 2),
                    "status": status,
                    "error_code": err,
                    "error_message": "",
                    "checksum_algorithm": (blob.get("checksumAlgorithm") or "").strip(),
                    "checksum": (blob.get("checksum_base64") or "").strip(),
                    "checksum_hex": (blob.get("checksum_hex") or "").strip(),
                }
                write_rec(rec)

summary = {
    "run_id": run_id,
    "batch_job_id": job_id,
    "batch_status": batch_status,
    "report_key": report_key,
    "objects_total": int(objects_total),
    "objects_succeeded": int(objects_succeeded),
    "objects_failed": int(objects_failed),
    "top_error_codes": dict(top_errors.most_common(10)),
}

with open(summary_out, "w") as out:
    json.dump(summary, out, indent=2)
PY
      # Verification JSONL and summary kept local (will be in consolidated report)
    else
      echo "python3 not available in this container; skipping per-object verification parsing." 
    fi

      # Produce a combined per-file audit log (transfer + verification) for easier human review.
      # Outputs:
      #  - ${LOG_DIR}/file-audit.jsonl
      #  - ${LOG_DIR}/file-audit.csv
      FILE_AUDIT_JSONL="${LOG_DIR}/file-audit.jsonl"
      FILE_AUDIT_CSV="${LOG_DIR}/file-audit.csv"

      if command -v python3 >/dev/null 2>&1 && [[ -s "${TRANSFER_LOG_JSONL}" ]] && [[ -s "${VERIFY_LOG_JSONL}" ]]; then
        RUN_ID_ENV="$RUN_ID" \
        TRANSFER_LOG_JSONL_ENV="$TRANSFER_LOG_JSONL" \
        VERIFY_LOG_JSONL_ENV="$VERIFY_LOG_JSONL" \
        FILE_AUDIT_JSONL_ENV="$FILE_AUDIT_JSONL" \
        FILE_AUDIT_CSV_ENV="$FILE_AUDIT_CSV" \
        python3 - <<'PY' || echo "WARN: failed to build file-audit artifacts; continuing." >&2
import os, json, csv

run_id = os.environ.get('RUN_ID_ENV','')
transfers_path = os.environ.get('TRANSFER_LOG_JSONL_ENV','')
verify_path = os.environ.get('VERIFY_LOG_JSONL_ENV','')
out_jsonl = os.environ.get('FILE_AUDIT_JSONL_ENV','')
out_csv = os.environ.get('FILE_AUDIT_CSV_ENV','')

# Load transfers keyed by s3_key
transfers = {}
with open(transfers_path,'r') as f:
    for line in f:
        line=line.strip()
        if not line:
            continue
        rec=json.loads(line)
        key=rec.get('s3_key')
        if not key:
            continue
        transfers[key]=rec

# Stream verification rows and merge
rows=[]
with open(verify_path,'r') as f:
    for line in f:
        line=line.strip()
        if not line:
            continue
        v = json.loads(line)

        # Key in Batch Ops reports may be URL-ish encoded in some environments
        # (e.g. spaces rendered as '+'). Keep the original, but try a decoded
        # variant ONLY for joining to the transfer log so we don't break real '+' keys.
        key_raw = v.get('key') or v.get('Key')
        if not key_raw:
            continue

        key_join = key_raw
        t = transfers.get(key_join)
        if t is None and '+' in key_raw:
            alt = key_raw.replace('+', ' ')
            if alt in transfers:
                key_join = alt
                t = transfers.get(key_join)

        if t is None:
            t = {}

        merged={
            'run_id': run_id,
            's3_bucket': t.get('s3_bucket') or v.get('bucket'),
            # s3_key is the best-guess canonical key for dashboards (prefers transfer log)
            's3_key': key_join,
            # keep what the Batch report / verification log originally said for troubleshooting
            's3_key_reported': key_raw,
            'bytes': t.get('bytes', 0),
            'local_path': t.get('local_path',''),
            'mtime_utc': t.get('mtime_utc',''),
            'upload_ts_utc': t.get('ts_utc',''),
            'upload_status': t.get('upload_status',''),
            'verify_status': v.get('status',''),
            'verify_error_code': v.get('error_code',''),
            'verify_error_message': v.get('error_message',''),
            'checksum_algorithm': v.get('checksum_algorithm',''),
            'checksum': v.get('checksum',''),
            'version_id': v.get('version_id',''),
        }
        rows.append(merged)

# Write JSONL
with open(out_jsonl,'w') as out:
    for r in rows:
        out.write(json.dumps(r) + "\n")

# Write CSV
fields=[
  'run_id','s3_bucket','s3_key','s3_key_reported','bytes','local_path','mtime_utc','upload_ts_utc','upload_status',
  'verify_status','verify_error_code','verify_error_message','checksum_algorithm','checksum','version_id'
]
with open(out_csv,'w',newline='') as out:
    w=csv.DictWriter(out, fieldnames=fields)
    w.writeheader()
    for r in rows:
        w.writerow(r)
PY

        # File-audit artifacts kept local (will be in consolidated report)
      fi
  else
    echo "No batch report object found yet under prefix: ${REPORT_PREFIX}"
  fi
fi


#
# Recompute duration at the end (covers WAIT_FOR_BATCH=true runs)
DURATION_SECONDS="$(elapsed_seconds)"

# If we waited for batch, update the run summary with final timing + status + report pointers.
# (We initially write the run summary immediately after job creation so the run is discoverable even
#  if the pod gets killed; this final write makes it accurate for dashboards.)
final_batch_status="${status:-}"
final_report_key_local="${final_report_key:-}"
reports_summary_key="${BATCH_PREFIX}/reports-summary/${SHARE_NAME}/${RUN_ID}.json"

# Only update these fields if we actually waited
if is_true "${WAIT_FOR_BATCH}"; then
  END_EPOCH="$(date +%s)"
  END_TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # NOTE: Summary file no longer uploaded - consolidated report will be generated below
fi

# Final metrics emission (if WAIT_FOR_BATCH=true we may know final status; otherwise InProgress already emitted)
final_status="${status:-}"  # from WAIT_FOR_BATCH loop, may be empty
success_flag=0
if [[ ${SYNC_RC:-0} -eq 0 ]]; then success_flag=1; fi
if [[ -n "${final_status}" ]]; then
  pushgateway_emit "${success_flag}" "${DURATION_SECONDS}" "${TOTAL_BYTES:-0}" "${TOTAL_FILES:-0}" "${UPLOAD_COUNT}" 1 "${final_status}"
else
  pushgateway_emit "${success_flag}" "${DURATION_SECONDS}" "${TOTAL_BYTES:-0}" "${TOTAL_FILES:-0}" "${UPLOAD_COUNT}" 1 ""
fi

#
# Generate consolidated report (DataSync-style single JSON report per execution)
#
CONSOLIDATED_REPORT="${LOG_DIR}/consolidated-report.json"
CONSOLIDATED_REPORT_KEY="${SHARE_NAME}/${TS}/report.json"

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
  python3 - <<'PY' || echo "WARN: failed to generate consolidated report" >&2
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

# Determine overall status
if sync_rc != 0:
    status = "FAILED"
elif batch_status and batch_status.lower() != "complete":
    status = "FAILED"
else:
    status = "SUCCESS"

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
                    "sourceChecksum": "",  # Not available from local file
                    "destChecksum": rec.get('checksum', ''),
                    "checksumAlgorithm": rec.get('checksum_algorithm', ''),
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
        "filesVerified": verification_summary.get('objects_succeeded', 0),
        "filesSucceeded": files_succeeded,
        "filesFailed": files_failed,
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
        "objectsTotal": verification_summary.get('objects_total', 0),
        "objectsSucceeded": verification_summary.get('objects_succeeded', 0),
        "objectsFailed": verification_summary.get('objects_failed', 0),
        "topErrorCodes": verification_summary.get('top_error_codes', {})
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

# Write consolidated report
with open(output_path, 'w') as f:
    json.dump(report, f, indent=2)

print(f"Consolidated report written to: {output_path}")
PY

  # Upload consolidated report to S3
  if [[ -s "${CONSOLIDATED_REPORT}" ]]; then
    echo "Uploading consolidated report to: s3://${METADATA_BUCKET}/${CONSOLIDATED_REPORT_KEY}"
    s3_put_object "${METADATA_BUCKET}" "${CONSOLIDATED_REPORT_KEY}" "${CONSOLIDATED_REPORT}"
    echo "Consolidated report available at: s3://${METADATA_BUCKET}/${CONSOLIDATED_REPORT_KEY}"

    # Cleanup: Remove AWS Batch Ops infrastructure files now that data is in consolidated report
    if [[ -n "${JOB_ID:-}" ]]; then
      echo "Cleaning up batch infrastructure files..."
      # Delete manifest
      aws s3 rm "s3://${METADATA_BUCKET}/${MANIFEST_KEY}" --region "${AWS_REGION}" 2>/dev/null || true
      # Delete batch reports directory (contains manifest.json, results/*.csv, etc.)
      aws s3 rm "s3://${METADATA_BUCKET}/${REPORT_PREFIX}/job-${JOB_ID}/" --recursive --region "${AWS_REGION}" 2>/dev/null || true
      echo "Cleanup complete - only consolidated report remains"
    fi
  fi
else
  echo "WARN: python3 not available; skipping consolidated report generation"
fi

echo "=== Done ==="
