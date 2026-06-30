#!/usr/bin/env python3
"""Email the weekly doc/IaC drift audit summary via AWS SES SMTP.

The audit runs on the devbox (no in-cluster IRSA), so it can't use the daily report's
SES-API path — instead it sends over SES SMTP using creds the runner decrypts from
alertmanager-secret.sops.yaml. Pure stdlib so it runs under the devbox system python.

Env:  SMTP_HOST ("host:port"), SMTP_USER, SMTP_PASS, MAIL_FROM, MAIL_TO
Args: <status>  <subject>  <body-file>
"""
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage


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
    msg.set_content(body)

    ctx = ssl.create_default_context()
    with smtplib.SMTP(host, port, timeout=30) as srv:
        srv.starttls(context=ctx)
        srv.login(user, pw)
        srv.send_message(msg)
    print(f"sent doc-drift audit email ({status}) to {mail_to} via {host}:{port}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
