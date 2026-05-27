"""Twilio voice + SMS webhook handler.

Replaces the legacy Twilio Studio Flow "Fwd voice to mobile / SMS to email"
(FWba4e77be0b8a26120f1219a40fb123f0) and the old Twilio Function at
email-aws-ses-1365.twil.io. Single Lambda handles both:

  voice request → returns TwiML <Response><Dial>$FORWARD_NUMBER</Dial></Response>
  SMS request   → sends SES email to $EMAIL_TO, returns empty <Response/>

Webhook auth via X-Twilio-Signature HMAC-SHA1 over (URL + sorted POST
params); only enforced if TWILIO_AUTH_TOKEN is set.
"""
import base64
import datetime
import hashlib
import hmac
import html
import json
import logging
import os
import urllib.parse

import boto3
from botocore.exceptions import ClientError

_log = logging.getLogger()
_log.setLevel(logging.INFO)

_ses = boto3.client("ses", region_name=os.environ.get("SES_REGION", "us-west-2"))


# Trimmed-down sibling of the advisor's _EMAIL_CSS — same color tokens
# + typography, no advisor-specific bits. Dark-mode aware.
_EMAIL_CSS = """
  body { margin:0; padding:0; background:#f6f7f9; color:#0f172a;
    font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;
    font-size:15px; line-height:1.5; -webkit-font-smoothing:antialiased; }
  .wrap { max-width:640px; margin:0 auto; padding:32px 20px 48px; }
  .eyebrow { font-size:11px; font-weight:600; color:#64748b;
    letter-spacing:0.12em; text-transform:uppercase; margin:0 0 10px; }
  h1 { font-size:22px; font-weight:700; letter-spacing:-0.015em;
    margin:0 0 20px; color:#0f172a; }
  .stats { display:table; width:100%; border-collapse:collapse;
    background:#ffffff; border:1px solid #e5e7eb; border-radius:10px;
    margin:0 0 20px; overflow:hidden; }
  .stat { display:table-cell; padding:14px 16px; vertical-align:top;
    border-right:1px solid #eef0f3; }
  .stat:last-child { border-right:none; }
  .stat-label { font-size:11px; font-weight:600; color:#64748b;
    letter-spacing:0.08em; text-transform:uppercase; margin:0 0 4px; }
  .stat-value { font-size:14px; color:#0f172a; font-weight:500;
    font-variant-numeric:tabular-nums; }
  .card { background:#ffffff; border:1px solid #e5e7eb; border-radius:10px;
    padding:18px 20px; margin:0 0 16px; }
  .card-title { font-size:11px; font-weight:600; color:#64748b;
    letter-spacing:0.08em; text-transform:uppercase; margin:0 0 10px; }
  .body-text { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
    font-size:13.5px; white-space:pre-wrap; color:#0f172a; margin:0; }
  .media a { display:block; font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
    font-size:12.5px; color:#1d4ed8; word-break:break-all; margin:4px 0;
    text-decoration:none; }
  .media a:hover { text-decoration:underline; }
  .footer { font-size:12px; color:#64748b; margin-top:20px;
    padding-top:16px; border-top:1px solid #eef0f3; }
  .footer code { background:#f3f4f6; padding:1px 6px; border-radius:4px;
    font-size:11.5px; color:#1f2937; }
  @media (prefers-color-scheme: dark) {
    body { background:#0b1220; color:#e8eaf0; }
    h1 { color:#e8eaf0; }
    .eyebrow, .stat-label, .card-title, .footer { color:#94a3b8; }
    .stats, .card { background:#131c2e; border-color:#243049; }
    .stat { border-right-color:#1b2538; }
    .stat-value, .body-text { color:#e8eaf0; }
    .footer { border-top-color:#1b2538; }
    .footer code { background:rgba(148,163,184,0.12); color:#e8eaf0; }
    .media a { color:#93c5fd; }
  }
""".strip()


def _twiml(body: str) -> dict:
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "text/xml; charset=utf-8"},
        "body": body,
    }


def _verify_signature(event: dict, params: dict) -> bool:
    """Compute X-Twilio-Signature ourselves + constant-time compare.

    Per Twilio docs: signature = base64(HMAC-SHA1(auth_token, full_url +
    concat(sorted(k+v for k,v in params)))). If TWILIO_AUTH_TOKEN is unset,
    skip verification (return True) — relies on URL unguessability.
    """
    token = os.environ.get("TWILIO_AUTH_TOKEN", "")
    if not token:
        return True

    headers = event.get("headers", {}) or {}
    sig = headers.get("x-twilio-signature") or headers.get("X-Twilio-Signature")
    if not sig:
        _log.warning("missing X-Twilio-Signature header")
        return False

    # Reconstruct the full URL the way Twilio computed the signature with.
    # Function URLs land at a fixed host; the path is "/".
    req_ctx = event.get("requestContext", {})
    domain = req_ctx.get("domainName", "")
    path = req_ctx.get("http", {}).get("path", "/")
    url = f"https://{domain}{path}"

    data = url + "".join(f"{k}{v}" for k, v in sorted(params.items()))
    expected = base64.b64encode(
        hmac.new(token.encode(), data.encode(), hashlib.sha1).digest()
    ).decode()
    return hmac.compare_digest(expected, sig)


