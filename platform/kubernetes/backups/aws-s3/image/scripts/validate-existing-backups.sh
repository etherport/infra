#!/usr/bin/env bash
#
# validate-existing-backups.sh
#
# Retroactively validate S3 backup integrity by comparing source file checksums
# with S3's stored ChecksumSHA256 metadata.
#
# Usage:
#   validate-existing-backups.sh <share-name> [sample-percent]
#
# Examples:
#   validate-existing-backups.sh graham           # Validate all files in graham share
#   validate-existing-backups.sh graham 10        # Validate random 10% sample
#
# Required Environment Variables:
#   SRC_PATH          - Local source directory (e.g., /mnt/src)
#   DEST_BUCKET       - S3 destination bucket
#   DEST_PREFIX       - S3 key prefix (e.g., objects/graham)
#   METADATA_BUCKET   - S3 bucket for validation reports
#   AWS_REGION        - AWS region
#
# Optional Environment Variables:
#   PARALLEL_WORKERS  - Number of parallel workers (default: 50)
#   REPORT_PREFIX     - S3 prefix for validation reports (default: validation-reports)
#

set -euo pipefail

# Configuration
SHARE_NAME="${1:-}"
SAMPLE_PERCENT="${2:-100}"
PARALLEL_WORKERS="${PARALLEL_WORKERS:-50}"
REPORT_PREFIX="${REPORT_PREFIX:-validation-reports}"

if [[ -z "$SHARE_NAME" ]]; then
  echo "ERROR: Share name required" >&2
  echo "Usage: $0 <share-name> [sample-percent]" >&2
  exit 1
fi

# Validate required environment variables
for var in SRC_PATH DEST_BUCKET DEST_PREFIX METADATA_BUCKET AWS_REGION; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: Required environment variable $var not set" >&2
    exit 1
  fi
done

echo "==================================="
echo "S3 Backup Validation"
echo "==================================="
echo "Share:            $SHARE_NAME"
echo "Source:           $SRC_PATH"
echo "S3 Bucket:        $DEST_BUCKET"
echo "S3 Prefix:        $DEST_PREFIX"
echo "Sample:           ${SAMPLE_PERCENT}%"
echo "Parallel Workers: $PARALLEL_WORKERS"
echo "==================================="
echo

# Create work directory
WORK_DIR="/tmp/validation-$$"
mkdir -p "$WORK_DIR"
trap "rm -rf $WORK_DIR" EXIT

VALIDATION_TS="$(date -u +%Y%m%dT%H%M%SZ)"
START_EPOCH="$(date +%s)"

# List all objects in S3 with their metadata
echo "[1/5] Listing S3 objects..."
OBJECT_LIST="$WORK_DIR/objects.jsonl"

aws s3api list-objects-v2 \
  --bucket "$DEST_BUCKET" \
  --prefix "$DEST_PREFIX/" \
  --region "$AWS_REGION" \
  --output json | \
  jq -c '.Contents[]? | {key: .Key, size: .Size, etag: .ETag, last_modified: .LastModified}' \
  > "$OBJECT_LIST"

TOTAL_OBJECTS=$(wc -l < "$OBJECT_LIST" | tr -d ' ')
echo "Found $TOTAL_OBJECTS objects in S3"

if [[ "$TOTAL_OBJECTS" -eq 0 ]]; then
  echo "ERROR: No objects found in s3://${DEST_BUCKET}/${DEST_PREFIX}/" >&2
  exit 1
fi

# Sample objects if requested
if [[ "$SAMPLE_PERCENT" -lt 100 ]]; then
  echo "[2/5] Sampling ${SAMPLE_PERCENT}% of objects..."
  SAMPLE_LIST="$WORK_DIR/sample.jsonl"

  # Calculate sample size
  SAMPLE_SIZE=$(( TOTAL_OBJECTS * SAMPLE_PERCENT / 100 ))
  if [[ "$SAMPLE_SIZE" -lt 1 ]]; then
    SAMPLE_SIZE=1
  fi

  # Random sample using shuf
  shuf -n "$SAMPLE_SIZE" "$OBJECT_LIST" > "$SAMPLE_LIST"
  OBJECT_LIST="$SAMPLE_LIST"

  TOTAL_OBJECTS=$(wc -l < "$OBJECT_LIST" | tr -d ' ')
  echo "Selected $TOTAL_OBJECTS objects for validation"
