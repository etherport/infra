#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# daily-report.sh
#
# Generates HTML email report of S3 sync executions in the last 24 hours.
# Queries Prometheus for backup metrics and Kubernetes for job details.
#
# Requires:
#   - kubectl, curl, jq, python3 in PATH
#   - /scripts/send-email.sh present and executable
#   - AWS creds in env (for SES), and EMAIL_* env vars
#
# Env:
#   PROM_URL                  Prometheus URL (required)
#   EMAIL_FROM, EMAIL_TO, EMAIL_SUBJECT (required)
# ------------------------------------------------------------------------------

: "${PROM_URL:?missing PROM_URL}"
: "${EMAIL_FROM:?missing EMAIL_FROM}"
: "${EMAIL_TO:?missing EMAIL_TO}"
: "${EMAIL_SUBJECT:?missing EMAIL_SUBJECT}"

SEND_EMAIL_SCRIPT="${SEND_EMAIL_SCRIPT:-/scripts/send-email.sh}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
DEST_BUCKET="${DEST_BUCKET:-archive-test.wind.etherport.net}"
BATCH_PREFIX="${BATCH_PREFIX:-batch}"
AWS_REGION="${AWS_REGION:-us-west-2}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[daily-report] ERROR: kubectl not found" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[daily-report] ERROR: python3 not found" >&2
  exit 2
fi

if [[ ! -x "$SEND_EMAIL_SCRIPT" ]]; then
  echo "[daily-report] ERROR: send-email script not found/executable at: $SEND_EMAIL_SCRIPT" >&2
  exit 2
fi

NOW_EPOCH=$(date +%s)
LOOKBACK_SECONDS=$((LOOKBACK_HOURS * 3600))
START_EPOCH=$((NOW_EPOCH - LOOKBACK_SECONDS))

# Query Prometheus for backup metrics
# We want the latest metrics for each share that were updated in the last 24 hours
PROM_QUERY='homelab_backup_last_run_timestamp_seconds'

METRICS_JSON=$(curl -sS "${PROM_URL}/api/v1/query?query=${PROM_QUERY}" | jq -c '.data.result')

# Get all Jobs from Kubernetes in backups namespace
JOBS_JSON=$(kubectl -n backups get jobs -o json | jq -c '.items')

# Generate HTML report using Python
export NOW_EPOCH START_EPOCH LOOKBACK_HOURS METRICS_JSON JOBS_JSON PROM_URL

REPORT_FILE=$(mktemp)
trap 'rm -f "$REPORT_FILE"' EXIT

python3 - > "${REPORT_FILE}" <<'PYTHON'
import os, json, sys
from datetime import datetime, timezone, timedelta
from collections import defaultdict
import urllib.request
import urllib.parse

now_epoch = int(os.environ['NOW_EPOCH'])
start_epoch = int(os.environ['START_EPOCH'])
lookback_hours = int(os.environ['LOOKBACK_HOURS'])
prom_url = os.environ['PROM_URL']

metrics_json = json.loads(os.environ['METRICS_JSON'])
jobs_json = json.loads(os.environ['JOBS_JSON'])

now = datetime.fromtimestamp(now_epoch, tz=timezone.utc)
start = datetime.fromtimestamp(start_epoch, tz=timezone.utc)

# Convert to Pacific Time for display
pacific_offset = timedelta(hours=-8)  # PST (adjust for PDT as needed)
now_pt = now + pacific_offset
start_pt = start + pacific_offset

def parse_ts(s):
    if not s:
        return None
    try:
        if s.endswith("Z"):
            return datetime.fromisoformat(s.replace("Z", "+00:00"))
        return datetime.fromisoformat(s)
    except:
        return None

def to_pt(dt):
    if not dt:
        return None
    return dt + pacific_offset

def format_bytes(b):
    if b == 0:
        return "0 B"
    units = ["B", "KB", "MB", "GB", "TB"]
    i = 0
    while b >= 1024 and i < len(units) - 1:
        b /= 1024.0
        i += 1
    return f"{b:.1f} {units[i]}"

def format_duration(seconds):
    if seconds == 0:
        return "-"
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    if h > 0:
        return f"{h}h {m}m {s}s"
    elif m > 0:
        return f"{m}m {s}s"
    else:
        return f"{s}s"

