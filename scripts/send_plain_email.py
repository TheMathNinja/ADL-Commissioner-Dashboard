import json
import os
import re
import smtplib
import ssl
import sys
from email.message import EmailMessage
from pathlib import Path
from urllib.parse import urlparse


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[1] == "--payload":
        payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    elif len(sys.argv) == 4:
        subject, recipient, body_file = sys.argv[1:]
        payload = dict(subject=subject, to=[recipient], body=Path(body_file).read_text(encoding="utf-8"))
    else:
        raise SystemExit("usage: send_plain_email.py SUBJECT RECIPIENT BODY_FILE")

    sender = required("ADL_ALERT_EMAIL_FROM")
    username = required("ADL_SMTP_USERNAME")
    password = required("ADL_SMTP_PASSWORD")
    server_url = required("ADL_SMTP_SERVER")
    parsed = urlparse(server_url if "://" in server_url else f"smtp://{server_url}")
    host = parsed.hostname or parsed.path
    use_ssl = parsed.scheme.lower() == "smtps" or parsed.port == 465
    port = parsed.port or (465 if use_ssl else 587)

    message = EmailMessage()
    message["From"] = sender
    message["To"] = ", ".join(payload["to"])
    if payload.get("cc"):
        message["Cc"] = ", ".join(payload["cc"])
    message["Subject"] = payload["subject"]
    message.set_content(payload["body"])
    if payload.get("html"):
        message.add_alternative(payload["html"], subtype="html")

    context = ssl.create_default_context()
    if re.fullmatch(r'(?:[a-z]{4} ){3}[a-z]{4}', password):
        password = password.replace(' ', '')
    factory = smtplib.SMTP_SSL if use_ssl else smtplib.SMTP
    with factory(host, port, timeout=30, **({'context': context} if use_ssl else {})) as smtp:
        if not use_ssl:
            smtp.starttls(context=context)
        smtp.ehlo()
        if 'LOGIN' in smtp.esmtp_features.get('auth', '').upper().split():
            smtp.user, smtp.password = username, password
            smtp.auth('LOGIN', smtp.auth_login, initial_response_ok=False)
        else:
            smtp.login(username, password, initial_response_ok=False)
        refused = smtp.send_message(message)

    if refused:
        raise RuntimeError("Partial SMTP delivery; review before retrying")
    print("SMTP accepted all recipients")


if __name__ == "__main__":
    main()
