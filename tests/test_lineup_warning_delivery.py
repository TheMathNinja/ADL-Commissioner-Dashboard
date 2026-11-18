import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from lineup_warning_delivery import coordinate, deliver_lineup, accepted_legacy, digest
from email_delivery_state import DeliveryUncertain


def payload(*keys, resolved=(), held=()):
    return dict(subject='GM warning', to=['gm@example.test'], cc=[], lineup_season=2026,
                lineup_week=11, lineup_franchise='MIN', lineup_header='Roster needs attention',
                lineup_footer='Submit New Lineup: team link', lineup_legacy={},
                lineup_entries=[dict(keys=[key], body='Detail ' + key) for key in keys],
                lineup_resolved=list(resolved), lineup_held=list(held))


class CoordinationTests(unittest.TestCase):
    def setUp(self):
        self.state = {}
        self.sent = []
        self.saved = []

    def run_check(self, value, **kw):
        return coordinate(self.state, value, self.sent.append,
                          lambda: self.saved.append(copy.deepcopy(self.state)), **kw)

    def test_readiness_and_later_lineup_share_one_episode(self):
        self.run_check(payload('position:PN'))
        later = payload('position:PN', 'position:PN')
        later['lineup_entries'][0]['body'] = 'Missing PN in lineup'
        later['lineup_entries'][1]['body'] = 'Punter is on bye'
        self.assertFalse(self.run_check(later))
        self.assertEqual(len(self.sent), 1)

    def test_independent_problem_is_sent_without_repeating_previous_detail(self):
        self.run_check(payload('position:PN'))
        self.run_check(payload('position:PN', 'player:injured-wr'))
        self.assertEqual(len(self.sent), 2)
        self.assertNotIn('Detail position:PN', self.sent[-1]['body'])
        self.assertIn('player:injured-wr', self.sent[-1]['body'])

    def test_multiple_new_issues_are_one_combined_gm_message(self):
        self.run_check(payload('position:PN', 'position:PK'))
        self.assertEqual(len(self.sent), 1)
        self.assertIn('position:PN', self.sent[0]['body'])
        self.assertIn('position:PK', self.sent[0]['body'])
        self.assertEqual(self.sent[0]['cc'], [])

    def test_verified_repair_allows_recurrence(self):
        self.run_check(payload('position:PN'))
        self.run_check(payload(resolved=['position:PN']))
        self.run_check(payload('position:PN'))
        self.assertEqual(len(self.sent), 2)

    def test_pending_or_unknown_data_does_not_claim_repair(self):
        self.run_check(payload('position:PN'))
        self.run_check(payload('position:PN', held=['position:PN'], resolved=['position:PN']))
        self.run_check(payload('position:PN'))
        self.assertEqual(len(self.sent), 1)

    def test_active_evidence_overrides_conflicting_repair(self):
        self.run_check(payload('position:PN'))
        self.run_check(payload('position:PN', resolved=['position:PN']))
        self.assertEqual(len(self.sent), 1)

    def test_import_only_exact_accepted_legacy_evidence(self):
        value = payload('position:PN')
        value['lineup_legacy'] = {'position:PN': 'exact-old-key'}
        self.assertFalse(self.run_check(value, legacy=lambda key: key == 'exact-old-key'))
        self.assertEqual(self.sent, [])
        self.run_check(payload(resolved=['position:PN']))
        self.run_check(value, legacy=lambda key: True)
        self.assertEqual(len(self.sent), 1)

    def test_unverified_legacy_evidence_does_not_hide_a_warning(self):
        value = payload('position:PN')
        value['lineup_legacy'] = {'position:PN': 'not-accepted'}
        self.assertTrue(self.run_check(value, legacy=lambda key: False))

    def test_uncertain_delivery_is_not_retried_but_independent_issue_can_send(self):
        with self.assertRaises(TimeoutError):
            coordinate(self.state, payload('position:PN'), lambda message: (_ for _ in ()).throw(TimeoutError()), lambda: None)
        with self.assertRaises(DeliveryUncertain):
            self.run_check(payload('position:PN'))
        self.run_check(payload('position:PN', 'position:PK'))
        self.assertEqual(len(self.sent), 1)
        self.assertNotIn('Detail position:PN', self.sent[0]['body'])

    def test_save_failure_prevents_smtp(self):
        with self.assertRaises(RuntimeError):
            coordinate({}, payload('position:PN'), self.sent.append,
                       lambda: (_ for _ in ()).throw(RuntimeError('CAS conflict')))
        self.assertEqual(self.sent, [])

    def test_accepted_delivery_is_not_replayed_if_final_bookkeeping_crashed(self):
        self.run_check(payload('position:PN'))
        del self.state['issues']['position:PN']['notified']
        self.assertFalse(self.run_check(payload('position:PN')))
        self.assertEqual(len(self.sent), 1)

    def test_no_state_or_email_created_for_previously_healthy_team(self):
        import os
        from unittest.mock import patch
        requests = []
        with patch.dict(os.environ, GITHUB_REPOSITORY='test/offline'):
            self.assertFalse(deliver_lineup(payload(resolved=['position:PN']), self.sent.append,
                request=lambda url: requests.append(url)))
        self.assertEqual(len(requests), 1)
        self.assertEqual(self.sent, [])

    def test_stale_snapshot_cannot_reopen_a_repaired_issue(self):
        value = payload('position:PN'); value['lineup_checked_at'] = 10
        self.run_check(value)
        repaired = payload(resolved=['position:PN']); repaired['lineup_checked_at'] = 20
        self.run_check(repaired)
        self.assertFalse(self.run_check(value))
        self.assertEqual(len(self.sent), 1)

    def test_legacy_status_requires_accepted_not_dispatch_or_uncertainty(self):
        import base64
        import json
        import os
        from unittest.mock import patch
        key = 'exact-legacy'
        identity = digest('r-alert:' + key)
        def request(status):
            value = dict(delivery_receipts={identity: dict(status=status)})
            return lambda url: dict(content=base64.b64encode(json.dumps(value).encode()).decode())
        with patch.dict(os.environ, GITHUB_REPOSITORY='test/offline'):
            self.assertTrue(accepted_legacy(key, request('accepted')))
            self.assertFalse(accepted_legacy(key, request('dispatched')))
            with self.assertRaises(DeliveryUncertain):
                accepted_legacy(key, request('uncertain'))


if __name__ == '__main__':
    unittest.main()
