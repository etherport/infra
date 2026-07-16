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
import boto3
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
    for k in ("EMAIL_FROM", "EMAIL_TO", "EMAIL_SUBJECT"):
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
    elif kind == "mini_metric":
        # A cairn/mini pushgateway gauge where >=1 means healthy. `target` is the
        # metric name (mini_health_up, cairn_healthy). The mini pushes from a
        # cron-driven agent, so a stale push (no mini_health check in >6h) means the
        # agent stopped reporting → degraded rather than a false "up".
        val = first_value(prom_query(target))
        if val is None:
            return ("unknown", None, None)
        last = first_value(prom_query("mini_health_last_check_timestamp_seconds"))
        now = datetime.now(timezone.utc).timestamp()
        if last is not None and (now - last) > 6 * 3600:
            return ("degraded", 0, 1)  # stale — mini stopped pushing
        return ("up", 1, 1) if val >= 1 else ("down", 0, 1)
    elif kind == "mini_backup_rollup":
        # Rollup across all cairn per-category backups (cairn_backup_last_rc{job=...},
        # 0 = ok). up iff every category's last run succeeded; ready/desired shows
        # the succeeding-category count (e.g. 8/9). Also degrade if the mini stopped
        # pushing (stale), so a frozen all-zero snapshot isn't read as healthy.
        worst = first_value(prom_query("max(cairn_backup_last_rc)"))
        ok = first_value(prom_query("count(cairn_backup_last_rc == 0)"))
        tot = first_value(prom_query("count(cairn_backup_last_rc)"))
        if worst is None or tot is None:
            return ("unknown", None, None)
        ok_i, tot_i = int(ok or 0), int(tot)
        last = first_value(prom_query("mini_health_last_check_timestamp_seconds"))
        now = datetime.now(timezone.utc).timestamp()
        if last is not None and (now - last) > 6 * 3600:
            return ("degraded", ok_i, tot_i)  # stale push
        if worst == 0:
            return ("up", ok_i, tot_i)
        return ("down", ok_i, tot_i) if ok_i == 0 else ("degraded", ok_i, tot_i)
    elif kind == "drift_status":
        # A config-drift detector's last result, read from the `drift-status` ConfigMap
        # mounted at /drift (one file per detector, content "status,timestamp"; status
        # 0=clean, 1=drift). `target` = the detector name. Stale (>26h, these are daily) or
        # absent => unknown/degraded so a frozen "0" can't masquerade as healthy.
        try:
            with open(f"/drift/{target}") as fh:
                status_s, ts_s = fh.read().strip().split(",", 1)
            val, ts = int(status_s), int(ts_s)
        except Exception:
            return ("unknown", None, None)
        now = datetime.now(timezone.utc).timestamp()
        if (now - ts) > 26 * 3600:
            return ("degraded", 0, 1)  # detector hasn't reported in >26h
        return ("up", 1, 1) if val == 0 else ("down", 0, 1)  # 0=clean→up, 1=drift→down
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

# Terminal headline + uppercase state + dot tone for the 2a layout.
def _plural(n):
    return "" if n == 1 else "s"
if counts["down"] > 0:
    overall_head, overall_state, overall_tone = f"{counts['down']} service{_plural(counts['down'])} down", "DOWN", "err"
elif counts["degraded"] > 0:
    overall_head, overall_state, overall_tone = f"{counts['degraded']} service{_plural(counts['degraded'])} degraded", "DEGRADED", "warn"
elif counts["unknown"] == total and total > 0:
    overall_head, overall_state, overall_tone = "All services unknown", "UNKNOWN", "muted"
elif counts["unknown"] > 0:
    overall_head, overall_state, overall_tone = f"{counts['unknown']} service{_plural(counts['unknown'])} unknown", "UNKNOWN", "muted"
else:
    overall_head, overall_state, overall_tone = "All systems healthy", "HEALTHY", "ok"


# ---- build HTML ----------------------------------------------------------

_SVC_TAG = {
    "up":       ("[ ok ]", "t-ok"),
    "degraded": ("[warn]", "t-warn"),
    "down":     ("[fail]", "t-err"),
    "unknown":  ("[ ?? ]", "t-muted"),
}