else
  echo "[2/5] Validating all objects (no sampling)"
fi

# Function to validate a single object
validate_object() {
  local OBJECT_JSON="$1"
  local SRC_PATH="$2"
  local DEST_BUCKET="$3"
  local DEST_PREFIX="$4"
  local AWS_REGION="$5"
  local WORK_DIR="$6"

  # Parse object metadata
  local S3_KEY=$(echo "$OBJECT_JSON" | jq -r '.key')
  local S3_SIZE=$(echo "$OBJECT_JSON" | jq -r '.size')

  # Construct local file path (strip DEST_PREFIX from S3_KEY)
  local RELATIVE_PATH="${S3_KEY#$DEST_PREFIX/}"
  local LOCAL_PATH="${SRC_PATH}/${RELATIVE_PATH}"

  # Create result object
  local RESULT="$WORK_DIR/results/$(echo -n "$S3_KEY" | md5sum | awk '{print $1}').json"
  mkdir -p "$(dirname "$RESULT")"

  # Check if source file exists
  if [[ ! -f "$LOCAL_PATH" ]]; then
    jq -cn \
      --arg s3_key "$S3_KEY" \
      --arg local_path "$LOCAL_PATH" \
      --arg status "source_missing" \
      --arg error "Source file no longer exists" \
      '{s3_key:$s3_key, local_path:$local_path, status:$status, error:$error}' \
      > "$RESULT"
    return
  fi

  # Get file size
  local LOCAL_SIZE=$(stat -c%s "$LOCAL_PATH" 2>/dev/null || echo 0)

  # Check size match
  if [[ "$LOCAL_SIZE" != "$S3_SIZE" ]]; then
    jq -cn \
      --arg s3_key "$S3_KEY" \
      --arg local_path "$LOCAL_PATH" \
      --arg status "size_mismatch" \
      --argjson local_size "$LOCAL_SIZE" \
      --argjson s3_size "$S3_SIZE" \
      --arg error "Size mismatch: local=$LOCAL_SIZE, S3=$S3_SIZE" \
      '{s3_key:$s3_key, local_path:$local_path, status:$status, local_size:$local_size, s3_size:$s3_size, error:$error}' \
      > "$RESULT"
    return
  fi

  # Compute source checksum
  local SOURCE_SHA256=$(sha256sum "$LOCAL_PATH" 2>/dev/null | awk '{print $1}')

  # Get S3 checksum from metadata
  local S3_METADATA=$(aws s3api head-object \
    --bucket "$DEST_BUCKET" \
    --key "$S3_KEY" \
    --checksum-mode ENABLED \
    --region "$AWS_REGION" \
    --output json 2>/dev/null || echo '{}')

  local S3_SHA256=$(echo "$S3_METADATA" | jq -r '.ChecksumSHA256 // ""')

  if [[ -z "$S3_SHA256" ]]; then
    jq -cn \
      --arg s3_key "$S3_KEY" \
      --arg local_path "$LOCAL_PATH" \
      --arg status "s3_checksum_missing" \
      --arg source_sha256 "$SOURCE_SHA256" \
      --arg error "S3 object has no ChecksumSHA256 metadata" \
      '{s3_key:$s3_key, local_path:$local_path, status:$status, source_sha256:$source_sha256, error:$error}' \
      > "$RESULT"
    return
  fi

  # Compare checksums
  if [[ "$SOURCE_SHA256" == "$S3_SHA256" ]]; then
    jq -cn \
      --arg s3_key "$S3_KEY" \
      --arg local_path "$LOCAL_PATH" \
      --arg status "valid" \
      --arg source_sha256 "$SOURCE_SHA256" \
      --arg s3_sha256 "$S3_SHA256" \
      --argjson size "$LOCAL_SIZE" \
      '{s3_key:$s3_key, local_path:$local_path, status:$status, source_sha256:$source_sha256, s3_sha256:$s3_sha256, size:$size}' \
      > "$RESULT"
  else
    jq -cn \
      --arg s3_key "$S3_KEY" \
      --arg local_path "$LOCAL_PATH" \
      --arg status "checksum_mismatch" \
      --arg source_sha256 "$SOURCE_SHA256" \
      --arg s3_sha256 "$S3_SHA256" \
      --argjson size "$LOCAL_SIZE" \
      --arg error "CRITICAL: Checksum mismatch - data corruption detected!" \
      '{s3_key:$s3_key, local_path:$local_path, status:$status, source_sha256:$source_sha256, s3_sha256:$s3_sha256, size:$size, error:$error}' \
      > "$RESULT"
  fi
}