# Query Prometheus for each metric we need
def prom_query(query):
    url = f"{prom_url}/api/v1/query?query={urllib.parse.quote(query)}"
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = json.load(resp)
            return data.get('data', {}).get('result', [])
    except Exception as e:
        print(f"[warn] Prometheus query failed: {e}", file=sys.stderr)
        return []

# Build a map of latest Prometheus metrics per share
prom_metrics_by_share = {}
for metric in metrics_json:
    labels = metric.get('metric', {})
    share = labels.get('share', '')
    if not share:
        continue

    prom_metrics_by_share[share] = {
        'bucket': labels.get('bucket', ''),
        'timestamp': int(float(metric.get('value', [0, 0])[1])),
    }

# For each share with metrics, get additional metrics from Prometheus
for share in list(prom_metrics_by_share.keys()):
    # Get success status
    success_result = prom_query(f'homelab_backup_last_run_success{{share="{share}"}}')
    if success_result:
        prom_metrics_by_share[share]['success'] = int(float(success_result[0]['value'][1]))
    else:
        prom_metrics_by_share[share]['success'] = 0

    # Get files transferred
    files_result = prom_query(f'homelab_backup_last_run_files_total{{share="{share}"}}')
    if files_result:
        prom_metrics_by_share[share]['files'] = int(float(files_result[0]['value'][1]))
    else:
        prom_metrics_by_share[share]['files'] = 0

    # Get bytes transferred
    bytes_result = prom_query(f'homelab_backup_last_run_bytes_total{{share="{share}"}}')
    if bytes_result:
        prom_metrics_by_share[share]['bytes'] = int(float(bytes_result[0]['value'][1]))
    else:
        prom_metrics_by_share[share]['bytes'] = 0

    # Get duration
    duration_result = prom_query(f'homelab_backup_last_run_duration_seconds{{share="{share}"}}')
    if duration_result:
        prom_metrics_by_share[share]['duration'] = int(float(duration_result[0]['value'][1]))
    else:
        prom_metrics_by_share[share]['duration'] = 0

# Helper to download and parse S3 summary JSON for a specific execution
def get_s3_summary_metrics(share, start_time_epoch):
    """
    Try to download the S3 summary JSON for this execution.
    Returns dict with metrics or empty dict if not found.
    """
    import subprocess

    dest_bucket = os.environ.get('DEST_BUCKET', 'archive-test.wind.etherport.net')
    batch_prefix = os.environ.get('BATCH_PREFIX', 'batch')
    aws_region = os.environ.get('AWS_REGION', 'us-west-2')

    # List summary files for this share
    s3_prefix = f"s3://{dest_bucket}/{batch_prefix}/runs/{share}/"

    try:
        # List all summary JSON files for this share
        result = subprocess.run(
            ['aws', 's3', 'ls', s3_prefix, '--region', aws_region],
            capture_output=True, text=True, timeout=10
        )

        if result.returncode != 0:
            return {}

        # Parse the listing to find files matching our time window
        # Files are named like: scans-20251228T214429Z.json
        # We want the one closest to our start_time
        best_match = None
        best_diff = float('inf')

        for line in result.stdout.strip().split('\n'):
            if not line or not line.endswith('.json'):
                continue

            parts = line.split()
            if len(parts) < 4:
                continue

            filename = parts[-1]

            # Extract timestamp from filename (format: {share}-{timestamp}.json)
            # Example: scans-20251228T214429Z.json
            if not filename.startswith(f'{share}-'):
                continue

            ts_part = filename[len(share)+1:-5]  # Remove "share-" prefix and ".json" suffix

            # Parse timestamp: 20251228T214429Z -> epoch
            try:
                file_dt = datetime.strptime(ts_part, '%Y%m%dT%H%M%SZ').replace(tzinfo=timezone.utc)
                file_epoch = int(file_dt.timestamp())

                # Find the file closest to our job's start time
                diff = abs(file_epoch - start_time_epoch)
                if diff < best_diff and diff < 300:  # Within 5 minutes
                    best_diff = diff
                    best_match = filename
            except:
                continue

        if not best_match:
            return {}

        # Download the summary file
        s3_path = f"{s3_prefix}{best_match}"
        result = subprocess.run(
            ['aws', 's3', 'cp', s3_path, '-', '--region', aws_region],
            capture_output=True, text=True, timeout=10
        )

        if result.returncode != 0:
            return {}

        summary = json.loads(result.stdout)

        # Extract metrics from summary
        return {
            'success': 1 if summary.get('sync_exit_code', 1) == 0 else 0,
            'files': summary.get('files_transferred', 0),
            'bytes': summary.get('bytes_transferred', 0),
            'duration': summary.get('duration_seconds', 0),
        }

    except Exception as e:
        print(f"[warn] Failed to fetch S3 summary for {share}: {e}", file=sys.stderr)
        return {}

