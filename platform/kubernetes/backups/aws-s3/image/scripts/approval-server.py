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
TOLERANCE_PCT = int(os.environ.get("APPROVAL_TOLERANCE_PERCENT", "10"))
PORT = int(os.environ.get("LISTEN_PORT", "8080"))
REQUIRE_CF_EMAIL = os.environ.get("APPROVAL_REQUIRE_CF_EMAIL", "false").lower() in ("1", "true", "yes")
ALLOWED_EMAILS = {e.strip().lower() for e in os.environ.get("APPROVAL_ALLOWED_EMAILS", "").split(",") if e.strip()}

if not SECRET:
    print("[approval-server] FATAL: APPROVAL_HMAC_SECRET not set", file=sys.stderr)
    sys.exit(1)

CSS = """<style>
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;color:#222;max-width:820px;margin:0 auto;padding:24px;line-height:1.5}
.header{padding:18px 20px;border-radius:8px 8px 0 0;margin:-24px -24px 20px;color:#fff}
.header.warn{background:#b45309}.header.ok{background:#15803d}.header.bad{background:#b91c1c}
.header h1{margin:0;font-size:21px}
.kv{display:grid;grid-template-columns:160px 1fr;gap:8px;background:#f7f7f7;padding:16px;border-radius:8px;margin:16px 0;font-size:14px}
.kv .l{color:#666;font-weight:600}.kv .v{font-family:'SF Mono',Consolas,monospace;word-break:break-all}
table{border-collapse:collapse;width:100%;font-size:13px;margin:8px 0}
th,td{border-bottom:1px solid #e5e5e5;padding:6px 8px;text-align:left}th{color:#666}
.btn{display:inline-block;background:#b45309;color:#fff!important;border:0;text-decoration:none;font-weight:700;padding:13px 24px;border-radius:8px;font-size:15px;cursor:pointer}
.muted{color:#777;font-size:12px}
ul.sample{font-family:'SF Mono',Consolas,monospace;font-size:12px;color:#444}
a.dl{font-size:13px}
</style>"""


def page(title, klass, body):
    return ("<!DOCTYPE html><html><head><meta charset='utf-8'><title>" + html.escape(title) + "</title>" +
            CSS + "</head><body><div class='header " + klass + "'><h1>" + html.escape(title) +
            "</h1></div>" + body + "</body></html>").encode()


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
    tmp = tempfile.mktemp()
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
    tmp = tempfile.mktemp()
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
            "<tr><td>{f}</td><td style='text-align:right'>{c:,}</td><td style='text-align:right'>{b}</td></tr>".format(
                f=html.escape(r.get("folder", "")), c=r.get("count", 0), b=human(r.get("bytes", 0)))
            for r in rollup
        )
        sample = pend.get("sample", [])
        sample_html = "".join("<li>" + html.escape(k) + "</li>" for k in sample)
        exp_str = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(int(payload.get("exp", 0))))
        body = (
            "<p>You are about to <b>approve deleting {cnt:,} object(s)</b> ({bytes}) from the "
            "<b>{share}</b> backup. After you confirm, the <b>next</b> scheduled sync for this share "
            "will be allowed to perform this deletion (single use, expires {exp}).</p>".format(
                cnt=would, bytes=human(pend.get("bytesTotal", 0)), share=html.escape(share), exp=exp_str)
            + "<div class='kv'>"
            + "<div class='l'>Share</div><div class='v'>" + html.escape(share) + "</div>"
            + "<div class='l'>Run ID</div><div class='v'>" + html.escape(pend.get("runId", "")) + "</div>"
            + "<div class='l'>Destination</div><div class='v'>" + html.escape(pend.get("destination", "")) + "</div>"
            + "<div class='l'>Current backup</div><div class='v'>" + format(pend.get("destCount", 0), ",") + " objects</div>"
            + "<div class='l'>Held because</div><div class='v'>" + html.escape(pend.get("tripReason", "")) + "</div>"
            + "</div>"
            + "<h3>Where the deletions fall</h3>"
            + "<table><tr><th>Folder</th><th style='text-align:right'>Files</th><th style='text-align:right'>Size</th></tr>"
            + rows + "</table>"
            + "<p><a class='dl' href='/manifest?t=" + html.escape(urllib.parse.quote(token)) + "'>&#11015; Download full list (CSV)</a></p>"
            + "<h3>Sample (first " + str(len(sample)) + ")</h3><ul class='sample'>" + sample_html + "</ul>"
            + "<form method='POST' action='/approve' style='margin-top:24px'>"
            + "<input type='hidden' name='t' value='" + html.escape(token) + "'>"
            + "<button class='btn' type='submit'>Confirm &mdash; approve this deletion</button></form>"
            + "<p class='muted'>This only records consent for this specific deletion (up to "
            + format(would, ",") + " objects). A larger deletion on a later run will be held again. "
            + "The backup is untouched until the next sync runs.</p>"
        )
        return self._send(200, page("Approve backup deletion", "warn", body))

    # ----- POST -----
    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if u.path != "/approve":
            return self._send(404, page("Not found", "bad", "<p>Not found.</p>"))
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        token = urllib.parse.parse_qs(raw).get("t", [""])[0]
        payload = verify_token(token)
        if not payload or not self._identity_ok():
            return self._send(403, page("Link invalid or expired", "bad",
                                        "<p>This approval link is invalid, expired, or you are not "
                                        "authorised. No changes were made.</p>"))

        share = payload["share"]
        would = int(payload.get("would_delete", 0))
        approved_max = int(would * (1 + TOLERANCE_PCT / 100.0)) + 5
        now = int(time.time())
        marker = {
            "share": share,
            "runId": payload.get("run_id", ""),
            "approvedMaxDelete": approved_max,
            "wouldDeleteAtApproval": would,
            "approvedAtEpoch": now,
            "approvedBy": self._cf_email() or "unknown",
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
                "<p class='muted'>Approved by " + html.escape(marker["approvedBy"]) +
                ". You can close this page.</p>")
        return self._send(200, page("Deletion approved", "ok", body))


def main():
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[approval-server] listening on :{PORT} bucket={METADATA_BUCKET} "
          f"require_cf_email={REQUIRE_CF_EMAIL}", file=sys.stderr)
    srv.serve_forever()


if __name__ == "__main__":
    main()
