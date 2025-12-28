#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# daily-report.sh
#
# Sends a daily summary email of S3 sync CronJobs/Jobs in a namespace.
#
# Requires:
#   - kubectl in PATH inside the container
#   - aws cli in PATH (already in your image)
#   - /scripts/send-email.sh present and executable
#   - AWS creds in env (for SES), and EMAIL_* env vars for send-email.sh
#
# Env:
#   REPORT_NAMESPACE          (default: backups)
#   REPORT_LOOKBACK_HOURS     (default: 24)
#   CRONJOB_NAME_PREFIX       (default: s3-sync-)
#
# send-email.sh requires:
#   EMAIL_FROM, EMAIL_TO, EMAIL_SUBJECT (and optional EMAIL_FROM_NAME)
# ------------------------------------------------------------------------------

REPORT_NAMESPACE="${REPORT_NAMESPACE:-backups}"
REPORT_LOOKBACK_HOURS="${REPORT_LOOKBACK_HOURS:-24}"
CRONJOB_NAME_PREFIX="${CRONJOB_NAME_PREFIX:-s3-sync-}"

SEND_EMAIL_SCRIPT="${SEND_EMAIL_SCRIPT:-/scripts/send-email.sh}"

: "${EMAIL_FROM:?missing EMAIL_FROM}"
: "${EMAIL_TO:?missing EMAIL_TO}"
: "${EMAIL_SUBJECT:?missing EMAIL_SUBJECT}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[daily-report] ERROR: kubectl not found in container PATH. Add kubectl to the image." >&2
  exit 2
fi

if [[ ! -x "$SEND_EMAIL_SCRIPT" ]]; then
  echo "[daily-report] ERROR: send-email script not found/executable at: $SEND_EMAIL_SCRIPT" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[daily-report] ERROR: python3 not found in container PATH." >&2
  exit 2
fi

NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

CRONJOBS_JSON="$(kubectl -n "$REPORT_NAMESPACE" get cronjobs.batch -o json)"
JOBS_JSON="$(kubectl -n "$REPORT_NAMESPACE" get jobs.batch -o json)"

export REPORT_NAMESPACE REPORT_LOOKBACK_HOURS CRONJOB_NAME_PREFIX NOW_UTC CRONJOBS_JSON JOBS_JSON EMAIL_SUBJECT

REPORT_FILE="$(mktemp)"
trap 'rm -f "$REPORT_FILE"' EXIT

python3 - <<'PY' > "${REPORT_FILE}"
import os, json
from datetime import datetime, timedelta, timezone

ns = os.environ.get("REPORT_NAMESPACE", "backups")
lookback_hours = int(os.environ.get("REPORT_LOOKBACK_HOURS", "24"))
prefix = os.environ.get("CRONJOB_NAME_PREFIX", "s3-sync-")
now_utc = os.environ.get("NOW_UTC")
subject = os.environ.get("EMAIL_SUBJECT", "Sequoia to S3 Sync Report")

def parse_ts(s):
    if not s:
        return None
    try:
        if s.endswith("Z"):
            return datetime.fromisoformat(s.replace("Z","+00:00"))
        return datetime.fromisoformat(s)
    except Exception:
        return None

now = parse_ts(now_utc) or datetime.now(timezone.utc)
since = now - timedelta(hours=lookback_hours)

cronjobs = json.loads(os.environ["CRONJOBS_JSON"])["items"]
jobs = json.loads(os.environ["JOBS_JSON"])["items"]

# Relevant cronjobs
cj_map = {}
for cj in cronjobs:
    name = cj["metadata"]["name"]
    if name.startswith(prefix):
        cj_map[name] = cj

# Jobs by owning cronjob
jobs_by_cj = {name: [] for name in cj_map.keys()}

for job in jobs:
    owners = job.get("metadata", {}).get("ownerReferences", []) or []
    cj_owner = None
    for o in owners:
        if o.get("kind") == "CronJob":
            cj_owner = o.get("name")
            break
    if not cj_owner or cj_owner not in jobs_by_cj:
        continue

    st = parse_ts(job.get("status", {}).get("startTime"))
    created = parse_ts(job.get("metadata", {}).get("creationTimestamp"))
    active = (job.get("status", {}).get("active", 0) or 0) > 0

    if active:
        jobs_by_cj[cj_owner].append(job)
        continue

    t = st or created
    if t and t >= since:
        jobs_by_cj[cj_owner].append(job)

