#!/usr/bin/env python3
"""
service-status-report.py

Queries Prometheus for service health, rolls each up into UP / DEGRADED /
DOWN, and emits a styled HTML email via SMTP (the same SES relay the
alertmanager uses, so no extra credentials live in this namespace).

Env (required):
  PROM_URL              Prometheus base URL
  SMTP_SMARTHOST        host:port (e.g. email-smtp.us-west-2.amazonaws.com:587)
  SMTP_AUTH_USERNAME    SMTP auth user
  SMTP_AUTH_PASSWORD    SMTP auth password
  SMTP_FROM             RFC 5322 From: header
  EMAIL_TO              Recipient
  EMAIL_SUBJECT         Subject line (overall-status suffix is appended)

Env (optional):
  ALERTMANAGER_URL      If set, firing alerts are pulled from this URL's
                        /api/v2/alerts endpoint (richer summary annotations).
                        Otherwise we fall back to Prometheus ALERTS{} series.
  REPORT_TITLE          H1 text (default: "Homelab status")
  STDOUT_ONLY=1         Skip SMTP, write HTML to stdout (debug / dry-run)
"""

import json
import os
import smtplib
import ssl
import sys
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from email.message import EmailMessage
from zoneinfo import ZoneInfo

# Inventory is the single source of truth at ./services.py — both this
# script and gen-dashboard.py import the same SERVICES list. Both files
# are mounted into this pod via the service-status-report-script
# ConfigMap (see kustomization.yaml), and /work is on sys.path because
# the script lives there.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from services import SERVICES  # noqa: E402

PROM_URL = os.environ.get("PROM_URL", "").rstrip("/")
ALERTMANAGER_URL = os.environ.get("ALERTMANAGER_URL", "").rstrip("/")
REPORT_TITLE = os.environ.get("REPORT_TITLE", "Homelab status")
STDOUT_ONLY = os.environ.get("STDOUT_ONLY") == "1"

if not PROM_URL:
    print("ERROR: PROM_URL is required", file=sys.stderr)
    sys.exit(2)

if not STDOUT_ONLY:
    for k in ("SMTP_SMARTHOST", "SMTP_AUTH_USERNAME", "SMTP_AUTH_PASSWORD",
              "SMTP_FROM", "EMAIL_TO", "EMAIL_SUBJECT"):
        if not os.environ.get(k):
            print(f"ERROR: {k} is required (or set STDOUT_ONLY=1)", file=sys.stderr)
            sys.exit(2)

PACIFIC = ZoneInfo("America/Los_Angeles")
NOW = datetime.now(timezone.utc)
NOW_PT = NOW.astimezone(PACIFIC)

def prom_query(query: str):
    """Return the `data.result` array, or [] on any error."""
    url = f"{PROM_URL}/api/v1/query?query={urllib.parse.quote(query)}"
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = json.loads(resp.read())
        if data.get("status") != "success":
            return []
        return data.get("data", {}).get("result", [])
    except Exception as e:
        print(f"[warn] prom_query failed: {query!r}: {e}", file=sys.stderr)
        return []


def first_value(result):
    """Pull `result[0].value[1]` as float, or None."""
    if not result:
        return None
    try:
        return float(result[0]["value"][1])
    except (KeyError, IndexError, ValueError, TypeError):
        return None


