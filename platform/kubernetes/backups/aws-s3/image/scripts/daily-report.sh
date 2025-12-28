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

# Get metrics for all shares
shares_data = {}
for metric in metrics_json:
    labels = metric.get('metric', {})
    share = labels.get('share', '')
    if not share:
        continue

    timestamp = int(float(metric.get('value', [0, 0])[1]))

    # Only include if timestamp is within lookback window
    if timestamp < start_epoch:
        continue

    if share not in shares_data:
        shares_data[share] = {
            'share': share,
            'bucket': labels.get('bucket', ''),
            'timestamp': timestamp,
        }

# For each share, get additional metrics
for share in list(shares_data.keys()):
    # Get success status
    success_result = prom_query(f'homelab_backup_last_run_success{{share="{share}"}}')
    if success_result:
        shares_data[share]['success'] = int(float(success_result[0]['value'][1]))
    else:
        shares_data[share]['success'] = 0

    # Get files transferred
    files_result = prom_query(f'homelab_backup_last_run_files_total{{share="{share}"}}')
    if files_result:
        shares_data[share]['files'] = int(float(files_result[0]['value'][1]))
    else:
        shares_data[share]['files'] = 0

    # Get bytes transferred
    bytes_result = prom_query(f'homelab_backup_last_run_bytes_total{{share="{share}"}}')
    if bytes_result:
        shares_data[share]['bytes'] = int(float(bytes_result[0]['value'][1]))
    else:
        shares_data[share]['bytes'] = 0

    # Get duration
    duration_result = prom_query(f'homelab_backup_last_run_duration_seconds{{share="{share}"}}')
    if duration_result:
        shares_data[share]['duration'] = int(float(duration_result[0]['value'][1]))
    else:
        shares_data[share]['duration'] = 0

# Match with Kubernetes Jobs to get timing details
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
    # E.g., 's3-sync-scans-manual-20251228' -> 'scans'
    share = parts[0]

    if share not in shares_data:
        continue

    status = job.get('status', {})
    start_time = parse_ts(status.get('startTime'))
    completion_time = parse_ts(status.get('completionTime'))

    # Check if job is in our time window
    if start_time and start_time.timestamp() >= start_epoch:
        shares_data[share]['start_time'] = start_time
        shares_data[share]['end_time'] = completion_time
        shares_data[share]['job_name'] = job_name

        # Determine job status
        if status.get('active', 0) > 0:
            shares_data[share]['job_status'] = 'running'
        elif status.get('succeeded', 0) > 0:
            shares_data[share]['job_status'] = 'succeeded'
        elif status.get('failed', 0) > 0:
            shares_data[share]['job_status'] = 'failed'
        else:
            shares_data[share]['job_status'] = 'unknown'

# Calculate summary totals
total_executions = len(shares_data)
total_completed = sum(1 for s in shares_data.values() if s.get('job_status') == 'succeeded')
total_in_progress = sum(1 for s in shares_data.values() if s.get('job_status') == 'running')
total_errors = sum(1 for s in shares_data.values() if s.get('job_status') in ['failed', 'unknown'] or s.get('success', 0) == 0)
total_files = sum(s.get('files', 0) for s in shares_data.values())
total_bytes = sum(s.get('bytes', 0) for s in shares_data.values())

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
.metric-card.executions {{
    background-color: #d4edda;
    border-color: #c3e6cb;
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
        <div class="metric-card executions">
            <div class="metric-label">Executions</div>
            <div class="metric-value">{total_executions}</div>
        </div>
        <div class="metric-card">
            <div class="metric-label">Completed</div>
            <div class="metric-value">{total_completed}</div>
        </div>
        <div class="metric-card">
            <div class="metric-label">In progress</div>
            <div class="metric-value">{total_in_progress}</div>
        </div>
        <div class="metric-card errors">
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

# Sort shares by name
sorted_shares = sorted(shares_data.values(), key=lambda x: x['share'])

for share_data in sorted_shares:
    share = share_data['share']
    job_status = share_data.get('job_status', 'unknown')
    success = share_data.get('success', 0)

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

    start_time = share_data.get('start_time')
    end_time = share_data.get('end_time')
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
            <span class="detail-value">{share_data.get('files', 0):,}</span>
        </div>
        <div class="detail-row">
            <span class="detail-label">Data transferred</span>
            <span class="detail-value">{format_bytes(share_data.get('bytes', 0))}</span>
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
            <span class="detail-value">{format_duration(share_data.get('duration', 0))}</span>
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
