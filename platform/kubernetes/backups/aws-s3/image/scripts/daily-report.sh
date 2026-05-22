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
METADATA_BUCKET="${METADATA_BUCKET:-logs.archive.wind.etherport.net}"
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

# Create temp files first (before environment gets large)
REPORT_FILE=$(mktemp)
METRICS_FILE=$(mktemp)
JOBS_FILE=$(mktemp)
trap 'rm -f "$REPORT_FILE" "$METRICS_FILE" "$JOBS_FILE"' EXIT

# Query Prometheus for backup metrics
# We want the latest metrics for each share that were updated in the last 24 hours
PROM_QUERY='homelab_backup_last_run_timestamp_seconds'

curl -sS "${PROM_URL}/api/v1/query?query=${PROM_QUERY}" | jq -c '.data.result' > "$METRICS_FILE"

# Get all Jobs from Kubernetes in backups namespace
kubectl -n backups get jobs -o json | jq -c '.items' > "$JOBS_FILE"

# Generate HTML report using Python (pass large data via files, not env vars)
export NOW_EPOCH START_EPOCH LOOKBACK_HOURS PROM_URL METADATA_BUCKET METRICS_FILE JOBS_FILE

python3 - > "${REPORT_FILE}" <<'PYTHON'
import os, json, sys
from datetime import datetime, timezone, timedelta
from zoneinfo import ZoneInfo
from collections import defaultdict
import urllib.request
import urllib.parse

now_epoch = int(os.environ['NOW_EPOCH'])
start_epoch = int(os.environ['START_EPOCH'])
lookback_hours = int(os.environ['LOOKBACK_HOURS'])
prom_url = os.environ['PROM_URL']

# Read large JSON data from files instead of environment variables
with open(os.environ['METRICS_FILE']) as f:
    metrics_json = json.load(f)
with open(os.environ['JOBS_FILE']) as f:
    jobs_json = json.load(f)

now = datetime.fromtimestamp(now_epoch, tz=timezone.utc)
start = datetime.fromtimestamp(start_epoch, tz=timezone.utc)

