#!/usr/bin/env python3
"""Delete-approval web service (runs in-cluster behind Cloudflare Access).

Renders a confirmation page for a pending S3 delete-guard trip and, on POST,
writes a scoped, one-time, expiring approval marker that the next guarded sync
run consumes. The service can NEVER delete anything itself — it only records
operator consent that a future guarded sync run checks.

Auth model (defence in depth):
  1. Cloudflare Access (edge) restricts WHO can reach this hostname.
  2. An HMAC-signed token (shared secret with the sync job) proves the request
     corresponds to a REAL pending deletion and binds share/run_id/would_delete
     — it can't be forged or pointed at a different/larger deletion.
  3. GET renders a page; POST confirms (two-step defeats email-link prefetch).
  4. Optional: require the Cloudflare Access identity header to match an allow
     list (APPROVAL_REQUIRE_CF_EMAIL), which also closes the in-cluster
     direct-to-service bypass path.

Pure stdlib HTTP server; S3 access via the aws-cli already in the image.
"""
import os
import sys
import json
import time
import hmac
import hashlib
import base64
import html
import subprocess
import tempfile
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

METADATA_BUCKET = os.environ["METADATA_BUCKET"]
AWS_REGION = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-west-2"))
EXPECTED_OWNER = os.environ.get("EXPECTED_BUCKET_OWNER", os.environ.get("AWS_ACCOUNT_ID", ""))
SECRET = os.environ.get("APPROVAL_HMAC_SECRET", "")
MARKER_TTL_H = int(os.environ.get("APPROVAL_MARKER_TTL_HOURS", "48"))
REJECT_SNOOZE_H = int(os.environ.get("APPROVAL_REJECT_SNOOZE_HOURS", "24"))
TOLERANCE_PCT = int(os.environ.get("APPROVAL_TOLERANCE_PERCENT", "10"))
PORT = int(os.environ.get("LISTEN_PORT", "8080"))
REQUIRE_CF_EMAIL = os.environ.get("APPROVAL_REQUIRE_CF_EMAIL", "false").lower() in ("1", "true", "yes")
ALLOWED_EMAILS = {e.strip().lower() for e in os.environ.get("APPROVAL_ALLOWED_EMAILS", "").split(",") if e.strip()}

if not SECRET:
    print("[approval-server] FATAL: APPROVAL_HMAC_SECRET not set", file=sys.stderr)
    sys.exit(1)

# House style — matches platform/kubernetes/monitoring/service-status-report.py
HOUSE_CSS = """
  :root{--bg:#f6f7f9;--surface:#fff;--text:#0f172a;--text-muted:#64748b;--border:#e5e7eb;--border-soft:#eef0f3;
    --ok:#047857;--ok-bg:#ecfdf5;--warn:#b45309;--warn-bg:#fffbeb;--err:#b91c1c;--err-bg:#fef2f2;--muted:#6b7280;--muted-bg:#f3f4f6;--accent:#1f2937;--btn-go:#2d8f4d;--btn-no:#8f2d2d;}
  @media (prefers-color-scheme:dark){:root{--bg:#0b1220;--surface:#131c2e;--text:#e8eaf0;--text-muted:#94a3b8;--border:#243049;--border-soft:#1b2538;
    --ok:#34d399;--ok-bg:rgba(16,185,129,.12);--warn:#fbbf24;--warn-bg:rgba(217,119,6,.15);--err:#f87171;--err-bg:rgba(220,38,38,.16);--muted:#94a3b8;--muted-bg:rgba(148,163,184,.12);--accent:#f1f5f9;}}
  body{margin:0;padding:0;background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;-webkit-font-smoothing:antialiased;}
  .wrap{max-width:720px;margin:0 auto;padding:36px 20px 56px;}
  .eyebrow{font-size:11px;font-weight:600;color:var(--text-muted);letter-spacing:.12em;text-transform:uppercase;margin:0 0 10px;}
  h1{font-size:26px;font-weight:700;letter-spacing:-.015em;margin:0 0 6px;color:var(--accent);}
  .subhead{color:var(--text-muted);font-size:14px;margin:0 0 22px;}
  .hero-status{margin:8px 0 26px;}
  .pill{display:inline-flex;align-items:center;gap:7px;padding:5px 11px;border-radius:999px;font-size:13px;font-weight:500;line-height:1;}
  .pill .dot{width:7px;height:7px;border-radius:50%;background:currentColor;display:inline-block;}
  .pill-warn{background:var(--warn-bg);color:var(--warn);} .pill-err{background:var(--err-bg);color:var(--err);} .pill-ok{background:var(--ok-bg);color:var(--ok);} .pill-muted{background:var(--muted-bg);color:var(--muted);}
  .summary-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin:0 0 8px;}
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
  .btn-row{margin:24px 0 8px;}
  .btn{display:inline-block;padding:12px 22px;font-weight:600;font-size:14px;border-radius:6px;text-decoration:none;margin-right:10px;line-height:1.2;border:0;cursor:pointer;}
  .btn-approve{background:var(--btn-go);color:#fff!important;}
  .btn-reject{background:var(--btn-no);color:#fff!important;}
  a.dl{font-size:13px;color:var(--err);font-weight:600;text-decoration:none;}
  .footer{margin-top:34px;padding-top:18px;border-top:1px solid var(--border);font-size:12px;color:var(--text-muted);text-align:center;}
"""

