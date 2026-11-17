from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import guardian_check_policy as policy
import guardian_health_monitor as monitor


class ThreeCheckpointTests(unittest.TestCase):
    def setUp(self):
        self.kickoff = datetime(2026, 11, 22, 18, tzinfo=timezone.utc)
        self.start = self.kickoff - timedelta(minutes=90)
        self.scope = {key: {'week': 11, 'kickoffs': [self.kickoff.isoformat()]} for key in ('ADL', 'FAFL')}

    def at(self, before):
        return self.kickoff - timedelta(minutes=before)

    def receipts(self, offsets):
        return [{'league': key, 'week': 11, 'mode': 'monitor', 'checkedAt': self.at(offset).isoformat()}
                for key in self.scope for offset in offsets]

    def test_only_75_45_15_are_new_dispatch_slots(self):
        for before, expected in ((90, None), (76, None), (75, 75), (60, 75),
                                 (46, 75), (45, 45), (30, 45), (16, 45), (15, 15), (1, 15)):
            self.assertEqual(policy.monitor_slot(self.start, self.at(before)),
                             None if expected is None else self.at(expected))

    def test_never_started_is_reported_ten_minutes_after_first_required_check(self):
        self.assertEqual(monitor.assess([], self.scope, self.at(66), self.start), [])
        self.assertEqual(len(monitor.assess([], self.scope, self.at(65), self.start)), 2)

    def test_every_later_slot_needs_new_verified_coverage(self):
        for done, before in (([75], 35), ([75, 45], 5)):
            self.assertEqual(monitor.assess(self.receipts(done), self.scope, self.at(before + 1), self.start), [])
            self.assertEqual(len(monitor.assess(self.receipts(done), self.scope, self.at(before), self.start)), 2)
        self.assertEqual(monitor.assess(self.receipts([75, 45, 15]), self.scope, self.kickoff, self.start), [])

    def test_recovery_is_per_league_and_does_not_forge_a_receipt(self):
        rows = self.receipts([75])
        late = self.receipts([34])
        self.assertEqual(len(monitor.assess(rows + late[:1], self.scope, self.at(33), self.start)), 1)
        self.assertEqual(monitor.assess(rows + late, self.scope, self.at(33), self.start), [])
        self.assertEqual(len(monitor.assess(rows + late, self.scope, self.at(5), self.start)), 2)

    def test_activation_mid_window_requires_immediate_check_without_shifting_future_slots(self):
        activated = self.at(60)
        self.assertEqual(policy.monitor_slot(self.start, activated, activated), activated)
        self.assertEqual(policy.monitor_slot(self.start, self.at(45), activated), self.at(45))
        self.assertIsNone(policy.monitor_slot(self.start, self.kickoff, self.kickoff))

    def test_old_fifteen_minute_windows_keep_their_deadlines(self):
        old = datetime(2026, 11, 16, 23, 45, tzinfo=timezone.utc)
        self.assertEqual(policy.monitor_slot(old, old + timedelta(minutes=15)), old + timedelta(minutes=15))
        self.assertTrue(policy.monitor_missing([old], old, old + timedelta(minutes=25), old))


if __name__ == '__main__':
    unittest.main()
