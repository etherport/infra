#!/usr/bin/env python3
"""Build delete-approval request artifacts when the S3 delete guard trips.

Invoked by sync-and-verify.sh (Guard 2) when a run would delete an anomalous
volume of objects. Reads the dry-run delete manifest and produces, in LOG_DIR:

  - approval-pending.json   : pending-approval record (rollup + sample + meta)
  - approval-manifest.csv   : full list of every object that would be deleted
  - approval-email.html     : HTML email body (summary + signed approve button)

and prints the signed approval URL to stdout. The caller uploads the pending
record + manifest to S3 and sends the email. No deletion happens.

Pure stdlib (the aws-s3-sync image has python3). S3 uploads are done by the
caller via the owner-checked s3_put_object helper.
"""
import os
import sys
import json
import time
import hmac
import hashlib
import base64
import html
import csv


def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        print(f"[request-approval] missing required env {name}", file=sys.stderr)
        sys.exit(3)
    return v


share = env("SHARE_NAME", required=True)
run_id = env("RUN_ID", required=True)
dest_prefix = (env("DEST_PREFIX", "") or "").strip("/")
dest_uri = env("DEST_URI", "")
src_path = env("SRC_PATH", "")
would_delete = int(env("WOULD_DELETE", "0"))
dest_count = int(env("DEST_COUNT", "0"))
trip_reason = env("TRIP_REASON", "")
secret = env("APPROVAL_HMAC_SECRET", "")
base_url = (env("APPROVAL_BASE_URL", "") or "").rstrip("/")
token_ttl_h = int(env("APPROVAL_TOKEN_TTL_HOURS", "72"))
log_dir = env("LOG_DIR", "/work/logs")
keys_file = env("DELETE_KEYS_FILE", "")
dest_list_file = env("DEST_LIST_FILE", "")

if not secret:
    print("[request-approval] APPROVAL_HMAC_SECRET is empty; cannot mint token", file=sys.stderr)
    sys.exit(3)


# --- load the would-delete keys (strip s3://bucket/ -> key) -----------------
def to_key(line):
    line = line.rstrip("\n")
    if not line.strip():
        return None
    if line.startswith("s3://"):
        rest = line[len("s3://"):]
        parts = rest.split("/", 1)
        return parts[1] if len(parts) == 2 else ""
    return line.strip()


del_keys = []
if keys_file and os.path.exists(keys_file):
    with open(keys_file) as f:
        for ln in f:
            k = to_key(ln)
            if k:
                del_keys.append(k)

# --- size map from `aws s3 ls --recursive` output (date time size key) -------
size_map = {}
if dest_list_file and os.path.exists(dest_list_file):
    with open(dest_list_file) as f:
        for ln in f:
            if not ln.strip():
                continue
            cols = ln.split(None, 3)
            if len(cols) < 4:
                continue
            try:
                size_map[cols[3].rstrip("\n")] = int(cols[2])
            except (ValueError, IndexError):
                continue


def rel(key):
    pfx = dest_prefix + "/"
    return key[len(pfx):] if dest_prefix and key.startswith(pfx) else key


def folder_of(relpath, depth=2):
    segs = relpath.split("/")
    if len(segs) <= 1:
        return "(root)"
    return "/".join(segs[:depth])


def human(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{int(n)} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


total_bytes = 0
rollup = {}
for k in del_keys:
    sz = size_map.get(k, 0)
    total_bytes += sz
    fld = folder_of(rel(k))
    r = rollup.setdefault(fld, {"count": 0, "bytes": 0})
    r["count"] += 1
    r["bytes"] += sz

rollup_list = sorted(
    ({"folder": f, "count": v["count"], "bytes": v["bytes"]} for f, v in rollup.items()),
    key=lambda x: x["count"],
    reverse=True,
)
sample = del_keys[:20]

now = int(time.time())
exp = now + token_ttl_h * 3600
exp_str = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(exp))

# --- mint signed token: base64url(payload).base64url(hmac_sha256) ------------
payload = {"share": share, "run_id": run_id, "would_delete": would_delete, "exp": exp}
raw = base64.urlsafe_b64encode(json.dumps(payload, separators=(",", ":")).encode()).rstrip(b"=")
sig = base64.urlsafe_b64encode(hmac.new(secret.encode(), raw, hashlib.sha256).digest()).rstrip(b"=")
token = raw.decode() + "." + sig.decode()
approve_url = f"{base_url}/approve?t={token}" if base_url else "(APPROVAL_BASE_URL unset)"

