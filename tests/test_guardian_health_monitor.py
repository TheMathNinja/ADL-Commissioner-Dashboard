import copy
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import os
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import guardian_health_monitor as monitor

NOW = datetime(2026, 11, 15, 17, 0, tzinfo=timezone.utc)


def ledger():
    return {'schemaVersion': 1, 'generatedAt': NOW.isoformat(), 'checks': [],
            'leagues': [{'key': k, 'leagueId': '1', 'franchiseId': '0005'} for k in ('ADL', 'FAFL')]}


def state():
    return {'activatedAt': NOW.isoformat(), 'incidents': {}, 'schedules': {}}


def schedule(row, now):
    return {'week': 10, 'kickoffs': [(NOW + timedelta(minutes=90)).isoformat()]}


class MonitorTests(unittest.TestCase):
    def test_optional_opaque_input_hash_is_backward_compatible(self):
        value = ledger()
        self.assertIs(monitor.validate(value, NOW), value)
        value['publicInputs'] = {'ADL': {'week': 10, 'checkedAt': NOW.isoformat(), 'fingerprint': 'a' * 64}}
        self.assertIs(monitor.validate(value, NOW), value)
        value['publicInputs']['ADL']['players'] = ['not allowed']
        with self.assertRaises(ValueError):
            monitor.validate(value, NOW)
    def test_matches_private_deadline_engine(self):
        root = os.environ.get('GUARDIAN_TEST_ROOT')
        if not root:
            self.skipTest('Private reference is supplied only to the local/private cross-repository gate')
        sys.path.insert(0, str(Path(root) / 'scripts'))
        from check_guardian_coverage import assess as reference
        from export_health_receipts import export
        for mode in ('monitor', 'initial'):
            for status in ('ok', 'changed', 'idle', 'warning', 'error'):
                for offset in (-100, -10, 0, 5, 15):
                    checked = NOW + timedelta(minutes=offset)
                    audit = {'runMode': mode, 'dryRun': False,
                             'completedAt': (checked + timedelta(seconds=2)).isoformat(),
                             'results': [{'key': 'ADL', 'week': 10, 'status': status,
                                          'reason': 'roster_needs_attention', 'checkedAt': checked.isoformat()}],
                             'snapshots': [{'league': 'ADL', 'week': 10, 'players': [1],
                                            'capturedAt': (checked + timedelta(seconds=1)).isoformat()}]}
                    checks = export([audit], ledger()['leagues'])['checks']
                    schedules = {'ADL': schedule({}, NOW)}
                    activated = NOW - timedelta(days=2)
                    for minute in (9, 10, 20, 90, 120):
                        now = NOW + timedelta(minutes=minute)
                        self.assertEqual(monitor.assess(checks, schedules, now, activated),
                                         reference([audit], schedules, now, activated))

    def test_never_started_both_leagues_at_ten_minutes(self):
        for minute, count in ((9, 0), (10, 2)):
            result = monitor.evaluate(ledger(), state(), NOW + timedelta(minutes=minute), schedule)
            self.assertEqual(sum(i['status'] == 'open' for i in result['incidents'].values()), count)

    def test_recovery_and_independent_initial_failure(self):
        value = ledger()
        original = monitor.evaluate(value, state(), NOW + timedelta(minutes=10), schedule)
        value['checks'] = [{'league': k, 'week': 10, 'mode': 'monitor',
                            'checkedAt': (NOW + timedelta(minutes=11)).isoformat()} for k in ('ADL', 'FAFL')]
        recovered = monitor.evaluate(value, original, NOW + timedelta(minutes=12), schedule)
        self.assertTrue(all(i['status'] == 'resolved' for i in recovered['incidents'].values()))
        value['checks'].pop()
        still_failed = monitor.evaluate(value, original, NOW + timedelta(minutes=12), schedule)
        self.assertEqual([i['league'] for i in still_failed['incidents'].values() if i['status'] == 'open'], ['FAFL'])

    def test_stale_ledger_is_not_a_new_success(self):
        value = ledger()
        value['generatedAt'] = (NOW - timedelta(days=5)).isoformat()
        result = monitor.evaluate(value, state(), NOW + timedelta(minutes=10), schedule)
        self.assertEqual(len(result['incidents']), 2)

    def test_missed_window_survives_week_rollover(self):
        original = monitor.evaluate(ledger(), state(), NOW + timedelta(minutes=100), schedule)
        next_schedule = lambda row, now: {'week': 11, 'kickoffs': [(NOW + timedelta(days=7)).isoformat()]}
        result = monitor.evaluate(ledger(), original, NOW + timedelta(days=1), next_schedule)
        self.assertEqual(sum(i['status'] == 'open' and i['week'] == 10 for i in result['incidents'].values()), 2)

    def test_refuse_unknown_payload_and_future_receipt(self):
        value = ledger()
        value['rosters'] = 'private'
        with self.assertRaises(ValueError):
            monitor.validate(value, NOW)
        value = ledger()
        value['checks'] = [{'league': 'ADL', 'week': 10, 'mode': 'monitor',
                            'checkedAt': (NOW + timedelta(seconds=1)).isoformat()}]
        with self.assertRaises(ValueError):
            monitor.validate(value, NOW)

    def test_dry_refresh_never_writes(self):
        import base64, json
        def api(repo, path):
            value = ledger() if 'guardian_health' in path else dict(state(), schedules={'ADL': schedule({}, NOW), 'FAFL': schedule({}, NOW)})
            return {'sha': 'test', 'content': base64.b64encode(json.dumps(value).encode()).decode()}
        with patch.object(monitor, 'persist') as persist, patch.object(monitor, 'schedule', schedule):
            # evaluate's injectable default is bound at definition; no network is needed here.
            with patch.object(monitor, 'public_json', side_effect=OSError('offline')):
                monitor.refresh(api, NOW + timedelta(minutes=10), dry=True)
            persist.assert_not_called()


if __name__ == '__main__':
    unittest.main()