service_rows_html = []
for category in sorted(by_category.keys()):
    services = by_category[category]
    # Sort: down → degraded → unknown → up, then by name
    order = {"down": 0, "degraded": 1, "unknown": 2, "up": 3}
    services.sort(key=lambda s: (order[s["status"]], s["name"].lower()))

    rows = []
    for s in services:
        if s["status"] in ("up", "down", "degraded") and s["ready"] is not None and s["desired"] is not None:
            counts_text = f'{s["ready"]}/{s["desired"]}'
        else:
            counts_text = "—"
        tag_text, tag_tone = _SVC_TAG[s["status"]]
        rows.append(f"""
        <div class="lrow">
          <span class="l-name">{html_escape(s['name'])}</span>
          <span class="leader"></span>
          <span class="l-count">{counts_text}</span>
          <span class="tag {tag_tone}">{tag_text}</span>
        </div>""")

    service_rows_html.append(
        f'<div class="catblock"><div class="cat"># {html_escape(category)}</div>{"".join(rows)}</div>')


def render_alert_block():
    if not firing:
        return ""
    tag_map = {"critical": ("[crit]", "t-err"), "warning": ("[warn]", "t-warn"), "info": ("[info]", "t-cyan")}
    rows = []
    for sev in ("critical", "warning", "info"):
        items = firing_by_sev.get(sev, [])
        if not items:
            continue
        tag_text, tag_tone = tag_map.get(sev, ("[info]", "t-cyan"))
        for a in items:
            qual = html_escape(a["instance"]) if a["instance"] else ""
            qual_html = f' <span class="a-qual">{qual}</span>' if qual else ""
            summary = html_escape(a["summary"]) if a["summary"] else ""
            summary_html = f'<div class="a-summary">{summary}</div>' if summary else ""
            rows.append(
                f'<div class="arow"><span class="tag {tag_tone}">{tag_text}</span> '
                f'<span class="a-name">{html_escape(a["alertname"])}</span>{qual_html}{summary_html}</div>'
            )
    return ('<div class="rule">── FIRING ───────────────────────</div>'
            '<div class="firing">' + ''.join(rows) + '</div>')


def _labeled(query, label="service"):
    """Return [(label_value, float), ...] for a labeled Prometheus vector."""
    out = []
    for r in prom_query(query) or []:
        try:
            out.append((r["metric"].get(label, "?"), float(r["value"][1])))
        except (KeyError, ValueError, IndexError):
            continue
    return out


def render_cost_block():
    """AWS cost section (M136) — MTD, forecast vs budget, top services, spikes.

    Reads the aws_cost_* gauges the aws-cost-exporter pushes to Pushgateway. If
    the exporter is stale/missing (no data), renders a muted 'unavailable' note
    rather than nothing, so a broken cost pipeline is itself visible."""
    last = first_value(prom_query("aws_cost_exporter_last_success_timestamp_seconds"))
    mtd = first_value(prom_query("aws_cost_mtd_usd"))
    forecast = first_value(prom_query("aws_cost_forecast_usd"))
    budget = first_value(prom_query("aws_cost_budget_usd"))
    yday = first_value(prom_query("aws_cost_yesterday_usd"))

    _rule = '<div class="rule">── COST · AWS ───────────────────────</div>'

    # Stale (>30h) or never-pushed → show a muted note (matches AWSCostExporterStale).
    if last is None or (NOW_PT.timestamp() - last) > 108000:
        return _rule + '<div class="kvline" style="color:var(--dim)">cost data unavailable — aws-cost-exporter stale</div>'

    def money(v):
        return f"${v:,.2f}" if v is not None else "—"

    # Forecast tone vs budget.
    f_tone = "t-ok"
    if budget and forecast:
        if forecast > budget:
            f_tone = "t-err"
        elif forecast > 0.8 * budget:
            f_tone = "t-warn"

    line = (f'mtd <span class="v">{money(mtd)}</span><span class="sep">  ·  </span>'
            f'forecast <span class="{f_tone}">{money(forecast)}</span>'
            f'<span class="sep">/{money(budget)}</span><span class="sep">  ·  </span>'
            f'yday <span class="v">{money(yday)}</span>')

    # Top-3 services by MTD → compact dim line.
    top = sorted(_labeled("aws_cost_service_mtd_usd"), key=lambda kv: -kv[1])[:3]
    top_html = ""
    if top:
        parts = '<span class="sep">  ·  </span>'.join(
            f'{html_escape(s)} <span class="v">{money(v)}</span>' for s, v in top)
        top_html = f'<div class="kvline kvline-sub">top {parts}</div>'

    # Spikes: any service whose yesterday >2x its 7-day average.
    spikes = [(s, r) for s, r in _labeled("aws_cost_service_spike_ratio") if r > 2]
    spikes.sort(key=lambda kv: -kv[1])
    spike_html = ""
    if spikes:
        rows = "".join(
            f'<div class="arow"><span class="tag t-warn">[warn]</span> '
            f'<span class="a-name">{html_escape(s)}</span> '
            f'<span class="a-qual">{r:.1f}× 7-day avg</span></div>'
            for s, r in spikes[:4]
        )
        spike_html = f'<div class="firing">{rows}</div>'

    return _rule + f'<div class="kvline">{line}</div>{top_html}{spike_html}'