CSS = "<style>" + HOUSE_CSS + "</style>"

# klass -> (pill class, pill text)
_PILL = {"warn": ("pill-err", "Held — review"), "ok": ("pill-ok", "Approved"),
         "bad": ("pill-err", "Can't proceed"), "rejected": ("pill-err", "Rejected")}


def page(title, klass, body):
    pc, pt = _PILL.get(klass, ("pill-muted", ""))
    return ("<!DOCTYPE html><html><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width, initial-scale=1.0'>"
            "<meta name='color-scheme' content='light dark'>"
            "<title>" + html.escape(title) + "</title>" + CSS + "</head><body><div class='wrap'>"
            "<div class='eyebrow'>Backups · deletion approval</div>"
            "<h1>" + html.escape(title) + "</h1>"
            "<div class='hero-status'><span class='pill " + pc + "'><span class='dot'></span>" + html.escape(pt) + "</span></div>"
            + body + "</div></body></html>").encode()


def human(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "?"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{int(n)} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def verify_token(token):
    """Return the decoded payload dict if the token is valid + unexpired, else None."""
    try:
        raw, sig = token.split(".", 1)
        expected = base64.urlsafe_b64encode(
            hmac.new(SECRET.encode(), raw.encode(), hashlib.sha256).digest()
        ).rstrip(b"=").decode()
        if not hmac.compare_digest(sig, expected):
            return None
        pad = "=" * (-len(raw) % 4)
        payload = json.loads(base64.urlsafe_b64decode(raw + pad))
        if int(payload.get("exp", 0)) < int(time.time()):
            return None
        return payload
    except Exception:
        return None


def _aws_s3api(args, **kw):
    cmd = ["aws", "s3api"] + args + ["--region", AWS_REGION]
    if EXPECTED_OWNER:
        cmd += ["--expected-bucket-owner", EXPECTED_OWNER]
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def s3_get_text(key):
    fd, tmp = tempfile.mkstemp()
    os.close(fd)
    try:
        r = _aws_s3api(["get-object", "--bucket", METADATA_BUCKET, "--key", key, tmp])
        if r.returncode != 0:
            return None
        with open(tmp) as f:
            return f.read()
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def s3_put_text(key, body, content_type="application/json"):
    fd, tmp = tempfile.mkstemp()
    os.close(fd)
    try:
        with open(tmp, "w") as f:
            f.write(body)
        r = _aws_s3api(["put-object", "--bucket", METADATA_BUCKET, "--key", key,
                        "--body", tmp, "--content-type", content_type])
        return r.returncode == 0
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def pending_key(share, run_id):
    return f"approvals/pending/{share}/{run_id}.json"


def load_pending(payload):
    raw = s3_get_text(pending_key(payload["share"], payload["run_id"]))
    if not raw:
        return None
    try:
        return json.loads(raw)
    except Exception:
        return None


class Handler(BaseHTTPRequestHandler):
    server_version = "approval/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("[approval-server] %s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _cf_email(self):
        return (self.headers.get("Cf-Access-Authenticated-User-Email", "") or "").strip().lower()

    def _identity_ok(self):
        if not REQUIRE_CF_EMAIL:
            return True
        email = self._cf_email()
        return bool(email) and (not ALLOWED_EMAILS or email in ALLOWED_EMAILS)

    # ----- GET -----
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/healthz":
            return self._send(200, b"ok", "text/plain")

        qs = urllib.parse.parse_qs(u.query)
        token = (qs.get("t", [""])[0])

        if u.path == "/manifest":
            payload = verify_token(token)
            if not payload or not self._identity_ok():
                return self._send(403, page("Link invalid or expired", "bad",
                                            "<p>This approval link is invalid or has expired.</p>"))
            pend = load_pending(payload) or {}
            csv_text = s3_get_text(pend.get("manifestKey", "")) or "s3_key,bytes\n"
            return self._send(200, csv_text.encode(), "text/csv; charset=utf-8")

        if u.path == "/approve":
            payload = verify_token(token)
            if not payload or not self._identity_ok():
                return self._send(403, page("Link invalid or expired", "bad",
                                            "<p>This approval link is invalid, expired, or you are not "
                                            "authorised. No changes were made.</p>"))
            return self._render_confirm(token, payload)

        return self._send(404, page("Not found", "bad", "<p>Not found.</p>"))

    def _render_confirm(self, token, payload):
        pend = load_pending(payload)
        share = payload["share"]
        would = int(payload.get("would_delete", 0))
        if not pend:
            body = ("<p>Approval token is valid, but the pending-deletion record could not be loaded "
                    "(it may have been cleared). Re-run the sync to regenerate it.</p>")
            return self._send(200, page("Pending record missing", "bad", body))

        rollup = pend.get("rollup", [])
        rows = "".join(
            "<tr><td class='svc-name'>{f}</td><td class='num'>{c:,}</td><td class='num'>{b}</td></tr>".format(
                f=html.escape(r.get("folder", "")), c=r.get("count", 0), b=human(r.get("bytes", 0)))
            for r in rollup
        )
        sample = pend.get("sample", [])
        sample_html = "".join("<li>" + html.escape(k) + "</li>" for k in sample)
        exp_str = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(int(payload.get("exp", 0))))
        tok = html.escape(token)

        # Approve (green) + Reject (red) buttons, rendered both above and below
        # the (potentially long) list — matching the AI-advisor email style.
        action_buttons = (
            "<div class='btn-row'>"
            "<form method='POST' action='/approve' style='display:inline'>"
            "<input type='hidden' name='t' value='" + tok + "'>"
            "<button class='btn btn-approve' type='submit'>Approve deletion</button></form>"
            "<form method='POST' action='/reject' style='display:inline'>"
            "<input type='hidden' name='t' value='" + tok + "'>"
            "<button class='btn btn-reject' type='submit'>Reject</button></form>"
            "</div>"
        )
        body = (
            "<p class='subhead' style='margin-top:-12px'>You're about to approve deleting <b>"
            + format(would, ",") + " object(s)</b> (" + human(pend.get("bytesTotal", 0)) + ") from the <b>"
            + html.escape(share) + "</b> backup. On confirm, the <b>next</b> scheduled sync may perform this "
            "deletion — single use, expires " + exp_str + ".</p>"
            "<div class='summary-grid'>"
            "<div class='metric tone-err'><div class='metric-label'>Would delete</div><div class='metric-value'>" + format(would, ",") + "</div></div>"
            "<div class='metric tone-err'><div class='metric-label'>Size</div><div class='metric-value'>" + human(pend.get("bytesTotal", 0)) + "</div></div>"
            "<div class='metric'><div class='metric-label'>Current backup</div><div class='metric-value'>" + format(pend.get("destCount", 0), ",") + "</div></div>"
            "<div class='metric'><div class='metric-label'>Expires</div><div class='metric-value' style='font-size:15px'>" + exp_str + "</div></div>"
            "</div>"
            "<div class='note'><b>Held because:</b> " + html.escape(pend.get("tripReason", "")) + "</div>"
            + action_buttons  # TOP button
            + "<div class='card'><div class='card-head'>Where the deletions fall</div>"
            "<table><tr><th>Folder</th><th class='num'>Files</th><th class='num'>Size</th></tr>"
            + rows + "</table></div>"
            "<p style='margin:4px 2px 18px'><a class='dl' href='/manifest?t=" + html.escape(urllib.parse.quote(token))
            + "'>&#11015; Download full list (CSV)</a></p>"
            "<div class='card'><div class='card-head'>Sample (first " + str(len(sample)) + ")</div>"
            "<ul class='sample'>" + sample_html + "</ul></div>"
            + action_buttons  # BOTTOM button (in case of long content)
            + "<div class='footer'>Records consent for this specific deletion only (up to "
            + format(would, ",") + " objects); a larger deletion on a later run is held again. "
            "Destination <code>" + html.escape(pend.get("destination", "")) + "</code> · run <code>"
            + html.escape(pend.get("runId", "")) + "</code>. The backup is untouched until the next sync runs.</div>"
        )
        return self._send(200, page("Approve backup deletion", "warn", body))

    # ----- POST -----
    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if u.path not in ("/approve", "/reject"):
            return self._send(404, page("Not found", "bad", "<p>Not found.</p>"))
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        token = urllib.parse.parse_qs(raw).get("t", [""])[0]
        payload = verify_token(token)
        if not payload or not self._identity_ok():
            return self._send(403, page("Link invalid or expired", "bad",
                                        "<p>This link is invalid, expired, or you are not "
                                        "authorised. No changes were made.</p>"))

        share = payload["share"]
        would = int(payload.get("would_delete", 0))
        now = int(time.time())
        who = self._cf_email() or "unknown"

        if u.path == "/reject":
            exp = now + REJECT_SNOOZE_H * 3600
            marker = {
                "share": share, "runId": payload.get("run_id", ""),
                "wouldDeleteAtReject": would, "rejectedAtEpoch": now,
                "rejectedBy": who, "expiresAtEpoch": exp,
            }
            s3_put_text(f"approvals/rejected/{share}.json", json.dumps(marker, indent=2))
            exp_str = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(exp))
            body = ("<p><b>Rejected — nothing will be deleted.</b> The delete-guard stays in effect "
                    "for <b>" + html.escape(share) + "</b>. Re-notification is snoozed until "
                    + exp_str + " (a larger pending deletion will still notify).</p>"
                    "<p class='subhead'>Rejected by " + html.escape(who) + ". You can close this page. "
                    "Changed your mind? Use the Approve link before it expires.</p>")
            return self._send(200, page("Deletion rejected", "rejected", body))

        # /approve
        approved_max = int(would * (1 + TOLERANCE_PCT / 100.0)) + 5
        marker = {
            "share": share,
            "runId": payload.get("run_id", ""),
            "approvedMaxDelete": approved_max,
            "wouldDeleteAtApproval": would,
            "approvedAtEpoch": now,
            "approvedBy": who,
            "expiresAtEpoch": now + MARKER_TTL_H * 3600,
        }
        ok = s3_put_text(f"approvals/approved/{share}.json", json.dumps(marker, indent=2))
        if not ok:
            return self._send(500, page("Could not save approval", "bad",
                                        "<p>Failed to write the approval marker to S3. Please retry.</p>"))
        exp_str = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(marker["expiresAtEpoch"]))
        body = ("<p><b>Approved.</b> The next scheduled sync for <b>" + html.escape(share) +
                "</b> may delete up to " + format(approved_max, ",") + " object(s). "
                "This approval is single-use and expires " + exp_str + ".</p>"
                "<p class='subhead'>Approved by " + html.escape(who) +
                ". You can close this page.</p>")
        return self._send(200, page("Deletion approved", "ok", body))


def main():
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[approval-server] listening on :{PORT} bucket={METADATA_BUCKET} "
          f"require_cf_email={REQUIRE_CF_EMAIL}", file=sys.stderr)
    srv.serve_forever()


if __name__ == "__main__":
    main()
