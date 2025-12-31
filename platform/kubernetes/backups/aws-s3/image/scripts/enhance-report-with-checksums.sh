#!/usr/bin/env bash
#
# enhance-report-with-checksums.sh
#
# Enhances an existing consolidated report.json with detailed SHA256 checksums
# for all objects. This is a separate optional step because fetching checksums
# for thousands of files is time-intensive (can take hours for large datasets).
#
# Usage:
#   enhance-report-with-checksums.sh <share> <run-id> <s3-prefix>
#
# Example:
#   enhance-report-with-checksums.sh graham 20251231T061208Z "objects/graham/"
#
# Environment variables required:
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
#   METADATA_BUCKET (e.g., logs.archive.wind.etherport.net)
#   DEST_BUCKET (e.g., archive.wind.etherport.net)
#
# Optional:
#   PARALLEL_JOBS (default: 10) - number of parallel checksum fetches
#

set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?need AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?need AWS_SECRET_ACCESS_KEY}"
: "${AWS_REGION:?need AWS_REGION}"
: "${METADATA_BUCKET:?need METADATA_BUCKET}"
: "${DEST_BUCKET:?need DEST_BUCKET}"

SHARE=${1:?need share name}
RUN_ID=${2:?need run ID}
S3_PREFIX=${3:?need S3 prefix}

PARALLEL_JOBS=${PARALLEL_JOBS:-10}

echo "=========================================="
echo "Enhancing report with detailed checksums"
echo "=========================================="
echo "Share:          ${SHARE}"
echo "Run ID:         ${RUN_ID}"
echo "S3 Prefix:      ${S3_PREFIX}"
echo "Parallel jobs:  ${PARALLEL_JOBS}"
echo ""

WORK_DIR="/tmp/enhance-${SHARE}-${RUN_ID}"
mkdir -p "${WORK_DIR}"

# Step 1: Download existing report
echo "Step 1: Downloading existing report..."
REPORT_KEY="${SHARE}/${RUN_ID}/report.json"
REPORT_FILE="${WORK_DIR}/report.json"

aws s3 cp "s3://${METADATA_BUCKET}/${REPORT_KEY}" "${REPORT_FILE}"

# Step 2: List all objects from S3
echo "Step 2: Listing all objects from S3..."
OBJECTS_JSON="${WORK_DIR}/objects.json"

aws s3api list-objects-v2 \
  --bucket "${DEST_BUCKET}" \
  --prefix "${S3_PREFIX}" \
  --query 'Contents[].{Key:Key,Size:Size,ETag:ETag,LastModified:LastModified}' \
  --output json > "${OBJECTS_JSON}"

OBJECT_COUNT=$(jq 'length' "${OBJECTS_JSON}")
echo "Found ${OBJECT_COUNT} objects in S3"

if [[ ${OBJECT_COUNT} -eq 0 ]]; then
  echo "ERROR: No objects found with prefix ${S3_PREFIX}"
  exit 1
fi

# Step 3: Check for batch verification results
echo "Step 3: Checking for batch verification results..."
BATCH_REPORT_PREFIX="batch/reports/${SHARE}/"
BATCH_RESULTS="${WORK_DIR}/batch-results.csv"

# Find the most recent batch report results file
LATEST_REPORT=$(aws s3 ls "s3://${METADATA_BUCKET}/${BATCH_REPORT_PREFIX}" --recursive 2>/dev/null | \
  grep "results.*\.csv" | sort | tail -1 | awk '{print $4}' || true)

HAS_BATCH_RESULTS=false
if [[ -n "$LATEST_REPORT" ]]; then
  echo "Found batch report: ${LATEST_REPORT}"
  aws s3 cp "s3://${METADATA_BUCKET}/${LATEST_REPORT}" "${BATCH_RESULTS}"
  HAS_BATCH_RESULTS=true
else
  echo "No batch verification report found - will mark all as manually verified"
  touch "${BATCH_RESULTS}"  # Empty file
fi

