#!/usr/bin/env python3
"""Email the weekly doc/IaC drift audit summary via AWS SES SMTP.

The audit runs on the devbox (no in-cluster IRSA), so it can't use the daily report's
SES-API path — instead it sends over SES SMTP using creds the runner decrypts from
alertmanager-secret.sops.yaml. Pure stdlib so it runs under the devbox system python.

Sends multipart/alternative: a plain-text part (the raw markdown) + an HTML part styled to
match the homelab house style (the ai-advisor email — eyebrow/title/status-pill/cards/footer,
light+dark). The audit's per-item "Review & apply ->" GitHub links render as green buttons on
their own line (the #40 deep-link approve flow: each actionable item links to that apply
workflow's Run page). hrefs are restricted to http(s) so LLM-authored markdown can't inject
javascript:/data: links.

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
_BAREURL = re.compile(r"(?<![\"=>])(https?://[^\s<>()]+)")
_BOLD = re.compile(r"\*\*([^*]+)\*\*")
_ITALIC = re.compile(r"(?<![\w*])[_*]([^_*\n]+)[_*](?![\w*])")
_CODE = re.compile(r"`([^`]+)`")

_CSS = """
:root{--bg:#f6f7f9;--surface:#fff;--text:#0f172a;--text-muted:#64748b;--border:#e5e7eb;
--border-soft:#eef0f3;--accent:#1f2937;--ok:#047857;--ok-bg:#ecfdf5;--warn:#b45309;
--warn-bg:#fffbeb;--err:#b91c1c;--err-bg:#fef2f2;--muted:#6b7280;--muted-bg:#f3f4f6;--btn-go:#2d8f4d}
@media (prefers-color-scheme:dark){:root{--bg:#0b1220;--surface:#131c2e;--text:#e8eaf0;
--text-muted:#94a3b8;--border:#243049;--border-soft:#1b2538;--accent:#f1f5f9;--ok:#34d399;
--ok-bg:rgba(16,185,129,.12);--warn:#fbbf24;--warn-bg:rgba(217,119,6,.15);--err:#f87171;
--err-bg:rgba(220,38,38,.16);--muted:#94a3b8;--muted-bg:rgba(148,163,184,.12)}}
body{margin:0;padding:0;background:var(--bg);color:var(--text);
font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;
font-size:15px;line-height:1.55;-webkit-font-smoothing:antialiased}
.wrap{max-width:720px;margin:0 auto;padding:36px 20px 56px}
.eyebrow{font-size:11px;font-weight:600;color:var(--text-muted);letter-spacing:.12em;
text-transform:uppercase;margin:0 0 10px}
h1{font-size:23px;font-weight:700;letter-spacing:-.015em;margin:0 0 6px;color:var(--accent)}
.subhead{color:var(--text-muted);font-size:14px;margin:0 0 20px}
.pill{display:inline-flex;align-items:center;gap:7px;padding:5px 12px;border-radius:999px;
font-size:13px;font-weight:600;line-height:1;margin:0 0 24px}
.pill .dot{width:7px;height:7px;border-radius:50%;background:currentColor;display:inline-block}
.pill-ok{background:var(--ok-bg);color:var(--ok)}.pill-warn{background:var(--warn-bg);color:var(--warn)}
.pill-err{background:var(--err-bg);color:var(--err)}.pill-muted{background:var(--muted-bg);color:var(--muted)}
.card{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:18px 22px;margin:0 0 16px}
h2.sec{font-size:12px;font-weight:700;color:var(--text-muted);text-transform:uppercase;
letter-spacing:.07em;margin:0 0 12px}
p{margin:0 0 12px}p:last-child{margin-bottom:0}
ul{margin:0;padding:0;list-style:none}
li{margin:0 0 14px;padding:0 0 0 18px;position:relative}li:last-child{margin-bottom:0}
li:before{content:"";position:absolute;left:2px;top:9px;width:5px;height:5px;border-radius:50%;background:var(--text-muted)}
code{background:var(--muted-bg);padding:2px 6px;border-radius:4px;font-size:13px;
font-family:"SF Mono","Monaco",Menlo,Consolas,monospace}
a{color:#0969da}em{font-style:italic;color:var(--text-muted)}
.btn-wrap{margin:9px 0 2px}
.btn{display:inline-block;padding:9px 18px;background:var(--btn-go);color:#fff;font-weight:600;
font-size:13px;border-radius:6px;text-decoration:none;line-height:1.2}
.footer{margin-top:30px;padding-top:18px;border-top:1px solid var(--border-soft);
font-size:12px;color:var(--text-muted)}
.footer code{font-size:11px}
"""


def _inline(text: str) -> str:
    """Inline markdown -> HTML on a raw (unescaped) string. Escapes, then links/bold/italic/code.
    Only http(s) URLs become links (no javascript:/data:). Returns safe HTML."""
    slots: list[str] = []

    def stash(frag: str) -> str:
        slots.append(frag)
        return f"\x00{len(slots) - 1}\x00"

    # Pull links out first (on the RAW string so brackets/parens are intact), escaping their text.
    def mdlink(m: "re.Match[str]") -> str:
        return stash(f'<a href="{html.escape(m.group(2), quote=True)}">{html.escape(m.group(1))}</a>')

    text = _MDLINK.sub(mdlink, text)
    text = _BAREURL.sub(lambda m: stash(f'<a href="{html.escape(m.group(1), quote=True)}">{html.escape(m.group(1))}</a>'), text)
    text = html.escape(text)
    text = _CODE.sub(lambda m: f"<code>{m.group(1)}</code>", text)
    text = _BOLD.sub(r"<strong>\1</strong>", text)
    text = _ITALIC.sub(r"<em>\1</em>", text)
    for i, frag in enumerate(slots):
        text = text.replace(f"\x00{i}\x00", frag)
    return text


def _buttons(line: str) -> tuple[str, str]:
    """Split apply-workflow links out of a line so they render as block buttons under the text.
    Returns (line_without_apply_links, buttons_html)."""
    btns: list[str] = []

    def grab(m: "re.Match[str]") -> str:
        text, url = m.group(1), m.group(2)
        if "actions/workflows" in url or "apply" in text.lower():
            btns.append(f'<div class="btn-wrap"><a class="btn" href="{html.escape(url, quote=True)}">{html.escape(text)}</a></div>')
            return ""  # remove from inline flow
        return m.group(0)

    stripped = _MDLINK.sub(grab, line).rstrip(" .")
    return stripped, "".join(btns)


def _md_to_html(body: str) -> str:
    body = body.replace("\x00", "")  # NUL would collide with the placeholder sentinels below
    out: list[str] = []
    in_ul = False
    para: list[str] = []
    seen_heading = False

    def flush_para():
        nonlocal para
        if para:
            out.append(f"<p>{_inline(' '.join(para))}</p>")
            para = []

    def close_ul():
        nonlocal in_ul
        if in_ul:
            out.append("</ul>")
            in_ul = False

    for raw in body.splitlines():
        line = raw.rstrip()
        heading = re.match(r"^(#{1,4})\s+(.*)$", line)
        bullet = re.match(r"^\s*[-*]\s+(.*)$", line)
        if heading:
            flush_para(); close_ul()
            # Skip the first heading — the email template already shows the title.
            if not seen_heading:
                seen_heading = True
                continue
            out.append(f'<h2 class="sec">{_inline(heading.group(2))}</h2>')
        elif bullet:
            flush_para()
            if not in_ul:
                out.append("<ul>"); in_ul = True
            text, btns = _buttons(bullet.group(1))
            out.append(f"<li>{_inline(text)}{btns}</li>")
        elif not line.strip():
            flush_para(); close_ul()
        else:
            close_ul(); para.append(line)
    flush_para(); close_ul()
    return "".join(out)


_PILL = {
    "clean": ("pill-ok", "Clean — no drift"),
    "drift": ("pill-warn", "Review needed"),
    "error": ("pill-err", "Audit error"),
}
_SUBHEAD = {
    "clean": "Docs + IaC match live state this week.",
    "drift": "One or more items need manual review.",
    "error": "The audit run exited with an error — see the log.",
}


def _render(status: str, body_md: str) -> str:
    cls, label = _PILL.get(status, ("pill-muted", "Audit ran"))
    subhead = _SUBHEAD.get(status, "Weekly live-anchored doc/IaC drift audit.")
    body_html = _md_to_html(body_md)
    return (
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1.0">'
        '<meta name="color-scheme" content="light dark">'
        '<meta name="supported-color-schemes" content="light dark">'
        '<title>Doc/IaC drift — weekly audit</title>'
        f"<style>{_CSS}</style></head><body><div class='wrap'>"
        '<p class="eyebrow">Homelab &middot; Doc / IaC Drift Audit</p>'
        '<h1>Weekly doc / IaC drift audit</h1>'
        f'<p class="subhead">{html.escape(subhead)}</p>'
        f'<span class="pill {cls}"><span class="dot"></span>{html.escape(label)}</span>'
        f'<div class="card">{body_html}</div>'
        '<div class="footer">Live-anchored audit on the devbox &middot; full log: '
        '<code>~/.local/state/doc-drift-audit/</code> &middot; tracked in the '
        '<code>doc-drift</code> GitHub issue.</div>'
        "</div></body></html>"
    )


def main() -> int:
    status, subject, body_file = sys.argv[1], sys.argv[2], sys.argv[3]
    host, _, port = os.environ["SMTP_HOST"].partition(":")
    port = int(port or "587")

    try:
        with open(body_file, encoding="utf-8") as fh:
            body = fh.read().strip()
    except OSError:
        body = ""
    if not body:
        body = "(the audit produced no summary text; see the devbox run log)"
    # Strip NUL: the HTML renderer uses \x00-delimited placeholders internally, and html.escape
    # does not escape NUL — a literal NUL in the body could collide/corrupt. (Defensive; LLM
    # markdown realistically never contains NUL, but keep both parts clean.)
    body = body.replace("\x00", "")

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = os.environ["MAIL_FROM"]
    msg["To"] = os.environ["MAIL_TO"]
    msg.set_content(body)  # plain-text fallback = the raw markdown
    msg.add_alternative(_render(status, body), subtype="html")

    ctx = ssl.create_default_context()
    with smtplib.SMTP(host, port, timeout=30) as srv:
        srv.starttls(context=ctx)
        srv.login(os.environ["SMTP_USER"], os.environ["SMTP_PASS"])
        srv.send_message(msg)
    print(f"sent doc-drift audit email ({status}) to {os.environ['MAIL_TO']} via {host}:{port}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
