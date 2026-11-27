import copy
import base64
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import email_workflow_failures as m


class FailureReports(unittest.TestCase):
    def test_mfl_pregame_archive_shares_capture_and_never_backfills(self):
        from datetime import timedelta
        from mfl_pregame_archive import capture, due_slots
        now = m.gameday_time('2026-11-26T17:33:00Z')
        kickoffs = ['2026-11-26T18:00:00Z', '2026-11-26T18:00:00Z', '2026-11-26T18:05:00Z']
        self.assertEqual(len(due_slots(kickoffs, now)), 1)
        self.assertEqual(len(due_slots(kickoffs, now + timedelta(minutes=3))), 2)
        coverage = dict(schedules={'ADL': {'week': 12, 'kickoffs': kickoffs}})
        stored, reads = {}, []
        def request(url, payload=None, method=None):
            if 'myfantasyleague.com' in url:
                reads.append(url)
                return {'injuries': {'week': '12', 'injury': [
                    {'id': '123', 'status': 'Out', 'details': 'not stored'}]}}
            if method == 'PUT':
                stored[url + '?ref=main'] = json.loads(base64.b64decode(payload['content']))
                return
            return stored.get(url)
        on_time = now + timedelta(minutes=3)
        self.assertEqual(capture(coverage, on_time, request, clock=lambda: on_time), 2)
        self.assertEqual(capture(coverage, on_time, request, clock=lambda: on_time), 0)
        self.assertEqual(len(reads), 1)
        self.assertTrue(all(row['observedAt'] == on_time.isoformat() and
                            row['injuries'] == [{'player_id': '123', 'player_status': 'Out'}]
                            for row in stored.values()))
        stored.clear()
        self.assertEqual(capture(coverage, on_time, request, clock=lambda: now + timedelta(minutes=22)), 0)
        self.assertEqual(stored, {})
        self.assertEqual(capture(dict(coverage, scheduleFailures={'ADL': 'missing'}), now, request), 0)
        self.assertEqual(len(reads), 2)

    def test_public_account_scans_do_not_spend_private_api_quota(self):
        with patch.dict(os.environ, {'ACCOUNT_FAILURE_COVERAGE': 'true', 'PRIVATE_REPORT_TOKEN': 'fixture'}), \
             patch.dict(m.API_BACKOFF_UNTIL, {}, clear=True), \
             patch.object(m.mail, 'get_json', return_value={'workflow_runs': []}) as public, \
             patch.object(m.urllib.request, 'urlopen') as private:
            self.assertEqual(m.api(m.DAILY_REPO, 'actions/runs'), {'workflow_runs': []})
        public.assert_called_once()
        private.assert_not_called()

    def test_rate_limit_stops_one_credential_without_blocking_the_other(self):
        quota = HTTPError('https://api.github.com/', 403, 'Forbidden',
                          {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '1700'}, None)
        with patch.dict(os.environ, {'PRIVATE_REPORT_TOKEN': 'fixture'}), \
             patch.dict(m.API_BACKOFF_UNTIL, {}, clear=True), \
             patch.object(m.mail.time, 'time', return_value=1600), \
             patch.object(m.mail, 'get_json', return_value={'workflow_runs': []}) as public, \
             patch.object(m.urllib.request, 'urlopen', side_effect=quota) as private:
            with self.assertRaisesRegex(RuntimeError, 'rate-limit reset'):
                m.api(m.GUARDIAN, 'actions/runs')
            with self.assertRaisesRegex(RuntimeError, 'rate-limit reset'):
                m.api(m.GUARDIAN, 'contents/data/guardian_coverage.json')
            self.assertEqual(m.api(m.DAILY_REPO, 'actions/runs'), {'workflow_runs': []})
        private.assert_called_once()
        public.assert_called_once()

    def test_nov15_startup_runs_and_missed_checks_have_one_reporter_owner(self):
        from datetime import datetime, timezone
        from email_delivery_state import deliver_once
        coverage={'alertOwner':'commissioner-v1','checkedAt':datetime.now(timezone.utc).isoformat(),
                  'activatedAt':'2026-11-15T20:00:00Z','incidents':{}}
        for league in ('ADL','FAFL'):
            coverage['incidents'][league]=dict(key=league,league=league,week=10,mode='monitor',
                kickoff='2026-11-15T21:25:00Z',lastVerified='2026-11-15T20:30:32Z',status='open',delivery='pending')
        runs=[dict(self.run,id=id,path='.github/workflows/guardian.yml',name='Chicago Bears Lineup Guardian',
              display_title='Chicago Bears Lineup Guardian',created_at=f'2026-11-15T20:{minute}:44Z',
              updated_at=f'2026-11-15T20:{minute+1}:36Z')
              for id,minute in [(43758870359,34),(43759326271,39),(43759782849,44),(43760237046,49)]]
        job=[dict(name='guardian',conclusion='failure',steps=[
            dict(name='Run npm test',conclusion='failure'),dict(name='Run npm run check',conclusion='skipped'),
            dict(name='Archive exact roster checks',conclusion='success')])]
        state={'sent':{},'checked':{}}
        with patch.dict(os.environ,{'WEEKLY_REPORT_EMAIL_TO':m.OWNER,'GITHUB_REPOSITORY':m.COMMISSIONER,
                    'GUARDIAN_ALERT_OWNER':'commissioner-v1','PRIVATE_FAILURE_REPORTING_SINCE':'2026-11-15T00:00:00Z'}), \
             patch.object(sys,'argv',['report']),patch.object(m,'REPOS',[]), \
             patch.object(m,'runs',return_value=runs),patch.object(m,'jobs',return_value=job), \
             patch.object(m,'api',return_value={'content':base64.b64encode(json.dumps(coverage).encode()).decode()}), \
             patch.object(m.mail,'document',return_value=state),patch.object(m,'save'), \
             patch.object(m.mail,'deliver_once',side_effect=deliver_once),patch.object(m.mail,'send_email') as send:
            m.main();m.main()
            self.assertEqual(send.call_count,1)
            self.assertIn('ADL Week 10',send.call_args.args[1])
            self.assertIn('FAFL Week 10',send.call_args.args[1])

    def test_guardian_roster_warning_requires_delivered_exact_run_evidence(self):
        run = dict(id=43528287932, run_attempt=1, path='.github/workflows/guardian.yml', conclusion='failure')
        jobs = [dict(name='guardian', conclusion='failure', steps=[dict(name='Run npm run check', conclusion='failure')])]
        audit_id = '43528287932-1-monitor'
        message = 'No fully legal lineup can be formed from eligible, unlocked players'
        audit = dict(id=audit_id, dryRun=False, runMode='monitor', completedAt='2026-11-13T23:36:00Z',
                     results=[dict(key='ADL', status='idle'), dict(key='FAFL', status='error', message=message)],
                     snapshots=[dict(league='FAFL', players=[dict(id=str(i),position='LB',rosterStatus='ROSTER',
                                      unavailable=False,gameLocked=False) for i in range(10)])])
        notices = [dict(id=audit_id+':0', status='sent', sentAt='2026-11-13T23:36:07Z',
                        subject='[FAFL Bears] Lineup guardian needs attention', body=message)]
        def check(a=audit, n=notices, j=jobs, r=run):
            def api(repo, path):
                value = a if '/audits/' in path else n
                return {'content': base64.b64encode(json.dumps(value).encode()).decode()}
            with patch.object(m, 'api', side_effect=api):
                return m.delivered_guardian_roster_warning(m.GUARDIAN, r, j)
        self.assertTrue(check())
        typed = copy.deepcopy(audit)
        typed['results'][1].update(status='warning', reason='roster_needs_attention')
        self.assertTrue(check(a=typed))
        for change in ({'error':'other failure'}, {'dryRun':True}, {'snapshots':[]},
                       {'rosterManagement':{'status':'error'}}, {'id':'wrong-attempt'}):
            self.assertFalse(check(a={**audit, **change}))
        for change in ({'status':'pending'}, {'status':'failed'}, {'id':'wrong-run:0'}, {'body':'some other warning'}):
            self.assertFalse(check(n=[{**notices[0], **change}]))
        bad = copy.deepcopy(audit)
        bad['results'][0]['status'] = 'error'
        self.assertFalse(check(a=bad))
        enough = copy.deepcopy(audit)
        enough['snapshots'][0]['players'] *= 2
        self.assertFalse(check(a=enough))
        extra = copy.deepcopy(jobs)
        extra[0]['steps'].append(dict(name='Send private Guardian notifications',conclusion='failure'))
        self.assertFalse(check(j=extra))
        self.assertFalse(check(r={**run, 'path':'.github/workflows/preflight.yml'}))
        with patch.object(m, 'api', side_effect=RuntimeError('API unavailable')):
            self.assertFalse(m.delivered_guardian_roster_warning(m.GUARDIAN,run,jobs))

    def setUp(self):
        self.enterContext(patch.object(m, 'read_gameday_health', return_value={'incidents': []}))
        self.enterContext(patch.object(m, 'check_gameday_direct'))
        self.run = dict(id=1, run_attempt=1, workflow_id=10, path='.github/workflows/refresh.yml',
                        head_branch='main', event='workflow_dispatch', status='completed', conclusion='failure',
                        name='Official FAFL Weekly League Update',
                        display_title='Official FAFL weekly update · Week 3',
                        html_url='https://github.com/test/runs/1',
                        created_at='2026-10-01T14:00:00Z', updated_at='2026-10-01T14:10:00Z')
        self.jobs = [dict(name='refresh', conclusion='failure', steps=[
            dict(name='Enter and verify official Bonus Games in MFL', conclusion='failure')])]

    def test_production_is_limited_to_recurring_or_orchestrated_runs(self):
        self.assertTrue(m.production(self.run))

    def test_missed_check_watchdog_failure_is_monitored_for_both_automatic_triggers(self):
        run=dict(self.run,path='.github/workflows/guardian-coverage.yml',_private_report=True)
        for event in ('schedule','workflow_run','workflow_dispatch'):
            self.assertTrue(m.production(dict(run,event=event)))
            self.assertFalse(m.production(dict(run,event=event,head_branch='preview')))
        self.assertFalse(m.production(dict(run,event='pull_request')))

    def test_general_recovery_matches_failed_and_dependent_work(self):
        later = dict(self.run, id=2, conclusion='success',
                     created_at='2026-10-01T15:00:00Z', updated_at='2026-10-01T15:10:00Z')
        passed = copy.deepcopy(self.jobs)
        passed[0]['conclusion'] = 'success'
        passed[0]['steps'][0]['conclusion'] = 'success'
        with patch.object(m, 'jobs', return_value=passed):
            check = lambda old, candidate: m.verified_recovery(m.REPOS[1], self.run, old, [candidate])
            self.assertEqual(check(self.jobs, later), later)
            for changes in ({'display_title': 'Manual preview'}, {'head_branch': 'test'},
                            {'workflow_id': 999}, {'status': 'in_progress'},
                            {'conclusion': 'failure'}, {'path': 'refresh_rosters.yml'},
                            {'created_at': '2026-10-02T15:00:00Z'},
                            {'created_at': '2026-10-01T13:00:00Z'}):
                self.assertIsNone(check(self.jobs, dict(later, **changes)))
            self.assertIsNone(check(self.jobs + [dict(name='publish', conclusion='skipped')], later))
            blocked = copy.deepcopy(self.jobs)
            blocked[0]['steps'].append(dict(name='publish', conclusion='skipped'))
            self.assertIsNone(check(blocked, later))
            self.assertEqual(check([], later), later)
        for evidence in ([], self.jobs, [dict(name='refresh', conclusion='skipped', steps=[])]):
            with patch.object(m, 'jobs', return_value=evidence):
                self.assertIsNone(check(self.jobs, later))
                self.assertIsNone(check([], later))
        with patch.object(m, 'jobs', side_effect=RuntimeError('unavailable')):
            self.assertIsNone(check(self.jobs, later))

    def test_adl_preliminary_recovery_requires_exact_snapshot_and_full_signoff(self):
        old = dict(self.run, id=45333868748,
                   path='.github/workflows/refresh_extension_calculator.yml',
                   display_title='Preliminary ADL weekly update \u00b7 Week 11 \u00b7 ' + 'a'*64,
                   created_at='2026-11-24T05:31:05Z', updated_at='2026-11-24T05:40:58Z')
        later = dict(old, id=45339512245, conclusion='success',
                     created_at='2026-11-24T06:22:36Z', updated_at='2026-11-24T06:39:05Z')
        def step(name, conclusion='success'):
            return dict(name=name, conclusion=conclusion)
        def job(name, conclusion='success', *steps):
            return dict(name=name, conclusion=conclusion, steps=steps)
        browser = 'Test generated Playoff Picture in Chromium'
        cap = 'Require official cap snapshot for preliminary weekly publication'
        rollover = 'Roll Live Bonus Game Watch to the upcoming week'
        completion = 'Request weekly completion email'
        personal = 'Personal CHI Team Tools (after league publication)'
        old_jobs = [
            job('refresh', 'failure', step(browser, 'failure'), step(cap, 'failure'),
                step('Require official MFL Bonus Games verification', 'skipped'),
                step('Preserve previous EXT publication after an EXT-only failure', 'skipped')),
            job(rollover, 'skipped'), job(completion, 'skipped'), job(personal, 'skipped'),
        ]
        required = [browser, cap, 'Validate the shared MFL snapshot', 'Publish updated reports on GitHub Pages',
                    'Verify published Playoff Picture in Chromium', 'Require a verified Payouts publication for every refresh',
                    'Confirm weekly publication and record processed scores']
        new_jobs = [job('refresh', 'success', *map(step, required)), job(rollover, 'skipped'),
                    job(completion, 'success', step('Dispatch shared completion verifier')),
                    job(personal, 'success', step('Queue the final personal forecast refresh'))]
        repo = m.DAILY_REPO
        with patch.object(m, 'jobs', return_value=new_jobs):
            self.assertEqual(m.verified_recovery(repo, old, old_jobs, [later]), later)
            self.assertIsNone(m.verified_recovery(repo, old, old_jobs, [
                dict(later, display_title=later['display_title'][:-1] + 'b')]))
            self.assertIsNone(m.verified_recovery(repo, old, old_jobs + [job(rollover, 'failure')], [later]))
            self.assertIsNone(m.verified_recovery(repo, old, old_jobs + [job('unknown required job', 'skipped')], [later]))
        for name in required:
            with patch.object(m, 'jobs', return_value=[
                    job('refresh', 'success', *[step(x) for x in required if x != name]), *new_jobs[1:]]):
                self.assertIsNone(m.verified_recovery(repo, old, old_jobs, [later]), name)
        with patch.object(m, 'jobs', side_effect=lambda _, run: old_jobs if run == old else new_jobs):
            state = {}
            self.assertTrue(m.reconcile_delivered_failure(repo, old, [later], state))
            self.assertEqual(state['resolved_at'], later['updated_at'])
        ended = m.datetime.fromisoformat(old['updated_at'])
        self.assertTrue(m.notification_pending(repo, old, ended + m.timedelta(minutes=59)))
        self.assertFalse(m.notification_pending(repo, old, ended + m.timedelta(minutes=60)))
        self.assertFalse(m.notification_pending(repo, dict(old, display_title='Other job'),
                                                ended + m.timedelta(minutes=15)))

    def test_fafl_verified_completion_recovers_exact_snapshot_with_expected_skips(self):
        old = dict(self.run, id=45330175261, path='.github/workflows/refresh.yml',
                   display_title='Official FAFL weekly update \u00b7 Week 11 \u00b7 ' + 'a'*64,
                   created_at='2026-11-24T04:59:48Z', updated_at='2026-11-24T05:10:58Z')
        new = dict(old, id=45336514175, conclusion='success',
                   created_at='2026-11-24T05:54:00Z', updated_at='2026-11-24T06:07:31Z')
        generated = 'Test generated Playoff Picture in Chromium'
        old_jobs = [dict(name='refresh', conclusion='failure', steps=[dict(name=generated, conclusion='failure')]),
                    dict(name='Roll Live Bonus Game Watch to the upcoming week', conclusion='skipped')]
        passed = [generated, 'Verify published Playoff Picture in Chromium', 'Save published snapshots',
                  'Run actions/deploy-pages@v4', 'Require a verified Payouts publication for every refresh',
                  'Confirm weekly publication and record processed scores']
        evidence = [dict(name='refresh', conclusion='success', steps=[
                        dict(name=n, conclusion='success') for n in passed]),
                    dict(name='Request weekly completion email', conclusion='success',
                         steps=[dict(name='Dispatch shared completion verifier', conclusion='success')])]
        with patch.object(m, 'jobs', return_value=evidence):
            self.assertEqual(m.verified_recovery(m.FAFL_REPO, old, old_jobs, [new]), new)
            self.assertIsNone(m.verified_recovery(m.FAFL_REPO, old, old_jobs, [
                dict(new, display_title=old['display_title'][:-1] + 'b')]))
        evidence[0]['steps'][-1]['conclusion'] = 'skipped'
        with patch.object(m, 'jobs', return_value=evidence):
            self.assertIsNone(m.verified_recovery(m.FAFL_REPO, old, old_jobs, [new]))

    def test_push_preflight_requires_verified_descendant_and_both_audits(self):
        old = dict(self.run, path='.github/workflows/automation-preflight.yml', _audit_report=True,
                   event='push', head_sha='a'*40, display_title='Earlier revision')
        later = dict(old, id=2, conclusion='success', head_sha='b'*40, display_title='Subsequent revision',
                     created_at='2026-10-01T14:30:00Z', updated_at='2026-10-01T14:31:00Z')
        old_jobs = [dict(name=n, conclusion='failure') for n, _ in m.PRIVATE_PARENT_STEPS.values()]
        old_jobs.append(dict(name='preflight', conclusion='skipped'))
        completed = [dict(name=n, conclusion='success', steps=[dict(name=s, conclusion='success')])
                     for n, s in m.PRIVATE_PARENT_STEPS.values()]
        with patch.object(m, 'jobs', return_value=completed), patch.object(m, 'api') as api:
            api.return_value = dict(status='ahead', behind_by=0)
            self.assertEqual(m.verified_recovery(m.COMMISSIONER, old, old_jobs, [later]), later)
            api.return_value = dict(status='diverged', behind_by=1)
            self.assertIsNone(m.verified_recovery(m.COMMISSIONER, old, old_jobs, [later]))
        with patch.object(m, 'jobs', return_value=completed[:1]):
            self.assertIsNone(m.verified_recovery(m.COMMISSIONER, old, old_jobs, [later]))

    def test_retry_success_groups_attempts_without_sending_or_backfilling_email(self):
        from email_delivery_state import deliver_once
        state = {'recovery_notices_since': '2026-10-01T14:00:00Z'}
        later = dict(self.run, id=2, conclusion='success', updated_at='2026-10-01T15:00:00Z')
        def record(run, recovery=later):
            m.remember_recovery(state, m.FAFL_REPO, run, recovery, ['refresh: Browser installation'])
        record(dict(self.run, updated_at='2026-10-01T13:59:00Z'))
        self.assertNotIn('recovery_notices', state)
        record(self.run)
        record(dict(self.run, run_attempt=2))
        self.assertEqual(len(state['recovery_notices']), 1)
        errors = []
        with patch.object(m.mail, 'send_email') as send, patch.object(m.mail, 'deliver_once', side_effect=deliver_once), \
             patch.object(m, 'save'), patch('builtins.print') as printed:
            m.deliver_recovery_notices(state, False, errors)
            m.deliver_recovery_notices(state, False, errors)
            send.assert_not_called()
            printed.assert_called_once()
            self.assertIn('Passed on retry (no email)', printed.call_args.args[0])
            notice = next(iter(state['recovery_notices'].values()))
            self.assertEqual(set(notice['failures']), {'1:1', '1:2'})
            self.assertIn('no reviewed root-cause fix', notice['suppressed_reason'])
            self.assertNotIn('notified_at', notice)
            record(dict(self.run, id=3), dict(later, id=4))
            m.deliver_recovery_notices(state, False, errors)
            self.assertEqual(printed.call_count, 2)
            send.assert_not_called()
        self.assertFalse(errors)

    def test_root_cause_notice_requires_reviewed_exact_attempts_and_deployed_commit(self):
        from email_delivery_state import deliver_once
        repo = m.FAFL_REPO
        sha = 'a' * 40
        state = {'recovery_notices_since': '2026-10-01T14:00:00Z'}
        later = dict(self.run, id=2, head_sha=sha, run_attempt=2, conclusion='success',
                     updated_at='2026-10-01T15:00:00Z')
        m.remember_recovery(state, repo, self.run, later, ['report: Retryable read'])
        evidence = {(repo, 2, 2): (sha, sha, frozenset({'1:1'}), 'Corrected the read timeout handling.')}
        verified_state = copy.deepcopy(state)
        errors = []
        with patch.object(m.mail, 'send_email') as send, patch.object(m.mail, 'deliver_once', side_effect=deliver_once), \
             patch.object(m, 'save'):
            m.deliver_recovery_notices(verified_state, False, errors)
            send.assert_not_called()
            with patch.object(m, 'REVIEWED_ROOT_CAUSE_FIXES', evidence):
                m.deliver_recovery_notices(verified_state, False, errors)
                m.deliver_recovery_notices(verified_state, False, errors)
            send.assert_called_once()
            self.assertIn('Root cause fixed', send.call_args.args[0])
            self.assertIn(f'https://github.com/{repo}/commit/{sha}', send.call_args.args[1])
        self.assertFalse(errors)
        with patch.object(m, 'REVIEWED_ROOT_CAUSE_FIXES', evidence), patch('builtins.print') as printed:
            m.deliver_recovery_notices(state, True, [])
            body = printed.call_args.args[0]
            self.assertIn('Root cause fixed', body)
            self.assertIn('Your action: None.', body)
            self.assertIn('Corrected the read timeout handling.', body)
            self.assertIn(f'https://github.com/{repo}/commit/{sha}', body)
            m.remember_recovery(state, repo, dict(self.run, id=3), later, ['report: Other failure'])
            m.deliver_recovery_notices(state, True, [])
            self.assertIn('Passed on retry', printed.call_args.args[0])
            self.assertNotIn('Root cause fixed', printed.call_args.args[0])
        for wrong in ({'verified_head_sha': 'b' * 40}, {'verified_attempt': 1}, {'verified_run_id': 7}):
            with self.subTest(wrong=wrong), patch.object(m, 'REVIEWED_ROOT_CAUSE_FIXES', evidence):
                notice = next(iter(state['recovery_notices'].values()))
                self.assertIsNone(m.reviewed_root_cause_fix(dict(notice, failures={'1:1': []}, **wrong)))

    def test_reviewed_fafl_save_fix_uses_checkout_commit_and_does_not_repeat_notice(self):
        notice = dict(repository=m.FAFL_REPO, verified_run_id=45553536609, verified_attempt=1,
                      verified_head_sha='ceb56c43aa365f48cae56054fed8aa3eafe708c5',
                      failures={'45552785478:1': ['rebuild: Save generated module'],
                                '45553213870:1': ['Workflow ended with cancelled']},
                      investigation='fafl-generated-save', investigation_notified=True)
        errors = []
        with patch.object(m.mail, 'deliver_once') as deliver:
            m.deliver_recovery_notices({'recovery_notices': {'verified': notice}}, False, errors)
            deliver.assert_not_called()
        self.assertFalse(errors)
        self.assertTrue(notice['verified_fix_url'].endswith('5a016b6efdd86410090908f3936187098bdda935'))
        self.assertIn('already emailed', notice['suppressed_reason'])

    def test_unverified_later_success_keeps_review_action(self):
        later = dict(self.run, html_url='https://github.com/test/runs/2')
        subject, body = m.message(m.FAFL_REPO, self.run, 'Example impact', ['Test'], later)
        self.assertIn('FAILED', subject)
        self.assertIn('Your action: Review the failed steps.', body)
        self.assertNotIn('Passed on retry', body)

    def test_log_diagnosis_recognizes_historical_classes_and_keeps_unknowns_manual(self):
        from failure_repair_policy import diagnose
        cases = {
            'generated-output-conflict': 'RuntimeError: Generated output conflicts with newer changes',
            'credential-or-permission': 'HTTP Error 403: Forbidden',
            'stale-or-incomplete-input': 'Error: Missing or stale forecasts',
            'validation-regression': 'AssertionError: Quarterly forecast mismatch',
            'transient-upstream-read': 'urllib.error.HTTPError: HTTP Error 503: Service unavailable',
            'unclassified': 'RuntimeError: unexpected new failure',
        }
        for code, error in cases.items():
            with self.subTest(code=code):
                self.assertEqual(diagnose([error])[0], code)
        self.assertEqual(diagnose([cases['transient-upstream-read'], cases['credential-or-permission']])[0],
                         'credential-or-permission')

    def test_replay_is_write_ahead_bounded_and_pinned_to_read_only_definition(self):
        from failure_repair_policy import READ_ONLY_WORKFLOWS, consider_replay
        (repo, path), blob = next(iter(READ_ONLY_WORKFLOWS.items()))
        now = m.datetime(2026, 11, 25, 11, 10, tzinfo=m.timezone.utc)
        run = dict(self.run, id=94, path=path, head_sha='a' * 40, head_branch='main',
                   status='completed', conclusion='failure', event='workflow_dispatch',
                   run_attempt=1, updated_at='2026-11-25T11:00:00Z')
        state = {'automation_repair_enabled_at': '2026-11-25T10:00:00Z'}
        trace = []
        def read(repository, endpoint):
            self.assertEqual(repository, repo)
            if not endpoint:
                return {'private': False}
            return run if endpoint == 'actions/runs/94' else {'sha': blob}
        def save(doc):
            trace.append(doc['automation_repairs'][f'{repo}:94:1']['status'])
        def request(repository, run_id):
            self.assertEqual((repository, run_id), (repo, 94))
            trace.append('POST')
            return 'uncertain'
        def evaluate(doc=state, when=now, checked=run, dry_run=False, reader=read, diagnosis='transient-upstream-read'):
            return consider_replay(doc, repo, checked, ['check: Read'], {'check': diagnosis}, when,
                                   dry_run=dry_run, read=reader, request=request, save=save)
        self.assertIsNone(evaluate(dry_run=True))
        self.assertIsNone(evaluate(checked=dict(run, path='.github/workflows/guardian.yml')))
        self.assertIsNone(evaluate(checked=dict(run, head_branch='preview')))
        self.assertIsNone(evaluate(checked=dict(run, run_attempt=2)))
        self.assertIsNone(evaluate(diagnosis='credential-or-permission'))
        self.assertIsNone(evaluate(reader=lambda r, p: {'private': True}))
        self.assertIsNone(evaluate(reader=lambda r, p: {'sha': 'changed'} if p.startswith('contents/') else read(r, p)))
        self.assertFalse(trace)
        self.assertEqual(evaluate(), 'pending')
        self.assertEqual(trace, ['sending', 'POST', 'uncertain'])
        self.assertEqual(evaluate(), 'pending')
        self.assertEqual(evaluate(when=now + m.timedelta(minutes=20)), 'retry_deadline')
        self.assertEqual(trace, ['sending', 'POST', 'uncertain'])
        self.assertEqual(evaluate(checked=dict(run, id=95)), 'replay_limit')

    def test_verified_rebuild_does_not_hide_unresolved_save_problem(self):
        from email_delivery_state import deliver_once
        state = {'recovery_notices_since': '2026-11-25T00:00:00Z'}
        repo = m.FAFL_REPO
        original = dict(self.run, id=45546157971, path='.github/workflows/rebuild_bonus_games.yml',
                        updated_at='2026-11-25T04:29:41Z')
        later = dict(original, id=45547066760, conclusion='success')
        errors = []
        with patch.object(m.mail, 'send_email') as send, patch.object(m.mail, 'deliver_once', side_effect=deliver_once), \
             patch.object(m, 'save'):
            m.remember_recovery(state, repo, original, later, ['rebuild: Save generated module'])
            m.deliver_recovery_notices(state, False, errors)
            m.remember_recovery(state, repo, dict(original, id=45546157972),
                                dict(later, id=45547066761), ['rebuild: Save generated module'])
            m.deliver_recovery_notices(state, False, errors)
            send.assert_called_once()
            self.assertIn('Save failure needs investigation', send.call_args.args[0])
            self.assertIn('Your action: Review the failed save.', send.call_args.args[1])
            self.assertNotIn('Root cause fixed', send.call_args.args[0])
        self.assertFalse(errors)

    def test_queued_fafl_rebuild_requires_real_later_job_and_descendant(self):
        old = dict(self.run, id=45349627253, _account_report=True, head_sha='a'*40,
                   event='push', path='.github/workflows/rebuild_bonus_games.yml',
                   created_at='2026-11-24T07:39:01Z', updated_at='2026-11-24T07:47:50Z')
        later = dict(old, id=45349845268, head_sha='b'*40, conclusion='success',
                     created_at='2026-11-24T07:40:44Z', updated_at='2026-11-24T07:56:28Z')
        original = [dict(name='rebuild', conclusion='failure', steps=[
            dict(name='Save generated module', conclusion='failure')])]
        required = ('Build and validate selected module from published score cache',
                    'Save generated module', 'Request Pages publication')
        job = dict(name='rebuild', conclusion='success', started_at='2026-11-24T07:47:52Z',
                   steps=[dict(name=name, conclusion='success') for name in required])
        check = lambda: m.verified_recovery(m.FAFL_REPO, old, original, [later])
        with patch.object(m, 'jobs', return_value=[job]), patch.object(m, 'api') as api:
            api.return_value = dict(status='ahead', behind_by=0)
            self.assertEqual(check(), later)
            api.assert_called_once_with(m.FAFL_REPO, f'compare/{"a"*40}...{"b"*40}')
            api.return_value = dict(status='diverged', behind_by=1)
            self.assertIsNone(check())
            api.return_value = dict(status='ahead', behind_by=0)
            job['started_at'] = '2026-11-24T07:47:49Z'
            self.assertIsNone(check())
            job['started_at'] = '2026-11-24T07:47:52Z'
            job['steps'][-1]['conclusion'] = 'skipped'
            self.assertIsNone(check())

    def test_pages_cancellation_replacements_and_legacy_queue_do_not_email(self):
        from email_delivery_state import deliver_once
        repo = m.COMMISSIONER
        state = {'recovery_notices_since': '2026-10-01T14:00:00Z'}
        old = dict(self.run, id=45358926950, path='dynamic/pages/pages-build-deployment',
                   display_title='pages build and deployment', event='dynamic', conclusion='cancelled')
        later = dict(old, id=45362568457, conclusion='success')
        key = f'recovery:{repo}:{later["id"]}:1'
        for attempt, steps in enumerate(([], [{'name': 'Set up job', 'conclusion': 'cancelled'}]), 1):
            jobs = [{'name': 'build', 'conclusion': 'cancelled', 'steps': steps}]
            run = dict(old, run_attempt=attempt)
            m.remember_recovery(state, repo, run, later, m.failures(run, jobs), jobs)
        self.assertNotIn('recovery_notices', state)
        state['recovery_notices'] = {key: {'title': 'pages build and deployment', 'repository': repo}}
        errors = []
        with patch.object(m.mail, 'send_email') as send, patch.object(m.mail, 'deliver_once', side_effect=deliver_once), \
             patch.object(m, 'save'):
            m.deliver_recovery_notices(state, False, errors)
            send.assert_not_called()
            self.assertIn('suppressed_reason', state['recovery_notices'][key])
            failed = [{'name': 'build', 'conclusion': 'cancelled',
                       'steps': [{'name': 'Build site', 'conclusion': 'failure'}]}]
            replacement = dict(later, id=45362568458)
            m.remember_recovery(state, repo, old, replacement, m.failures(old, failed), failed)
            m.deliver_recovery_notices(state, False, errors)
            send.assert_not_called()
            notice = state['recovery_notices'][f'recovery:{repo}:{replacement["id"]}:1']
            self.assertEqual(notice['failures'][f'{old["id"]}:1'], ['build: Build site'])
            self.assertIn('no reviewed root-cause fix', notice['suppressed_reason'])
        self.assertFalse(errors)

    def test_verified_retry_is_recorded_without_email(self):
        earlier = copy.deepcopy(self.run)
        later = dict(earlier, run_attempt=2, conclusion='success', updated_at='2026-10-01T15:00:00Z')
        passed = copy.deepcopy(self.jobs)
        passed[0]['conclusion'] = passed[0]['steps'][0]['conclusion'] = 'success'
        state = {'sent': {}, 'checked': {}}
        with patch.dict(os.environ, {'WEEKLY_REPORT_EMAIL_TO': m.OWNER, 'GITHUB_REPOSITORY': m.COMMISSIONER}), \
             patch.object(sys, 'argv', ['report']), patch.object(m, 'REPOS', [m.REPOS[1]]), \
             patch.object(m, 'runs', return_value=[later]), patch.object(m, 'api', return_value=earlier), \
             patch.object(m, 'jobs', side_effect=lambda repo, run: self.jobs if run.get('run_attempt') == 1 else passed), \
             patch.object(m.mail, 'document', return_value=state), \
             patch.object(m.mail, 'send_email') as send, patch.object(m, 'save'):
            m.main()
        send.assert_not_called()
        self.assertIn('verified recovery', state['checked'][m.REPOS[1] + ':1:1'])

    def test_nov17_overlapping_pages_replacement_requires_deployed_descendant(self):
        old = dict(self.run, id=44022410030, _account_report=True, conclusion='cancelled',
                   path='dynamic/pages/pages-build-deployment', name='pages build and deployment',
                   created_at='2026-11-17T05:12:09Z', updated_at='2026-11-17T05:12:23Z',
                   head_sha='b850e7b0c1482531b82807d984594b2043044b42')
        new = dict(old, id=44022429020, conclusion='success', created_at='2026-11-17T05:12:19Z',
                   updated_at='2026-11-17T05:13:02Z', head_sha='a7cff9a5081a5e95f4067531f1dc0a1752dc1067')
        failed = [dict(name='build', conclusion='cancelled', steps=[
                      dict(name='Pull Jekyll', conclusion='cancelled')]),
                  dict(name='report-build-status', conclusion='cancelled', steps=[]),
                  dict(name='deploy', conclusion='cancelled', steps=[])]
        completed = [dict(name='build', conclusion='success', steps=[dict(name='Pull Jekyll', conclusion='success')]),
                     dict(name='report-build-status', conclusion='success', steps=[dict(name='Report Build Status', conclusion='success')]),
                     dict(name='deploy', conclusion='success', steps=[dict(name='Deploy to GitHub Pages', conclusion='success')])]
        with patch.object(m, 'jobs', return_value=completed), patch.object(
                m, 'api', return_value={'status': 'ahead', 'behind_by': 0}):
            self.assertEqual(m.verified_recovery(m.REPOS[1], old, failed, [new]), new)
            for changes in ({'conclusion': 'failure'}, {'head_branch': 'preview'}, {'head_sha': None},
                            {'created_at': '2026-11-17T05:12:21Z'}, {'path': '.github/workflows/other.yml'}):
                self.assertIsNone(m.verified_recovery(m.REPOS[1], dict(old, **changes), failed, [new]))
            skipped = copy.deepcopy(completed)
            skipped[-1]['steps'][0]['conclusion'] = 'skipped'
            with patch.object(m, 'jobs', return_value=skipped):
                self.assertIsNone(m.verified_recovery(m.REPOS[1], old, failed, [new]))
        with patch.object(m, 'jobs', return_value=completed):
            for comparison in ({'status': 'diverged', 'behind_by': 1}, {'status': 'behind', 'behind_by': 1}, {}):
                with patch.object(m, 'api', return_value=comparison):
                    self.assertIsNone(m.verified_recovery(m.REPOS[1], old, failed, [new]))
            with patch.object(m, 'api', side_effect=RuntimeError('visibility unavailable')):
                self.assertIsNone(m.verified_recovery(m.REPOS[1], old, failed, [new]))

    def test_pages_server_error_waits_for_verified_deployment_then_alerts_if_unresolved(self):
        from datetime import timedelta
        from failure_repair_policy import diagnose
        old = dict(self.run, id=45650523035, event='dynamic', conclusion='failure', _account_report=True,
                   path='dynamic/pages/pages-build-deployment', head_branch='main',
                   created_at='2026-11-25T16:02:01Z', updated_at='2026-11-25T16:03:14Z',
                   head_sha='20993c0469abe25c8bb0e47ebd1d69b071f359df')
        later = dict(old, id=45653885731, conclusion='success', created_at='2026-11-25T16:26:32Z',
                     updated_at='2026-11-25T16:27:27Z', head_sha='b224264947db0e2902afdebd9f633bc3effad9e6')
        step = 'Deploy to GitHub Pages'
        failed = [dict(name='deploy', conclusion='failure', steps=[dict(name=step, conclusion='failure')])]
        passed = [dict(name='deploy', conclusion='success', steps=[dict(name=step, conclusion='success')])]
        steps = m.failures(old, failed)
        reason = diagnose(['Error: Failed to create deployment (status: 500) with build version <revision>.'])[0]
        self.assertEqual(reason, 'pages-deployment-service-error')
        end = m.gameday_time(old['updated_at'])
        self.assertTrue(m.pages_service_recovery_pending(old, steps, {'deploy': reason}, end + timedelta(minutes=29)))
        self.assertFalse(m.pages_service_recovery_pending(old, steps, {'deploy': reason}, end + timedelta(minutes=30)))
        self.assertFalse(m.pages_service_recovery_pending(old, steps, {'deploy': 'credential-or-permission'}, end))
        self.assertFalse(m.pages_service_recovery_pending(old, steps + ['build: test'], {'deploy': reason}, end))
        with patch.object(m, 'jobs', return_value=passed), patch.object(m, 'api') as api:
            api.return_value = {'status': 'ahead', 'behind_by': 0}
            self.assertEqual(m.verified_recovery(m.COMMISSIONER, old, failed, [later]), later)
            api.return_value = {'status': 'diverged', 'behind_by': 1}
            self.assertIsNone(m.verified_recovery(m.COMMISSIONER, old, failed, [later]))
        with patch.object(m, 'jobs', return_value=[dict(passed[0], steps=[])]):
            self.assertIsNone(m.verified_recovery(m.COMMISSIONER, old, failed, [later]))

    def test_nov23_cancelled_pages_wrapper_did_not_cancel_its_deployment(self):
        repo = m.REPOS[0]
        run = dict(self.run, id=45126216920, run_attempt=1, _account_report=True, conclusion='cancelled',
                   path='dynamic/pages/pages-build-deployment', name='pages build and deployment',
                   created_at='2026-11-23T06:45:04Z', updated_at='2026-11-23T06:45:48Z',
                   head_sha='c74d3f0f461469961905dca396510dbb5529b596')
        log = f'https://github.com/{repo}/actions/runs/45126216920/job/137531223838'
        jobs = [dict(name='build', conclusion='success'), dict(name='report-build-status', conclusion='success'),
                dict(name='deploy', conclusion='success', id=137531223838, run_id=run['id'], run_attempt=1,
                     started_at='2026-11-23T06:45:37Z',
                     steps=[dict(name='Deploy to GitHub Pages', conclusion='success')])]
        deployment = dict(id=7992248864, sha=run['head_sha'], created_at='2026-11-23T06:45:33Z',
                          environment='github-pages')
        status = dict(created_at=run['updated_at'], state='success', environment='github-pages', log_url=log)
        inactive = dict(status, state='inactive', created_at='2026-11-23T06:46:51Z')
        with patch.object(m, 'api', side_effect=[[deployment], [inactive, status]]) as api:
            self.assertEqual(m.verified_recovery(repo, run, jobs, []), dict(html_url=log, updated_at=run['updated_at']))
        self.assertIn('sha='+run['head_sha'], api.call_args_list[0].args[1])
        self.assertIn('/7992248864/statuses', api.call_args_list[1].args[1])
        for changes in ({'state': 'in_progress'}, {'log_url': log+'0'}, {'environment': 'preview'},
                        {'created_at': '2026-11-23T06:45:00Z'}, {'created_at': '2026-11-23T06:45:49Z'}):
            with patch.object(m, 'api', side_effect=[[deployment], [dict(status, **changes)]]):
                self.assertIsNone(m.verified_recovery(repo, run, jobs, []))
        with patch.object(m, 'api', side_effect=OSError('API unavailable')):
            self.assertIsNone(m.verified_recovery(repo, run, jobs, []))
        for job_changes in ({'run_attempt': 2}, {'conclusion': 'failure'}, {'steps': []}):
            with patch.object(m, 'api') as api:
                self.assertIsNone(m.verified_recovery(repo, run, [*jobs[:2], dict(jobs[-1], **job_changes)], []))
                api.assert_not_called()

    def test_report_silently_reconciles_existing_pages_email(self):
        repo = m.REPOS[0]
        run = dict(self.run, id=45126216920, run_attempt=1, _account_report=True, conclusion='cancelled',
                   path='dynamic/pages/pages-build-deployment', name='pages build and deployment')
        stamp = '2026-11-23T06:45:48Z'
        log = f'https://github.com/{repo}/actions/runs/45126216920/job/137531223838'
        key = f'{repo}:45126216920:1'
        state = {'sent': {key: {'sent_at': 'prior', 'subject': 'existing delivery'}}, 'checked': {}}
        with patch.dict(os.environ, {'WEEKLY_REPORT_EMAIL_TO': m.OWNER, 'GITHUB_REPOSITORY': m.COMMISSIONER}), \
             patch.object(sys, 'argv', ['report']), patch.object(m, 'REPOS', [repo]), \
             patch.object(m, 'runs', return_value=[run]), patch.object(m, 'jobs', return_value=[]), \
             patch.object(m, 'completed_pages_before_cancel', return_value={'updated_at': stamp, 'html_url': log}), \
             patch.object(m.mail, 'document', return_value=state), patch.object(m, 'save'), \
             patch.object(m.mail, 'send_email') as send:
            m.main()
        send.assert_not_called()
        self.assertEqual(state['sent'][key], {'sent_at': 'prior', 'subject': 'existing delivery',
                                              'resolved_at': stamp, 'recovery_url': log})

    def test_recovered_inactivity_startup_requires_live_same_day_check(self):
        run = dict(self.run, id=42671504712, path='fafl-inactivity-watch.yml',
                   display_title='FAFL Inactivity Watch', created_at='2026-11-09T18:09:31Z',
                   updated_at='2026-11-09T18:10:32Z')
        later = dict(run, id=42680641457, conclusion='success',
                     created_at='2026-11-09T19:09:31Z', updated_at='2026-11-09T19:10:00Z')
        steps = [dict(name=name, conclusion='success') for name in (
            'Test inactivity policy and source parsing',
            'Check FAFL inactivity and deliver scoped notifications')]
        with patch.object(m, 'jobs', return_value=[dict(conclusion='success', steps=steps)]):
            check = lambda jobs, recovery: m.recovered_inactivity_startup(m.COMMISSIONER, run, jobs, recovery)
            self.assertTrue(check([], later))
            self.assertFalse(check(self.jobs, later))
            self.assertFalse(check([], None))
            for changes in ({'conclusion': 'failure'}, {'status': 'in_progress'},
                            {'display_title': 'FAFL Inactivity Watch - read-only'},
                            {'workflow_id': 99}, {'head_branch': 'test'},
                            {'created_at': '2026-11-10T19:09:31Z'},
                            {'created_at': '2026-11-09T17:09:31Z'}):
                self.assertFalse(check([], dict(later, **changes)))
        with patch.object(m, 'jobs', return_value=[dict(conclusion='success', steps=steps[:1])]):
            self.assertFalse(m.recovered_inactivity_startup(m.COMMISSIONER, run, [], later))

    def test_daily_parent_child_incidents(self):
        parent = dict(self.run,id=42,path='daily_adl_league_maintenance.yml',display_title='Daily ADL League Maintenance')
        for path,(suffix,name,step) in m.DAILY_CHILDREN.items():
            child=dict(parent,id=43,path=path,display_title=f'Daily maintenance 42 - {suffix}')
            self.assertTrue(m.production(child))
            self.assertFalse(m.production(dict(child,display_title='preview')))
            job=dict(id=7,name=name,started_at=parent['created_at'],completed_at=parent['updated_at'])
            state={'sent':{m.COMMISSIONER+':43:1':dict(daily_parent='42',daily_job=name,failed_at=child['updated_at'])}}
            with patch.object(m.subprocess,'run') as cmd:
                cmd.return_value.stdout='Child workflow 43 completed with conclusion: failure.'
                args=(m.DAILY_REPO,parent,{name:job},name+': '+step)
                self.assertTrue(m.delivered_child(state,*args))
                self.assertFalse(m.delivered_child({'sent':{}},*args))
                self.assertFalse(m.delivered_child(state,*args[:-1],name+': Independent verification failed'))
                cmd.return_value.stdout='Unable to dispatch a child'
                self.assertFalse(m.delivered_child(state,*args))

    def test_other_production_exclusions(self):
        self.assertIsNone(m.production(dict(self.run, event='pull_request')))

    def test_historical_child_does_not_treat_preview_as_delivery(self):
        old = dict(self.run, path='daily-commissioner-alerts.yml',display_title='Daily maintenance 42 - Commissioner alerts')
        ok = dict(old,created_at='2026-10-31T09:00:00Z',conclusion='success',display_title='Daily maintenance 43 - Commissioner alerts')
        preview = dict(ok,display_title='daily-commissioner-alerts')
        self.assertIsNone(m.later_daily_cycle(m.COMMISSIONER,old,[preview]))
        self.assertEqual(ok,m.later_daily_cycle(m.COMMISSIONER,old,[ok,preview]))
        subject,body=m.message(m.COMMISSIONER,old,'impact',['alert step'],None,later_cycle=ok)
        self.assertIn('history:',subject)
        self.assertIn('does not confirm',body)
        self.assertNotIn('No later successful',body)

    def test_manual_and_unrelated_workflows(self):
        self.assertIsNone(m.production(dict(self.run, path='.github/workflows/evaluate_playoff_model.yml')))
        self.assertIsNone(m.production(dict(self.run, event='pull_request')))
        self.assertIsNone(m.production(dict(self.run, event='push')))
        self.assertIsNone(m.production(dict(self.run, event='workflow_dispatch', name='Manual ad hoc run',
                                            display_title='Manual ad hoc run')))
        self.assertIsNone(m.production(dict(self.run, event='workflow_dispatch', display_title='FAFL manual preview')))
        self.assertIsNone(m.production(dict(self.run, head_branch='test')))

        weekly_cap = dict(
            self.run,
            event='workflow_dispatch',
            path='.github/workflows/weekly_salary_cap_accounting.yml',
            name='Official Week 4 cap snapshot (weekly package 123456)',
            display_title='Official Week 4 cap snapshot (weekly package 123456)',
        )
        self.assertTrue(m.production(weekly_cap))

        weekly_refresh = dict(
            self.run,
            event='workflow_dispatch',
            path='.github/workflows/refresh_extension_calculator.yml',
            name='Preliminary 60206 2026 week 4',
            display_title='Preliminary 60206 2026 week 4',
        )
        self.assertTrue(m.production(weekly_refresh))

        watchdog = dict(
            self.run,
            event='workflow_dispatch',
            path='.github/workflows/dashboard_watchdog.yml',
            name='Dashboard Watchdog',
            display_title='Dashboard Watchdog',
        )
        self.assertTrue(m.production(watchdog))

    def test_workflow_can_persist_reported_incident_state(self):
        workflow = (Path(__file__).parents[1] / '.github' / 'workflows' /
                    'email_workflow_failures.yml').read_text(encoding='utf-8')
        permissions = workflow.split('permissions:', 1)[1].split('concurrency:', 1)[0]
        self.assertIn('contents: write', permissions)
        self.assertIn('actions: read', permissions)

    def test_guardian_phase_does_not_run_general_reports_or_publish_reporter_heartbeat(self):
        state = {'sent': {}, 'checked': {}}
        with patch.dict(os.environ, {'WEEKLY_REPORT_EMAIL_TO': m.OWNER, 'GITHUB_REPOSITORY': m.COMMISSIONER}), \
             patch.object(sys, 'argv', ['report', '--guardian-only']), \
             patch.object(m.mail, 'document', return_value=state), \
             patch.object(m, 'guardian_phase') as guardian, patch.object(m, 'runs') as runs, \
             patch.object(m, 'save') as save:
            m.main()
        guardian.assert_called_once_with(state, False, [], deliver_alerts=True)
        runs.assert_not_called()
        save.assert_not_called()
        self.assertNotIn('healthyAt', state)

    def test_pending_retry_is_bounded_and_ignores_unrelated_dispatch(self):
        repo = m.REPOS[1]
        ended = m.datetime.fromisoformat(self.run['updated_at'].replace('Z', '+00:00'))
        retry = dict(self.run, run_attempt=2, status='in_progress')
        unrelated = dict(retry, id=2, path='.github/workflows/other.yml')
        self.assertEqual(m.repair_disposition(repo, self.run, [unrelated], ended), 'no_safe_retry')
        self.assertEqual(m.repair_disposition(repo, self.run, [retry], ended+m.timedelta(minutes=29)), 'pending')
        self.assertEqual(m.repair_disposition(repo, self.run, [retry], ended+m.timedelta(minutes=30)), 'retry_deadline')
        completed = dict(retry, status='completed', conclusion='failure')
        self.assertEqual(m.repair_disposition(repo, self.run, [completed], ended+m.timedelta(minutes=20)), 'retry_unverified')

    def test_independent_timer_owns_reporter_outages_even_with_account_coverage(self):
        reporter_path = '.github/workflows/email_workflow_failures.yml'
        self_failures = [
            dict(self.run, id=45316659745 + offset, path=reporter_path + suffix,
                 event=event, name='Email league workflow failures')
            for offset, (event, suffix) in enumerate(
                [('workflow_dispatch', ''), ('schedule', '@main'), ('push', '')])
        ]
        state = {'sent': {}, 'checked': {}}
        other_repo = m.REPOS[1]

        def job_evidence(repo, run):
            self.assertEqual((repo, run['id']), (other_repo, self.run['id']))
            return self.jobs

        with patch.dict(os.environ, {'WEEKLY_REPORT_EMAIL_TO': m.OWNER,
                                     'GITHUB_REPOSITORY': m.COMMISSIONER,
                                     'ACCOUNT_FAILURE_COVERAGE': 'true'}), \
             patch('account_failure_coverage.repositories', return_value=[m.COMMISSIONER, other_repo]), \
             patch.object(sys, 'argv', ['report']), patch.object(m, 'REPOS', [m.COMMISSIONER, other_repo]), \
             patch.object(m, 'runs', side_effect=lambda repo: {
                 m.COMMISSIONER: self_failures, other_repo: [self.run], m.GUARDIAN: []}[repo]), \
             patch.object(m, 'jobs', side_effect=job_evidence), \
             patch.object(m.mail, 'document', return_value=state), \
             patch.object(m.mail, 'send_email') as send, patch.object(m, 'save'):
            m.main()
            m.main()
        send.assert_called_once()
        self.assertEqual(set(state['sent']), {f'{other_repo}:{self.run["id"]}:1'})
        self.assertEqual(state['healthSchema'], 1)
        self.assertFalse(m.independently_monitored(other_repo, self_failures[0]))

    def test_official_bonus_children_are_reported_but_previews_are_not(self):
        child=dict(self.run,path='.github/workflows/verify_bonus_mfl.yml',display_title='Synchronize MFL Bonus Games · official · source 123')
        self.assertTrue(m.production(child))
        self.assertIsNone(m.production(dict(child,display_title='Synchronize MFL Bonus Games · preview · source 123')))

    def test_cancelled_push_and_manual_runs_do_not_send(self):
        for event in ('push', 'workflow_dispatch'):
            with self.subTest(event=event):
                self.run.update(event=event, conclusion='cancelled')
                if event == 'workflow_dispatch':
                    self.run['name'] = 'Manual ad hoc run'
                    self.run['display_title'] = 'Manual ad hoc run'
                state, count, saved = self.exercise()
                self.assertEqual(count, 0)
                self.assertEqual(saved, 1)  # Completed scan heartbeat, not an incident acknowledgement.
                self.assertFalse(state['sent'])
                self.assertFalse(state['checked'])
                self.assertEqual(state['healthSchema'], 1)
                self.assertIsNotNone(m.datetime.fromisoformat(state['healthyAt']).tzinfo)

    def test_incomplete_scan_does_not_advance_healthy_heartbeat(self):
        state = {'sent': {}, 'checked': {}, 'healthSchema': 1,
                 'healthyAt': '2026-10-01T13:00:00+00:00'}
        original = copy.deepcopy(state)
        with patch.dict(os.environ, {'WEEKLY_REPORT_EMAIL_TO': m.OWNER,
                                     'GITHUB_REPOSITORY': m.COMMISSIONER}), \
             patch.object(sys, 'argv', ['report']), patch.object(m, 'REPOS', [m.REPOS[1]]), \
             patch.object(m, 'runs', side_effect=RuntimeError('GitHub unavailable')), \
             patch.object(m.mail, 'document', return_value=state), \
             patch.object(m.mail, 'send_email') as send, patch.object(m, 'save') as save:
            with self.assertRaisesRegex(RuntimeError, 'Failure coverage unavailable'):
                m.main()
        self.assertEqual(state, original)
        send.assert_not_called()
        save.assert_not_called()

    def test_unread_job_evidence_does_not_stop_independent_run_or_mark_coverage_healthy(self):
        repo = m.REPOS[1]
        unread = dict(self.run, id=45326184869)
        unread_key = f'{repo}:{unread["id"]}:1'
        independent_key = f'{repo}:{self.run["id"]}:1'
        heartbeat = '2026-10-01T13:00:00+00:00'
        state = {'sent': {}, 'checked': {}, 'healthSchema': 1, 'healthyAt': heartbeat}

        def read_api(repository, path):
            self.assertEqual(repository, repo)
            if path == f'actions/runs/{unread["id"]}/attempts/1/jobs?per_page=100&page=1':
                raise RuntimeError(f'GitHub API remained unavailable for {repository}/{path}')
            self.assertEqual(path, f'actions/runs/{self.run["id"]}/attempts/1/jobs?per_page=100&page=1')
            return {'jobs': self.jobs}

        with patch.dict(os.environ, {'WEEKLY_REPORT_EMAIL_TO': m.OWNER,
                                     'GITHUB_REPOSITORY': m.COMMISSIONER}, clear=True), \
             patch.object(sys, 'argv', ['report']), patch.object(m, 'REPOS', [repo]), \
             patch.object(m, 'runs', return_value=[self.run, unread]), \
             patch.object(m, 'api', side_effect=read_api), \
             patch.object(m.mail, 'document', return_value=state), \
             patch.object(m.mail, 'send_email') as send, patch.object(m, 'save') as save:
            with self.assertRaisesRegex(RuntimeError, f'Failure coverage unavailable.*{unread_key}'):
                m.main()

        send.assert_called_once()
        save.assert_called()
        self.assertEqual(set(state['sent']), {independent_key})
        self.assertNotIn(unread_key, state['checked'])
        self.assertEqual(state['healthyAt'], heartbeat)
        self.assertEqual(state['healthSchema'], 1)

    def test_unassigned_watchdog_cancellation_after_same_day_success_is_suppressed(self):
        cancelled = dict(
            self.run,
            path='.github/workflows/dashboard_watchdog.yml',
            workflow_id=22,
            event='schedule',
            conclusion='cancelled',
            created_at='2026-10-05T19:29:36Z',
        )
        jobs = [dict(name='check-dashboard-freshness', conclusion='cancelled', runner_id=0, steps=[])]
        history = [dict(cancelled), dict(
            cancelled,
            id=2,
            conclusion='success',
            event='workflow_dispatch',
            created_at='2026-10-05T11:01:01Z',
        )]
        self.assertTrue(m.cancelled_without_runner_after_same_day_success(cancelled, jobs, history))
        jobs[0]['runner_id'] = 123
        self.assertFalse(m.cancelled_without_runner_after_same_day_success(cancelled, jobs, history))

    def test_continued_failure_is_not_hidden_by_success(self):
        self.assertIn('Bonus Games', m.failures(dict(self.run, conclusion='success'), self.jobs)[0])
        self.assertEqual(m.failures(dict(self.run, conclusion='success'), []), [])
        self.assertTrue(m.failures(dict(self.run, conclusion='timed_out'), []))

    def test_report_impact_and_recovery(self):
        subject, body = m.message(m.REPOS[1], self.run, m.production(self.run), m.failures(self.run, self.jobs), self.run)
        self.assertIn('FAILED', subject)
        self.assertIn('Bonus Games', body)
        self.assertIn('later run', body)
        self.assertIn(m.OWNER, body)

    def test_recurring_failure_note_requires_prior_exact_step_known_cause_and_workflow(self):
        repo = m.REPOS[1]
        incident = m.incident_key(repo, self.run)
        failed = ['refresh: Bonus Games']
        good = {'incident_key': incident, 'failed_at': '2026-09-22T11:00:00Z', 'failed_steps': failed,
                'cause_codes': {'refresh': 'a' * 64}}
        def note(entry, codes=None):
            return m.recurring_failure_context({'sent': {'prior': entry}}, repo, self.run, failed,
                                               good['cause_codes'] if codes is None else codes)
        self.assertIn('2026-09-22 UTC', note(good))
        for change in ({'failed_steps': ['refresh: unrelated']}, {'cause_codes': {'refresh': 'b' * 64}},
                       {'failed_at': self.run['updated_at']}, {'incident_key': incident + ':other'},
                       {'incident_key': None}):
            self.assertEqual(note({**good, **change}), '')
        self.assertEqual(note(good, {'refresh': 'unclassified'}), '')

    def test_failed_followup_poll_acknowledges_verified_publication(self):
        poll=dict(self.run,path='.github/workflows/poll_score_corrections.yml',event='schedule',
                  name='Poll Thursday score corrections',display_title='Poll Thursday score corrections',
                  created_at='2026-10-29T21:55:57Z')
        receipt=dict(season=2026,week=7,league_id='22686',process='corrections',status='success',
                     bonus_mfl_verified=True,payouts_verified=True,run_id='40897559806',completed_at='2026-10-29T15:12:04Z')
        with patch.object(m.mail,'document',return_value=receipt),patch.object(m,'api',return_value={'jobs':[{'name':'refresh','conclusion':'success'}]}):
            publication=m.correction_publication(m.REPOS[1],poll)
            _,body=m.message(m.REPOS[1],poll,m.production(poll),['check: MFL timeout'],None,publication)
            self.assertIn('already completed successfully',body)
            self.assertIn('Only the follow-up freshness check failed',body)
            self.assertIn('40897559806',body)
            self.assertNotIn('may not have been processed',body)
        for change in [dict(week=6),dict(bonus_mfl_verified=False),dict(status='failure')]:
            with patch.object(m.mail,'document',return_value={**receipt,**change}),patch.object(m,'api')as api:
                self.assertIsNone(m.correction_publication(m.REPOS[1],poll));api.assert_not_called()
        with patch.object(m.mail,'document',return_value=receipt),patch.object(m,'api',return_value={'jobs':[{'name':'refresh','conclusion':'failure'}]}):
            self.assertIsNone(m.correction_publication(m.REPOS[1],poll))

    def test_unknown_publication_is_not_called_missing_after_poll_failure(self):
        poll=dict(self.run,path='.github/workflows/poll_score_corrections.yml',event='schedule')
        _,body=m.message(m.REPOS[1],poll,m.production(poll),['check: MFL timeout'],None)
        self.assertIn('does not establish',body)
        self.assertNotIn('already completed successfully',body)

    def exercise(self, state=None, dry=False, send_error=None):
        state = state or {'sent': {}, 'checked': {}}
        with patch.dict(os.environ, {'WEEKLY_REPORT_EMAIL_TO': m.OWNER, 'GITHUB_REPOSITORY': m.REPOS[2]}), \
             patch.object(sys, 'argv', ['report'] + (['--dry-run'] if dry else [])), \
             patch.object(m, 'REPOS', [m.REPOS[1]]), \
             patch.object(m, 'runs', return_value=[self.run]), \
             patch.object(m, 'jobs', return_value=self.jobs), \
             patch.object(m.mail, 'document', return_value=state), \
             patch.object(m.mail, 'send_email', side_effect=send_error) as send, \
             patch.object(m, 'save') as save:
            if send_error:
                with self.assertRaises(RuntimeError):
                    m.main()
            else:
                m.main()
            return state, send.call_count, save.call_count

    def test_send_once_and_dry_run_does_not_acknowledge(self):
        state, count, saved = self.exercise(dry=True)
        self.assertEqual(count, 0)
        self.assertEqual(saved, 0)
        self.assertFalse(state['sent'])
        self.assertNotIn('healthyAt', state)
        self.assertNotIn('healthSchema', state)
        state, count, _ = self.exercise()
        self.assertEqual(count, 1)
        _, count, _ = self.exercise(state)
        self.assertEqual(count, 0)

    def test_repeated_dispatch_of_same_incident_does_not_email_again(self):
        incident = m.incident_key(m.REPOS[1], self.run)
        state = {'sent': {'old:run:1': {'scope':incident+':2026-10-01','failed_steps':m.failures(self.run,self.jobs),'failed_at':self.run['updated_at']}}, 'checked': {}}
        state, count, _ = self.exercise(state)
        self.assertEqual(count, 0)
        self.assertIn('duplicate notification', next(iter(state['checked'].values())))


    def test_distinct_step_and_midnight_does_not_reopen(self):
        repo=m.REPOS[1];scope,_=m.unreported_steps({'sent':{}},repo,self.run,[],['a'])
        state={'sent':{'old':dict(scope=scope,failed_steps=['a'],failed_at=self.run['updated_at'])}}
        later=dict(self.run,updated_at='2026-10-01T16:00:00Z')
        self.assertEqual(m.unreported_steps(state,repo,later,[],['a','b'])[1],['b'])
        self.assertEqual(m.unreported_steps(state,repo,dict(later,created_at='2026-10-02T14:00:00Z'),[],['a'])[1],[])

    def test_ambiguous_smtp_is_not_recorded_as_sent_or_blindly_retried(self):
        state, _, saved = self.exercise(send_error=RuntimeError('SMTP unavailable'))
        self.assertFalse(state['sent'])
        self.assertEqual(saved, 3)  # Claim, uncertain receipt, then scan checkpoint.
        self.assertEqual(next(iter(state['delivery_receipts'].values()))['status'], 'uncertain')
        _, count, _ = self.exercise(state, send_error=RuntimeError('must not send again'))
        self.assertEqual(count, 0)

    def test_missing_dispatch_and_receipts_notify_once_per_delivery(self):
        now=m.datetime.fromisoformat('2026-11-03T16:00:00+00:00')
        state={'sent':{}}
        with patch.object(m,'api',return_value={'workflow_runs':[]}),patch.object(m.mail,'document',return_value=None),patch.object(m,'save'),patch.object(m.mail,'send_email')as send:
            m.check_deadlines(state,False,now);m.check_deadlines(state,False,now)
            self.assertEqual(send.call_count,3)

    def test_uncertain_deadline_does_not_hide_other_missing_publications(self):
        now=m.datetime.fromisoformat('2026-11-03T16:00:00+00:00')
        state={'sent':{}}
        errors=[]
        with patch.object(m,'api',return_value={'workflow_runs':[]}),patch.object(m.mail,'document',return_value=None),patch.object(m,'save'),patch.object(m.mail,'send_email',side_effect=[TimeoutError('unknown acceptance'),None,None]) as send:
            m.check_deadlines(state,False,now,delivery_errors=errors)
            self.assertEqual(send.call_count,3)
            self.assertEqual(len(state['sent']),2)
            self.assertEqual(len(errors),1)
            self.assertIn('TimeoutError',errors[0])
            m.check_deadlines(state,False,now,delivery_errors=errors)
            self.assertEqual(send.call_count,3)
            self.assertIn('DeliveryUncertain',errors[-1])

    def test_uncertain_delivery_is_not_replayed_under_a_new_run_id(self):
        repo=m.REPOS[1]
        old=repo+':1:1'
        entry={'incident_key':m.incident_key(repo,self.run),'failed_at':self.run['updated_at'],
               'failed_steps':['refresh: first'],'cause_codes':{'refresh':'same'}}
        state={'sent':{},'delivery_incidents':{old:entry},
               'delivery_receipts':{'failure:'+old:{'status':'uncertain'}}}
        later=dict(self.run,id=2,updated_at='2026-10-01T16:00:00Z')
        remaining=m.pending_delivery_steps(state,repo+':2:1',repo,later,[],
                                         ['refresh: first','other: second'],{'refresh':'same'})
        self.assertEqual(remaining,['other: second'])
        state['delivery_receipts']['failure:'+old]['status']='rejected'
        self.assertEqual(m.pending_delivery_steps(state,repo+':2:1',repo,later,[],
                         ['refresh: first'],{'refresh':'same'}),['refresh: first'])

    def test_completed_deliveries_do_not_send_deadline_mail(self):
        now=m.datetime.fromisoformat('2026-11-05T16:00:00+00:00')
        def receipt(repo,path):
            return dict(season=2026,week=8,league_id='60206' if 'ADL-' in repo else '22686',process='corrections',status='success',payouts_verified=True,bonus_mfl_verified=True)
        daily={'display_title':'Daily ADL League Maintenance','status':'completed','conclusion':'success','created_at':'2026-11-05T10:18:00Z'}
        with patch.object(m,'api',return_value={'workflow_runs':[daily]}),patch.object(m.mail,'document',side_effect=receipt),patch.object(m.mail,'send_email')as send:
            m.check_deadlines({'sent':{}},False,now);send.assert_not_called()

    def test_wrong_recipient_rejected_before_any_scan(self):
        with patch.dict(os.environ, {'WEEKLY_REPORT_EMAIL_TO': 'someone@example.com'}), \
             patch.object(sys, 'argv', ['report']), patch.object(m, 'runs') as scan:
            with self.assertRaises(ValueError):
                m.main()
            scan.assert_not_called()

    def test_successful_retry_preserves_original_failed_attempt(self):
        earlier = copy.deepcopy(self.run)
        self.run.update(run_attempt=2, conclusion='success', updated_at='2026-10-01T15:00:00Z')
        with patch.dict(os.environ, {'WEEKLY_REPORT_EMAIL_TO': m.OWNER, 'GITHUB_REPOSITORY': m.REPOS[2]}), \
             patch.object(sys, 'argv', ['report']), patch.object(m, 'REPOS', [m.REPOS[1]]), \
             patch.object(m, 'runs', return_value=[self.run]), patch.object(m, 'api', return_value=earlier), \
             patch.object(m, 'jobs', side_effect=[self.jobs, [], []]), \
             patch.object(m.mail, 'document', return_value=None), \
             patch.object(m.mail, 'send_email') as send, patch.object(m, 'save'):
            m.main()
            self.assertEqual(send.call_count, 1)
            self.assertIn('later run', send.call_args.args[1])
            self.assertTrue(send.call_args.args[2].endswith(':1:1'))

    def test_recovered_watchdog_requires_both_checks_and_same_day(self):
        old = dict(self.run, path='dashboard_watchdog.yml', name='Dashboard Watchdog', display_title='Dashboard Watchdog')
        later = dict(old, id=2, conclusion='success', updated_at='2026-10-01T16:00:00Z')
        checks = [dict(name=name, conclusion='success') for name in
                  ["Check today's maintenance result and alert ownership", "Verify SalAdjCurator checked in recently"]]
        with patch.object(m, 'jobs', return_value=[dict(conclusion='success', steps=checks)]):
            self.assertTrue(m.recovered_watchdog(m.COMMISSIONER, old, later))
            self.assertFalse(m.recovered_watchdog(m.COMMISSIONER, old, None))
            self.assertFalse(m.recovered_watchdog(m.COMMISSIONER, old, dict(later, created_at='2026-10-02T14:00:00Z')))
            self.assertFalse(m.recovered_watchdog(m.COMMISSIONER, old, dict(later, head_branch='preview')))
            self.assertFalse(m.recovered_watchdog(m.COMMISSIONER, self.run, later))
        checks[0]['conclusion'] = 'skipped'
        with patch.object(m, 'jobs', return_value=[dict(conclusion='success', steps=checks)]):
            self.assertFalse(m.recovered_watchdog(m.COMMISSIONER, old, later))

    def test_recovered_watchdog_is_recorded_without_sending_catchup(self):
        old = dict(self.run, path='dashboard_watchdog.yml', name='Dashboard Watchdog', display_title='Dashboard Watchdog')
        later = dict(old, id=2, conclusion='success', updated_at='2026-10-01T16:00:00Z')
        checks = [dict(name=name, conclusion='success') for name in
                  ["Check today's maintenance result and alert ownership", "Verify SalAdjCurator checked in recently"]]
        state = {'sent': {}, 'checked': {}}
        with patch.dict(os.environ, {'WEEKLY_REPORT_EMAIL_TO': m.OWNER, 'GITHUB_REPOSITORY': m.COMMISSIONER}), \
             patch.object(sys, 'argv', ['report']), patch.object(m, 'REPOS', [m.COMMISSIONER]), \
             patch.object(m, 'runs', return_value=[later, old]), \
             patch.object(m, 'jobs', return_value=[dict(conclusion='success', steps=checks)]), \
             patch.object(m.mail, 'document', return_value=state), \
             patch.object(m.mail, 'send_email') as send, patch.object(m, 'save'):
            m.main()
        send.assert_not_called()
        self.assertIn('verified same-day', state['checked'][m.COMMISSIONER + ':1:1'])

    def test_pagination_does_not_miss_older_failures(self):
        with patch.object(m, 'api', side_effect=[{'workflow_runs': [self.run] * 20}, {'workflow_runs': [self.run]}]) as api:
            self.assertEqual(len(list(m.runs(m.REPOS[1]))), 21)
            self.assertIn('branch=main', api.call_args_list[0].args[1])

    def test_transient_api_timeout_is_retried(self):
        with patch.object(m.mail, 'get_json', side_effect=[TimeoutError('slow'), {'ok': True}]), \
             patch.object(m.mail.time, 'sleep') as sleep:
            self.assertEqual(m.api(m.REPOS[0], 'actions/runs'), {'ok': True})
            sleep.assert_called_once_with(1)

    def test_truncated_api_response_is_retried(self):
        truncated = m.http.client.IncompleteRead(b'', 674165)
        with patch.object(m.mail, 'get_json', side_effect=[truncated, {'ok': True}]), \
             patch.object(m.mail.time, 'sleep') as sleep:
            self.assertEqual(m.api(m.REPOS[0], 'actions/runs'), {'ok': True})
            sleep.assert_called_once_with(1)


