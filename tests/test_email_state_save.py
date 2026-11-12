import base64
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch, Mock
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import email_weekly_completion as mail


def item(state, sha='old'):
    return {'sha': sha, 'content': base64.b64encode(json.dumps(state).encode()).decode()}


class StateSaveTests(unittest.TestCase):
    @patch.object(mail.time, 'sleep')
    def test_explicit_temporary_smtp_rejection_retries_same_message(self, sleep):
        smtp=Mock();message=object()
        smtp.send_message.side_effect=[mail.smtplib.SMTPDataError(451,b'temporary'),{}]
        mail.send_message_with_retries(smtp,message,'sender',['recipient'])
        self.assertEqual(smtp.send_message.call_count,2)
        self.assertEqual(smtp.send_message.call_args_list[0],smtp.send_message.call_args_list[1])
        sleep.assert_called_once_with(2)

    @patch.object(mail.time, 'sleep')
    def test_persistent_temporary_smtp_rejection_is_not_success(self, sleep):
        smtp=Mock();smtp.send_message.side_effect=mail.smtplib.SMTPDataError(451,b'temporary')
        with self.assertRaises(mail.smtplib.SMTPDataError):
            mail.send_message_with_retries(smtp,object(),'sender',['recipient'])
        self.assertEqual(smtp.send_message.call_count,3)

    @patch.object(mail.time, 'sleep')
    def test_permanent_or_ambiguous_smtp_delivery_is_not_retried(self, sleep):
        for error in [mail.smtplib.SMTPDataError(550,b'permanent'),TimeoutError(),mail.smtplib.SMTPServerDisconnected()]:
            smtp=Mock();smtp.send_message.side_effect=error
            with self.assertRaises(type(error)):
                mail.send_message_with_retries(smtp,object(),'sender',['recipient'])
            self.assertEqual(smtp.send_message.call_count,1)
        sleep.assert_not_called()

    def setUp(self):
        self.env = patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo')
        self.env.start()
        self.addCleanup(self.env.stop)

    @patch.object(mail.time, 'sleep')
    def test_accepted_write_with_lost_response(self, sleep):
        state = {'sent': {'one': {'sent_at': 'now'}}}
        with patch.object(mail, 'get_json', side_effect=[item({}), HTTPError('url', 502, '', {}, None), item(state)]) as api:
            mail.save_state(state)
        self.assertEqual(api.call_count, 3)
        sleep.assert_called_once_with(2)

    @patch.object(mail.time, 'sleep')
    def test_conflict_rereads_sha_and_preserves_other_records(self, sleep):
        state = {'sent': {'one': 'new'}, 'checked': {'a': 'done'}}
        remote = {'sent': {'other': 'kept'}, 'checked': {'b': 'done'}}
        with patch.object(mail, 'get_json', side_effect=[item({}), HTTPError('url', 409, '', {}, None), item(remote, 'new'), {}]) as api:
            mail.save_state(state)
        payload = api.call_args.args[1]
        self.assertEqual(payload['sha'], 'new')
        self.assertEqual(json.loads(base64.b64decode(payload['content'])), state)
        self.assertEqual(state['sent'], {'other': 'kept', 'one': 'new'})
        self.assertEqual(state['checked'], {'a': 'done', 'b': 'done'})

    @patch.object(mail.time, 'sleep')
    def test_persistent_outage_fails(self, sleep):
        with patch.object(mail, 'get_json', side_effect=HTTPError('url', 503, '', {}, None)) as api:
            with self.assertRaises(HTTPError):
                mail.save_state({'sent': {}})
        self.assertEqual(api.call_count, 4)

    @patch.object(mail.time, 'sleep')
    def test_auth_error_is_immediate(self, sleep):
        with patch.object(mail, 'get_json', side_effect=HTTPError('url', 403, '', {}, None)):
            with self.assertRaises(HTTPError):
                mail.save_state({})
        sleep.assert_not_called()

    def test_write_404_is_not_success(self):
        with patch.dict(os.environ, GH_TOKEN='test'), patch.object(mail.urllib.request, 'urlopen', side_effect=HTTPError('url', 404, '', {}, None)):
            with self.assertRaises(HTTPError):
                mail.get_json('https://api.github.com/test', {}, method='PUT')