def check_service(kind, namespace, target):
    """Return (status, ready, desired) where status ∈ up/degraded/down/unknown."""
    if kind == "deployment":
        avail = first_value(prom_query(
            f'kube_deployment_status_replicas_available{{namespace="{namespace}",deployment="{target}"}}'))
        desired = first_value(prom_query(
            f'kube_deployment_spec_replicas{{namespace="{namespace}",deployment="{target}"}}'))
    elif kind == "statefulset":
        avail = first_value(prom_query(
            f'kube_statefulset_status_replicas_ready{{namespace="{namespace}",statefulset="{target}"}}'))
        desired = first_value(prom_query(
            f'kube_statefulset_replicas{{namespace="{namespace}",statefulset="{target}"}}'))
    elif kind == "daemonset":
        avail = first_value(prom_query(
            f'kube_daemonset_status_number_ready{{namespace="{namespace}",daemonset="{target}"}}'))
        desired = first_value(prom_query(
            f'kube_daemonset_status_desired_number_scheduled{{namespace="{namespace}",daemonset="{target}"}}'))
    elif kind == "external":
        # `namespace` carries the scrape job name; `target` matches the instance prefix.
        avail = first_value(prom_query(
            f'up{{job="{namespace}",instance=~"{target}.*"}}'))
        # External hosts have no "desired" — 1 means scrape succeeded.
        desired = 1.0 if avail is not None else None
    elif kind == "probe":
        # blackbox-exporter Probe — `namespace` carries the appliance label,
        # `target` is the probe name (also the appliance label value).
        # probe_success{} returns 1 if the probe got a 2xx/3xx, 0 if not.
        avail = first_value(prom_query(
            f'probe_success{{appliance="{target}"}}'))
        desired = 1.0 if avail is not None else None
    elif kind == "cronjob":
        # CronJobs don't have a steady "up" — instead check most recent run.
        # "up" if last_successful_time within 2× schedule period;
        # "degraded" if last_successful is older but last_schedule is recent;
        # "down" if neither metric known. `target` = cronjob name.
        last_succ = first_value(prom_query(
            f'kube_cronjob_status_last_successful_time{{namespace="{namespace}",cronjob="{target}"}}'))
        last_sched = first_value(prom_query(
            f'kube_cronjob_status_last_schedule_time{{namespace="{namespace}",cronjob="{target}"}}'))
        # Use the local clock for "now" — Prometheus `time()` returns a SCALAR
        # result ([ts, "val"]), but first_value() only parses vector results
        # (result[0]["value"][1]), so it always returned None here → EVERY
        # cronjob was falsely reported "unknown" regardless of health. The pod
        # clock is NTP-synced and last_successful_time is a unix epoch, so this
        # comparison is correct.
        now = datetime.now(timezone.utc).timestamp()
        if last_succ is None:
            return ("unknown", None, None)
        # Treat anything within last 24h as healthy (covers daily crons).
        # For sub-daily crons this is generous but not misleading — we'd
        # rather under-alarm than over-alarm here.
        age_hours = (now - last_succ) / 3600
        if age_hours <= 24:
            return ("up", 1, 1)
        if last_sched is not None and (now - last_sched) <= 24 * 3600:
            return ("degraded", 0, 1)
        return ("down", 0, 1)
    else:
        return ("unknown", None, None)

    if avail is None or desired is None:
        return ("unknown", avail, desired)

    avail_i = int(avail)
    desired_i = int(desired)

    if desired_i == 0:
        # Intentionally scaled to zero — treat as up (operator decision).
        return ("up", avail_i, desired_i)
    if avail_i == 0:
        return ("down", avail_i, desired_i)
    if avail_i < desired_i:
        return ("degraded", avail_i, desired_i)
    return ("up", avail_i, desired_i)


def fetch_firing_alerts():
    """Return list of {alertname, severity, instance, summary} for firing alerts."""
    if ALERTMANAGER_URL:
        url = f"{ALERTMANAGER_URL}/api/v2/alerts?filter=alertstate%3Dfiring"
    else:
        # Fallback: query Prometheus's ALERTS series
        result = prom_query('ALERTS{alertstate="firing"}')
        out = []
        for r in result:
            labels = r.get("metric", {})
            out.append({
                "alertname": labels.get("alertname", "?"),
                "severity": labels.get("severity", "info"),
                "instance": labels.get("instance", labels.get("namespace", "")),
                "summary": "",
            })
        return out

    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        print(f"[warn] alertmanager fetch failed: {e}", file=sys.stderr)
        return []

    out = []
    for a in data:
        if a.get("status", {}).get("state") != "active":
            continue
        labels = a.get("labels", {})
        ann = a.get("annotations", {})
        out.append({
            "alertname": labels.get("alertname", "?"),
            "severity": labels.get("severity", "info"),
            "instance": labels.get("instance", labels.get("namespace", "")),
            "summary": ann.get("summary", ""),
        })
    return out


def html_escape(s: str) -> str:
    return (s.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;")
             .replace('"', "&quot;"))


# ---- gather state ---------------------------------------------------------

by_category = defaultdict(list)
counts = {"up": 0, "degraded": 0, "down": 0, "unknown": 0}

