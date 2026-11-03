import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import send_plain_email as mail


class TransportTest(unittest.TestCase):
    def test_payload_and_partial_delivery(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'payload.json'
            path.write_text(json.dumps(dict(subject='Test', body='plain', html='<b>html</b>',
                                            to=['a@example.org'], cc=['b@example.org'])))
            with patch.dict(os.environ, ADL_ALERT_EMAIL_FROM='s@example.org',
                            ADL_SMTP_USERNAME='user', ADL_SMTP_PASSWORD='password',
                            ADL_SMTP_SERVER='smtps://example.org'), \
                    patch.object(sys, 'argv', ['sender', '--payload', str(path)]), \
                    patch.object(mail.smtplib, 'SMTP_SSL') as factory:
                send = factory.return_value.__enter__.return_value.send_message
                send.return_value = {}
                mail.main()
                msg = send.call_args.args[0]
                self.assertEqual(str(msg['Cc']), 'b@example.org')
                self.assertEqual(str(msg['To']), 'a@example.org')
                self.assertEqual(msg.get_content_type(), 'multipart/alternative')
                send.return_value = {'b@example.org': (450, b'refused')}
                with self.assertRaisesRegex(RuntimeError, 'Partial'):
                    mail.main()