# Convert to Pacific Time for display (handles DST automatically)
pacific = ZoneInfo("America/Los_Angeles")
now_pt = now.astimezone(pacific)
start_pt = start.astimezone(pacific)

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
    return dt.astimezone(pacific)

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
# Only include actual backup shares (exclude daily-report and other non-backup jobs)
expected_shares = os.environ.get('SHARES', 'scans archive backups content graham mark media').split()
prom_metrics_by_share = {}
for metric in metrics_json:
    labels = metric.get('metric', {})
    share = labels.get('share', '')
    if not share:
        continue

    # Skip shares that aren't in the expected backup shares list
    if share not in expected_shares:
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

    metadata_bucket = os.environ.get('METADATA_BUCKET', 'logs.archive.wind.etherport.net')
    aws_region = os.environ.get('AWS_REGION', 'us-west-2')

    # List consolidated report directories for this share
    # Reports are stored at: s3://{metadata_bucket}/reports/{share}/{timestamp}/report.json
    s3_prefix = f"s3://{metadata_bucket}/reports/{share}/"

    try:
        # List all directories (timestamps) for this share
        result = subprocess.run(
            ['aws', 's3', 'ls', s3_prefix, '--region', aws_region],
            capture_output=True, text=True, timeout=10
        )

        if result.returncode != 0:
            return {}

        # Parse the listing to find timestamp directories matching our time window
        # Directories are named like: 20251231T003444Z/
        # We want the one closest to our start_time
        best_match = None
        best_diff = float('inf')

        for line in result.stdout.strip().split('\n'):
            if not line or not line.endswith('/'):
                continue

            parts = line.split()
            if len(parts) < 2:
                continue

            # Directory name is the last part (format: 20251231T003444Z/)
            dirname = parts[-1].rstrip('/')

            # Parse timestamp: 20251231T003444Z -> epoch
            try:
                file_dt = datetime.strptime(dirname, '%Y%m%dT%H%M%SZ').replace(tzinfo=timezone.utc)
                file_epoch = int(file_dt.timestamp())

                # Find the directory closest to our job's start time
                diff = abs(file_epoch - start_time_epoch)
                if diff < best_diff and diff < 300:  # Within 5 minutes
                    best_diff = diff
                    best_match = dirname
            except:
                continue

        if not best_match:
            return {}

        # Download the consolidated report file
        s3_path = f"{s3_prefix}{best_match}/report.json"
        result = subprocess.run(
            ['aws', 's3', 'cp', s3_path, '-', '--region', aws_region],
            capture_output=True, text=True, timeout=10
        )

        if result.returncode != 0:
            return {}

        summary = json.loads(result.stdout)

        # Extract metrics from consolidated report
        # Report structure: {status, sync: {exitCode, filesTransferred, bytesTransferred}, summary: {...}, durationSeconds}
        report_status = summary.get('status', 'UNKNOWN')
        sync_data = summary.get('sync', {})
        summary_data = summary.get('summary', {})

        # Check both top-level status field AND sync exitCode
        # Report status should be "SUCCESS" and sync exitCode should be 0
        is_success = (
            report_status == 'SUCCESS' and
            sync_data.get('exitCode', 1) == 0
        )

        return {
            'success': 1 if is_success else 0,
            'files': summary_data.get('filesTransferred', 0),
            'bytes': summary_data.get('bytesTransferred', 0),
            'duration': summary.get('durationSeconds', 0),
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

    # Exclude the daily-report job itself
    if 'daily-report' in job_name:
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

# Determine overall status pill
if total_errors > 0:
    overall_pill_class = 'err'
    overall_pill_text = f"{total_errors} error{'s' if total_errors != 1 else ''}"
elif total_in_progress > 0:
    overall_pill_class = 'warn'
    overall_pill_text = f"{total_in_progress} in progress"
elif total_executions == 0:
    overall_pill_class = 'warn'
    overall_pill_text = "No runs in window"
else:
    overall_pill_class = 'ok'
    overall_pill_text = f"All {total_completed} completed"

# Sort executions by start time (most recent first)
sorted_executions = sorted(
    executions,
    key=lambda x: x.get('start_time') or datetime.min.replace(tzinfo=timezone.utc),
    reverse=True,
)

# Build per-execution task cards
tasks_html_parts = []
for execution in sorted_executions:
    share = execution['share']
    job_status = execution.get('job_status', 'unknown')
    success = execution.get('success', 0)

    if job_status == 'running':
        status_text, status_class = 'in progress', 'warn'
    elif job_status == 'succeeded' and success == 1:
        status_text, status_class = 'completed', 'ok'
    else:
        status_text, status_class = 'error', 'err'

    start_time_v = execution.get('start_time')
    end_time_v = execution.get('end_time')
    start_pt_v = to_pt(start_time_v) if start_time_v else None
    end_pt_v = to_pt(end_time_v) if end_time_v else None

    tasks_html_parts.append(f"""
        <div class="task">
            <div class="task-head">
                <span class="task-name">{share.title()}</span>
                <span class="pill pill-{status_class}"><span class="dot"></span>{status_text}</span>
            </div>
            <div class="task-body">
                <div class="kv"><div class="kv-label">Files</div><div class="kv-value">{execution.get('files', 0):,}</div></div>
                <div class="kv"><div class="kv-label">Data</div><div class="kv-value">{format_bytes(execution.get('bytes', 0))}</div></div>
                <div class="kv"><div class="kv-label">Start</div><div class="kv-value mono">{start_pt_v.strftime('%H:%M') if start_pt_v else '—'}</div></div>
                <div class="kv"><div class="kv-label">End</div><div class="kv-value mono">{end_pt_v.strftime('%H:%M') if end_pt_v else '—'}</div></div>
                <div class="kv kv-wide"><div class="kv-label">Duration</div><div class="kv-value">{format_duration(execution.get('duration', 0))}</div></div>
            </div>
        </div>""")

tasks_html = '\n'.join(tasks_html_parts) if tasks_html_parts else \
    '<div class="empty">No executions in this window.</div>'

# Render the full email. Targets Apple Mail (iCloud) primarily — modern
# CSS (vars, grid, prefers-color-scheme) is supported there. Other
# clients degrade to plainer layout but content stays legible.
html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>Sequoia → S3 backup report</title>
<style>
  :root {{
    --bg: #f6f7f9;
    --surface: #ffffff;
    --text: #0f172a;
    --text-muted: #64748b;
    --border: #e5e7eb;
    --border-soft: #eef0f3;
    --ok: #047857;       --ok-bg: #ecfdf5;
    --warn: #b45309;     --warn-bg: #fffbeb;
    --err: #b91c1c;      --err-bg: #fef2f2;
    --accent: #1f2937;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      --bg: #0b1220;
      --surface: #131c2e;
      --text: #e8eaf0;
      --text-muted: #94a3b8;
      --border: #243049;
      --border-soft: #1b2538;
      --ok: #34d399;     --ok-bg: rgba(16,185,129,0.12);
      --warn: #fbbf24;   --warn-bg: rgba(217,119,6,0.15);
      --err: #f87171;    --err-bg: rgba(220,38,38,0.16);
      --accent: #f1f5f9;
    }}
  }}
  body {{
    margin: 0; padding: 0;
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Helvetica, Arial, sans-serif;
    font-size: 15px;
    line-height: 1.5;
    -webkit-font-smoothing: antialiased;
    -webkit-text-size-adjust: 100%;
  }}
  .wrap {{ max-width: 680px; margin: 0 auto; padding: 36px 20px 56px; }}
  .eyebrow {{
    font-size: 11px;
    font-weight: 600;
    color: var(--text-muted);
    letter-spacing: 0.12em;
    text-transform: uppercase;
    margin: 0 0 10px;
  }}
  h1 {{
    font-size: 26px;
    font-weight: 700;
    letter-spacing: -0.015em;
    margin: 0 0 6px;
    color: var(--accent);
  }}
  .subhead {{
    color: var(--text-muted);
    font-size: 14px;
    margin: 0 0 22px;
  }}
  .pill {{
    display: inline-flex;
    align-items: center;
    gap: 7px;
    padding: 5px 11px;
    border-radius: 999px;
    font-size: 13px;
    font-weight: 500;
    line-height: 1;
  }}
  .pill .dot {{
    width: 7px; height: 7px; border-radius: 50%; background: currentColor;
    display: inline-block;
  }}
  .pill-ok   {{ background: var(--ok-bg);   color: var(--ok);   }}
  .pill-warn {{ background: var(--warn-bg); color: var(--warn); }}
  .pill-err  {{ background: var(--err-bg);  color: var(--err);  }}
  .hero-status {{ margin: 0 0 32px; }}
  .section-label {{
    font-size: 11px;
    font-weight: 600;
    color: var(--text-muted);
    letter-spacing: 0.1em;
    text-transform: uppercase;
    margin: 0 0 10px;
  }}
  .metrics {{
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 10px;
    margin: 0 0 32px;
  }}
  @media (max-width: 520px) {{
    .metrics {{ grid-template-columns: repeat(2, 1fr); }}
  }}
  .metric {{
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 14px 16px;
  }}
  .metric-label {{
    font-size: 11px;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.06em;
    margin: 0 0 6px;
  }}
  .metric-value {{
    font-size: 22px;
    font-weight: 600;
    line-height: 1.15;
    color: var(--accent);
    font-variant-numeric: tabular-nums;
  }}
  .metric.tone-ok   .metric-value {{ color: var(--ok); }}
  .metric.tone-warn .metric-value {{ color: var(--warn); }}
  .metric.tone-err  .metric-value {{ color: var(--err); }}
  .task {{
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 12px;
    margin: 0 0 10px;
    overflow: hidden;
  }}
  .task-head {{
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 14px 18px;
    border-bottom: 1px solid var(--border-soft);
  }}
  .task-name {{ font-weight: 600; font-size: 15px; color: var(--text); }}
  .task-body {{
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 0;
  }}
  .kv {{
    padding: 12px 18px;
    border-top: 1px solid var(--border-soft);
    border-right: 1px solid var(--border-soft);
  }}
  .kv:nth-child(even) {{ border-right: none; }}
  .kv:nth-child(-n+2) {{ border-top: none; }}
  .kv-wide {{ grid-column: 1 / -1; border-right: none; }}
  .kv-label {{
    font-size: 11px;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.05em;
    margin: 0 0 3px;
  }}
  .kv-value {{
    font-size: 14px;
    color: var(--text);
    font-variant-numeric: tabular-nums;
  }}
  .kv-value.mono {{
    font-family: ui-monospace, SFMono-Regular, Menlo, "JetBrains Mono", monospace;
    font-size: 13px;
  }}
  .empty {{
    background: var(--surface);
    border: 1px dashed var(--border);
    border-radius: 12px;
    padding: 24px;
    color: var(--text-muted);
    text-align: center;
  }}
  .footer {{
    margin-top: 36px;
    padding-top: 18px;
    border-top: 1px solid var(--border);
    font-size: 12px;
    color: var(--text-muted);
    text-align: center;
  }}
