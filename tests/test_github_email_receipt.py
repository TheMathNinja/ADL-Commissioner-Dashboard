import base64
import copy
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from github_email_receipt import deliver
from email_delivery_state import DeliveryUncertain


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.remote = None
        self.revision = 0

    def api(self, url, payload=None):
        if payload is None:
            return copy.deepcopy(self.remote)
        if self.remote and payload.get('sha') != self.remote['sha']:
            raise RuntimeError('CAS conflict')
        if not self.remote and 'sha' in payload:
            raise RuntimeError('unexpected update')
        self.revision += 1
        self.remote = {'sha': str(self.revision), 'content': payload['content']}
        return {'content': {'sha': str(self.revision)}}

    @patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo')
    def test_confirmed_delivery_is_not_repeated_after_process_restart(self):
        send = Mock()
        deliver('same report', send, self.api)
        deliver('same report', send, self.api)
        self.assertEqual(send.call_count, 1)
        state = json.loads(base64.b64decode(self.remote['content']))
        self.assertEqual(next(iter(state['delivery_receipts'].values()))['status'], 'accepted')

    @patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo')
    def test_concurrent_claim_prevents_smtp(self):
        send = Mock()
        def request(url, payload=None):
            if payload is not None:
                raise RuntimeError('CAS conflict')
        with self.assertRaises(RuntimeError):
            deliver('same report', send, request)
        send.assert_not_called()

    @patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo')
    def test_ambiguous_write_after_acceptance_is_not_replayed(self):
        send = Mock()
        def request(url, payload=None):
            if payload is not None and self.revision == 1:
                raise TimeoutError('cannot confirm second write')
            return self.api(url, payload)
        with self.assertRaises(TimeoutError):
            deliver('same report', send, request)
        with self.assertRaises(DeliveryUncertain):
            deliver('same report', send, self.api)
        self.assertEqual(send.call_count, 1)


if __name__ == '__main__':
    unittest.main()
