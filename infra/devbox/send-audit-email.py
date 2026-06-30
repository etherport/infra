#!/usr/bin/env python3
"""Email the weekly doc/IaC drift audit summary via AWS SES SMTP.

The audit runs on the devbox (no in-cluster IRSA), so it can't use the daily report's
SES-API path — instead it sends over SES SMTP using creds the runner decrypts from
alertmanager-secret.sops.yaml. Pure stdlib so it runs under the devbox system python.

Sends multipart/alternative: a plain-text part (the raw markdown) + an HTML part rendered
from it, so the audit's per-item "Review & apply ->" GitHub links render as clickable buttons
(the #40 deep-link approve flow: each actionable item links to that apply workflow's Run page).

Env:  SMTP_HOST ("host:port"), SMTP_USER, SMTP_PASS, MAIL_FROM, MAIL_TO
Args: <status>  <subject>  <body-file>
"""
import html
import os
import re
import smtplib
import ssl
import sys
from email.message import EmailMessage

_MDLINK = re.compile(r"\[([^\]]+)\]\((https?://[^\s)]+)\)")
_BAREURL = re.compile(r"(?<!\")(https?://[^\s<>()]+)")
_BOLD = re.compile(r"\*\*([^*]+)\*\*")
_CODE = re.compile(r"`([^`]+)`")


def _inline(escaped_line: str) -> str:
    """Inline markdown -> HTML on an already-HTML-escaped string. Links become buttons when
    they point at a workflow Run page (the approve action); placeholders avoid double-linking."""
    slots: list[str] = []

    def stash(htmlfrag: str) -> str:
        slots.append(htmlfrag)
        return f"\x00{len(slots) - 1}\x00"

    def mdlink(m: "re.Match[str]") -> str:
        text, url = m.group(1), m.group(2)
        is_btn = "actions/workflows" in url or "apply" in text.lower()
        cls = "btn" if is_btn else "lnk"
        return stash(f'<a class="{cls}" href="{url}">{text}</a>')

    s = _MDLINK.sub(mdlink, escaped_line)
    s = _BAREURL.sub(lambda m: stash(f'<a class="lnk" href="{m.group(1)}">{m.group(1)}</a>'), s)
    s = _BOLD.sub(r"<strong>\1</strong>", s)
    s = _CODE.sub(r"<code>\1</code>", s)
    for i, frag in enumerate(slots):
        s = s.replace(f"\x00{i}\x00", frag)
    return s


def _md_to_html(body: str) -> str:
    out: list[str] = []
    in_ul = False
    for raw in body.splitlines():
        line = raw.rstrip()
        esc = html.escape(line)
        bullet = re.match(r"^\s*[-*]\s+(.*)$", line)
        heading = re.match(r"^(#{1,4})\s+(.*)$", line)
        if bullet:
            if not in_ul:
                out.append("<ul>")
                in_ul = True
            out.append(f"<li>{_inline(html.escape(bullet.group(1)))}</li>")
            continue
        if in_ul:
            out.append("</ul>")
            in_ul = False
        if heading:
            lvl = min(len(heading.group(1)) + 1, 4)
            out.append(f"<h{lvl}>{_inline(html.escape(heading.group(2)))}</h{lvl}>")
        elif not line.strip():
            out.append("")
        else:
            out.append(f"<p>{_inline(esc)}</p>")
    if in_ul:
        out.append("</ul>")
    css = (
        "body{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;"
        "color:#1f2328;line-height:1.5;max-width:720px} h2,h3,h4{margin:18px 0 6px}"
        "code{background:#f0f1f2;padding:1px 5px;border-radius:4px;font-size:90%}"
        "a.lnk{color:#0969da} ul{margin:6px 0;padding-left:22px}"
        "a.btn{display:inline-block;margin:2px 0;padding:7px 14px;background:#1f883d;color:#fff;"
        "font-weight:600;text-decoration:none;border-radius:6px;font-size:13px}"
    )
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{css}</style></head><body>{''.join(out)}</body></html>"


def main() -> int:
    status, subject, body_file = sys.argv[1], sys.argv[2], sys.argv[3]
    host, _, port = os.environ["SMTP_HOST"].partition(":")
    port = int(port or "587")
    user = os.environ["SMTP_USER"]
    pw = os.environ["SMTP_PASS"]
    mail_from = os.environ["MAIL_FROM"]
    mail_to = os.environ["MAIL_TO"]

    try:
        with open(body_file, encoding="utf-8") as fh:
            body = fh.read().strip()
    except OSError:
        body = ""
    if not body:
        body = "(the audit produced no summary text; see the devbox run log)"

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = mail_from
    msg["To"] = mail_to
    msg.set_content(body)  # plain-text fallback = the raw markdown
    msg.add_alternative(_md_to_html(body), subtype="html")

    ctx = ssl.create_default_context()
    with smtplib.SMTP(host, port, timeout=30) as srv:
        srv.starttls(context=ctx)
        srv.login(user, pw)
        srv.send_message(msg)
    print(f"sent doc-drift audit email ({status}) to {mail_to} via {host}:{port}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