for category, name, kind, namespace, target in SERVICES:
    status, ready, desired = check_service(kind, namespace, target)
    counts[status] += 1
    by_category[category].append({
        "name": name,
        "kind": kind,
        "namespace": namespace,
        "target": target,
        "status": status,
        "ready": ready,
        "desired": desired,
    })

firing = fetch_firing_alerts()
# Drop housekeeping alerts that aren't service-status signal
SUPPRESS = {"Watchdog", "InfoInhibitor"}
firing = [a for a in firing if a["alertname"] not in SUPPRESS]
firing_by_sev = defaultdict(list)
for a in firing:
    firing_by_sev[a["severity"]].append(a)

total = sum(counts.values())

if counts["down"] > 0:
    overall_class, overall_text = "err",  f"{counts['down']} down"
elif counts["degraded"] > 0:
    overall_class, overall_text = "warn", f"{counts['degraded']} degraded"
elif counts["unknown"] == total and total > 0:
    overall_class, overall_text = "warn", "All unknown (Prometheus unreachable?)"
elif counts["unknown"] > 0:
    overall_class, overall_text = "warn", f"{counts['unknown']} unknown"
else:
    overall_class, overall_text = "ok",   f"All {counts['up']} healthy"


# ---- build HTML ----------------------------------------------------------

def render_status_pill(status):
    """Compact pill — same idiom as the s3-sync report."""
    mapping = {
        "up":       ("ok",   "up"),
        "degraded": ("warn", "degraded"),
        "down":     ("err",  "down"),
        "unknown":  ("muted","unknown"),
    }
    cls, label = mapping[status]
    return f'<span class="pill pill-{cls}"><span class="dot"></span>{label}</span>'


service_rows_html = []
for category in sorted(by_category.keys()):
    services = by_category[category]
    # category order: alphabetical for stability, but External edge last
    # by adding a sort key prefix below

    # Sort: down → degraded → unknown → up, then by name
    order = {"down": 0, "degraded": 1, "unknown": 2, "up": 3}
    services.sort(key=lambda s: (order[s["status"]], s["name"].lower()))

    rows = []
    for s in services:
        if s["status"] in ("up", "down", "degraded") and s["ready"] is not None and s["desired"] is not None:
            counts_text = f'{s["ready"]}/{s["desired"]}'
        else:
            counts_text = "—"

        meta = html_escape(f'{s["kind"]} · {s["namespace"]}/{s["target"]}')

        rows.append(f"""
              <tr>
                <td class="svc-cell">
                  <div class="svc-name">{html_escape(s['name'])}</div>
                  <div class="svc-meta mono">{meta}</div>
                </td>
                <td class="svc-counts mono">{counts_text}</td>
                <td class="svc-status">{render_status_pill(s['status'])}</td>
              </tr>""")

    service_rows_html.append(f"""
      <div class="category">
        <div class="category-head">{html_escape(category)}</div>
        <table class="svc-table" role="presentation">
          <tbody>{''.join(rows)}
          </tbody>
        </table>
      </div>""")


def render_alert_block():
    if not firing:
        return ""
    blocks = []
    for sev in ("critical", "warning", "info"):
        items = firing_by_sev.get(sev, [])
        if not items:
            continue
        sev_class = {"critical": "err", "warning": "warn", "info": "muted"}.get(sev, "muted")
        lis = []
        for a in items:
            qual = html_escape(a["instance"]) if a["instance"] else ""
            qual_html = f' <span class="alert-qual mono">{qual}</span>' if qual else ""
            summary = html_escape(a["summary"]) if a["summary"] else ""
            summary_html = f'<div class="alert-summary">{summary}</div>' if summary else ""
            lis.append(f"""
              <li class="alert-row alert-{sev_class}">
                <span class="alert-name">{html_escape(a['alertname'])}{qual_html}</span>
                {summary_html}
              </li>""")
        blocks.append(f"""
          <div class="alert-group">
            <div class="alert-sev-label sev-{sev_class}">{sev} ({len(items)})</div>
            <ul class="alert-list">{''.join(lis)}
            </ul>
          </div>""")
    return f"""
      <div class="section-label">Firing alerts</div>
      <div class="alerts-box">{''.join(blocks)}
      </div>"""