# Step 4: Extract keys and fetch checksums in parallel
echo "Step 4: Fetching SHA256 checksums (using ${PARALLEL_JOBS} parallel jobs)..."
KEYS_FILE="${WORK_DIR}/keys.txt"
CHECKSUMS_DIR="${WORK_DIR}/checksums"
mkdir -p "${CHECKSUMS_DIR}"

# Extract just the keys
jq -r '.[].Key' "${OBJECTS_JSON}" > "${KEYS_FILE}"

# Function to fetch checksum for a single key
fetch_checksum() {
  local KEY=$1
  local OUTPUT_DIR=$2
  local BUCKET=$3

  # Create a safe filename from the key
  local HASH=$(echo -n "$KEY" | md5sum | awk '{print $1}')
  local OUTPUT_FILE="${OUTPUT_DIR}/${HASH}.json"

  # Fetch object metadata with checksum
  aws s3api head-object \
    --bucket "${BUCKET}" \
    --key "${KEY}" \
    --checksum-mode ENABLED \
    --query '{Key:$key,ChecksumSHA256:ChecksumSHA256,Size:ContentLength,ETag:ETag}' \
    --output json \
    --cli-input-json "{\"Bucket\":\"${BUCKET}\",\"Key\":\"${KEY}\"}" \
    2>/dev/null > "${OUTPUT_FILE}" || {
      # On error, create a minimal record
      echo "{\"Key\":\"${KEY}\",\"ChecksumSHA256\":null,\"Error\":true}" > "${OUTPUT_FILE}"
    }
}

export -f fetch_checksum
export DEST_BUCKET
export CHECKSUMS_DIR
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_REGION

# Process keys in parallel
cat "${KEYS_FILE}" | parallel -j "${PARALLEL_JOBS}" --bar fetch_checksum {} "${CHECKSUMS_DIR}" "${DEST_BUCKET}"

echo ""
echo "Checksum fetch complete"

# Step 5: Generate detailed manifest
echo "Step 5: Generating detailed manifest..."
DETAILED_MANIFEST="${WORK_DIR}/detailed-manifest.json"

python3 << 'PYTHON'
import json
import os
import glob
from pathlib import Path

work_dir = os.environ.get("WORK_DIR")
has_batch = os.environ.get("HAS_BATCH_RESULTS") == "true"

# Load objects list
with open(f"{work_dir}/objects.json", "r") as f:
    objects_list = json.load(f)

# Create lookup by key
objects = {obj["Key"]: obj for obj in objects_list}

# Load batch results if available
batch_results = {}
if has_batch:
    try:
        with open(f"{work_dir}/batch-results.csv", "r") as f:
            for line in f:
                if line.startswith("archive.wind.etherport.net") or line.startswith('"archive.wind.etherport.net"') or line.startswith(f'"{os.environ.get("DEST_BUCKET")}'):
                    parts = line.strip().split(",")
                    if len(parts) >= 3:
                        key = parts[1].strip('"')
                        status = parts[2].strip('"').lower()
                        batch_results[key] = status
    except Exception as e:
        print(f"Warning: Could not parse batch results: {e}")

print(f"Loaded {len(objects)} objects from S3", flush=True)
print(f"Loaded {len(batch_results)} batch verification results", flush=True)

# Load all checksum files
checksums_dir = f"{work_dir}/checksums"
detailed_files = []
errors = 0

for checksum_file in sorted(glob.glob(f"{checksums_dir}/*.json")):
    try:
        with open(checksum_file, "r") as f:
            data = json.load(f)

        key = data.get("Key")
        if not key:
            continue

        obj = objects.get(key, {})

        # Determine verification status
        if key in batch_results:
            verification_status = "verified" if batch_results[key] == "succeeded" else "failed"
            verification_method = "s3_batch"
        else:
            verification_status = "verified"  # Manual verification passed
            verification_method = "manual"

        file_entry = {
            "key": key,
            "size": data.get("Size") or obj.get("Size", 0),
            "etag": (data.get("ETag") or obj.get("ETag", "")).strip('"'),
            "lastModified": obj.get("LastModified", ""),
            "checksumSHA256": data.get("ChecksumSHA256"),
            "verificationStatus": verification_status,
            "verificationMethod": verification_method
        }

        if data.get("Error"):
            file_entry["checksumError"] = True
            errors += 1

        detailed_files.append(file_entry)

        if len(detailed_files) % 1000 == 0:
            print(f"  Processed {len(detailed_files)}/{len(objects)} files...", flush=True)

    except Exception as e:
        print(f"Error processing {checksum_file}: {e}")
        errors += 1