def job_state(job):
    st = job.get("status", {}) or {}
    if (st.get("active", 0) or 0) > 0:
        return "RUNNING"
    if (st.get("failed", 0) or 0) > 0:
        return "FAILED"
    if (st.get("succeeded", 0) or 0) > 0:
        return "SUCCEEDED"
    return "UNKNOWN"

def job_duration(job):
    st = parse_ts(job.get("status", {}).get("startTime"))
    ct = parse_ts(job.get("status", {}).get("completionTime"))
    if not st:
        return ""
    end = ct or now
    secs = max(0, int((end - st).total_seconds()))
    h = secs // 3600
    m = (secs % 3600) // 60
    s = secs % 60
    if h:
        return f"{h}h {m:02d}m"
    if m:
        return f"{m}m {s:02d}s"
    return f"{s}s"

def fmt_ts(dt):
    if not dt:
        return ""
    return dt.strftime("%Y-%m-%d %H:%M:%S UTC")

summary = []
for cj_name, cj in sorted(cj_map.items()):
    js = jobs_by_cj.get(cj_name, [])

    def sort_key(job):
        st = parse_ts(job.get("status", {}).get("startTime"))
        ct = parse_ts(job.get("metadata", {}).get("creationTimestamp"))
        return st or ct or datetime(1970,1,1,tzinfo=timezone.utc)

    js_sorted = sorted(js, key=sort_key, reverse=True)
    latest = js_sorted[0] if js_sorted else None

    suspend = bool((cj.get("spec", {}) or {}).get("suspend", False))

    latest_state = job_state(latest) if latest else "NO-RUN"
    latest_start = parse_ts(latest.get("status", {}).get("startTime")) if latest else None
    latest_end = parse_ts(latest.get("status", {}).get("completionTime")) if latest else None

    summary.append({
        "cronjob": cj_name,
        "suspend": suspend,
        "latest_job": latest.get("metadata", {}).get("name") if latest else "",
        "state": latest_state,
        "start": latest_start,
        "end": latest_end,
        "duration": job_duration(latest) if latest else "",
        "active": int((latest.get("status", {}) or {}).get("active", 0) or 0) if latest else 0,
    })

failed = [x for x in summary if x["state"] == "FAILED"]
running = [x for x in summary if x["state"] == "RUNNING"]
succeeded = [x for x in summary if x["state"] == "SUCCEEDED"]
norun = [x for x in summary if x["state"] == "NO-RUN"]
unknown = [x for x in summary if x["state"] == "UNKNOWN"]

lines = []
lines.append(subject)
lines.append("")
lines.append(f"Namespace: {ns}")
lines.append(f"Window: last {lookback_hours} hours (since {fmt_ts(since)})")
lines.append(f"Generated: {fmt_ts(now)}")
lines.append("")

def section(title, rows):
    lines.append(title)
    lines.append("-" * len(title))
    if not rows:
        lines.append("(none)")
        lines.append("")
        return
    for r in rows:
        susp = " (suspended)" if r["suspend"] else ""
        lines.append(f"- {r['cronjob']}{susp}")
        lines.append(f"  state: {r['state']}{' (active='+str(r['active'])+')' if r['active'] else ''}")
        if r["start"]:
            lines.append(f"  start: {fmt_ts(r['start'])}")
        if r["end"]:
            lines.append(f"  end:   {fmt_ts(r['end'])}")
        if r["duration"]:
            lines.append(f"  dur:   {r['duration']}")
        if r["latest_job"]:
            lines.append(f"  job:   {r['latest_job']}")
        lines.append("")
    lines.append("")

section("FAILED", failed)
section("RUNNING / IN PROGRESS", running)
section("SUCCEEDED", succeeded)
section("NO RUNS IN WINDOW", norun)
if unknown:
    section("UNKNOWN", unknown)

lines.append("Notes")
lines.append("-----")
lines.append("- This report summarizes Kubernetes Job status for each sync CronJob.")
lines.append("- For per-run details, inspect logs for the referenced Job name.")
lines.append("")

print("\n".join(lines))
PY

"$SEND_EMAIL_SCRIPT" "$REPORT_FILE"
echo "[daily-report] sent to $EMAIL_TO"