# --- pending-approval record (uploaded to S3 by the caller) ------------------
pending = {
    "share": share,
    "runId": run_id,
    "wouldDelete": would_delete,
    "destCount": dest_count,
    "bytesTotal": total_bytes,
    "tripReason": trip_reason,
    "createdAtEpoch": now,
    "expiresAtEpoch": exp,
    "source": src_path,
    "destination": dest_uri,
    "rollup": rollup_list,
    "sample": sample,
    "manifestKey": f"approvals/pending/{share}/{run_id}.manifest.csv",
}
with open(os.path.join(log_dir, "approval-pending.json"), "w") as f:
    json.dump(pending, f, indent=2)

# --- full manifest CSV ------------------------------------------------------
with open(os.path.join(log_dir, "approval-manifest.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["s3_key", "bytes"])
    for k in del_keys:
        w.writerow([k, size_map.get(k, "")])

# --- HTML email body (house style — matches service-status-report.py) -------
created_str = time.strftime("%a %b %d, %H:%M UTC", time.gmtime(now))
rows = "".join(
    "<tr><td class='svc-name'>{f}</td><td class='num'>{c:,}</td><td class='num'>{b}</td></tr>".format(
        f=html.escape(r["folder"]), c=r["count"], b=human(r["bytes"]))
    for r in rollup_list[:10]
)
more = len(rollup_list) - 10
more_html = (f"<p class='subhead' style='margin:10px 2px 0'>+ {more} more folder(s) — "
             f"full breakdown on the approval page</p>") if more > 0 else ""
sample_html = "".join(f"<li>{html.escape(k)}</li>" for k in sample)

HOUSE_CSS = """
  :root{--bg:#f6f7f9;--surface:#fff;--text:#0f172a;--text-muted:#64748b;--border:#e5e7eb;--border-soft:#eef0f3;
    --ok:#047857;--ok-bg:#ecfdf5;--warn:#b45309;--warn-bg:#fffbeb;--err:#b91c1c;--err-bg:#fef2f2;--muted:#6b7280;--muted-bg:#f3f4f6;--accent:#1f2937;--btn-go:#2d8f4d;--btn-no:#8f2d2d;}
  @media (prefers-color-scheme:dark){:root{--bg:#0b1220;--surface:#131c2e;--text:#e8eaf0;--text-muted:#94a3b8;--border:#243049;--border-soft:#1b2538;
    --ok:#34d399;--ok-bg:rgba(16,185,129,.12);--warn:#fbbf24;--warn-bg:rgba(217,119,6,.15);--err:#f87171;--err-bg:rgba(220,38,38,.16);--muted:#94a3b8;--muted-bg:rgba(148,163,184,.12);--accent:#f1f5f9;}}
  body{margin:0;padding:0;background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;-webkit-font-smoothing:antialiased;-webkit-text-size-adjust:100%;}
  .wrap{max-width:720px;margin:0 auto;padding:36px 20px 56px;}
  .eyebrow{font-size:11px;font-weight:600;color:var(--text-muted);letter-spacing:.12em;text-transform:uppercase;margin:0 0 10px;}
  h1{font-size:26px;font-weight:700;letter-spacing:-.015em;margin:0 0 6px;color:var(--accent);}
  .subhead{color:var(--text-muted);font-size:14px;margin:0 0 22px;}
  .pill{display:inline-flex;align-items:center;gap:7px;padding:5px 11px;border-radius:999px;font-size:13px;font-weight:500;line-height:1;}
  .pill .dot{width:7px;height:7px;border-radius:50%;background:currentColor;display:inline-block;}
  .pill-warn{background:var(--warn-bg);color:var(--warn);} .pill-err{background:var(--err-bg);color:var(--err);} .pill-ok{background:var(--ok-bg);color:var(--ok);}
  .summary-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin:24px 0 8px;}
  @media (max-width:520px){.summary-grid{grid-template-columns:repeat(2,1fr);}}
  .metric{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:14px 16px;}
  .metric-label{font-size:11px;color:var(--text-muted);text-transform:uppercase;letter-spacing:.06em;margin:0 0 6px;}
  .metric-value{font-size:21px;font-weight:600;line-height:1.15;color:var(--accent);font-variant-numeric:tabular-nums;}
  .metric.tone-err .metric-value{color:var(--err);} .metric.tone-warn .metric-value{color:var(--warn);}
  .note{background:var(--err-bg);border:1px solid var(--border);border-left:3px solid var(--err);border-radius:8px;padding:12px 14px;margin:18px 0;font-size:14px;}
  .card{background:var(--surface);border:1px solid var(--border);border-radius:12px;margin:18px 0;overflow:hidden;}
  .card-head{font-size:13px;font-weight:600;padding:12px 18px;border-bottom:1px solid var(--border-soft);background:linear-gradient(180deg,var(--surface) 0%,var(--border-soft) 100%);}
  table{width:100%;border-collapse:collapse;}
  td,th{padding:10px 18px;border-top:1px solid var(--border-soft);text-align:left;font-size:14px;}
  th{color:var(--text-muted);font-size:11px;text-transform:uppercase;letter-spacing:.06em;font-weight:600;border-top:none;}
  tr:first-child td{border-top:none;}
  .num{text-align:right;font-variant-numeric:tabular-nums;color:var(--text-muted);}
  .svc-name{font-weight:500;color:var(--text);}
  ul.sample{margin:0;padding:14px 18px 16px 34px;}
  ul.sample li{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;color:var(--text-muted);margin:2px 0;word-break:break-all;}
  .btn-row{margin:26px 0 8px;}
  .btn{display:inline-block;padding:12px 22px;font-weight:600;font-size:14px;border-radius:6px;text-decoration:none;margin-right:10px;line-height:1.2;}
  .btn-approve{background:var(--btn-go);color:#fff!important;}
  .footer{margin-top:34px;padding-top:18px;border-top:1px solid var(--border);font-size:12px;color:var(--text-muted);text-align:center;}
"""

TEMPLATE = """<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark">
<title>Backup deletion held — approval needed</title>
<style>__CSS__</style></head><body><div class="wrap">
  <div class="eyebrow">Backups · approval needed</div>
  <h1>Backup deletion held</h1>
  <p class="subhead">__SHARE__ · __CREATED__</p>
  <div class="hero-status"><span class="pill pill-err"><span class="dot"></span>Held — nothing deleted</span></div>
  <div class="note"><b>Why it was held:</b> __REASON__ &nbsp;The sync would have mirrored these deletions to S3 via <code>--delete</code>; it was stopped so you can confirm they're intended.</div>
  <div class="summary-grid">
    <div class="metric tone-err"><div class="metric-label">Would delete</div><div class="metric-value">__COUNT__</div></div>
    <div class="metric tone-err"><div class="metric-label">Size</div><div class="metric-value">__BYTES__</div></div>
    <div class="metric"><div class="metric-label">Current backup</div><div class="metric-value">__DESTCOUNT__</div></div>
    <div class="metric"><div class="metric-label">Expires</div><div class="metric-value" style="font-size:15px">__EXP__</div></div>
  </div>
  <div class="btn-row"><a class="btn btn-approve" href="__URL__">Review &amp; approve deletion &rarr;</a></div>
  <div class="card"><div class="card-head">Where the deletions fall</div>
    <table><tr><th>Folder</th><th class="num">Files</th><th class="num">Size</th></tr>__ROWS__</table>
  </div>
  __MORE__
  <div class="card"><div class="card-head">Sample (first __NSAMPLE__)</div>
    <ul class="sample">__SAMPLE__</ul>
  </div>
  <p class="subhead" style="margin:18px 2px 0">Destination <code>__DEST__</code> · run <code>__RUNID__</code></p>
  <div class="footer">
    Opens a confirmation page (Cloudflare Access sign-in) with the full manifest before you confirm.
    Approval is scoped to this deletion, single-use, and expires __EXP__.
    If this is <b>not</b> expected, do nothing — investigate the source; the backup is untouched.
  </div>
</div></body></html>"""

repl = {
    "__CSS__": HOUSE_CSS,
    "__SHARE__": html.escape(share),
    "__CREATED__": created_str,
    "__REASON__": html.escape(trip_reason),
    "__COUNT__": f"{would_delete:,}",
    "__BYTES__": human(total_bytes),
    "__DESTCOUNT__": f"{dest_count:,}",
    "__RUNID__": html.escape(run_id),
    "__DEST__": html.escape(dest_uri),
    "__EXP__": exp_str,
    "__ROWS__": rows,
    "__MORE__": more_html,
    "__NSAMPLE__": str(len(sample)),
    "__SAMPLE__": sample_html,
    "__URL__": html.escape(approve_url),
}
body = TEMPLATE
for k, v in repl.items():
    body = body.replace(k, v)
with open(os.path.join(log_dir, "approval-email.html"), "w") as f:
    f.write(body)

print(approve_url)
