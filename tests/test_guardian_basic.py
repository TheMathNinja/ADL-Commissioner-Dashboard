import copy
import json
import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import guardian_basic as basic
import guardian_health_monitor as health
from guardian_incidents import report_missing_checks
from guardian_incidents import owned_basic_failure
from actions_budget import configured_projection


class Basic(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 11, 22, 17, tzinfo=timezone.utc)
        self.league = dict(key='ADL', leagueId='12345', franchiseId='0005')
        self.ledger = dict(schemaVersion=1, generatedAt=self.now.isoformat(),
                           leagues=[self.league, dict(self.league, key='FAFL', leagueId='67890')], checks=[])
        self.fixtures = {
            'rosters': {'rosters': {'franchise': {'id': '0005', 'week': '12', 'player': [{'id': '1', 'status': 'ROSTER'}]}}},
            'weeklyResults': {'weeklyResults': {'week': '12', 'matchup': {'franchise': {'id': '0005', 'starters': '1,'}}}},
            'players': {'players': {'player': {'id': '1', 'name': 'Test Starter', 'position': 'QB', 'team': 'X'}}},
            'league': {'league': {'starters': {'count': '1', 'iop_starters': '1', 'idp_starters': '0',
                                             'position': {'name': 'QB', 'limit': '1'}}}},
            'injuries': {'injuries': {'week': '12', 'injury': []}},
            'nflByeWeeks': {'nflByeWeeks': {'team': []}},
            'nflSchedule': {'nflSchedule': {'week': '12', 'matchup': {'kickoff': str(int((self.now+timedelta(hours=1)).timestamp())),
                                                                  'team': {'id': 'X'}}}},
        }
        self.read = Mock(side_effect=lambda year, kind, **kw: copy.deepcopy(self.fixtures[kind]))

    def test_healthy_receipts_use_only_public_feeds_and_no_scores(self):
        ledger, warning = basic.check(self.ledger, {}, 'monitor', self.now, self.read)
        self.assertEqual(len(ledger['checks']), 2)
        self.assertEqual(warning['incidents'], {})
        self.assertEqual({c.args[1] for c in self.read.call_args_list}, basic.FEEDS)
        self.assertNotIn('projection', json.dumps(ledger).lower())

    def test_out_starter_is_warning_not_failed_check_and_no_replacement_ranking(self):
        self.fixtures['injuries']['injuries']['injury'] = {'id': '1', 'status': 'Out'}
        ledger, warnings = basic.check(self.ledger, {}, 'monitor', self.now, self.read)
        self.assertEqual(len(ledger['checks']), 2)
        detail = warnings['incidents']['ADL:12:starter:1']['detail']
        self.assertIn('Remove Test Starter', detail)
        self.assertIn('private CHI Tools', detail)
        self.assertNotIn('score', detail)

    def test_missing_punter_is_an_explicit_position_warning(self):
        rules = self.fixtures['league']['league']['starters']
        rules['count'] = '2'
        rules['position'] = [rules['position'], {'name': 'PN', 'limit': '1'}]
        _, issues = basic.inspect(self.league, self.now, self.read)
        self.assertIn('PN: requires 1-1; currently 0', issues['lineup-rules'])
        self.assertEqual(len(issues), 1)

    def test_locked_starter_does_not_get_impossible_replacement_instruction(self):
        self.fixtures['injuries']['injuries']['injury'] = {'id': '1', 'status': 'O'}
        self.fixtures['nflSchedule']['nflSchedule']['matchup']['kickoff'] = str(int((self.now-timedelta(minutes=1)).timestamp()))
        self.assertEqual(basic.inspect(self.league, self.now, self.read)[1], {})

    def test_known_starter_no_longer_rostered_is_a_warning_not_a_failed_check(self):
        self.fixtures['rosters']['rosters']['franchise']['player'] = []
        ledger, warning = basic.check(self.ledger, {}, 'monitor', self.now, self.read)
        self.assertEqual(len(ledger['checks']), 2)
        self.assertIn('NOT_ON_ROSTER', warning['incidents']['ADL:12:starter:1']['detail'])

    def test_taxi_starter_gets_an_exact_activation_instruction_without_ranking(self):
        self.fixtures['rosters']['rosters']['franchise']['player'][0]['status'] = 'TAXI_SQUAD'
        _, issues = basic.inspect(self.league, self.now, self.read)
        self.assertIn('from Taxi to Active', issues['starter:1'])

    def test_incomplete_reads_never_count_or_resolve_existing_warning(self):
        before = basic.record_warnings({}, 'ADL', 12, {'starter:1': 'remove'}, self.now)
        self.read.side_effect = OSError('not logged')
        ledger, after = basic.check(self.ledger, before, 'monitor', self.now, self.read)
        self.assertEqual(ledger['checks'], [])
        self.assertEqual(before, after)

    def test_one_league_read_failure_does_not_hide_its_gap_or_erase_the_other_check(self):
        def read(year, kind, **params):
            if params.get('L') == '67890':
                raise OSError('FAFL unavailable')
            return copy.deepcopy(self.fixtures[kind])
        ledger, _ = basic.check(self.ledger, {}, 'monitor', self.now, read)
        self.assertEqual([r['league'] for r in ledger['checks']], ['ADL'])
        schedule = dict(week=12, kickoffs=[(self.now+timedelta(minutes=15)).isoformat()])
        later = self.now+timedelta(minutes=11)
        state = health.evaluate(ledger, dict(activatedAt=(self.now-timedelta(hours=2)).isoformat()),
                                later, lambda *args: schedule)
        self.assertEqual({r['league'] for r in state['incidents'].values()}, {'FAFL'})

    def test_warning_deduplicates_until_verified_recovery_then_reopens(self):
        first = basic.record_warnings({}, 'ADL', 12, {'starter:1': 'remove'}, self.now)
        later = self.now + timedelta(minutes=10)
        repeated = basic.record_warnings(first, 'ADL', 12, {'starter:1': 'remove'}, later)
        self.assertEqual(first, repeated)
        recovered = basic.record_warnings(first, 'ADL', 12, {}, later)
        self.assertEqual(recovered['incidents']['ADL:12:starter:1']['status'], 'resolved')
        reopened = basic.record_warnings(recovered, 'ADL', 12, {'starter:1': 'remove'}, later)
        self.assertNotEqual(first['incidents']['ADL:12:starter:1']['openedAt'], reopened['incidents']['ADL:12:starter:1']['openedAt'])

    def test_projection_and_private_endpoint_are_not_allowed(self):
        for kind in ('projectedScores', 'weekly-projections', 'private-values'):
            with self.assertRaises(ValueError):
                basic.feed(2026, kind, L='12345')
        with self.assertRaises(ValueError):
            basic.feed(2026, 'players', L='https://private')

    def test_individual_lineup_link_keeps_the_correct_season_after_new_year(self):
        link = basic.submit_link(self.league, 17, datetime(2027, 1, 2, tzinfo=timezone.utc))
        self.assertIn('/2026/options?', link)
        self.assertIn('F=0005', link)
        self.assertIn('W=17', link)

    def test_never_started_basic_check_is_reported_once_and_independent_gaps_survive(self):
        kickoff = self.now + timedelta(minutes=15)
        schedule = dict(week=12, kickoffs=[kickoff.isoformat()])
        original = dict(activatedAt=(self.now-timedelta(hours=2)).isoformat())
        covered = health.evaluate(self.ledger, original, self.now, lambda *args: schedule)
        self.assertTrue(any(x['mode'] == 'monitor' for x in covered['incidents'].values()))
        state = {'sent': {}}
        deliver, send, save = Mock(side_effect=lambda s, k, callback, persist: callback()), Mock(), Mock()
        report_missing_checks(covered, state, False, deliver, save, send)
        report_missing_checks(covered, state, False, deliver, save, send)
        self.assertEqual(send.call_count, 1)
        self.assertIn('ADL', send.call_args.args[1])
        self.assertIn('FAFL', send.call_args.args[1])

    def test_public_split_zeroes_only_checker_cost_and_keeps_manual_reserve(self):
        projection = configured_projection(self.now, [self.now+timedelta(days=4)], conservation=True,
                                           runner='ubuntu-24.04-arm', public_basic=True)
        components = projection['componentsThroughReset']
        self.assertEqual(components['preKickoff'], 0)
        self.assertEqual(components['morningProtection'], 0)
        self.assertGreater(components['manualRefreshes'], 0)
        self.assertEqual(components['changesRetriesAndColdTestRuns'], 4)

    def test_public_worker_has_no_site_secret_private_checkout_or_artifacts(self):
        source = Path(basic.__file__).read_text()
        for forbidden in ('CHI_SITE_SERVICE_TOKEN', 'subprocess', 'projectedScores', 'actions/upload-artifact', 'engine/'):
            self.assertNotIn(forbidden, source)
        root = Path(__file__).resolve().parents[1]
        for name in ('guardian_fallback.yml', 'email_workflow_failures.yml'):
            workflow = (root / '.github/workflows' / name).read_text()
            self.assertIn('GUARDIAN_BASIC_OWNER: ${{ vars.GUARDIAN_BASIC_OWNER }}', workflow)
            self.assertNotIn('repository: TheMathNinja/Chicago-Bears-Lineup-Guardian', workflow)
            self.assertNotIn('private-model-context', workflow)
            self.assertNotIn('actions/upload-artifact', workflow)

    def test_public_mode_uses_basic_worker_and_never_launches_private_ranker(self):
        import guardian_fallback as gate
        schedule = dict(week=12, kickoffs=[(self.now+timedelta(minutes=60)).isoformat()])
        def document(path, optional=False):
            return (self.ledger if path in (gate.LEDGER, basic.HEALTH) else {}), {'sha': 'test'}
        with patch.dict(os.environ, GUARDIAN_BASIC_OWNER='public-basic-v1'), \
                patch.object(gate, 'document', side_effect=document), \
                patch.object(gate, 'observe', return_value=(schedule, 'a'*64)), \
                patch.object(gate, 'persist'), patch.object(gate, 'dispatch') as dispatch, \
                patch.object(gate, 'private') as private, patch.object(basic, 'run') as worker:
            gate.run(dry=False, now=self.now)
        worker.assert_called_once()
        self.assertEqual(worker.call_args.args[1], 'monitor')
        dispatch.assert_not_called()
        private.assert_not_called()

    def test_warning_delivery_is_once_and_dry_run_never_acknowledges(self):
        from base64 import b64encode
        warning = basic.record_warnings({}, 'ADL', 12, {'lineup-rules': 'Add an eligible PN.'}, self.now)
        ledger = copy.deepcopy(self.ledger)
        ledger['checks'] = [dict(league='ADL', week=12, mode='monitor', checkedAt=self.now.isoformat())]
        def api(repo, path):
            value = (warning if basic.WARNINGS in path else
                     dict(schedules={'ADL': dict(week=12, kickoffs=[(self.now+timedelta(hours=1)).isoformat()])})
                     if health.STATE in path else ledger)
            return {'content': b64encode(json.dumps(value).encode()).decode()}
        state, send, save = {'sent': {}}, Mock(), Mock()
        deliver = Mock(side_effect=lambda s, k, callback, persist: callback())
        basic.report(api, self.now, state, True, deliver, save, send)
        self.assertEqual(state['sent'], {})
        basic.report(api, self.now, state, False, deliver, save, send)
        basic.report(api, self.now, state, False, deliver, save, send)
        send.assert_called_once()
        self.assertIn('O=02', send.call_args.args[1])
        self.assertIn('F=0005', send.call_args.args[1])
        state['sent'] = {}
        send.reset_mock()
        basic.report(api, self.now-timedelta(hours=4), state, False, deliver, save, send)
        send.assert_not_called()

    def test_manual_verification_cannot_fall_back_to_a_private_job(self):
        import guardian_fallback as gate
        def document(path, optional=False):
            return (self.ledger if path in (gate.LEDGER, basic.HEALTH) else {}), {'sha': 'test'}
        with patch.dict(os.environ, GUARDIAN_BASIC_OWNER='public-basic-v1'), \
                patch.object(gate, 'document', side_effect=document), patch.object(gate, 'observe', return_value=None), \
                patch.object(gate, 'decision') as decide, patch.object(gate, 'dispatch') as dispatch, \
                patch.object(basic, 'run') as worker:
            gate.run(dry=False, now=self.now, verify_basic=True)
        worker.assert_called_once()
        decide.assert_not_called()
        dispatch.assert_not_called()
        with patch.dict(os.environ, GUARDIAN_BASIC_OWNER=''):
            with self.assertRaises(ValueError):
                gate.run(dry=False, now=self.now, verify_basic=True)

    def test_exact_legacy_delivery_migrates_without_resending_and_dispatch_is_not_delivery(self):
        from base64 import b64encode
        warning = basic.record_warnings({}, 'ADL', 12, {'starter:1': 'remove'}, self.now)
        proof = dict(source='verified-local-smtp-migration', file='data/notifications/123-1-monitor.json',
                     id='123-1-monitor:0', status='sent', sentAt=(self.now-timedelta(hours=1)).isoformat(),
                     receiptHash='a'*64, inputsFingerprint='b'*64)
        warning['incidents']['ADL:12:starter:1']['legacyDelivery'] = proof
        def api(repo, path):
            value = warning if basic.WARNINGS in path else {}
            return {'content': b64encode(json.dumps(value).encode()).decode()}
        state, send, save, deliver = {'sent': {}}, Mock(), Mock(), Mock()
        basic.report(api, self.now, state, False, deliver, save, send)
        self.assertTrue(next(iter(state['sent'].values()))['migrated'])
        self.assertEqual(next(iter(state['sent'].values()))['sent_at'], proof['sentAt'])
        send.assert_not_called()
        deliver.assert_not_called()
        state['sent'] = {}
        proof['status'] = 'dispatched'
        with self.assertRaises(ValueError):
            basic.report(api, self.now, state, False, deliver, save, send)
        self.assertEqual(state['sent'], {})

    def test_basic_failure_shares_gap_but_independent_test_failure_still_reports(self):
        kickoff = self.now+timedelta(minutes=15)
        coverage = dict(basicActivatedAt=(self.now-timedelta(days=1)).isoformat(),
                        activatedAt=(self.now-timedelta(hours=1)).isoformat(),
                        incidents={'x': dict(mode='monitor', kickoff=kickoff.isoformat())})
        run = dict(path='.github/workflows/guardian_fallback.yml', conclusion='failure', created_at=self.now.isoformat())
        jobs = [{'steps': [{'name': 'Request only required private Guardian work', 'conclusion': 'failure'}]}]
        self.assertTrue(owned_basic_failure(run, jobs, coverage))
        coverage['incidents']['x']['resolvedAt'] = (self.now-timedelta(minutes=1)).isoformat()
        self.assertFalse(owned_basic_failure(run, jobs, coverage))
        del coverage['incidents']['x']['resolvedAt']
        jobs[0]['steps'][0]['name'] = 'Test backup dispatch and off-hours suppression'
        self.assertFalse(owned_basic_failure(run, jobs, coverage))


if __name__ == '__main__':
    unittest.main()