alerts_block = render_alert_block()

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>{html_escape(REPORT_TITLE)}</title>
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
    --muted: #6b7280;    --muted-bg: #f3f4f6;
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
      --muted: #94a3b8;  --muted-bg: rgba(148,163,184,0.12);
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
  .wrap {{ max-width: 720px; margin: 0 auto; padding: 36px 20px 56px; }}
  .eyebrow {{
    font-size: 11px; font-weight: 600;
    color: var(--text-muted);
    letter-spacing: 0.12em; text-transform: uppercase;
    margin: 0 0 10px;
  }}
  h1 {{
    font-size: 26px; font-weight: 700; letter-spacing: -0.015em;
    margin: 0 0 6px; color: var(--accent);
  }}
  .subhead {{ color: var(--text-muted); font-size: 14px; margin: 0 0 22px; }}
  .pill {{
    display: inline-flex; align-items: center; gap: 7px;
    padding: 5px 11px; border-radius: 999px;
    font-size: 13px; font-weight: 500; line-height: 1;
  }}
  .pill .dot {{
    width: 7px; height: 7px; border-radius: 50%; background: currentColor;
    display: inline-block;
  }}
  .pill-ok    {{ background: var(--ok-bg);    color: var(--ok);    }}
  .pill-warn  {{ background: var(--warn-bg);  color: var(--warn);  }}
  .pill-err   {{ background: var(--err-bg);   color: var(--err);   }}
  .pill-muted {{ background: var(--muted-bg); color: var(--muted); }}
  .hero-status {{ margin: 0 0 32px; }}
  .section-label {{
    font-size: 11px; font-weight: 600;
    color: var(--text-muted);
    letter-spacing: 0.1em; text-transform: uppercase;
    margin: 18px 0 10px;
  }}
  .summary-grid {{
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 10px;
    margin: 0 0 28px;
  }}
  @media (max-width: 520px) {{
    .summary-grid {{ grid-template-columns: repeat(2, 1fr); }}
  }}
  .metric {{
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 14px 16px;
  }}
  .metric-label {{
    font-size: 11px; color: var(--text-muted);
    text-transform: uppercase; letter-spacing: 0.06em;
    margin: 0 0 6px;
  }}
  .metric-value {{
    font-size: 22px; font-weight: 600; line-height: 1.15;
    color: var(--accent); font-variant-numeric: tabular-nums;
  }}
  .metric.tone-ok   .metric-value {{ color: var(--ok);    }}
  .metric.tone-warn .metric-value {{ color: var(--warn);  }}
  .metric.tone-err  .metric-value {{ color: var(--err);   }}
  .metric.tone-mut  .metric-value {{ color: var(--muted); }}
  .category {{
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 12px;
    margin: 0 0 14px;
    overflow: hidden;
  }}
  .category-head {{
    font-size: 13px; font-weight: 600;
    padding: 12px 18px;
    border-bottom: 1px solid var(--border-soft);
    background: linear-gradient(180deg, var(--surface) 0%, var(--border-soft) 100%);
  }}
  .svc-table {{
    width: 100%; border-collapse: collapse;
  }}
  .svc-table td {{
    padding: 10px 18px;
    border-top: 1px solid var(--border-soft);
    vertical-align: middle;
  }}
  .svc-table tr:first-child td {{ border-top: none; }}
  .svc-cell {{ width: 60%; }}
  .svc-name {{ font-weight: 500; color: var(--text); font-size: 14px; }}
  .svc-meta {{ color: var(--text-muted); font-size: 11px; margin-top: 2px; word-break: break-all; }}
  .svc-counts {{ text-align: right; color: var(--text-muted); font-size: 13px; width: 60px; }}
  .svc-status {{ text-align: right; white-space: nowrap; }}
  .mono {{
    font-family: ui-monospace, SFMono-Regular, Menlo, "JetBrains Mono", monospace;
    font-variant-numeric: tabular-nums;
  }}
  .alerts-box {{
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 14px 18px 16px;
    margin: 0 0 24px;
  }}
  .alert-group + .alert-group {{ margin-top: 14px; }}
  .alert-sev-label {{
    font-size: 11px; font-weight: 600;
    text-transform: uppercase; letter-spacing: 0.08em;
    margin: 0 0 8px;
  }}
  .sev-err {{ color: var(--err); }}
  .sev-warn {{ color: var(--warn); }}
  .sev-muted {{ color: var(--muted); }}
  .alert-list {{ margin: 0; padding: 0; list-style: none; }}
  .alert-row {{
    padding: 8px 10px;
    border-radius: 8px;
    margin-bottom: 4px;
    background: var(--border-soft);
  }}
  .alert-row.alert-err  {{ background: var(--err-bg);  }}
  .alert-row.alert-warn {{ background: var(--warn-bg); }}
  .alert-name {{ font-weight: 500; font-size: 14px; }}
  .alert-qual {{ color: var(--text-muted); font-size: 12px; margin-left: 6px; }}
  .alert-summary {{ color: var(--text-muted); font-size: 12px; margin-top: 2px; }}
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
  <div class="eyebrow">Homelab · status</div>
  <h1>{html_escape(REPORT_TITLE)}</h1>
  <p class="subhead">{NOW_PT.strftime('%a %b %-d, %H:%M')} PT</p>

  <div class="hero-status">
    <span class="pill pill-{overall_class}"><span class="dot"></span>{html_escape(overall_text)}</span>
  </div>

  <div class="section-label">Summary</div>
  <div class="summary-grid">
    <div class="metric tone-ok"><div class="metric-label">Healthy</div><div class="metric-value">{counts['up']}</div></div>
    <div class="metric{' tone-warn' if counts['degraded'] else ''}"><div class="metric-label">Degraded</div><div class="metric-value">{counts['degraded']}</div></div>
    <div class="metric{' tone-err' if counts['down'] else ''}"><div class="metric-label">Down</div><div class="metric-value">{counts['down']}</div></div>
    <div class="metric{' tone-mut' if counts['unknown'] else ''}"><div class="metric-label">Unknown</div><div class="metric-value">{counts['unknown']}</div></div>
  </div>
{alerts_block}

  <div class="section-label">Services</div>
{''.join(service_rows_html)}

  <div class="footer">Generated {NOW_PT.strftime('%Y-%m-%d %H:%M:%S')} PT · {len(SERVICES)} services tracked</div>