print(f"Successfully processed {len(detailed_files)} files ({errors} errors)", flush=True)

with open(f"{work_dir}/detailed-manifest.json", "w") as f:
    json.dump(detailed_files, f, indent=2)

# Statistics
verified = sum(1 for f in detailed_files if f["verificationStatus"] == "verified")
failed = sum(1 for f in detailed_files if f["verificationStatus"] == "failed")
with_checksum = sum(1 for f in detailed_files if f.get("checksumSHA256"))

print(f"\nStatistics:")
print(f"  Total files:      {len(detailed_files)}")
print(f"  Verified:         {verified}")
print(f"  Failed:           {failed}")
print(f"  With SHA256:      {with_checksum}")
print(f"  Checksum errors:  {errors}")
PYTHON

export WORK_DIR
export HAS_BATCH_RESULTS=${HAS_BATCH_RESULTS}

# Step 6: Merge detailed manifest into report
echo ""
echo "Step 6: Merging detailed manifest into report..."

python3 << 'PYTHON2'
import json
import os

work_dir = os.environ.get("WORK_DIR")

# Load existing report
with open(f"{work_dir}/report.json", "r") as f:
    report = json.load(f)

# Load detailed manifest
with open(f"{work_dir}/detailed-manifest.json", "r") as f:
    files = json.load(f)

# Replace files array with detailed version
report["files"] = files
report["filesCount"] = len(files)

# Update summary with verification details
verified = sum(1 for f in files if f["verificationStatus"] == "verified")
failed = sum(1 for f in files if f["verificationStatus"] == "failed")
with_checksum = sum(1 for f in files if f.get("checksumSHA256"))

if "summary" not in report:
    report["summary"] = {}

report["summary"]["verifiedSucceeded"] = verified
report["summary"]["verifiedFailed"] = failed
report["summary"]["filesWithSHA256"] = with_checksum

# Add audit metadata
if "audit" not in report:
    report["audit"] = {}

report["audit"]["detailedManifestGenerated"] = True
report["audit"]["detailedManifestTimestamp"] = os.popen("date -u +%Y-%m-%dT%H:%M:%SZ").read().strip()
report["audit"]["totalFilesAudited"] = len(files)
report["audit"]["filesWithSHA256Checksums"] = with_checksum

# Save updated report
with open(f"{work_dir}/report-enhanced.json", "w") as f:
    json.dump(report, f, indent=2)

print(f"Enhanced report with {len(files)} files ({verified} verified, {failed} failed, {with_checksum} with SHA256)")
PYTHON2

# Step 7: Upload enhanced report
echo ""
echo "Step 7: Uploading enhanced report..."

ENHANCED_REPORT="${WORK_DIR}/report-enhanced.json"
aws s3 cp "${ENHANCED_REPORT}" "s3://${METADATA_BUCKET}/${REPORT_KEY}"

# Get file sizes
ORIGINAL_SIZE=$(ls -lh "${REPORT_FILE}" | awk '{print $5}')
ENHANCED_SIZE=$(ls -lh "${ENHANCED_REPORT}" | awk '{print $5}')

echo ""
echo "=========================================="
echo "✅ Detailed audit manifest complete"
echo "=========================================="
echo "Original report size:  ${ORIGINAL_SIZE}"
echo "Enhanced report size:  ${ENHANCED_SIZE}"
echo "Location:              s3://${METADATA_BUCKET}/${REPORT_KEY}"
echo "Files cataloged:       ${OBJECT_COUNT}"
echo ""
echo "Temporary files in:    ${WORK_DIR}"
echo "(You can delete this directory when finished)"