alerts_block = render_alert_block()
cost_block = render_cost_block()

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
  .prompt {{ margin:0 0 20px; color:var(--text); word-break:break-all; }}
  .p-user {{ color:var(--ok); }} .p-punc {{ color:var(--dim); }} .p-path {{ color:var(--cyan); }}
  .cursor {{ display:inline-block; width:8px; height:15px; background:var(--text);
    margin-left:4px; vertical-align:-2px; animation: blink 1.1s step-end infinite; }}
  @keyframes blink {{ 50% {{ opacity:0; }} }}
  h1 {{ font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;
    font-size:26px; font-weight:700; letter-spacing:-0.02em; color:var(--text); margin:0 0 5px; }}
  .meta {{ font-size:12px; color:var(--dim); margin:0 0 18px; }}
  .status-line {{ font-size:14px; margin:0 0 24px; }}
  .status-line i {{ width:9px; height:9px; border-radius:50%; background:currentColor;
    display:inline-block; margin-right:8px; vertical-align:middle; }}
  .rule {{ color:var(--dim); font-size:11px; letter-spacing:0.14em; margin:0 0 10px; }}
  .sgrid {{ display:grid; grid-template-columns:repeat(4,1fr); gap:8px; margin:0 0 24px; }}
  .cell {{ border:1px solid var(--border); border-radius:6px; padding:11px 12px; }}
  .cell .num {{ font-size:23px; font-weight:700; font-variant-numeric:tabular-nums; }}
  .cell .lab {{ font-size:10px; letter-spacing:0.1em; color:var(--dim); }}
  .kvline {{ font-size:13px; color:var(--prose); margin:0 0 24px; }}
  .kvline-sub {{ margin-top:-16px; }}
  .kvline .v {{ color:var(--text); }}
  .kvline .sep {{ color:var(--dim2); }}
  .cat {{ color:var(--cyan); font-size:12px; margin:0 0 8px; }}
  .catblock {{ margin:0 0 16px; }}
  .lrow {{ display:flex; align-items:center; gap:8px; font-size:13px; margin:0 0 6px; }}
  .l-name {{ color:var(--text); flex:none; }}
  .l-count {{ color:var(--dim); }}
  .leader {{ flex:1; border-bottom:1px dotted var(--leader); transform:translateY(-4px); }}
  .tag {{ white-space:nowrap; }}
  .firing {{ margin:0 0 24px; }}
  .arow {{ font-size:13px; margin:0 0 10px; }}
  .a-name {{ color:var(--text); }}
  .a-qual {{ color:var(--dim); font-size:12px; }}
  .a-summary {{ font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;
    color:var(--prose); font-size:13px; padding-left:52px; margin-top:2px; }}
  .t-ok {{ color:var(--ok); }} .t-warn {{ color:var(--warn); }} .t-err {{ color:var(--err); }}
  .t-cyan {{ color:var(--cyan); }} .t-muted {{ color:var(--dim); }}
  .t-strong {{ color:var(--text); }} .t-dim {{ color:var(--dim2); }}
  .footer {{ margin-top:24px; color:var(--dim2); font-size:11px; }}
