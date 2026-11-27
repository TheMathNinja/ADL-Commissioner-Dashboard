import copy
from base64 import b64encode
from io import BytesIO
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
from guardian_phone import send_for_pending
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
            'players': {'players': {'player': {'id': '1', 'name': 'Test Starter', 'position': 'QB', 'team': 'LVR'}}},
            'league': {'league': {'starters': {'count': '1', 'iop_starters': '1', 'idp_starters': '0',
                                             'position': {'name': 'QB', 'limit': '1'}}}},
            'injuries': {'injuries': {'week': '12', 'injury': []}},
            'nflByeWeeks': {'nflByeWeeks': {'team': []}},
            'nflSchedule': {'nflSchedule': {'week': '12', 'matchup': {'kickoff': str(int((self.now+timedelta(hours=1)).timestamp())),
                                                                  'team': {'id': 'LV'}}}},
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

    def test_qb_with_healthy_unlocked_backup_is_silent_in_both_leagues(self):
        self.fixtures['injuries']['injuries']['injury'] = {'id': '1', 'status': 'Q'}
        players = self.fixtures['players']['players']
        players['player'] = [players['player'], dict(id='2', name='Bench QB', position='QB', team='BUF')]
        roster = self.fixtures['rosters']['rosters']['franchise']['player']
        roster.append(dict(id='2', status='ROSTER'))
        schedule = self.fixtures['nflSchedule']['nflSchedule']
        bench_game = dict(team={'id': 'BUF'}, kickoff=str(int((self.now + timedelta(hours=2)).timestamp())))
        schedule['matchup'] = [schedule['matchup'], bench_game]
        for league in self.ledger['leagues']:
            self.assertEqual(basic.inspect(league, self.now, self.read)[1], {})
        for restriction in ('LOCKED', 'DOUBTFUL', 'TAXI'):
            with self.subTest(restriction=restriction):
                bench_game['kickoff'] = str(int((self.now + timedelta(hours=-1 if restriction=='LOCKED' else 2)).timestamp()))
                self.fixtures['injuries']['injuries']['injury'] = [{'id':'1','status':'Q'}] + (
                    [{'id':'2','status':'D'}] if restriction=='DOUBTFUL' else [])
                roster[1]['status'] = 'TAXI_SQUAD' if restriction=='TAXI' else 'ROSTER'
                finding = basic.inspect(self.league, self.now, self.read)[1]['starter:1']
                self.assertTrue(finding.shortage_risk)
                self.assertEqual(finding.severity, 'advisory')
        roster[1]['status'] = 'ROSTER'
        self.fixtures['injuries']['injuries']['injury'] = {'id':'1','status':'O'}
        self.assertEqual(basic.inspect(self.league, self.now, self.read)[1]['starter:1'].severity, 'confirmed')

    def test_flex_can_cover_questionable_starter_without_same_position_backup(self):
        self.fixtures['league']['league']['starters'].update(count='2', iop_starters='2',
            position=[{'name':'QB','limit':'1'}, {'name':'RB','limit':'0-1'}, {'name':'WR','limit':'0-1'}])
        self.fixtures['weeklyResults']['weeklyResults']['matchup']['franchise']['starters'] = '1,2,'
        players = self.fixtures['players']['players']
        players['player'] = [players['player'], dict(id='2', name='Test RB', position='RB', team='LV'),
                             dict(id='3', name='Bench WR', position='WR', team='LV')]
        roster = self.fixtures['rosters']['rosters']['franchise']['player']
        roster.extend(dict(id=i, status='ROSTER') for i in ('2', '3'))
        self.fixtures['injuries']['injuries']['injury'] = {'id':'2','status':'Q'}
        self.assertEqual(basic.inspect(self.league, self.now, self.read)[1], {})
        self.fixtures['league']['league']['starters']['position'][1]['limit'] = '1'
        self.assertTrue(basic.inspect(self.league, self.now, self.read)[1]['starter:2'].shortage_risk)

    def test_missing_punter_is_an_explicit_position_warning(self):
        rules = self.fixtures['league']['league']['starters']
        rules['count'] = '2'
        rules['position'] = [rules['position'], {'name': 'PN', 'limit': '1'}]
        _, issues = basic.inspect(self.league, self.now, self.read)
        self.assertIn('PN: requires 1-1; currently 0', issues['lineup-rules'].detail)
        self.assertEqual(len(issues), 1)

    def test_both_leagues_push_confirmed_findings_only_in_the_action_window(self):
        for case in ('OUT', 'INACTIVE', 'IR', 'SUSP', 'SUSPENDED', 'BYE', 'TAXI', 'EMPTY', 'Q', 'D'):
            with self.subTest(case=case):
                self.setUp()
                morning = self.now.replace(hour=11, minute=5)
                kickoff = self.now + timedelta(hours=1)
                ledger = dict(self.ledger, generatedAt=morning.isoformat())
                games = self.fixtures['nflSchedule']['nflSchedule']
                injuries = self.fixtures['injuries']['injuries']
                if case == 'BYE':
                    self.fixtures['nflByeWeeks']['nflByeWeeks']['team'] = {'id': 'LV'}
                    games['matchup']['team'] = {'id': 'BUF'}
                elif case == 'EMPTY':
                    self.fixtures['weeklyResults']['weeklyResults']['matchup']['franchise']['starters'] = ''
                elif case == 'TAXI':
                    self.fixtures['rosters']['rosters']['franchise']['player'][0]['status'] = 'TAXI_SQUAD'
                else:
                    injuries['injury'] = {'id': '1', 'status': case}
                coverage = {'schedules': {league: {'week': 12, 'kickoffs': [kickoff.isoformat()]}
                                          for league in ('ADL', 'FAFL')}}
                state, warning, send = {'sent': {}}, {}, Mock()
                transport = Mock(side_effect=lambda *a, **kw: BytesIO(b'{"status":"accepted"}'))
                phone = lambda pending, now: send_for_pending(pending, now, 'fake', transport)
                deliver = lambda state, key, callback, save: callback()

                def api(repo, path):
                    doc = warning if basic.WARNINGS in path else coverage if health.STATE in path else ledger
                    return {'content': b64encode(json.dumps(doc).encode()).decode()}

                for now in (morning, kickoff - timedelta(minutes=91)):
                    ledger, warning = basic.check(ledger, warning, 'monitor', now, self.read)
                    basic.report(api, now, state, False, deliver, Mock(), send, phone=phone)
                    transport.assert_not_called()
                self.assertEqual(send.call_count, 1)  # Morning email does not use the phone receipt.

                now = kickoff - timedelta(minutes=90)
                expected = {'ADL', 'FAFL'} if case not in ('Q', 'D') else set()
                for run_time in (now + timedelta(minutes=15), kickoff):
                    basic.report(api, run_time, state, False, deliver, Mock(), send, phone=phone)
                    transport.assert_not_called()  # Stale receipt and elapsed deadline.
                for schedule in coverage['schedules'].values():
                    schedule['kickoffs'] = [(kickoff + timedelta(minutes=5)).isoformat()]
                basic.report(api, now, state, False, deliver, Mock(), send, phone=phone)
                transport.assert_not_called()  # An unverified deadline cannot authorize a push.
                for schedule in coverage['schedules'].values():
                    schedule['kickoffs'] = [kickoff.isoformat()]
                basic.report(api, now, state, False, deliver, Mock(), send, phone=phone)
                self.assertEqual(transport.call_count, len(expected))
                payloads = [json.loads(call.args[0].data) for call in transport.call_args_list]
                self.assertEqual({p['league'] for p in payloads}, expected)
                self.assertEqual(set(state.get('guardian_basic_phone_claims', {})), {p['id'] for p in payloads})
                self.assertTrue(all(p['observedAt'] == (kickoff - timedelta(minutes=91)).isoformat()
                                    and p['expiresAt'] == kickoff.isoformat() for p in payloads))
                basic.report(api, now, state, False, deliver, Mock(), send, phone=phone)
                self.assertEqual(transport.call_count, len(expected))
                self.assertEqual(send.call_count, 1)

    def test_lineup_overage_already_locked_is_not_phone_actionable(self):
        rules = self.fixtures['league']['league']['starters']
        rules.update(count='0', iop_starters='0', position={'name': 'QB', 'limit': '0'})
        schedule = self.fixtures['nflSchedule']['nflSchedule']
        schedule['matchup'] = [schedule['matchup'], {'team': {'id': 'BUF'},
            'kickoff': str(int((self.now + timedelta(hours=2)).timestamp()))}]
        _, issues = basic.inspect(self.league, self.now + timedelta(hours=1), self.read)
        self.assertIsNone(issues['lineup-rules'].push_until)

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
        self.assertIn('from Taxi to Active', issues['starter:1'].detail)

    def test_incomplete_reads_never_count_or_resolve_existing_warning(self):
        before = basic.record_warnings({}, 'ADL', 12, {'starter:1': basic.Finding('remove')}, self.now)
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
        issues = {'starter:1': basic.Finding('remove')}
        first = basic.record_warnings({}, 'ADL', 12, issues, self.now)
        later = self.now + timedelta(minutes=10)
        repeated = basic.record_warnings(first, 'ADL', 12, issues, later)
        self.assertEqual(first, repeated)
        recovered = basic.record_warnings(first, 'ADL', 12, {}, later)
        self.assertEqual(recovered['incidents']['ADL:12:starter:1']['status'], 'resolved')
        reopened = basic.record_warnings(recovered, 'ADL', 12, issues, later)
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

    def test_pre_kickoff_lease_allows_retry_only_after_public_pass_completes(self):
        import guardian_fallback as gate
        claim_at = health.stamp('2026-11-27T01:06:24Z')
        now = health.stamp('2026-11-27T01:09:57Z')
        kickoff = '2026-11-27T01:20:00Z'
        schedule = dict(week=12, kickoffs=[kickoff])
        for completed, owner, both_covered, expect_retry in (
            (True, gate.PUBLIC_BASIC, False, True),
            (False, gate.PUBLIC_BASIC, False, False),
            (True, None, False, False),
            (True, gate.PUBLIC_BASIC, True, False),
        ):
            with self.subTest(completed=completed, owner=owner, both_covered=both_covered):
                previous = claim_at - timedelta(minutes=29)
                ledger = dict(self.ledger, generatedAt=(claim_at if completed else previous).isoformat(),
                              checks=[dict(league='FAFL', week=12, mode='monitor', checkedAt=previous.isoformat())])
                if completed:
                    ledger['checks'].append(dict(league='ADL', week=12, mode='monitor', checkedAt=claim_at.isoformat()))
                if both_covered:
                    ledger['checks'].append(dict(league='FAFL', week=12, mode='monitor', checkedAt=claim_at.isoformat()))
                saved = {'claim': {'at': claim_at.isoformat(), 'owner': owner}}
                coverage = {'schedules': {'ADL':schedule, 'FAFL':schedule}}
                values = {gate.LEDGER:ledger, basic.HEALTH:ledger, gate.STATE:coverage, gate.PATH:saved}
                with patch.dict(os.environ, GUARDIAN_BASIC_OWNER=gate.PUBLIC_BASIC, GUARDIAN_COALESCE_BACKGROUND='true'), \
                        patch.object(gate, 'document', side_effect=lambda path, optional=False: (values[path], {'sha':'current'})), \
                        patch.object(gate, 'observe', return_value=(schedule, 'a'*64)), \
                        patch.object(gate, 'persist') as persist, patch.object(gate, 'dispatch') as dispatch, \
                        patch.object(basic, 'run') as worker:
                    gate.run(dry=False, now=now)
                self.assertEqual(worker.call_count, int(expect_retry))
                self.assertEqual(persist.call_count, int(expect_retry))
                dispatch.assert_not_called()
                if expect_retry:
                    self.assertEqual(persist.call_args.args[2]['claim']['owner'], gate.PUBLIC_BASIC)

    def test_warning_delivery_is_once_and_dry_run_never_acknowledges(self):
        from base64 import b64encode
        warning = basic.record_warnings({}, 'ADL', 12,
                                        {'lineup-rules': basic.Finding('Add an eligible PN.')}, self.now)
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

    def test_report_sends_out_once_after_delivered_shortage_advisory(self):
        from base64 import b64encode

        start = self.now
        league = self.ledger['leagues'][1]
        health_state = copy.deepcopy(self.ledger)
        coverage = dict(schedules={'FAFL': dict(week=12, kickoffs=[(start+timedelta(hours=1)).isoformat()])})
        state, send, save = {'sent': {}}, Mock(), Mock()
        deliver = Mock(side_effect=lambda s, k, callback, persist: callback())
        warning = {}

        def api(repo, path):
            value = warning if basic.WARNINGS in path else coverage if health.STATE in path else health_state
            return {'content': b64encode(json.dumps(value).encode()).decode()}

        def observe(status, minutes):
            nonlocal warning
            now = start + timedelta(minutes=minutes)
            self.fixtures['injuries']['injuries']['injury'] = {'id': '1', 'status': status}
            week, issues = basic.inspect(league, now, self.read)
            warning = basic.record_warnings(warning, 'FAFL', week, issues, now)
            health_state['checks'] = [dict(league='FAFL', week=12, checkedAt=now.isoformat())]
            return now

        question = observe('QUESTIONABLE', 0)
        advisory = warning['incidents']['FAFL:12:starter:1']
        del advisory['shortageRisk']
        basic.report(api, question, state, False, deliver, save, send)
        send.assert_not_called()
        advisory['shortageRisk'] = True
        basic.report(api, question, state, False, deliver, save, send)
        self.assertEqual(send.call_count, 1)
        self.assertIn('QUESTIONABLE', send.call_args.args[1])
        advisory_receipt = next(iter(state['sent']))

        observe('O', 10)
        corrected = observe('Q', 11)
        basic.report(api, corrected, state, False, deliver, save, send)
        self.assertEqual(send.call_count, 1)  # Do not consume the Out receipt with Q text.
        for status, minutes in [('OUT', 12), ('O', 14), ('Q', 15), ('OUT', 17)]:
            at = observe(status, minutes)
            basic.report(api, at, state, False, deliver, save, send)
        self.assertEqual(send.call_count, 2)
        self.assertIn('Remove Test Starter (QB; OUT)', send.call_args.args[1])
        self.assertEqual(len(state['sent']), 2)
        self.assertIn(advisory_receipt, state['sent'])
        self.assertIn('guardian-basic:FAFL:12:starter:1:' + (start+timedelta(minutes=10)).isoformat(), state['sent'])

    def test_legacy_confirmed_warning_does_not_reopen_on_upgrade(self):
        key = 'ADL:12:starter:1'
        warning = {'incidents': {key: dict(league='ADL', week=12, status='open',
                                          openedAt=self.now.isoformat(), detail='Remove Starter (QB; OUT).')}}
        later = self.now + timedelta(minutes=5)
        result = basic.record_warnings(warning, 'ADL', 12, {'starter:1': basic.Finding('Remove Starter.')}, later)
        self.assertEqual(result['incidents'][key]['openedAt'], self.now.isoformat())

    def test_digest_groups_both_leagues_and_preserves_exact_delivery_after_a_crash(self):
        from base64 import b64encode
        from email_delivery_state import deliver_once

        warning = basic.record_warnings({}, 'ADL', 12,
                                        {'starter:1': basic.Finding('Check Player A.'),
                                         'starter:2': basic.Finding('Check Player B.')}, self.now)
        warning = basic.record_warnings(warning, 'FAFL', 12,
                                        {'starter:1': basic.Finding('Check Player C.')}, self.now)
        ledger = copy.deepcopy(self.ledger)
        ledger['checks'] = [dict(league=lg, week=12, checkedAt=self.now.isoformat()) for lg in ('ADL', 'FAFL')]
        schedule = dict(week=12, kickoffs=[(self.now + timedelta(hours=1)).isoformat()])
        coverage = dict(schedules={lg: schedule for lg in ('ADL', 'FAFL')})
        def api(repo, path):
            value = warning if basic.WARNINGS in path else coverage if health.STATE in path else ledger
            return {'content': b64encode(json.dumps(value).encode()).decode()}

        send, state, durable = Mock(), {'sent': {}}, {}
        def crash_on_ack(value):
            if value['sent']:
                raise OSError('interrupted before final per-warning save')
            durable.update(copy.deepcopy(value))

        with self.assertRaises(OSError):
            basic.report(api, self.now, state, False, deliver_once, crash_on_ack, send)
        send.assert_called_once()
        body = send.call_args.args[1]
        for detail in ('ADL | Week 12', 'FAFL | Week 12', 'Check Player A.', 'Check Player B.',
                       'Check Player C.', 'L=12345', 'L=67890'):
            self.assertIn(detail, body)
        self.assertEqual(body.count('Submit New Lineup:'), 2)
        self.assertEqual(durable['sent'], {})

        # A legacy individual receipt or an accepted digest must never be resent.
        state = copy.deepcopy(durable)
        opened = self.now.isoformat()
        state['delivery_receipts']['guardian-basic:ADL:12:starter:3:' + opened] = dict(
            status='accepted', accepted_at=opened)
        warning = basic.record_warnings(warning, 'ADL', 12, {
            'starter:1': basic.Finding('Check Player A.'), 'starter:2': basic.Finding('Check Player B.'),
            'starter:3': basic.Finding('Previously delivered.'), 'starter:4': basic.Finding('New injury.')}, self.now)
        basic.report(api, self.now, state, False, deliver_once, Mock(), send)
        self.assertEqual(send.call_count, 2)
        self.assertIn('New injury.', send.call_args.args[1])
        self.assertNotIn('Previously delivered.', send.call_args.args[1])
        self.assertNotIn('Check Player A.', send.call_args.args[1])
        self.assertEqual(len(state['sent']), 5)

        # Uncertain SMTP delivery also protects all included warnings from resends.
        state = copy.deepcopy(durable)
        next(iter(state['delivery_receipts'].values()))['status'] = 'uncertain'
        send.reset_mock()
        with self.assertRaisesRegex(RuntimeError, 'manual review'):
            basic.report(api, self.now, state, False, deliver_once, Mock(), send)
        send.assert_called_once()
        self.assertNotIn('Check Player A.', send.call_args.args[1])

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
        warning = basic.record_warnings({}, 'ADL', 12, {'starter:1': basic.Finding('remove')}, self.now)
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