class GamedayReports(unittest.TestCase):
    incident = dict(openedAt='2026-11-23T20:00:00Z', week=12, error='Forecast unavailable')

    def test_receipt_uses_shared_authenticated_reader_and_retries(self):
        payload = {'incidents': [self.incident]}
        response = {'encoding': 'base64', 'content': base64.b64encode(json.dumps(payload).encode()).decode()}
        with patch.dict(os.environ, {'ACCOUNT_FAILURE_COVERAGE': 'false'}), \
             patch.object(m.mail, 'get_json', side_effect=[TimeoutError('slow'), response, None]) as fetch, \
             patch.object(m.mail.time, 'sleep') as sleep:
            self.assertEqual(m.read_gameday_health(m.DAILY_REPO), payload)
            self.assertEqual(m.read_gameday_health(m.DAILY_REPO), {'incidents': []})
        sleep.assert_called_once_with(1)
        self.assertTrue(all(call.args[0].endswith('/contents/gameday-health.json?ref=live-bonus-watch')
                            for call in fetch.call_args_list))

    def test_malformed_receipt_is_not_treated_as_healthy(self):
        bad = {'content': base64.b64encode(b'{"incidents": {}}').decode()}
        with patch.object(m, 'api', return_value=bad):
            with self.assertRaisesRegex(ValueError, 'Invalid Gameday health receipt'):
                m.read_gameday_health(m.DAILY_REPO)

    start = m.gameday_time('2026-11-24T01:15:00Z')

    @staticmethod
    def snapshot(league, now, failing):
        return {'league': league, 'week': 11,
                'fetchedAt': (now - m.timedelta(minutes=5) if failing else now).isoformat(),
                'teams': [{'projectedScore': 100, 'liveMatchups': [{}]}] * 32,
                'liveBonusProbabilityBasis': 'final_event_outcome'}

    def failed_repair(self, week=11):
        return dict(self.incident, week=week, repairStatus='needs_attention',
                    repairAttemptedAt=(self.start + m.timedelta(minutes=17)).isoformat(),
                    checkedAt=(self.start + m.timedelta(minutes=18)).isoformat())

    def test_history_does_not_send_and_missing_feed_does_not_hide_other_league(self):
        incidents = [dict(self.incident, openedAt=(self.start - m.timedelta(minutes=i * 2)).isoformat(),
                          recoveredAt=(self.start - m.timedelta(minutes=i * 2) + m.timedelta(seconds=40)).isoformat())
                     for i in range(1, 31)]
        errors = []
        with patch.object(m, 'read_gameday_health', side_effect=[TimeoutError(), {'incidents': incidents}]), \
             patch.object(m.mail, 'deliver_once') as deliver:
            self.assertEqual(m.read_gameday_incidents(errors), {})
        self.assertEqual(errors, ['ADL Gameday incident reporting: TimeoutError'])
        deliver.assert_not_called()

    def test_short_flaps_stay_quiet_and_real_outage_reports_once(self):
        state, errors = {'sent': {}}, []
        with patch.object(m, 'read_gameday_snapshot') as read, patch.object(m, 'save'), \
             patch.object(m.mail, 'deliver_once', side_effect=lambda state, key, send, save: send()), \
             patch.object(m.mail, 'send_email') as send:
            for minute, failing in [(0, True), (2, False), (4, True), (6, False), (8, True), (18, True)]:
                read.side_effect = lambda league, now: self.snapshot(league, now, league == 'FAFL' and failing)
                m.check_gameday_direct(state, False, {}, errors, now=self.start + m.timedelta(minutes=minute))
            send.assert_not_called()
            for minute, failing, receipts in [
                    (28, True, {}), (30, True, {'FAFL': self.failed_repair()}),
                    (35, True, {'FAFL': self.failed_repair()}),
                    (38, False, {}), (40, True, {}), (48, True, {})]:
                read.side_effect = lambda league, now: self.snapshot(league, now, league == 'FAFL' and failing)
                m.check_gameday_direct(state, False, receipts, errors, now=self.start + m.timedelta(minutes=minute))
            send.assert_called_once()
            self.assertTrue(send.call_args.args[2].startswith('gameday-direct:FAFL:'))
        self.assertEqual(errors, [])

    def test_existing_delivery_and_preview_do_not_send(self):
        receipt = self.failed_repair()
        old_key = 'gameday:FAFL:' + receipt['openedAt']
        state = {'sent': {old_key: {'sent_at': self.start.isoformat()}}}
        errors = []
        with patch.object(m, 'read_gameday_snapshot',
                          side_effect=lambda league, now: self.snapshot(league, now, True)), \
             patch.object(m.mail, 'deliver_once') as deliver, patch.object(m, 'save') as save, \
             patch('builtins.print') as output:
            for minute in (0, 20, 25):
                m.check_gameday_direct(state, True, {'ADL': receipt, 'FAFL': receipt}, errors,
                                       now=self.start + m.timedelta(minutes=minute))
        self.assertEqual(errors, [])
        self.assertEqual(output.call_count, 1)
        self.assertIn('ADL Gameday forecast failure', output.call_args.args[0])
        self.assertEqual(set(state['sent']), {old_key})
        deliver.assert_not_called()
        save.assert_not_called()

    def test_wrong_week_old_and_unverified_repair_cannot_escalate(self):
        now = self.start + m.timedelta(minutes=20)
        receipt = self.failed_repair()
        self.assertTrue(m.gameday_failed_repair(receipt, 11, None, now))
        self.assertFalse(m.gameday_failed_repair(dict(receipt, week=10), 11, None, now))
        self.assertFalse(m.gameday_failed_repair(receipt, 11, None, now + m.timedelta(hours=1)))
        self.assertFalse(m.gameday_failed_repair(dict(receipt, repairStatus='attempting'), 11, None, now))
        self.assertFalse(m.gameday_failed_repair(dict(receipt, repairStatus='recovered'), 11, None, now))

    def test_nov26_failed_repair_followed_by_verified_recovery_does_not_email(self):
        opened = m.gameday_time('2026-11-27T00:57:16Z')
        failed = dict(week=12, season=2026, openedAt=opened.isoformat(), error='Snapshot is stale.',
                      repairStatus='needs_attention', repairAttemptedAt='2026-11-27T01:16:16Z',
                      checkedAt='2026-11-27T01:16:57Z')
        later_failed = dict(failed, repairAttemptedAt='2026-11-27T01:21:16Z',
                            checkedAt='2026-11-27T01:21:36Z')
        for healthy in (True, False):
            with self.subTest(healthy=healthy), patch.object(m, 'read_gameday_snapshot') as read, \
                 patch.object(m, 'save'), patch.object(m.mail, 'send_email') as send, \
                 patch.object(m.mail, 'deliver_once', side_effect=lambda state, key, do_send, save: do_send()):
                state, errors = {'sent': {}}, []
                for stamp, failing, receipt in (
                    ('2026-11-27T01:02:00Z', True, None),
                    ('2026-11-27T01:18:00Z', True, failed),
                    ('2026-11-27T01:22:00Z', True, later_failed),
                    ('2026-11-27T01:24:00Z', not healthy, None if healthy else later_failed),
                    ('2026-11-27T01:28:00Z', not healthy, None if healthy else later_failed),
                ):
                    read.side_effect = lambda league, now: dict(self.snapshot(league, now, league == 'FAFL' and failing),
                                                               week=12, season=2026)
                    m.check_gameday_direct(state, False, {'FAFL':receipt}, errors, now=m.gameday_time(stamp))
                    if stamp < '2026-11-27T01:24:00Z':
                        send.assert_not_called()
                self.assertEqual(send.call_count, 0 if healthy else 1)
                self.assertEqual(errors, [])


if __name__ == '__main__':
    unittest.main()
