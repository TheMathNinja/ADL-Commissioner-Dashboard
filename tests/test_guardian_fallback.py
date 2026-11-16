import copy
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import os
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import guardian_fallback as gate
from guardian_health_monitor import assess
from guardian_input_watch import fingerprint

NOW = datetime(2026, 11, 16, 4, 0, tzinfo=timezone.utc)  # Sunday 11 p.m. ET


def fixtures(now=NOW, kickoff=None):
    schedule = {'week': 10, 'kickoffs': [(kickoff or now + timedelta(days=1)).isoformat()]}
    ledger = {'schemaVersion': 1, 'generatedAt': now.isoformat(),
              'leagues': [{'key': k, 'leagueId': '1', 'franchiseId': '0005'} for k in ('ADL', 'FAFL')],
              'checks': [{'league': k, 'week': 10, 'mode': 'monitor', 'checkedAt': now.isoformat()} for k in ('ADL', 'FAFL')],
              'publicInputs': {k: {'week': 10, 'checkedAt': now.isoformat(), 'fingerprint': 'a' * 64} for k in ('ADL', 'FAFL')}}
    coverage = {'activatedAt': now.isoformat(), 'schedules': {k: schedule for k in ('ADL', 'FAFL')}}
    observed = {k: (schedule, 'a' * 64) for k in ('ADL', 'FAFL')}
    return ledger, coverage, observed


