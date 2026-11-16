from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import forecast_request_monitor as monitor

NOW = datetime(2026, 11, 16, tzinfo=timezone.utc)


def state():
    return {'schemaVersion': 1, 'signature': 'a' * 64, 'episode': 'a' * 64, 'week': 10,
            'status': 'pending', 'requestedAt': NOW.isoformat(), 'nextPollAt': NOW.isoformat(),
            'deadlineAt': (NOW + timedelta(minutes=105)).isoformat()}


class MonitorTests(unittest.TestCase):
    def test_successful_queue_does_not_claim_forecast_recovery(self):
        import email_workflow_failures as reporter
        run = {'path': '.github/workflows/refresh_chi_team_tools.yml'}
        completed = [{'steps': [{'name': 'Queue or inspect personal forecast refresh', 'conclusion': 'success'}]}]
        self.assertTrue(reporter.unverified_forecast_queue(reporter.GUARDIAN, run, completed))
        self.assertFalse(reporter.unverified_forecast_queue(reporter.GUARDIAN, dict(run, _forecast_verified=True), completed))
    def test_never_started_poll_is_detected_at_ten_minutes(self):
        value = dict(state(), pollClaimedAt=NOW.isoformat())
        self.assertFalse(monitor.problem(value, NOW + timedelta(minutes=9)))
        self.assertTrue(monitor.problem(value, NOW + timedelta(minutes=10)))
        value['lastCheckedAt'] = (NOW + timedelta(minutes=1)).isoformat()
        self.assertFalse(monitor.problem(value, NOW + timedelta(minutes=10)))

    def test_pending_is_not_completion_or_premature_failure(self):
        self.assertFalse(monitor.problem(state(), NOW + timedelta(minutes=105)))
        self.assertTrue(monitor.problem(dict(state(), status='attention'), NOW))
        self.assertFalse(monitor.problem(dict(state(), status='verified'), NOW + timedelta(days=1)))

    def test_claim_is_saved_before_single_dispatch(self):
        events = []
        with patch.object(monitor, 'read', return_value=(state(), {'sha': 'x'})), patch.object(monitor, 'persist', side_effect=lambda *args: events.append('save')), patch.object(monitor, 'dispatch', side_effect=lambda *args: events.append('dispatch')):
            monitor.review(Mock(), NOW, False, Mock())
        self.assertEqual(events, ['save', 'dispatch'])

    def test_lease_blocks_duplicate_and_dry_run_cannot_dispatch(self):
        value = dict(state(), pollClaimedAt=NOW.isoformat())
        for dry in (False, True):
            with patch.object(monitor, 'read', return_value=(value, {'sha': 'x'})), patch.object(monitor, 'persist') as persist, patch.object(monitor, 'dispatch') as dispatch:
                monitor.review(Mock(), NOW + timedelta(minutes=5), dry, Mock())
                persist.assert_not_called()
                dispatch.assert_not_called()

    def test_malformed_identity_cannot_dispatch(self):
        with self.assertRaises(RuntimeError):
            monitor.validate(dict(state(), signature='unexpected'))


if __name__ == '__main__':
    unittest.main()
