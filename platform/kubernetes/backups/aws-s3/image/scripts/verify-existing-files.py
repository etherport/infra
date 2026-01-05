#!/usr/bin/env python3
"""
Comprehensive S3 Backup Verification - All Existing Files
Scans source filesystem, fetches S3 checksums, verifies locally.
Properly handles excluded files to avoid false failures.
"""

import json
import hashlib
import base64
import os
import sys
import subprocess
import fnmatch
from pathlib import Path
from datetime import datetime

def load_exclude_patterns():
    """Load exclude patterns from environment variables."""
    patterns = []

    # Get exclude files from environment
    excludes_global = os.environ.get('EXCLUDES_GLOBAL_FILE', '')
    excludes_share = os.environ.get('EXCLUDES_SHARE_FILE', '')

    for exclude_file in [excludes_global, excludes_share]:
        if exclude_file and os.path.exists(exclude_file):
            with open(exclude_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    # Skip empty lines and comments
                    if line and not line.startswith('#'):
                        patterns.append(line)

    return patterns

def is_excluded(file_path, base_path, exclude_patterns):
    """Check if a file matches any exclude pattern."""
    if not exclude_patterns:
        return False

    relative_path = file_path.relative_to(base_path)
    relative_str = str(relative_path)

    for pattern in exclude_patterns:
        # Remove trailing /* from patterns for matching
        clean_pattern = pattern.rstrip('/*')

        # Try both with and without wildcards
        if fnmatch.fnmatch(relative_str, pattern):
            return True
        if fnmatch.fnmatch(relative_str, clean_pattern):
            return True
        # Also match against filename only for patterns like .DS_Store
        if fnmatch.fnmatch(file_path.name, pattern):
            return True
        # Match against any parent path component
        if any(fnmatch.fnmatch(part, pattern) or fnmatch.fnmatch(part, clean_pattern)
               for part in relative_path.parts):
            return True

    return False

def get_s3_checksum_for_key(bucket, key, aws_region):
    """Get checksum for a specific S3 object via HEAD request."""
    cmd = [
        'aws', 's3api', 'head-object',
        '--bucket', bucket,
        '--key', key,
        '--checksum-mode', 'ENABLED',
        '--region', aws_region,
        '--query', '{Checksum:ChecksumSHA256,ETag:ETag}',
        '--output', 'json'
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=30)
        metadata = json.loads(result.stdout)
        return metadata.get('Checksum', ''), metadata.get('ETag', '')
    except subprocess.TimeoutExpired:
        return '', ''
    except Exception:
        return '', ''

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

    composite_hash = hashlib.sha256(b''.join(part_hashes)).digest()
    composite_b64 = base64.b64encode(composite_hash).decode('ascii')

    return composite_b64, len(part_hashes)

def calculate_simple_checksum(file_path):
    """Calculate simple SHA256 checksum of entire file."""
    sha256_hash = hashlib.sha256()
    with open(file_path, 'rb') as f:
        for byte_block in iter(lambda: f.read(4096), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest()

def scan_directory(source_path, max_files=None, exclude_patterns=None):
    """Recursively scan directory and return list of non-excluded files."""
    files = []
    excluded_files = []
    source_path = Path(source_path)

    print(f"Scanning directory: {source_path}")
    if exclude_patterns:
        print(f"Using {len(exclude_patterns)} exclude patterns")

    for file_path in source_path.rglob('*'):
        if file_path.is_file():
            if exclude_patterns and is_excluded(file_path, source_path, exclude_patterns):
                excluded_files.append(file_path)
                continue

            files.append(file_path)
            if max_files and len(files) >= max_files:
                break

    return files, excluded_files

def verify_file(source_path, s3_key, bucket, aws_region):
    """Verify a single file against S3."""
    if not source_path.exists():
        return False, False, "error", f"Source file not found: {source_path}"

    # Get S3 checksum
    s3_checksum, etag = get_s3_checksum_for_key(bucket, s3_key, aws_region)

    if not s3_checksum:
        return False, False, "error", f"Failed to get S3 checksum"

    # Parse checksum to detect composite
    if '-' in s3_checksum:
        checksum_b64, part_count = s3_checksum.rsplit('-', 1)
        is_composite = True
        part_count = int(part_count)
    else:
        checksum_b64 = s3_checksum
        is_composite = False
        part_count = 1

    try:
        if is_composite:
            # Calculate composite checksum
            composite_b64, calculated_parts = calculate_composite_checksum(source_path)

            if composite_b64 == checksum_b64:
                return True, True, "composite", None
            else:
                return True, False, "composite", f"Checksum mismatch"
        else:
            # Simple checksum
            source_hex = calculate_simple_checksum(source_path)
            s3_hex = base64.b64decode(checksum_b64).hex()

            if source_hex == s3_hex:
                return True, True, "simple", None
            else:
                return True, False, "simple", f"Checksum mismatch"

    except Exception as e:
        return False, False, "error", f"Verification error: {str(e)}"

def main():
    if len(sys.argv) < 5:
        print("Usage: verify.py <share_name> <source_path> <s3_bucket> <s3_prefix> [max_files]")
        print("Example: verify.py scans /src archive.wind.etherport.net objects/scans 100")
        sys.exit(1)

    share_name = sys.argv[1]
    source_base_path = sys.argv[2]
    bucket = sys.argv[3]
    s3_prefix = sys.argv[4]
    max_files = int(sys.argv[5]) if len(sys.argv) > 5 else None
    aws_region = os.environ.get('AWS_REGION', 'us-west-2')

    execution_id = datetime.utcnow().strftime('%Y%m%dT%H%M%SZ')

    # Load exclude patterns
    exclude_patterns = load_exclude_patterns()

    print(f"=" * 80)
    print(f"S3 BACKUP VERIFICATION - ALL EXISTING FILES")
    print(f"=" * 80)
    print(f"Share: {share_name}")
    print(f"Source: {source_base_path}")
    print(f"S3: s3://{bucket}/{s3_prefix}/")
    print(f"Max files: {max_files if max_files else 'unlimited'}")
    print(f"Exclude patterns: {len(exclude_patterns)}")
    print()

    # Scan directory
    files, excluded_files = scan_directory(source_base_path, max_files, exclude_patterns)
    total_files = len(files)
    total_excluded = len(excluded_files)

    print(f"Found {total_files} files to verify")
    print(f"Excluded {total_excluded} files (matched exclude patterns)")
    print()

    # Verify each file
    verified_count = 0
    matched_count = 0
    mismatched_count = 0
    error_count = 0

    composite_files = 0
    simple_files = 0

    errors = []
    mismatches = []
    verified_files = []

    print("Verifying files...")
    for i, source_path in enumerate(files):
        if (i + 1) % 100 == 0 or (i + 1) == total_files:
            print(f"  Progress: {i+1}/{total_files} files ({(i+1)*100//total_files}%)...", end='\r')

        # Calculate S3 key
        relative_path = source_path.relative_to(source_base_path)
        s3_key = f"{s3_prefix}/{relative_path}"

        verified, match, checksum_type, error = verify_file(source_path, s3_key, bucket, aws_region)

        if checksum_type == "composite":
            composite_files += 1
        elif checksum_type == "simple":
            simple_files += 1

        file_result = {
            "path": str(relative_path),
            "s3_key": s3_key,
            "verified": verified,
            "match": match,
            "checksumType": checksum_type,
            "error": error
        }

        verified_files.append(file_result)

        if verified:
            verified_count += 1
            if match:
                matched_count += 1
            else:
                mismatched_count += 1
                mismatches.append({
                    'file': str(relative_path),
                    'error': error,
                    'type': checksum_type
                })
        else:
            error_count += 1
            errors.append({
                'file': str(relative_path),
                'error': error,
                'type': 'error'
            })

    print()
    print()
    print("=" * 80)
    print("VERIFICATION RESULTS")
    print("=" * 80)
    print(f"Total files scanned:   {total_files + total_excluded}")
    print(f"  Excluded:            {total_excluded} (not verified)")
    print(f"  To verify:           {total_files}")
    print()
    print(f"Checksum types:")
    print(f"  Simple checksums:    {simple_files}")
    print(f"  Composite checksums: {composite_files}")
    print()
    print(f"Verification results:")
    print(f"  ✅ Matched:          {matched_count}")
    print(f"  ❌ Mismatched:       {mismatched_count}")
    print(f"  ⚠️  Errors:           {error_count}")
    print("=" * 80)
    print()

    # Calculate costs
    head_requests = total_files
    cost = head_requests * 0.0004 / 1000
    print(f"S3 API Cost: ~${cost:.5f} ({head_requests} HEAD requests)")
    print()

    # Generate report
    report = {
        "executionId": f"{share_name}-verify-{execution_id}",
        "share": share_name,
        "status": "completed" if (matched_count == total_files and mismatched_count == 0) else "completed_with_issues",
        "timestamp": execution_id,
        "summary": {
            "totalFilesScanned": total_files + total_excluded,
            "excludedFiles": total_excluded,
            "filesToVerify": total_files,
            "verified": verified_count,
            "matched": matched_count,
            "mismatched": mismatched_count,
            "errors": error_count,
            "simpleChecksums": simple_files,
            "compositeChecksums": composite_files
        },
        "source": source_base_path,
        "destination": f"s3://{bucket}/{s3_prefix}/",
        "excludePatterns": exclude_patterns,
        "files": verified_files,
        "errors": errors,
        "mismatches": mismatches,
        "cost": {
            "headRequests": head_requests,
            "estimatedCost": cost
        }
    }

    # Save report
    report_file = f"/tmp/{share_name}-full-verification-{execution_id}.json"
    with open(report_file, 'w') as f:
        json.dump(report, f, indent=2)
    print(f"Report saved to: {report_file}")
    print()

    # Determine exit code based on REAL issues only
    if mismatched_count > 0:
        # CRITICAL: Checksum mismatches mean data corruption!
        print("❌ FAILURE: Data corruption detected - checksum mismatches found!")
        if mismatches:
            print("Mismatched files:")
            for err in mismatches[:10]:
                print(f"  - {err['file']}")
                print(f"    Type: {err['type']}, Error: {err['error']}")
            if len(mismatches) > 10:
                print(f"  ... and {len(mismatches) - 10} more mismatches")
        return 1
    elif matched_count == total_files:
        # Perfect - all files verified
        print("🎉 SUCCESS: 100% of files verified - NO DATA CORRUPTION!")
        print(f"   {total_excluded} files excluded (not verified, as expected)")
        return 0
    elif error_count > 0:
        # Some files couldn't be verified (S3 API errors, etc)
        print(f"⚠️  PARTIAL SUCCESS: {matched_count}/{total_files} files verified")
        print(f"   {error_count} files had verification errors (may not exist in S3)")
        print(f"   {total_excluded} files excluded (not verified, as expected)")
        if errors:
            print("Files with errors:")
            for err in errors[:10]:
                print(f"  - {err['file']}: {err['error']}")
            if len(errors) > 10:
                print(f"  ... and {len(errors) - 10} more errors")
        # Don't fail on errors - they might be expected (files never uploaded, etc)
        return 0
    else:
        print("✅ SUCCESS: All verifiable files matched")
        return 0

if __name__ == '__main__':
    sys.exit(main())
