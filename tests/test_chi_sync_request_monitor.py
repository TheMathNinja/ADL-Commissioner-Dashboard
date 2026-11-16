import copy
import sys
import unittest
from datetime import datetime, timezone, timedelta
from pathlib import Path
from unittest.mock import Mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import chi_sync_request_monitor as monitor
from email_workflow_failures import notification_episode


class Requests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 11, 16, 15, tzinfo=timezone.utc)
        self.current = dict(id='12345678-1234-4234-8234-123456789abc', episode='12345678-1234-4234-8234-123456789abc',
                            status='queued', requestedAt=self.now.isoformat())
        self.writes = []
        def site(body=None):
            if body:
                self.writes.append(body)
                if body['action'] == 'claim' and self.current['status'] == 'queued':
                    self.current.update(status='claimed', claimId=body['claimId'])
            return {'current': copy.deepcopy(self.current)}
        self.site = site
        self.launch, self.report = Mock(), Mock()
        self.api = Mock(return_value={'workflow_runs': []})

    def review(self, dry=False):
        return monitor.review(self.api, self.now, dry, self.report, self.site, self.launch)

    def test_claim_precedes_one_dispatch_and_repeated_poll_does_not_resend(self):
        self.review(); self.review()
        self.launch.assert_called_once_with(self.current['id'])
        self.assertEqual([x['action'] for x in self.writes], ['claim', 'dispatched'])

    def test_never_started_check_is_reported_after_deadline_without_a_job(self):
        self.current.update(status='claimed', requestedAt=(self.now-timedelta(minutes=26)).isoformat())
        self.review()
        self.report.assert_called_once()
        self.launch.assert_not_called()
        self.assertEqual(self.writes[-1]['outcome'], 'failure')

    def test_ambiguous_dispatch_is_not_retried(self):
        self.launch.side_effect = OSError('uncertain')
        with self.assertRaises(OSError): self.review()
        self.review()
        self.assertEqual(self.launch.call_count, 1)

    def test_failed_worker_is_owned_by_existing_failure_reporter(self):
        self.current['status'] = 'dispatched'
        self.api.return_value = {'workflow_runs': [{'display_title': 'Sync private CHI Team Tools trades - request '+self.current['id'],
                                                  'status': 'completed', 'conclusion': 'failure'}]}
        self.review()
        self.report.assert_not_called()
        self.assertEqual(self.writes[-1]['outcome'], 'failure')

    def test_dry_run_never_claims_or_launches(self):
        self.review(True)
        self.assertEqual(self.writes, [])
        self.launch.assert_not_called()

    def test_request_nonce_does_not_create_new_worker_outage_email(self):
        base='private:1:Sync private CHI Team Tools trades'
        self.assertEqual(notification_episode(base+' - request '+self.current['id'], '2026-11-16'),
                         notification_episode(base+' - request 22222222-2222-4222-8222-222222222222', '2026-11-17'))


if __name__ == '__main__': unittest.main()