# Export function and environment for parallel workers
export -f validate_object
export SRC_PATH DEST_BUCKET DEST_PREFIX AWS_REGION WORK_DIR
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_DEFAULT_REGION

# Create results directory
mkdir -p "$WORK_DIR/results"

echo "[3/5] Validating objects (${PARALLEL_WORKERS} parallel workers)..."
echo "Progress will be shown every 100 objects..."

if command -v parallel >/dev/null 2>&1; then
  # GNU parallel (fastest)
  cat "$OBJECT_LIST" | \
    parallel -j "$PARALLEL_WORKERS" --line-buffer \
    validate_object {} "$SRC_PATH" "$DEST_BUCKET" "$DEST_PREFIX" "$AWS_REGION" "$WORK_DIR"
else
  # Fallback: xargs with bash
  cat "$OBJECT_LIST" | \
    xargs -I {} -P "$PARALLEL_WORKERS" \
    bash -c 'validate_object "$@"' _ {} "$SRC_PATH" "$DEST_BUCKET" "$DEST_PREFIX" "$AWS_REGION" "$WORK_DIR"
fi

echo "Validation complete!"

# Aggregate results
echo "[4/5] Aggregating results..."
RESULTS_JSONL="$WORK_DIR/validation-results.jsonl"
cat "$WORK_DIR/results"/*.json 2>/dev/null > "$RESULTS_JSONL" || true

TOTAL_VALIDATED=$(wc -l < "$RESULTS_JSONL" | tr -d ' ')

# Count statuses
VALID_COUNT=$(jq -r 'select(.status == "valid") | .s3_key' "$RESULTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
CHECKSUM_MISMATCH_COUNT=$(jq -r 'select(.status == "checksum_mismatch") | .s3_key' "$RESULTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
SIZE_MISMATCH_COUNT=$(jq -r 'select(.status == "size_mismatch") | .s3_key' "$RESULTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
SOURCE_MISSING_COUNT=$(jq -r 'select(.status == "source_missing") | .s3_key' "$RESULTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')
S3_CHECKSUM_MISSING_COUNT=$(jq -r 'select(.status == "s3_checksum_missing") | .s3_key' "$RESULTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')

END_EPOCH="$(date +%s)"
DURATION=$((END_EPOCH - START_EPOCH))

# Determine overall status
if [[ "$CHECKSUM_MISMATCH_COUNT" -gt 0 ]]; then
  OVERALL_STATUS="CRITICAL"
elif [[ "$SIZE_MISMATCH_COUNT" -gt 0 ]]; then
  OVERALL_STATUS="FAILED"
elif [[ "$VALID_COUNT" -eq "$TOTAL_VALIDATED" ]]; then
  OVERALL_STATUS="SUCCESS"
else
  OVERALL_STATUS="PARTIAL"
fi

# Generate consolidated report
REPORT_FILE="$WORK_DIR/validation-report.json"

jq -cn \
  --arg validation_id "$VALIDATION_TS" \
  --arg share "$SHARE_NAME" \
  --arg status "$OVERALL_STATUS" \
  --arg start_time "$(date -u -d "@$START_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")" \
  --arg end_time "$(date -u -d "@$END_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")" \
  --argjson duration "$DURATION" \
  --argjson total_objects "$TOTAL_OBJECTS" \
  --argjson total_validated "$TOTAL_VALIDATED" \
  --argjson sample_percent "$SAMPLE_PERCENT" \
  --argjson valid "$VALID_COUNT" \
  --argjson checksum_mismatch "$CHECKSUM_MISMATCH_COUNT" \
  --argjson size_mismatch "$SIZE_MISMATCH_COUNT" \
  --argjson source_missing "$SOURCE_MISSING_COUNT" \
  --argjson s3_checksum_missing "$S3_CHECKSUM_MISSING_COUNT" \
  --arg source "$SRC_PATH" \
  --arg destination "s3://${DEST_BUCKET}/${DEST_PREFIX}" \
  '{
    validationId: $validation_id,
    share: $share,
    status: $status,
    startTime: $start_time,
    endTime: $end_time,
    durationSeconds: $duration,
    summary: {
      totalObjectsInS3: $total_objects,
      totalValidated: $total_validated,
      samplePercent: $sample_percent,
      valid: $valid,
      checksumMismatch: $checksum_mismatch,
      sizeMismatch: $size_mismatch,
      sourceMissing: $source_missing,
      s3ChecksumMissing: $s3_checksum_missing
    },
    source: $source,
    destination: $destination,
    validation: {
      algorithm: "SHA256",
      method: "source_vs_s3_metadata",
      parallelWorkers: '$PARALLEL_WORKERS'
    }
  }' > "$REPORT_FILE"

# Add detailed results
jq --slurpfile results "$RESULTS_JSONL" '. + {files: $results[]}' "$REPORT_FILE" > "$REPORT_FILE.tmp"
mv "$REPORT_FILE.tmp" "$REPORT_FILE"

# Add errors array
if [[ "$CHECKSUM_MISMATCH_COUNT" -gt 0 ]]; then
  MISMATCHED_FILES=$(jq -r 'select(.status == "checksum_mismatch") | .s3_key' "$RESULTS_JSONL" | jq -R -s 'split("\n") | map(select(length > 0))')
  jq --argjson mismatched "$MISMATCHED_FILES" \
     '. + {errors: [{stage: "validation", severity: "CRITICAL", message: "CRITICAL: Data corruption detected - checksums do not match!", mismatchedFiles: $mismatched}]}' \
     "$REPORT_FILE" > "$REPORT_FILE.tmp"
  mv "$REPORT_FILE.tmp" "$REPORT_FILE"
else
  jq '. + {errors: []}' "$REPORT_FILE" > "$REPORT_FILE.tmp"
  mv "$REPORT_FILE.tmp" "$REPORT_FILE"
fi

echo
echo "==================================="
echo "Validation Results"
echo "==================================="
echo "Status:             $OVERALL_STATUS"
echo "Total in S3:        $TOTAL_OBJECTS"
echo "Validated:          $TOTAL_VALIDATED"
echo "Valid:              $VALID_COUNT"
echo "Checksum Mismatch:  $CHECKSUM_MISMATCH_COUNT"
echo "Size Mismatch:      $SIZE_MISMATCH_COUNT"
echo "Source Missing:     $SOURCE_MISSING_COUNT"
echo "S3 Checksum Missing: $S3_CHECKSUM_MISSING_COUNT"
echo "Duration:           ${DURATION}s"
echo "==================================="
echo

if [[ "$CHECKSUM_MISMATCH_COUNT" -gt 0 ]]; then
  echo "❌ CRITICAL: Checksum mismatches detected!"
  echo "Mismatched files:"
  jq -r 'select(.status == "checksum_mismatch") | "  - " + .s3_key' "$RESULTS_JSONL"
  echo
fi

# Upload report to S3
echo "[5/5] Uploading validation report to S3..."
REPORT_S3_KEY="${REPORT_PREFIX}/${SHARE_NAME}/${VALIDATION_TS}/validation-report.json"

aws s3 cp "$REPORT_FILE" \
  "s3://${METADATA_BUCKET}/${REPORT_S3_KEY}" \
  --region "$AWS_REGION"

echo "Report uploaded to: s3://${METADATA_BUCKET}/${REPORT_S3_KEY}"
echo
echo "To download and view:"
echo "  aws s3 cp s3://${METADATA_BUCKET}/${REPORT_S3_KEY} - | jq ."
echo

exit $([[ "$OVERALL_STATUS" == "SUCCESS" ]] && echo 0 || echo 1)