# Collect all job executions in the time window (job-centric, not share-centric)
executions = []
for job in jobs_json:
    job_name = job.get('metadata', {}).get('name', '')

    # Extract share name from job name (format: s3-sync-{share}-*)
    if not job_name.startswith('s3-sync-'):
        continue

    # Remove 's3-sync-' prefix and extract first component as share name
    rest = job_name[8:]  # Remove 's3-sync-'
    parts = rest.split('-')
    if len(parts) < 1:
        continue

    # Share name is the first part after 's3-sync-'
    share = parts[0]

    status = job.get('status', {})
    start_time = parse_ts(status.get('startTime'))
    completion_time = parse_ts(status.get('completionTime'))

    # Only include jobs that started in our time window
    if not start_time or start_time.timestamp() < start_epoch:
        continue

    # Determine job status
    if status.get('active', 0) > 0:
        job_status = 'running'
    elif status.get('succeeded', 0) > 0:
        job_status = 'succeeded'
    elif status.get('failed', 0) > 0:
        job_status = 'failed'
    else:
        job_status = 'unknown'

    # Try to get metrics from S3 summary JSON (most accurate)
    start_time_epoch = int(start_time.timestamp())
    metrics = get_s3_summary_metrics(share, start_time_epoch)

    # Fall back to Prometheus if S3 summary not found
    if not metrics:
        metrics = prom_metrics_by_share.get(share, {})

    execution = {
        'job_name': job_name,
        'share': share,
        'start_time': start_time,
        'end_time': completion_time,
        'job_status': job_status,
        'success': metrics.get('success', 0),
        'files': metrics.get('files', 0),
        'bytes': metrics.get('bytes', 0),
        'duration': metrics.get('duration', 0),
    }

    executions.append(execution)

# Calculate summary totals
total_executions = len(executions)
total_completed = sum(1 for e in executions if e.get('job_status') == 'succeeded' and e.get('success', 0) == 1)
total_in_progress = sum(1 for e in executions if e.get('job_status') == 'running')
total_errors = sum(1 for e in executions if e.get('job_status') in ['failed', 'unknown'] or (e.get('job_status') == 'succeeded' and e.get('success', 0) == 0))
total_files = sum(e.get('files', 0) for e in executions)
total_bytes = sum(e.get('bytes', 0) for e in executions)

# Generate HTML
html = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<style>
body {{
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
    line-height: 1.6;
    color: #333;
    max-width: 1100px;
    margin: 0 auto;
    padding: 20px;
    background-color: #f5f5f5;
}}
.header {{
    background: white;
    padding: 20px;
    border-radius: 8px;
    margin-bottom: 20px;
}}
.header h1 {{
    margin: 0 0 8px 0;
    font-size: 28px;
    font-weight: 600;
}}
.header .meta {{
    color: #666;
    font-size: 14px;
}}
.summary {{
    margin-bottom: 20px;
}}
.summary-period {{
    font-size: 16px;
    margin-bottom: 16px;
    color: #333;
}}
.metrics-grid {{
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
    gap: 16px;
    margin-bottom: 20px;
}}
.metric-card {{
    background: white;
    padding: 20px;
    border-radius: 8px;
    text-align: center;
    border: 1px solid #e0e0e0;
}}
.metric-card.completed {{
    background-color: #d4edda;
    border-color: #c3e6cb;
}}
.metric-card.in-progress {{
    background-color: #fff3cd;
    border-color: #ffeaa7;
}}
.metric-card.errors {{
    background-color: #f8d7da;
    border-color: #f5c6cb;
}}
.metric-label {{
    font-size: 14px;
    color: #666;
    margin-bottom: 8px;
}}
.metric-value {{
    font-size: 32px;
    font-weight: 600;
    color: #333;
}}
.task-card {{
    background: white;
    padding: 24px;
    border-radius: 8px;
    margin-bottom: 16px;
    border: 1px solid #e0e0e0;
}}
.task-header {{
    font-size: 20px;
    font-weight: 600;
    margin-bottom: 16px;
    display: flex;
    justify-content: space-between;
    align-items: center;
}}
.status-badge {{
    display: inline-block;
    padding: 4px 12px;
    border-radius: 4px;
    font-size: 12px;
    font-weight: 600;
    text-transform: lowercase;
}}
.status-succeeded {{
    background-color: #d4edda;
    color: #155724;
}}
.status-running {{
    background-color: #fff3cd;
    color: #856404;
}}
.status-error {{
    background-color: #f8d7da;
    color: #721c24;
}}
.task-details {{
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
}}
.detail-row {{
    display: flex;
    justify-content: space-between;
    padding: 8px 0;
    border-bottom: 1px solid #f0f0f0;
}}
.detail-label {{
    color: #666;
    font-size: 14px;
}}
.detail-value {{
    color: #333;
    font-weight: 500;
    font-size: 14px;
}}
</style>
</head>
<body>