</style>
</head>
<body>
<div class="wrap">
  <div class="term">
    <div class="titlebar">
      <span class="dots"><i class="d-r"></i><i class="d-a"></i><i class="d-g"></i></span>
      <span class="brand"><span class="ring"><i></i></span><b>etherport</b><em>· status</em></span>
      <span class="tb-spacer"></span>
    </div>
    <div class="screen">
      <div class="prompt"><span class="p-user">alerts@etherport</span><span class="p-punc">:</span><span class="p-path">~</span><span class="p-punc">$</span> status<span class="cursor"></span></div>

      <h1>{html_escape(overall_head)}</h1>
      <p class="meta">// {NOW_PT.strftime('%a %b %-d %H:%M')} PT · {len(SERVICES)} services</p>
      <div class="status-line t-{overall_tone}"><i></i>{overall_state} · {total} services</div>

      <div class="rule">── SUMMARY ──────────────────────────</div>
      <div class="sgrid">
        <div class="cell"><div class="num t-ok">{counts['up']:02d}</div><div class="lab">HEALTHY</div></div>
        <div class="cell"><div class="num {'t-warn' if counts['degraded'] else 't-dim'}">{counts['degraded']:02d}</div><div class="lab">DEGRADED</div></div>
        <div class="cell"><div class="num {'t-err' if counts['down'] else 't-strong'}">{counts['down']:02d}</div><div class="lab">DOWN</div></div>
        <div class="cell"><div class="num t-muted">{counts['unknown']:02d}</div><div class="lab">UNKNOWN</div></div>
      </div>
{cost_block}
{alerts_block}
      <div class="rule">── SERVICES ─────────────────────────</div>
{''.join(service_rows_html)}
      <div class="footer">— generated {NOW_PT.strftime('%H:%M:%S')} PT · {len(SERVICES)} services tracked —</div>
    </div>
  </div>
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

msg = EmailMessage()
msg["Subject"] = subject
msg["From"] = os.environ["EMAIL_FROM"]
msg["To"] = os.environ["EMAIL_TO"]
# Set a plain-text fallback so non-HTML clients still get something useful.
plain = (
    f"{REPORT_TITLE} — {NOW_PT.strftime('%Y-%m-%d %H:%M')} PT\n\n"
    f"Healthy: {counts['up']}\n"
    f"Degraded: {counts['degraded']}\n"
    f"Down: {counts['down']}\n"
    f"Unknown: {counts['unknown']}\n"
)
_c_mtd = first_value(prom_query("aws_cost_mtd_usd"))
_c_fc = first_value(prom_query("aws_cost_forecast_usd"))
_c_bud = first_value(prom_query("aws_cost_budget_usd"))
if _c_mtd is not None or _c_fc is not None:
    plain += (
        f"\nAWS cost: MTD ${_c_mtd:.2f}" if _c_mtd is not None else "\nAWS cost:"
    )
    if _c_fc is not None:
        plain += f", forecast ${_c_fc:.2f}"
    if _c_bud is not None:
        plain += f" (budget ${_c_bud:.0f})"
    plain += "\n"
if firing:
    plain += "\nFiring alerts:\n"
    for a in firing:
        plain += f"  [{a['severity']}] {a['alertname']} {a['instance']}\n"
msg.set_content(plain)
msg.add_alternative(html, subtype="html")

# Send via the SES API (boto3) using the pod's IRSA role — no static SMTP creds
# (email-transport consolidation).
ses = boto3.client("ses", region_name=os.environ.get("AWS_REGION", "us-west-2"))
ses.send_raw_email(
    Source=os.environ["EMAIL_FROM"],
    Destinations=[os.environ["EMAIL_TO"]],
    RawMessage={"Data": msg.as_string()},
)

print(f"[service-status-report] sent: {subject}")