</div>
</body>
</html>"""

# ---- send -----------------------------------------------------------------

# Suffix the subject with overall status so the inbox preview is useful.
base_subject = os.environ.get("EMAIL_SUBJECT", "Homelab status")
if counts["down"] > 0:
    subject = f"{base_subject} — {counts['down']} down"
elif counts["degraded"] > 0:
    subject = f"{base_subject} — {counts['degraded']} degraded"
elif counts["unknown"] == total:
    subject = f"{base_subject} — all unknown"
elif counts["unknown"] > 0:
    # Partial unknowns must surface in the subject too — previously this fell
    # through to "all healthy", hiding e.g. un-scraped appliance probes.
    # Mirrors the HTML pill (overall_text) logic above.
    subject = f"{base_subject} — {counts['unknown']} unknown"
else:
    subject = f"{base_subject} — all healthy"

if STDOUT_ONLY:
    sys.stdout.write(html)
    sys.exit(0)

smarthost = os.environ["SMTP_SMARTHOST"]
if ":" in smarthost:
    host, port_str = smarthost.rsplit(":", 1)
    port = int(port_str)
else:
    host, port = smarthost, 587

msg = EmailMessage()
msg["Subject"] = subject
msg["From"] = os.environ["SMTP_FROM"]
msg["To"] = os.environ["EMAIL_TO"]
# Set a plain-text fallback so non-HTML clients still get something useful.
plain = (
    f"{REPORT_TITLE} — {NOW_PT.strftime('%Y-%m-%d %H:%M')} PT\n\n"
    f"Healthy: {counts['up']}\n"
    f"Degraded: {counts['degraded']}\n"
    f"Down: {counts['down']}\n"
    f"Unknown: {counts['unknown']}\n"
)
if firing:
    plain += "\nFiring alerts:\n"
    for a in firing:
        plain += f"  [{a['severity']}] {a['alertname']} {a['instance']}\n"
msg.set_content(plain)
msg.add_alternative(html, subtype="html")

context = ssl.create_default_context()
with smtplib.SMTP(host, port, timeout=30) as smtp:
    smtp.ehlo()
    smtp.starttls(context=context)
    smtp.ehlo()
    smtp.login(os.environ["SMTP_AUTH_USERNAME"], os.environ["SMTP_AUTH_PASSWORD"])
    smtp.send_message(msg)

print(f"[service-status-report] sent: {subject}")