<div class="header">
    <h1>S3 Backup Executions</h1>
    <div class="meta">Run time: {now_pt.strftime('%Y-%m-%d %H:%M:%S')} PT</div>
</div>

<div class="summary">
    <div class="summary-period">Summary period: {start_pt.strftime('%Y-%m-%d %H:%M')} PT – {now_pt.strftime('%Y-%m-%d %H:%M')} PT</div>

    <div class="metrics-grid">
        <div class="metric-card">
            <div class="metric-label">Executions</div>
            <div class="metric-value">{total_executions}</div>
        </div>
        <div class="metric-card{' completed' if total_completed > 0 else ''}">
            <div class="metric-label">Completed</div>
            <div class="metric-value">{total_completed}</div>
        </div>
        <div class="metric-card{' in-progress' if total_in_progress > 0 else ''}">
            <div class="metric-label">In progress</div>
            <div class="metric-value">{total_in_progress}</div>
        </div>
        <div class="metric-card{' errors' if total_errors > 0 else ''}">
            <div class="metric-label">Errors</div>
            <div class="metric-value">{total_errors}</div>
        </div>
        <div class="metric-card">
            <div class="metric-label">Total files transferred</div>
            <div class="metric-value">{total_files:,}</div>
        </div>
        <div class="metric-card">
            <div class="metric-label">Total data transferred</div>
            <div class="metric-value">{format_bytes(total_bytes)}</div>
        </div>
    </div>
</div>
"""

# Sort executions by start time (most recent first)
sorted_executions = sorted(executions, key=lambda x: x.get('start_time') or datetime.min.replace(tzinfo=timezone.utc), reverse=True)

for execution in sorted_executions:
    share = execution['share']
    job_status = execution.get('job_status', 'unknown')
    success = execution.get('success', 0)

    # Determine status and badge
    if job_status == 'running':
        status_text = 'in progress'
        status_class = 'running'
    elif job_status == 'succeeded' and success == 1:
        status_text = 'completed'
        status_class = 'succeeded'
    else:
        status_text = 'error'
        status_class = 'error'

    start_time = execution.get('start_time')
    end_time = execution.get('end_time')
    start_pt = to_pt(start_time) if start_time else None
    end_pt = to_pt(end_time) if end_time else None

    html += f"""
<div class="task-card">
    <div class="task-header">
        <span>Sequoia to S3 - {share.title()}</span>
        <span class="status-badge status-{status_class}">{status_text}</span>
    </div>
    <div class="task-details">
        <div class="detail-row">
            <span class="detail-label">Files transferred</span>
            <span class="detail-value">{execution.get('files', 0):,}</span>
        </div>
        <div class="detail-row">
            <span class="detail-label">Data transferred</span>
            <span class="detail-value">{format_bytes(execution.get('bytes', 0))}</span>
        </div>
        <div class="detail-row">
            <span class="detail-label">Start time (PT)</span>
            <span class="detail-value">{start_pt.strftime('%H:%M') if start_pt else '-'}</span>
        </div>
        <div class="detail-row">
            <span class="detail-label">End time (PT)</span>
            <span class="detail-value">{end_pt.strftime('%H:%M') if end_pt else '-'}</span>
        </div>
        <div class="detail-row">
            <span class="detail-label">Duration</span>
            <span class="detail-value">{format_duration(execution.get('duration', 0))}</span>
        </div>
    </div>
</div>
"""

html += """
</body>
</html>
"""

print(html)
PYTHON

# Send HTML email
HTML_BODY=$(cat "$REPORT_FILE")
export HTML_BODY

"$SEND_EMAIL_SCRIPT" --html

echo "[daily-report] sent to $EMAIL_TO"
