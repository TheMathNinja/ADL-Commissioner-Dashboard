import os
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
    if len(sys.argv) != 4:
        raise SystemExit("usage: send_plain_email.py SUBJECT RECIPIENT BODY_FILE")

    subject, recipient, body_file = sys.argv[1:]
    sender = required("ADL_ALERT_EMAIL_FROM")
    username = required("ADL_SMTP_USERNAME")
    password = required("ADL_SMTP_PASSWORD")
    server_url = required("ADL_SMTP_SERVER")
    parsed = urlparse(server_url if "://" in server_url else f"smtp://{server_url}")
    host = parsed.hostname or parsed.path
    use_ssl = parsed.scheme.lower() == "smtps"
    port = parsed.port or (465 if use_ssl else 587)

    message = EmailMessage()
    message["From"] = sender
    message["To"] = recipient
    message["Subject"] = subject
    message.set_content(Path(body_file).read_text(encoding="utf-8"))

    context = ssl.create_default_context()
    if use_ssl:
        with smtplib.SMTP_SSL(host, port, context=context, timeout=30) as smtp:
            smtp.login(username, password)
            smtp.send_message(message)
    else:
        with smtplib.SMTP(host, port, timeout=30) as smtp:
            smtp.ehlo()
            smtp.starttls(context=context)
            smtp.ehlo()
            smtp.login(username, password)
            smtp.send_message(message)

    print(f"Sent email to {recipient}")


if __name__ == "__main__":
    main()