def lambda_handler(event, context):
    body = event.get("body", "") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode()
    params = dict(urllib.parse.parse_qsl(body))

    safe_params = {
        k: v for k, v in params.items()
        if k not in ("FromCity", "FromState", "FromZip", "FromCountry",
                     "ToCity", "ToState", "ToZip", "ToCountry")
    }
    _log.info("Twilio webhook: %s", json.dumps(safe_params))

    if not _verify_signature(event, params):
        _log.error("signature verification failed")
        return {"statusCode": 403, "body": "forbidden"}

    # Twilio sends MessageSid for SMS, CallSid for voice. Use that to dispatch.
    if params.get("MessageSid"):
        return _handle_sms(params)
    if params.get("CallSid"):
        return _handle_voice(params)

    _log.warning("unknown webhook type — neither MessageSid nor CallSid present")
    return _twiml("<Response/>")


def _handle_voice(params: dict) -> dict:
    forward = os.environ["FORWARD_NUMBER"]
    # <Dial> connects the incoming caller to FORWARD_NUMBER. answerOnBridge
    # avoids billing the incoming call until the forward connects.
    twiml = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        f"<Response><Dial answerOnBridge=\"true\">{html.escape(forward)}</Dial></Response>"
    )
    return _twiml(twiml)


def _render_html(from_num, to_num, body, media_urls, received_at):
    media_html = ""
    if media_urls:
        items = "".join(
            f'<a href="{html.escape(u)}">{html.escape(u)}</a>'
            for u in media_urls
        )
        media_html = (
            '<div class="card"><div class="card-title">Media attachments</div>'
            f'<div class="media">{items}</div></div>'
        )

    return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SMS from {html.escape(from_num)}</title>
<style>{_EMAIL_CSS}</style></head>
<body><div class="wrap">
  <p class="eyebrow">SMS via Twilio Webhook</p>
  <h1>From {html.escape(from_num)}</h1>
  <div class="stats">
    <div class="stat">
      <div class="stat-label">From</div>
      <div class="stat-value">{html.escape(from_num)}</div>
    </div>
    <div class="stat">
      <div class="stat-label">To</div>
      <div class="stat-value">{html.escape(to_num)}</div>
    </div>
    <div class="stat">
      <div class="stat-label">Received</div>
      <div class="stat-value">{html.escape(received_at)}</div>
    </div>
  </div>
  <div class="card">
    <div class="card-title">Message body</div>
    <pre class="body-text">{html.escape(body or '(empty body)')}</pre>
  </div>
  {media_html}
  <div class="footer">
    Sent by <code>twilio-webhook</code> Lambda · replaces the legacy Twilio Studio Flow.
  </div>
</div></body></html>"""


def _handle_sms(params: dict) -> dict:
    sender = os.environ["SES_FROM"]
    recipient = os.environ["EMAIL_TO"]
    from_num = params.get("From", "unknown")
    to_num = params.get("To", "unknown")
    body = params.get("Body", "")
    num_media = int(params.get("NumMedia", "0") or "0")
    media_urls = [params.get(f"MediaUrl{i}", "") for i in range(num_media) if params.get(f"MediaUrl{i}")]
    received_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    subject = f"SMS to {to_num} from {from_num}"

    # Plain-text fallback for clients that don't render HTML
    text_lines = [
        f"From: {from_num}",
        f"To:   {to_num}",
        f"At:   {received_at}",
        "",
        body or "(empty body)",
    ]
    if media_urls:
        text_lines.append("")
        text_lines.append("Media:")
        for u in media_urls:
            text_lines.append(f"  {u}")
    text_body = "\n".join(text_lines)

    html_body = _render_html(from_num, to_num, body, media_urls, received_at)

    try:
        _ses.send_email(
            Source=sender,
            Destination={"ToAddresses": [recipient]},
            Message={
                "Subject": {"Data": subject},
                "Body": {
                    "Text": {"Data": text_body},
                    "Html": {"Data": html_body},
                },
            },
        )
        _log.info("SES email sent to %s for SMS from %s", recipient, from_num)
    except ClientError as e:
        _log.error("SES send failed: %s", e)
        # Still return 200 + empty TwiML — Twilio shouldn't retry a delivery
        # failure on our side. Investigate via CloudWatch.

    return _twiml("<Response/>")
