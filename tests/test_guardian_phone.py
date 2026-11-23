from datetime import datetime, timedelta, timezone
from io import BytesIO
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from guardian_phone import URL, send_for_pending


class PhoneWarnings(unittest.TestCase):
    now = datetime(2026, 11, 22, 20, tzinfo=timezone.utc)

    def warning(self, opened=-3, expires=10, severity='confirmed'):
        return ({'key': 'FAFL'}, {
            'severity': severity, 'detail': 'private name must not leave',
            'pushUntil': (self.now + timedelta(minutes=expires)).isoformat(),
            'openedAt': (self.now + timedelta(minutes=opened)).isoformat(),
        })

    def test_only_fresh_verified_actions_leave_no_player_data(self):
        transport = Mock(return_value=BytesIO(b'{"status":"accepted"}'))
        send_for_pending({
            'out': self.warning(),
            'q': self.warning(severity='advisory'),
            'locked': self.warning(expires=0),
            'stale': self.warning(opened=-16),
            'generic': ({'key': 'ADL'}, {'severity': 'confirmed'}),
        }, self.now, 'fake', transport)
        transport.assert_called_once()
        request = transport.call_args.args[0]
        self.assertEqual(request.full_url, URL)
        self.assertEqual(request.get_method(), 'PUT')
        payload = json.loads(request.data)
        self.assertEqual(set(payload), {'id', 'league', 'observedAt', 'expiresAt'})
        self.assertEqual(payload['league'], 'FAFL')
        self.assertEqual(len(payload['id']), 64)

    def test_phone_timeout_does_not_stop_email(self):
        transport = Mock(side_effect=TimeoutError)
        send_for_pending({'out': self.warning()}, self.now, 'fake', transport)
        transport.assert_called_once()
