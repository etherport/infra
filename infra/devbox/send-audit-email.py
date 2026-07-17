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
from datetime import datetime
from email.message import EmailMessage

_MDLINK = re.compile(r"\[([^\]]+)\]\((https?://[^\s)]+)\)")
_BAREURL = re.compile(r"(?<![\"=>])(https?://[^\s<>()]+)")
_BOLD = re.compile(r"\*\*([^*]+)\*\*")
_ITALIC = re.compile(r"(?<![\w*])[_*]([^_*\n]+)[_*](?![\w*])")
_CODE = re.compile(r"`([^`]+)`")

_MONO = 'ui-monospace,SFMono-Regular,Menlo,"JetBrains Mono",monospace'
_SANS = '-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif'

_CSS = """
:root{color-scheme:light dark;
--page:#e7e8ec;--surface:#f7f7f2;--border:#dedcd0;--titlebar:#eeece2;
--text:#26241d;--prose:#6b6a5f;--dim:#8a897e;--dim2:#c9c5b6;--leader:#cfcdbc;
--ok:#2f8f52;--cyan:#2a7d8c;--warn:#9a6100;--err:#a5342a;
--dot-r:#c9483d;--dot-a:#c08a1e;--dot-g:#2f8f52}
@media (prefers-color-scheme:dark){:root{
--page:#05070b;--surface:#0a0e14;--border:#1b232e;--titlebar:#0d1219;
--text:#e6edf3;--prose:#8a93a0;--dim:#6b7888;--dim2:#3a4553;--leader:#2a3542;
--ok:#46c46a;--cyan:#5ac2d4;--warn:#e0a53a;--err:#f4685c;
--dot-r:#f4685c;--dot-a:#e0a53a;--dot-g:#46c46a}}
body{margin:0;padding:0;background:var(--page);color:var(--text);
font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;
-webkit-font-smoothing:antialiased;-webkit-text-size-adjust:100%}
.wrap{max-width:600px;margin:0 auto;padding:28px 16px 46px}
.term{background:var(--surface);border:1px solid var(--border);border-radius:11px;overflow:hidden}
.titlebar{display:flex;align-items:center;padding:11px 16px;background:var(--titlebar);
border-bottom:1px solid var(--border);font-family:ui-monospace,SFMono-Regular,Menlo,"JetBrains Mono",monospace}
.dots{display:flex;gap:7px}
.dots i{width:11px;height:11px;border-radius:50%;display:inline-block}
.d-r{background:var(--dot-r)}.d-a{background:var(--dot-a)}.d-g{background:var(--dot-g)}
.brand{margin:0 auto;display:inline-flex;align-items:center;gap:8px;font-size:12.5px}
.ring{width:15px;height:15px;border:2px solid var(--ok);border-radius:50%;
display:inline-flex;align-items:center;justify-content:center;box-sizing:border-box;vertical-align:middle}
.ring i{width:4px;height:4px;border-radius:50%;background:var(--ok)}
.brand b{font-weight:600;color:var(--text)}
.brand em{font-style:normal;color:var(--dim)}
.tb-spacer{width:47px}
.screen{padding:24px 26px 28px;font-family:ui-monospace,SFMono-Regular,Menlo,"JetBrains Mono",monospace;font-size:13px;line-height:1.7}
.prompt{margin:0 0 20px;color:var(--text);overflow-wrap:break-word}
.p-user{color:var(--ok)}.p-punc{color:var(--dim)}.p-path{color:var(--cyan)}
.cursor{display:inline-block;width:8px;height:15px;background:var(--text);margin-left:4px;vertical-align:-2px;animation:blink 1.1s step-end infinite}
@keyframes blink{50%{opacity:0}}
h1{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;
font-size:24px;font-weight:700;letter-spacing:-.02em;color:var(--text);margin:0 0 5px}
.subhead{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;
color:var(--prose);font-size:14px;line-height:1.5;margin:0 0 16px}
.status-line{font-size:14px;margin:0 0 24px}
.status-line i{width:9px;height:9px;border-radius:50%;background:currentColor;display:inline-block;margin-right:8px;vertical-align:middle}
.t-ok{color:var(--ok)}.t-warn{color:var(--warn)}.t-err{color:var(--err)}.t-muted{color:var(--dim)}
.card{margin:0}
h2.sec{font-family:ui-monospace,SFMono-Regular,Menlo,"JetBrains Mono",monospace;
font-size:11px;font-weight:400;color:var(--dim);letter-spacing:.08em;text-transform:uppercase;margin:22px 0 10px}
h2.sec:before{content:"── "}
p{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;
color:var(--text);font-size:14.5px;line-height:1.62;margin:0 0 12px}p:last-child{margin-bottom:0}
ul{margin:0 0 16px;padding:0;list-style:none}
li{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;
color:var(--text);font-size:14px;line-height:1.55;margin:0 0 10px;padding-left:20px;position:relative}li:last-child{margin-bottom:0}
li:before{content:"▸";position:absolute;left:2px;top:0;color:var(--cyan);
font-family:ui-monospace,SFMono-Regular,Menlo,"JetBrains Mono",monospace}
code{background:var(--titlebar);border:1px solid var(--border);padding:1px 5px;border-radius:4px;font-size:12.5px;
font-family:ui-monospace,SFMono-Regular,Menlo,"JetBrains Mono",monospace;color:var(--warn)}
a{color:var(--cyan);text-decoration:underline}
em{font-style:italic;color:var(--prose)}
strong{font-weight:700;color:var(--text)}
.btn-wrap{margin:10px 0 2px}
.btn{display:inline-block;padding:10px 16px;color:var(--ok);border:1px solid var(--ok);background:rgba(70,196,106,.08);
font-weight:700;font-size:13px;border-radius:6px;text-decoration:none;line-height:1.2;
font-family:ui-monospace,SFMono-Regular,Menlo,"JetBrains Mono",monospace}
.footer{margin-top:24px;font-size:11px;color:var(--dim2);
font-family:ui-monospace,SFMono-Regular,Menlo,"JetBrains Mono",monospace}
.footer code{font-size:11px;background:none;border:none;padding:0;color:var(--dim)}
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


_STATE = {
    "clean": ("t-ok", "CLEAN — NO DRIFT"),
    "drift": ("t-warn", "REVIEW NEEDED"),
    "error": ("t-err", "AUDIT ERROR"),
}
_SUBHEAD = {
    "clean": "Docs + IaC match live state this week.",
    "drift": "One or more items need manual review.",
    "error": "The audit run exited with an error — see the log.",
}


def _render(status: str, body_md: str) -> str:
    tone, state = _STATE.get(status, ("t-muted", "AUDIT RAN"))
    subhead = _SUBHEAD.get(status, "Weekly live-anchored doc/IaC drift audit.")
    body_html = _md_to_html(body_md)
    now = datetime.now().strftime("%a %b %-d %H:%M")
    return (
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1.0">'
        '<meta name="color-scheme" content="light dark">'
        '<meta name="supported-color-schemes" content="light dark">'
        '<title>Doc/IaC drift — weekly audit</title>'
        f"<style>{_CSS}</style></head><body><div class='wrap'><div class='term'>"
        '<div class="titlebar">'
        '<span class="dots"><i class="d-r"></i><i class="d-a"></i><i class="d-g"></i></span>'
        '<span class="brand"><span class="ring"><i></i></span><b>etherport</b><em>&middot; drift</em></span>'
        '<span class="tb-spacer"></span></div>'
        '<div class="screen">'
        '<div class="prompt"><span class="p-user">alerts@etherport</span><span class="p-punc">:</span>'
        '<span class="p-path">~</span><span class="p-punc">$</span> drift audit --since last-week'
        '<span class="cursor"></span></div>'
        '<h1>Weekly doc / IaC drift audit</h1>'
        f'<p class="subhead">{html.escape(subhead)}</p>'
        f'<div class="status-line {tone}"><i></i>{state}</div>'
        f'<div class="card">{body_html}</div>'
        f'<div class="footer">— generated {now} PT · devbox · log '
        '<code>~/.local/state/doc-drift-audit/</code> · doc-drift issue —</div>'
        "</div></div></div></body></html>"
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
