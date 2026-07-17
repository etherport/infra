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

        # strict=False tolerates raw control chars that can appear in a backed-up
        # filename inside the report's file list (else the parse fails and the
        # share falls back to a plain "completed" instead of "subject to approval").
        summary = json.loads(result.stdout, strict=False)

        # Extract metrics from consolidated report
        # Report structure: {status, sync: {exitCode, filesTransferred, bytesTransferred}, summary: {...}, durationSeconds}
        report_status = summary.get('status', 'UNKNOWN')
        sync_data = summary.get('sync', {})
        summary_data = summary.get('summary', {})

        # Check both top-level status field AND sync exitCode. APPROVAL_PENDING
        # (deletion held for operator review) and REJECTED_HELD (operator rejected,
        # snooze active) are both SUCCESS-with-held-deletions — normal operation,
        # NOT failures; don't count/render them as errors.
        is_success = (
            report_status in ('SUCCESS', 'APPROVAL_PENDING', 'REJECTED_HELD') and
            sync_data.get('exitCode', 1) == 0
        )

        return {
            'success': 1 if is_success else 0,
            'status': report_status,
            'pending_deletions': summary.get('deletionsPendingApproval', 0),
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
        'status': metrics.get('status', ''),
        'pending_deletions': metrics.get('pending_deletions', 0),
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

# Shares whose run succeeded but is holding deletions (awaiting approval or
# rejected-snoozed) — surfaced in the header so "All N completed" can't mask them.
total_held = sum(1 for e in executions
                 if e.get('status') in ('APPROVAL_PENDING', 'REJECTED_HELD')
                 and e.get('job_status') == 'succeeded'
                 and e.get('success', 0) == 1)

# Determine overall status pill
if total_errors > 0:
    overall_pill_class = 'err'
    overall_pill_text = f"{total_errors} error{'s' if total_errors != 1 else ''}"
elif total_in_progress > 0:
    overall_pill_class = 'warn'
    overall_pill_text = f"{total_in_progress} in progress"
elif total_held > 0:
    overall_pill_class = 'warn'
    overall_pill_text = f"{total_held} holding deletions"
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
    rep_status = execution.get('status', '')
    pend = execution.get('pending_deletions', 0)

    if job_status == 'running':
        status_text, status_class = 'in progress', 'warn'
    elif rep_status == 'APPROVAL_PENDING' and job_status == 'succeeded' and success == 1:
        status_text = f'subject to approval ({pend:,} to delete)' if pend else 'subject to approval'
        status_class = 'warn'
    elif rep_status == 'REJECTED_HELD' and job_status == 'succeeded' and success == 1:
        # Operator already rejected this deletion; nothing is awaited — don't
        # phrase it as pending approval. (Both held branches require success==1
        # so a held report whose sync actually FAILED renders as an error card,
        # keeping the card list consistent with the header's error count.)
        status_text = f'rejected — {pend:,} deletions held' if pend else 'rejected — deletions held'
        status_class = 'warn'
    elif job_status == 'succeeded' and success == 1:
        status_text, status_class = 'completed', 'ok'
    else:
        status_text, status_class = 'error', 'err'

    start_time_v = execution.get('start_time')
    end_time_v = execution.get('end_time')
    start_pt_v = to_pt(start_time_v) if start_time_v else None
    end_pt_v = to_pt(end_time_v) if end_time_v else None

    # Terminal leader-row: name … detail … [ tag ]
    _tag_tone = {'ok': 't-ok', 'warn': 't-warn', 'err': 't-err'}[status_class]
    _tag_text = {'ok': '[ ok ]', 'warn': '[warn]', 'err': '[fail]'}[status_class]
    if status_class == 'ok':
        _detail = (f"{execution.get('files', 0):,} files · {format_bytes(execution.get('bytes', 0))} · "
                   f"{format_duration(execution.get('duration', 0))}")
    else:
        # Non-ok: lead with the human status, append size if we have it
        _detail = status_text
        if execution.get('files', 0) or execution.get('bytes', 0):
            _detail += f" · {execution.get('files', 0):,} files · {format_bytes(execution.get('bytes', 0))}"
    _win = ''
    if start_pt_v:
        _win = (f"{start_pt_v.strftime('%H:%M')}–{end_pt_v.strftime('%H:%M')}"
                if end_pt_v else start_pt_v.strftime('%H:%M'))
    tasks_html_parts.append(f"""
        <div class="lrow">
            <span class="l-name">{share.title()}</span>
            <span class="leader"></span>
            <span class="tag {_tag_tone}">{_tag_text}</span>
        </div>
        <div class="xdetail">{_detail}{(' · ' + _win) if _win else ''}</div>""")

tasks_html = '\n'.join(tasks_html_parts) if tasks_html_parts else \
    '<div class="empty">No executions in this window.</div>'

_exit_code = 0 if total_errors == 0 else 1
_summary_line = (f'runs <span class="v">{total_executions}</span>'
                 f'<span class="sep"> · </span>ok <span class="t-ok">{total_completed}</span>'
                 f'<span class="sep"> · </span>err <span class="v">{total_errors}</span>')
if total_in_progress:
    _summary_line += f'<span class="sep"> · </span>running <span class="t-warn">{total_in_progress}</span>'
_summary_line += (f'<span class="sep"> · </span>files <span class="v">{total_files:,}</span>'
                  f'<span class="sep"> · </span>data <span class="v">{format_bytes(total_bytes)}</span>')

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
    color-scheme: light dark;
    --page: #e7e8ec; --surface: #f7f7f2; --border: #dedcd0; --titlebar: #eeece2;
    --text: #26241d; --prose: #6b6a5f; --dim: #8a897e; --dim2: #c9c5b6; --leader: #cfcdbc;
    --ok: #2f8f52; --cyan: #2a7d8c; --warn: #9a6100; --err: #a5342a;
    --dot-r: #c9483d; --dot-a: #c08a1e; --dot-g: #2f8f52;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      --page: #05070b; --surface: #0a0e14; --border: #1b232e; --titlebar: #0d1219;
      --text: #e6edf3; --prose: #8a93a0; --dim: #6b7888; --dim2: #3a4553; --leader: #2a3542;
      --ok: #46c46a; --cyan: #5ac2d4; --warn: #e0a53a; --err: #f4685c;
      --dot-r: #f4685c; --dot-a: #e0a53a; --dot-g: #46c46a;
    }}
  }}
  body {{ margin:0; padding:0; background:var(--page); color:var(--text);
    font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;
    -webkit-font-smoothing:antialiased; -webkit-text-size-adjust:100%; }}
  .wrap {{ max-width: 600px; margin: 0 auto; padding: 28px 16px 46px; }}
  .term {{ background:var(--surface); border:1px solid var(--border); border-radius:11px; overflow:hidden; }}
  .mono {{ font-family: ui-monospace, SFMono-Regular, Menlo, "JetBrains Mono", monospace; }}
  .titlebar {{ display:flex; align-items:center; padding:11px 16px; background:var(--titlebar);
    border-bottom:1px solid var(--border);
    font-family: ui-monospace, SFMono-Regular, Menlo, "JetBrains Mono", monospace; }}
  .dots {{ display:flex; gap:7px; }}
  .dots i {{ width:11px; height:11px; border-radius:50%; display:inline-block; }}
  .d-r {{ background:var(--dot-r); }} .d-a {{ background:var(--dot-a); }} .d-g {{ background:var(--dot-g); }}
  .brand {{ margin:0 auto; display:inline-flex; align-items:center; gap:8px; font-size:12.5px; }}
  .ring {{ width:15px; height:15px; border:2px solid var(--ok); border-radius:50%;
    display:inline-flex; align-items:center; justify-content:center; box-sizing:border-box; vertical-align:middle; }}
  .ring i {{ width:4px; height:4px; border-radius:50%; background:var(--ok); }}
  .brand b {{ font-weight:600; color:var(--text); }}
  .brand em {{ font-style:normal; color:var(--dim); }}
  .tb-spacer {{ width:47px; }}
  .screen {{ padding:24px 26px 28px;
    font-family: ui-monospace, SFMono-Regular, Menlo, "JetBrains Mono", monospace;
    font-size:13px; line-height:1.7; }}
  .prompt {{ margin:0 0 20px; color:var(--text); overflow-wrap:break-word; }}
  .p-user {{ color:var(--ok); }} .p-punc {{ color:var(--dim); }} .p-path {{ color:var(--cyan); }}
  .cursor {{ display:inline-block; width:8px; height:15px; background:var(--text);
    margin-left:4px; vertical-align:-2px; animation: blink 1.1s step-end infinite; }}
  @keyframes blink {{ 50% {{ opacity:0; }} }}
  h1 {{ font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;
    font-size:24px; font-weight:700; letter-spacing:-0.02em; color:var(--text); margin:0 0 5px; }}
  .meta {{ font-size:12px; color:var(--dim); margin:0 0 18px; }}
  .status-line {{ font-size:14px; margin:0 0 24px; }}
  .status-line i {{ width:9px; height:9px; border-radius:50%; background:currentColor;
    display:inline-block; margin-right:8px; vertical-align:middle; }}
  .rule {{ color:var(--dim); font-size:11px; letter-spacing:0.14em; margin:0 0 10px; }}
  .kvline {{ font-size:13px; color:var(--prose); margin:0 0 24px; }}
  .kvline .v {{ color:var(--text); }}
  .kvline .sep {{ color:var(--dim2); }}
  .t-ok {{ color:var(--ok); }} .t-warn {{ color:var(--warn); }} .t-err {{ color:var(--err); }}
  .lrow {{ display:flex; align-items:center; gap:8px; font-size:13px; margin:0 0 3px; }}
  .l-name {{ color:var(--text); flex:none; }}
  .xdetail {{ color:var(--dim); font-size:12.5px; margin:-2px 0 13px; }}
  .leader {{ flex:1; border-bottom:1px dotted var(--leader); transform:translateY(-4px); }}
  .tag {{ white-space:nowrap; }}
  .empty {{ color:var(--dim); font-size:13px; }}
  .footer {{ margin-top:24px; color:var(--dim2); font-size:11px; }}