</style>
</head>
<body>
<div class="wrap">
  <div class="eyebrow">Homelab · backups</div>
  <h1>Sequoia → S3 backup report</h1>
  <p class="subhead">{start_pt.strftime('%a %b %-d')} {start_pt.strftime('%H:%M')} – {now_pt.strftime('%a %b %-d %H:%M')} PT</p>

  <div class="hero-status">
    <span class="pill pill-{overall_pill_class}"><span class="dot"></span>{overall_pill_text}</span>
  </div>

  <div class="section-label">Summary</div>
  <div class="metrics">
    <div class="metric"><div class="metric-label">Runs</div><div class="metric-value">{total_executions}</div></div>
    <div class="metric{' tone-ok' if total_completed > 0 else ''}"><div class="metric-label">Completed</div><div class="metric-value">{total_completed}</div></div>
    <div class="metric{' tone-warn' if total_in_progress > 0 else ''}"><div class="metric-label">In progress</div><div class="metric-value">{total_in_progress}</div></div>
    <div class="metric{' tone-err' if total_errors > 0 else ''}"><div class="metric-label">Errors</div><div class="metric-value">{total_errors}</div></div>
    <div class="metric"><div class="metric-label">Files</div><div class="metric-value">{total_files:,}</div></div>
    <div class="metric"><div class="metric-label">Data</div><div class="metric-value">{format_bytes(total_bytes)}</div></div>
  </div>

  <div class="section-label">Executions</div>
{tasks_html}

  <div class="footer">Generated {now_pt.strftime('%Y-%m-%d %H:%M:%S')} PT</div>
</div>
</body>
</html>"""

print(html)
PYTHON

# Send HTML email
HTML_BODY=$(cat "$REPORT_FILE")
export HTML_BODY

"$SEND_EMAIL_SCRIPT" --html

echo "[daily-report] sent to $EMAIL_TO"
