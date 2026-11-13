"""Shared SMTP acceptance policy; mirrored copies are checked by the release gate."""
import smtplib
import time


class PartialDeliveryError(RuntimeError):
    def __init__(self, refused, recipients):
        self.refused = refused
        self.accepted = tuple(address for address in recipients if address not in refused)
        super().__init__("Partial SMTP delivery; accepted recipients must not be retried")


def send_message_with_retries(smtp, message, sender, recipients, sleep=None):
    """Only explicit temporary DATA rejection proves that retrying is safe."""
    sleep = sleep or time.sleep
    recipients = list(dict.fromkeys(recipients))
    if not recipients:
        raise ValueError("At least one envelope recipient is required")
    for attempt in range(3):
        try:
            refused = smtp.send_message(message, from_addr=sender, to_addrs=recipients)
        except smtplib.SMTPDataError as error:
            if not 400 <= error.smtp_code < 500 or attempt == 2:
                raise
            sleep(2 ** (attempt + 1))
        else:
            if refused:
                raise PartialDeliveryError(refused, recipients)
            return {}


def definitely_rejected(error):
    # Disconnects, timeouts and arbitrary SMTP responses do not prove nonacceptance.
    return isinstance(error, (smtplib.SMTPDataError, smtplib.SMTPSenderRefused,
                              smtplib.SMTPRecipientsRefused, smtplib.SMTPAuthenticationError))