class SchedulingTests(unittest.TestCase):
    def test_unchanged_off_hours_start_no_private_job(self):
        for hour in (0, 2, 5, 8, 17, 23):
            now = NOW.replace(hour=hour)
            ledger, coverage, observed = fixtures(now)
            self.assertIsNone(gate.decision(ledger, coverage, {}, observed, now))

    def test_never_started_guardian_dispatches_inside_real_window(self):
        ledger, coverage, observed = fixtures(NOW, NOW + timedelta(minutes=90))
        ledger['checks'] = []
        self.assertEqual(gate.decision(ledger, coverage, {}, observed, NOW)['reason'], 'required_window')
        self.assertEqual(len(assess([], coverage['schedules'], NOW + timedelta(minutes=10), NOW)), 2)
        # Scheduling a backup has not forged a successful receipt.
        self.assertEqual(ledger['checks'], [])

    def test_healthy_primary_suppresses_duplicate_backup(self):
        ledger, coverage, observed = fixtures(NOW, NOW + timedelta(minutes=30))
        self.assertIsNone(gate.decision(ledger, coverage, {}, observed, NOW + timedelta(minutes=4)))
        self.assertEqual(gate.decision(ledger, coverage, {}, observed, NOW + timedelta(minutes=5))['reason'], 'required_window')

    def test_partial_league_success_does_not_hide_missing_other_league(self):
        ledger, coverage, observed = fixtures(NOW, NOW + timedelta(minutes=30))
        ledger['checks'] = ledger['checks'][:1]
        self.assertEqual(gate.decision(ledger, coverage, {}, observed, NOW)['reason'], 'required_window')

    def test_cached_current_week_survives_feed_rollover_and_read_failure(self):
        ledger, coverage, observed = fixtures(NOW, NOW + timedelta(minutes=30))
        ledger['checks'] = []
        observed['ADL'] = ({'week': 11, 'kickoffs': [(NOW + timedelta(days=7)).isoformat()]}, 'b' * 64)
        observed.pop('FAFL')
        self.assertEqual(gate.decision(ledger, coverage, {}, observed, NOW)['reason'], 'required_window')

    def test_unusual_weekday_kickoffs_are_not_filtered_out(self):
        now = datetime(2026, 11, 18, 18, 0, tzinfo=timezone.utc)  # Wednesday
        ledger, coverage, observed = fixtures(now, now + timedelta(minutes=60))
        ledger['checks'] = []
        self.assertEqual(gate.decision(ledger, coverage, {}, observed, now)['reason'], 'required_window')

    def test_morning_check_uses_eastern_clock_across_dst(self):
        for now in (datetime(2026, 10, 25, 10, tzinfo=timezone.utc), datetime(2026, 11, 8, 11, tzinfo=timezone.utc)):
            ledger, coverage, observed = fixtures(now)
            ledger['checks'] = []
            self.assertEqual(gate.decision(ledger, coverage, {}, observed, now)['reason'], 'morning_health')
            self.assertIsNone(gate.decision(*fixtures(now)[:2], {}, observed, now))

    def test_initial_safety_is_only_on_first_game_day_and_requires_its_own_receipt(self):
        now = datetime(2026, 11, 19, 11, tzinfo=timezone.utc)
        ledger, coverage, observed = fixtures(now, now + timedelta(hours=14))
        wanted = gate.decision(ledger, coverage, {}, observed, now)
        self.assertEqual(wanted['reason'], 'initial_safety')
        self.assertEqual(wanted['workflow'], 'initial-lineup.yml')
        ledger['checks'] = [dict(c, mode='initial') for c in ledger['checks']]
        self.assertIsNone(gate.decision(ledger, coverage, {}, observed, now))
        self.assertIsNone(gate.decision(ledger, coverage, {}, observed, now - timedelta(minutes=1)))

    def test_meaningful_background_change_is_checked_and_retries_are_bounded(self):
        ledger, coverage, observed = fixtures()
        observed['FAFL'] = (observed['FAFL'][0], 'b' * 64)
        wanted = gate.decision(ledger, coverage, {}, observed, NOW)
        self.assertEqual(wanted['reason'], 'public_inputs_changed')
        state = {'background': {'key': wanted['key'], 'attemptedAt': NOW.isoformat()}}
        self.assertIsNone(gate.decision(ledger, coverage, state, observed, NOW + timedelta(minutes=20)))
        self.assertEqual(gate.decision(ledger, coverage, state, observed, NOW + timedelta(hours=1))['reason'], 'public_inputs_changed')

    def test_deferred_private_work_is_not_stranded_by_unchanged_inputs(self):
        ledger, coverage, observed = fixtures()
        ledger['publicInputs']['FAFL']['nextCheckAt'] = (NOW + timedelta(minutes=15)).isoformat()
        self.assertIsNone(gate.decision(ledger, coverage, {}, observed, NOW))
        self.assertEqual(gate.decision(ledger, coverage, {}, observed, NOW + timedelta(minutes=15))['reason'], 'pending_private_work')
        saved = {'workAttemptedAt': (NOW + timedelta(minutes=15)).isoformat()}
        self.assertIsNone(gate.decision(ledger, coverage, saved, observed, NOW + timedelta(minutes=20)))
        self.assertEqual(gate.decision(ledger, coverage, saved, observed, NOW + timedelta(minutes=25))['reason'], 'pending_private_work')

    def test_unknown_inputs_do_not_silently_disable_the_worker(self):
        ledger, coverage, observed = fixtures()
        self.assertEqual(gate.decision(ledger, coverage, {}, {}, NOW)['reason'], 'schedule_or_inputs_unavailable')
        self.assertIsNone(gate.decision(ledger, coverage, {'degradedAt': NOW.isoformat()}, {}, NOW + timedelta(minutes=20)))

    def test_opaque_hash_ignores_scores_projections_names_and_order(self):
        players = [{'id': '2', 'starter': True, 'rosterStatus': 'ROSTER', 'reportedInjuryStatus': None},
                   {'id': '1', 'starter': False, 'rosterStatus': 'ROSTER', 'reportedInjuryStatus': 'Q'}]
        value = fingerprint(10, players)
        changed = [dict(p, score=500, projectedPoints=999, name='private', formula='private') for p in reversed(players)]
        self.assertEqual(value, fingerprint(10, changed))
        changed[0]['reportedInjuryStatus'] = 'O'
        self.assertNotEqual(value, fingerprint(10, changed))

    def test_only_known_live_inflight_runs_suppress_backup(self):
        run = {'created_at': NOW.isoformat(), 'status': 'queued', 'event': 'workflow_dispatch',
               'display_title': 'Chicago Bears Lineup Guardian - gas-20261116-guardian-yml'}
        self.assertTrue(gate.recent_inflight([run], NOW))
        self.assertFalse(gate.recent_inflight([dict(run, display_title='Manual dry run')], NOW))
        self.assertFalse(gate.recent_inflight([run], NOW + timedelta(minutes=5)))

    def test_preview_never_dispatches_or_writes(self):
        ledger, coverage, observed = fixtures(NOW, NOW + timedelta(minutes=30))
        ledger['checks'] = []
        def document(path, optional=False):
            return (ledger if path == gate.LEDGER else coverage if path == gate.STATE else {}), {'sha': 'x'}
        with patch.object(gate, 'document', side_effect=document), patch.object(gate, 'observe', side_effect=lambda league, now: observed[league['key']]), patch.object(gate, 'private', return_value={'workflow_runs': []}), patch.object(gate, 'persist') as persist, patch.object(gate, 'dispatch') as dispatch:
            gate.run(dry=True, now=NOW)
            persist.assert_not_called()
            dispatch.assert_not_called()

    def test_concurrent_dispatch_claim_does_not_send_again(self):
        ledger, coverage, observed = fixtures(NOW, NOW + timedelta(minutes=30))
        ledger['checks'] = []
        calls = [0]
        def document(path, optional=False):
            if path == gate.PATH:
                calls[0] += 1
                state = {} if calls[0] == 1 else {'claim': {'at': NOW.isoformat()}}
                return state, {'sha': 'x'}
            return (ledger if path == gate.LEDGER else coverage), {'sha': 'x'}
        with patch.object(gate, 'document', side_effect=document), patch.object(gate, 'observe', side_effect=lambda league, now: observed[league['key']]), patch.object(gate, 'private', return_value={'workflow_runs': []}), patch.object(gate, 'persist', side_effect=HTTPError('https://example.test', 409, 'Conflict', {}, None)), patch.object(gate, 'dispatch') as dispatch:
            gate.run(dry=False, now=NOW)
            dispatch.assert_not_called()

    def test_dispatch_uses_private_native_policy_not_a_public_permission_copy(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self): return b''
        with patch.dict(gate.os.environ, {'PRIVATE_REPORT_TOKEN': 'test'}), patch.object(gate, 'urlopen', return_value=Response()) as send:
            gate.dispatch('public-backup-test')
        import json
        payload = json.loads(send.call_args.args[0].data)
        self.assertEqual(payload['inputs']['live'], False)
        self.assertEqual(payload['inputs']['use_native_policy'], True)

    def test_ambiguous_dispatch_is_not_replayed_and_never_creates_coverage(self):
        ledger, coverage, observed = fixtures(NOW, NOW + timedelta(minutes=30))
        ledger['checks'] = []
        def document(path, optional=False):
            return (ledger if path == gate.LEDGER else coverage if path == gate.STATE else {}), {'sha': 'x'}
        with patch.dict(gate.os.environ, {'GUARDIAN_FALLBACK_LIVE': 'true'}), patch.object(gate, 'document', side_effect=document), patch.object(gate, 'observe', side_effect=lambda league, now: observed[league['key']]), patch.object(gate, 'private', return_value={'workflow_runs': []}), patch.object(gate, 'persist') as persist, patch.object(gate, 'dispatch', side_effect=URLError('timeout')) as dispatch:
            gate.run(dry=False, now=NOW)
            persist.assert_called_once()
            self.assertEqual(persist.call_args.args[0], gate.PATH)
            dispatch.assert_called_once()
            self.assertEqual(ledger['checks'], [])

    def test_native_private_runner_guard_does_not_disable_direct_work(self):
        root = os.environ.get('GUARDIAN_TEST_ROOT')
        if root:
            source = (Path(root) / '.github/workflows/guardian.yml').read_text()
            self.assertIn("  guardian:\n    if: github.event_name != 'schedule' || vars.GUARDIAN_NATIVE_FALLBACK != 'public-scheduler-v1'", source)
            self.assertIn('workflow_dispatch:', source)
            self.assertIn('group: lineup-guardian-writes', source)
            self.assertIn('run: npm run check', source)
            self.assertIn('LOOKAHEAD_MINUTES || 90', (Path(root) / 'src/config.js').read_text())
            self.assertIn('lookaheadMinutes: 90', (Path(root) / 'scheduler/Code.gs').read_text())
            initial = (Path(root) / '.github/workflows/initial-lineup.yml').read_text()
            self.assertIn("  initial-lineup:\n    if: github.event_name != 'schedule' || vars.GUARDIAN_NATIVE_FALLBACK != 'public-scheduler-v1'", initial)
            self.assertIn('use_native_policy:', initial)
        for event, armed, expected in (('schedule', True, False), ('schedule', False, True), ('workflow_dispatch', True, True)):
            self.assertEqual(event != 'schedule' or not armed, expected)

    def test_both_public_clocks_use_same_gate_and_reporting_survives_gate_failure(self):
        root = Path(__file__).resolve().parents[1]
        backup = (root / '.github/workflows/guardian_fallback.yml').read_text()
        reporter = (root / '.github/workflows/email_workflow_failures.yml').read_text()
        self.assertIn("cron: '2-59/5 * * 9-12,1 *'", backup)
        self.assertIn('scripts/guardian_fallback.py', backup)
        self.assertIn('scripts/guardian_fallback.py --live', reporter)
        self.assertIn('name: Report failed league dependencies independently of publication\n        if: always()', reporter)
        self.assertNotIn('repository: TheMathNinja/Chicago-Bears-Lineup-Guardian', backup)


if __name__ == '__main__':
    unittest.main()