</style>
</head>
<body>
<div class="wrap">
  <div class="term">
    <div class="titlebar">
      <span class="dots"><i class="d-r"></i><i class="d-a"></i><i class="d-g"></i></span>
      <span class="brand"><span class="ring"><i></i></span><b>etherport</b><em>· backups</em></span>
      <span class="tb-spacer"></span>
    </div>
    <div class="screen">
      <div class="prompt"><span class="p-user">alerts@etherport</span><span class="p-punc">:</span><span class="p-path">~</span><span class="p-punc">$</span> backups report --since {start_pt.strftime('%H:%M')}<span class="cursor"></span></div>

      <h1>Sequoia → S3</h1>
      <p class="meta">// {start_pt.strftime('%a %b %-d %H:%M')} – {now_pt.strftime('%a %b %-d %H:%M')} PT</p>
      <div class="status-line t-{overall_pill_class}"><i></i>{overall_pill_text}</div>

      <div class="rule">── SUMMARY ──────────────────────────</div>
      <div class="kvline">{_summary_line}</div>

      <div class="rule">── EXECUTIONS ───────────────────────</div>
{tasks_html}

      <div class="footer">— generated {now_pt.strftime('%H:%M:%S')} PT · exit {_exit_code} —</div>
    </div>
  </div>
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
