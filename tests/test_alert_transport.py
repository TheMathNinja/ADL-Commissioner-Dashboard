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
    def setUp(self):
        # Runner credentials and prior production receipts must never affect tests.
        self.enterContext(patch.dict(os.environ, {}, clear=True))
        self.enterContext(patch.object(mail.ssl, 'create_default_context'))
        self.enterContext(patch('urllib.request.urlopen', side_effect=AssertionError('Unexpected live HTTP in email test')))
        self.enterContext(patch.object(mail.smtplib, 'SMTP', side_effect=AssertionError('Unexpected live SMTP in email test')))
        self.enterContext(patch.object(mail.smtplib, 'SMTP_SSL', side_effect=AssertionError('Unexpected live SMTP in email test')))

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

    def test_actions_cli_uses_receipt_and_suppresses_already_delivered_message(self):
        payload = dict(subject='Test', body='plain', to=['a@example.org'], delivery_key='fixture')
        with patch.dict(os.environ, GITHUB_ACTIONS='true', GITHUB_REPOSITORY='test/offline'), \
                patch.object(sys, 'argv', ['sender', '--payload', 'fixture.json']), \
                patch.object(mail.Path, 'read_text', return_value=json.dumps(payload)), \
                patch.object(mail, 'send_payload') as send, \
                patch.object(mail, 'deliver', side_effect=lambda key, callback: callback()) as receipt:
            mail.main()
            self.assertEqual(receipt.call_args.args[0], 'r-alert:fixture')
            send.assert_called_once_with(payload)
            receipt.side_effect = None
            receipt.return_value = False
            mail.main()
            self.assertEqual(send.call_count, 1)
            self.assertEqual(receipt.call_count, 2)

    def test_non_actions_cli_does_not_access_remote_receipts(self):
        payload = dict(subject='Test', body='plain', to=['a@example.org'])
        with patch.object(sys, 'argv', ['sender', '--payload', 'fixture.json']), \
                patch.object(mail.Path, 'read_text', return_value=json.dumps(payload)), \
                patch.object(mail, 'send_payload') as send, \
                patch.object(mail, 'deliver', side_effect=AssertionError('Unexpected receipt access')):
            mail.main()
            send.assert_called_once_with(payload)
