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

# --- HTML email body --------------------------------------------------------
rows = "".join(
    "<tr><td>{f}</td><td style='text-align:right'>{c:,}</td><td style='text-align:right'>{b}</td></tr>".format(
        f=html.escape(r["folder"]), c=r["count"], b=human(r["bytes"])
    )
    for r in rollup_list[:10]
)
more = len(rollup_list) - 10
more_html = f"+ {more} more folder(s) — full breakdown on the approval page" if more > 0 else ""
sample_html = "".join(f"<li>{html.escape(k)}</li>" for k in sample)

TEMPLATE = """<!DOCTYPE html><html><head><meta charset="utf-8"><style>
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:#222;max-width:760px;margin:0 auto;padding:20px;line-height:1.5}
.header{background:#b45309;color:#fff;padding:18px 20px;border-radius:8px 8px 0 0;margin:-20px -20px 20px}
.header h1{margin:0;font-size:21px}
.pill{display:inline-block;background:#78350f;color:#fff;padding:3px 10px;border-radius:4px;font-size:13px;font-weight:700;margin-top:6px}
.kv{display:grid;grid-template-columns:150px 1fr;gap:8px;background:#f7f7f7;padding:16px;border-radius:8px;margin:16px 0;font-size:14px}
.kv .l{color:#666;font-weight:600}
.kv .v{font-family:'SF Mono',Consolas,monospace}
table{border-collapse:collapse;width:100%;font-size:13px;margin:8px 0}
th,td{border-bottom:1px solid #e5e5e5;padding:6px 8px;text-align:left}
th{color:#666}
.btn{display:inline-block;background:#b45309;color:#fff!important;text-decoration:none;font-weight:700;padding:13px 22px;border-radius:8px;font-size:15px}
.warn{background:#fff7ed;border-left:4px solid #b45309;padding:12px 14px;border-radius:4px;margin:16px 0;font-size:14px}
.muted{color:#777;font-size:12px}
ul.sample{font-family:'SF Mono',Consolas,monospace;font-size:12px;color:#444}
</style></head><body>
<div class="header"><h1>&#9888;&#65039; Backup deletion needs approval</h1><div class="pill">HELD &mdash; nothing deleted</div></div>
<p>The <b>__SHARE__</b> backup sync was about to delete a large number of objects from S3 and was <b>held by the delete-protection guard</b>. No sync or deletion has happened. Review what would be removed and approve only if it is expected.</p>
<div class="warn"><b>Why it was held:</b> __REASON__</div>
<div class="kv">
<div class="l">Share</div><div class="v">__SHARE__</div>
<div class="l">Would delete</div><div class="v">__COUNT__ objects &middot; __BYTES__</div>
<div class="l">Current backup</div><div class="v">__DESTCOUNT__ objects</div>
<div class="l">Run ID</div><div class="v">__RUNID__</div>
<div class="l">Destination</div><div class="v">__DEST__</div>
<div class="l">Approval expires</div><div class="v">__EXP__</div>
</div>
<h3>Where the deletions fall</h3>
<table><tr><th>Folder</th><th style="text-align:right">Files</th><th style="text-align:right">Size</th></tr>__ROWS__</table>
<p class="muted">__MORE__</p>
<h3>Sample (first __NSAMPLE__)</h3>
<ul class="sample">__SAMPLE__</ul>
<p style="margin:24px 0"><a class="btn" href="__URL__">Review &amp; approve deletion &rarr;</a></p>
<p class="muted">Opens a confirmation page (Cloudflare Access sign-in required) that shows the full list before you confirm. The approval is scoped to this deletion only, is single-use, and expires __EXP__. If this is <b>not</b> expected, do nothing &mdash; investigate the source share; the backup is untouched.</p>
</body></html>"""

repl = {
    "__SHARE__": html.escape(share),
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
