"""Replay Nov 12 retry identities without GitHub writes or SMTP."""
import copy
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import email_workflow_failures as m
import fafl_rebuild_repair as repair


class IncidentReplay(unittest.TestCase):
    def test_runner_mirror_error_is_identified_without_replaying_dashboard_writer(self):
        code, _ = m.diagnose([
            'E: Failed to fetch https://packages.microsoft.com/ubuntu/24.04/prod/dists/noble/InRelease  403 Forbidden',
        ])
        self.assertEqual(code, 'runner-unrelated-apt-source')
        self.assertEqual(m.diagnose(['HTTP 403 from a league source'])[0], 'credential-or-permission')
        run = dict(id=46049446112, path='.github/workflows/update_dashboard.yml', event='push')
        with patch.object(m, 'api') as api, patch.object(m, 'request_read_only_replay') as request:
            self.assertIsNone(m.consider_replay({}, 'TheMathNinja/ADL-Commissioner-Dashboard', run,
                ['build-dashboard: Set up cached ADL R runtime'], {'build-dashboard': code},
                m.gameday_time('2026-11-27T18:29:00Z'), dry_run=False, read=api, request=request,
                save=lambda _: self.fail('must not claim a write-capable replay')))
            api.assert_not_called()
            request.assert_not_called()

    def test_fafl_rebuild_claims_once_for_exact_transient_build_or_save(self):
        old = dict(id=45937111967, path=repair.PATH, head_branch='main', event='push',
                   status='completed', conclusion='failure', updated_at='2026-11-27T04:07:18Z',
                   head_sha='a'*40)
        now = m.gameday_time('2026-11-27T04:25:00Z')
        for step, line in (
            (repair.BUILD, 'collect_live_bonus.MFLReadExhausted: MFL public read retry exhausted: playerScores'),
            (repair.SAVE, 'RuntimeError: Main advanced again during the regenerated build; no stale output was pushed'),
        ):
            with self.subTest(step=step):
                records = {
                    '': dict(private=False, default_branch='main'),
                    f'actions/workflows/{repair.WORKFLOW}': dict(state='active', path=repair.PATH),
                    'git/ref/heads/main': dict(object=dict(sha='b'*40)),
                    f'compare/{"a"*40}...{"b"*40}': dict(status='ahead', behind_by=0),
                    f'contents/{repair.PATH}?ref={"b"*40}': dict(sha=repair.BLOB),
                    f'actions/workflows/{repair.WORKFLOW}/runs?branch=main&per_page=10': dict(workflow_runs=[]),
                }
                state, trace = {}, []
                def save(doc):trace.append(next(iter(doc['fafl_rebuild_repairs'].values()))['status'])
                def dispatch():
                    trace.append('POST')
                    return 'requested', 1234
                def check(run=old, when=now, dry=False, diagnosis=m.diagnose([line])[0]):
                    return repair.consider_rebuild(state, repair.REPO, run, [step], {'rebuild':diagnosis},
                        when, dry=dry, read=lambda repo, path: records[path], dispatch=dispatch,
                        save=save, stamp=m.gameday_time)
                self.assertIsNone(check(dry=True))
                self.assertIsNone(check(diagnosis='credential-or-permission'))
                records['']['private'] = True
                self.assertIsNone(check())
                records['']['private'] = False
                fresh = records[f'actions/workflows/{repair.WORKFLOW}/runs?branch=main&per_page=10']
                fresh['workflow_runs'] = [dict(id=555, status='queued')]
                self.assertEqual(check(), 'pending')
                self.assertEqual(trace, [])
                fresh['workflow_runs'] = []
                self.assertEqual(check(), 'pending')
                self.assertEqual(check(), 'pending')
                self.assertEqual(check(run=dict(old, id=222)), 'replay_limit')
                retry = dict(old, id=1234, event='workflow_dispatch')
                self.assertTrue(repair.owns_retry(state, repair.REPO, retry))
                self.assertIsNone(check(run=retry))
                self.assertEqual(check(when=now + m.timedelta(minutes=30)), 'retry_deadline')
                self.assertEqual(trace, ['sending','POST','requested'])

    def test_fafl_repair_requires_a_built_pages_commit_from_the_rebuild(self):
        old = dict(updated_at='2026-11-27T04:07:18Z', head_sha='a'*40)
        retry = dict(path=repair.PATH, head_branch='main', event='workflow_dispatch',
                     conclusion='success', head_sha='b'*40, updated_at='2026-11-27T04:25:01Z')
        job = dict(name='rebuild', conclusion='success', started_at='2026-11-27T04:10:00Z',
                   steps=[dict(name=s, conclusion='success') for s in sorted(repair.STEPS)])
        index = dict(league='FAFL',season=2026,currentWeek=12,generatedAt='2026-11-27T04:25:00Z')
        encode = lambda: json.dumps(index).encode()
        live = [encode()]
        def read(repo, path):
            self.assertEqual(repo, repair.REPO)
            if path=='git/ref/heads/main':return {'object':{'sha':'c'*40}}
            if path.startswith('contents/'):return {'sha':repair.git_blob(encode())}
            return {'status':'ahead','behind_by':0}
        check = lambda: repair.verified_rebuild(old, retry, [job], read, m.gameday_time, lambda:live[0])
        self.assertTrue(check())
        live[0] = b'{"league":"FAFL"}'
        self.assertFalse(check())
        index['generatedAt'] = '2026-11-27T04:09:59Z'
        live[0] = encode()
        self.assertFalse(check())
        index['generatedAt'] = '2026-11-27T04:25:00Z'
        live[0] = encode()
        job['steps'][0]['conclusion'] = 'skipped'
        self.assertFalse(check())

    def test_scheduled_live_watch_read_failure_waits_for_verified_publication(self):
        repo = 'TheMathNinja/ADL-GM-Dashboard'
        run = dict(path='.github/workflows/live_bonus_watch.yml', event='schedule', head_branch='main', conclusion='failure',
                   created_at='2026-11-26T23:45:59Z', updated_at='2026-11-26T23:47:40Z')
        failed = ['watch: Refresh public MFL live scores']
        code, _ = m.diagnose(['Error: MFL public read retry exhausted: liveScoring'])
        self.assertEqual(code, 'live-watch-read-exhausted')
        diagnoses = {'watch': code}
        early = m.gameday_time('2026-11-27T00:04:49Z')
        later = m.gameday_time('2026-11-27T00:19:00Z')
        snapshot = dict(league='ADL', season=2026, week=12, fetchedAt='2026-11-27T00:03:00Z',
                        teams=[dict(id=f'{i:04d}', score=0.0) for i in range(1,33)])
        def check(now=early, workflow=run, steps=failed, evidence=diagnoses):
            return m.live_watch_read_recovery(repo, workflow, steps, evidence, now)
        with patch.object(m, 'read_gameday_snapshot', return_value=snapshot) as read:
            self.assertEqual(check()[0], 'recovered')
            self.assertEqual(check(later)[0], 'retry_deadline')  # Old evidence is not fresh.
            read.reset_mock()
            self.assertIsNone(check(workflow=dict(run,event='workflow_dispatch')))
            self.assertIsNone(check(steps=failed+['watch: Publish']))
            self.assertIsNone(check(evidence={'watch':'unclassified'}))
            read.assert_not_called()
        for invalid in (dict(snapshot, league='FAFL'), dict(snapshot, season=2025),
                        dict(snapshot, liveProbabilityUnavailable=True),
                        dict(snapshot, fetchedAt='2026-11-26T23:47:39Z'), dict(snapshot, teams=snapshot['teams'][:-1])):
            with patch.object(m, 'read_gameday_snapshot', return_value=invalid):
                self.assertEqual(check()[0], 'pending')
                self.assertEqual(check(later)[0], 'retry_deadline')

    def test_nov15_diagnostic_audit_recovery_ignores_labels_not_required_work(self):
        old=dict(id=43782792510,workflow_id=123,path='.github/workflows/league-audit.yml',
            display_title='Private league audit - contracts - source verify-recovery-43731679111',
            event='workflow_dispatch',head_branch='main',status='completed',conclusion='failure',
            created_at='2026-11-16T00:51:01Z',updated_at='2026-11-16T00:51:44Z',_private_report=True)
        later=dict(old,id=43783144474,conclusion='success',created_at='2026-11-16T00:54:00Z',
            updated_at='2026-11-16T00:55:31Z',
            display_title='Private league audit - contracts - source verify-test-repair-43731679111')
        step="Validate both leagues' full Live Bonus Game Watch test suites"
        failed=[dict(name='contracts',conclusion='failure',steps=[dict(name=step,conclusion='failure')]),
                dict(name='guardian-audit',conclusion='skipped',steps=[])]
        passed=copy.deepcopy(failed);passed[0]['conclusion']='success';passed[0]['steps'][0]['conclusion']='success'
        with patch.object(m,'jobs',return_value=passed):
            self.assertEqual(m.verified_recovery(m.GUARDIAN,old,failed,[later]),later)
            wrong=dict(later,display_title='Private league audit - guardian - source verify-test-repair')
            self.assertIsNone(m.verified_recovery(m.GUARDIAN,old,failed,[wrong]))
            self.assertIsNone(m.verified_recovery(m.GUARDIAN,old,failed,[dict(later,head_branch='preview')]))
        passed[0]['steps'][0]['conclusion']='skipped'
        with patch.object(m,'jobs',return_value=passed):
            self.assertIsNone(m.verified_recovery(m.GUARDIAN,old,failed,[later]))

    def test_private_audit_recovery_across_parent_attempts(self):
        old=dict(id=43289997242,workflow_id=123,path='.github/workflows/league-audit.yml',
            display_title='Private league audit - guardian - source 43264268292-2-guardian',
            event='workflow_dispatch',head_branch='main',status='completed',conclusion='failure',
            created_at='2026-11-12T19:25:23Z',updated_at='2026-11-12T19:26:25Z',_private_report=True)
        later=dict(old,id=999,conclusion='success',created_at='2026-11-12T19:29:00Z',
            updated_at='2026-11-12T19:31:31Z',
            display_title='Private league audit - guardian - source 43264268292-3-guardian')
        step='Verify projection-based acquisition values without acquiring players'
        failed=[dict(name='guardian-audit / preflight',conclusion='failure',steps=[dict(name=step,conclusion='failure')]),
                dict(name='contracts',conclusion='skipped',steps=[])]
        passed=copy.deepcopy(failed)
        passed[0]['conclusion']='success';passed[0]['steps'][0]['conclusion']='success'
        with patch.object(m,'jobs',return_value=passed):
            self.assertEqual(m.verified_recovery(m.GUARDIAN,old,failed,[later]),later)
            other_parent=dict(later,display_title='Private league audit - guardian - source 123-3-guardian')
            self.assertEqual(m.verified_recovery(m.GUARDIAN,old,failed,[other_parent]),other_parent)
            wrong=dict(later,display_title='Private league audit - contracts - source 43264268292-3-contracts')
            self.assertIsNone(m.verified_recovery(m.GUARDIAN,old,failed,[wrong]))
            extra=failed+[dict(name='required publication',conclusion='skipped',steps=[])]
            self.assertIsNone(m.verified_recovery(m.GUARDIAN,old,extra,[later]))
        passed[0]['steps'][0]['conclusion']='skipped'
        with patch.object(m,'jobs',return_value=passed):
            self.assertIsNone(m.verified_recovery(m.GUARDIAN,old,failed,[later]))

    def test_nov15_numeric_parent_contracts_recover_after_midnight(self):
        old=dict(id=43801293546,workflow_id=123,path='.github/workflows/league-audit.yml',
            display_title='Private league audit - contracts - source 43801278899-1-contracts',
            event='workflow_dispatch',head_branch='main',status='completed',conclusion='failure',
            created_at='2026-11-16T03:58:00Z',updated_at='2026-11-16T03:59:00Z',_private_report=True)
        step='Verify cross-repository automation contracts'
        failed=[dict(name='contracts',conclusion='failure',steps=[dict(name=step,conclusion='failure')]),
                dict(name='guardian-audit',conclusion='skipped',steps=[])]
        later=dict(old,id=43803873119,conclusion='success',created_at='2026-11-16T05:01:00Z',
            updated_at='2026-11-16T05:03:00Z',
            display_title='Private league audit - contracts - source 43803873119-1-contracts')
        passed=copy.deepcopy(failed)
        passed[0]['conclusion']='success';passed[0]['steps'][0]['conclusion']='success'
        with patch.object(m,'jobs',return_value=passed):
            self.assertEqual(m.verified_recovery(m.GUARDIAN,old,failed,[later]),later)
            self.assertIsNone(m.verified_recovery(m.GUARDIAN,old,failed,[dict(later,head_branch='preview')]))
            self.assertIsNone(m.verified_recovery(m.GUARDIAN,old,failed,[dict(later,workflow_id=456)]))
        passed[0]['steps'][0]['conclusion']='skipped'
        with patch.object(m,'jobs',return_value=passed):
            self.assertIsNone(m.verified_recovery(m.GUARDIAN,old,failed,[later]))

    def setUp(self):
        self.enterContext(patch.object(m, 'read_gameday_health', return_value={'incidents': []}))
        self.enterContext(patch.object(m, 'check_gameday_direct'))
        self.repo = m.DAILY_REPO
        self.run = dict(id=43191957893, workflow_id=279881511,
                        display_title='Official ADL correction update \u00b7 Week 9 \u00b7 ' + 'a'*64,
                        path='refresh_extension_calculator.yml', head_branch='main',
                        status='completed', event='workflow_dispatch', conclusion='failure',
                        created_at='2026-11-12T09:29:47Z', updated_at='2026-11-12T09:36:59Z',
                        html_url='https://github.com/TheMathNinja/ADL-GM-Dashboard/actions/runs/43191957893')
        self.steps = ['refresh: Require synchronized quarterly forecasts before publication',
                      'refresh: Require a successful playoff forecast publication']

    def send(self, state, run, codes, steps=None, history=None):
        scope, remaining = m.unreported_steps(state, self.repo, run, history or [], steps or self.steps, codes)
        if remaining:
            state['sent'][str(run['id'])] = dict(scope=scope, incident_key=m.incident_key(self.repo,run),
                failed_steps=remaining, failed_at=run['updated_at'], cause_codes=codes,
                affected_jobs={'refresh':'failure'})
        return bool(remaining)

    def test_this_mornings_four_corrections_produce_one_email(self):
        state = {'sent': {}}
        runs = [(43191957893,131093267662,'09:36:59'),(43194917415,131103283357,'10:02:23'),
                (43205980592,131141142222,'11:12:53'),(43250233951,131293739243,'15:52:20')]
        count = 0
        for run_id, job_id, ended in runs:
            run = dict(self.run,id=run_id,updated_at='2026-11-12T'+ended+'Z')
            count += self.send(state,run,{'refresh':'unclassified:'+str(job_id)})
        self.assertEqual(count,1)
        self.assertEqual(next(iter(state['sent'].values()))['last_seen_at'],'2026-11-12T15:52:20Z')

    def test_existing_sent_state_migrates_without_resending(self):
        state = {'sent': {}}
        self.send(state,self.run,{'refresh':'unclassified:131093267662'})
        entry = state['sent'][str(self.run['id'])]
        entry.pop('incident_key')  # Legacy scope remains sufficient evidence.
        tomorrow = dict(self.run,id=2,created_at='2026-11-13T09:00:00Z',updated_at='2026-11-13T09:10:00Z')
        self.assertFalse(self.send(state,tomorrow,{'refresh':'unclassified:999'}))

    def test_unknown_becomes_known_without_email_but_new_cause_alerts(self):
        state = {'sent': {}}
        self.assertTrue(self.send(state,self.run,{'refresh':'unclassified:1'}))
        self.assertFalse(self.send(state,dict(self.run,id=2),{'refresh':'model-invalid'}))
        self.assertTrue(self.send(state,dict(self.run,id=3),{'refresh':'credentials-invalid'}))

    def test_new_component_and_new_week_are_not_hidden(self):
        state = {'sent': {}}
        self.send(state,self.run,{'refresh':'unclassified:1'})
        self.assertTrue(self.send(state,dict(self.run,id=2),{'publish':'unclassified'},['publish: Verify receipt']))
        week10 = dict(self.run,id=3,display_title=self.run['display_title'].replace('Week 9','Week 10'))
        self.assertTrue(self.send(state,week10,{'refresh':'unclassified'}))

    def test_verified_recovery_reopens_but_green_skipped_work_does_not(self):
        state = {'sent': {}}
        self.send(state,self.run,{'refresh':'model-invalid'})
        success = dict(self.run,id=2,conclusion='success',updated_at='2026-11-12T10:00:00Z')
        later = dict(self.run,id=3,updated_at='2026-11-12T11:00:00Z')
        jobs = [dict(name='refresh',conclusion='success',steps=[dict(name=s.split(': ',1)[1],conclusion='success') for s in self.steps])]
        with patch.object(m,'jobs',return_value=[]):
            self.assertFalse(self.send(copy.deepcopy(state),later,{'refresh':'model-invalid'},history=[success]))
        with patch.object(m,'jobs',return_value=jobs):
            self.assertTrue(self.send(state,later,{'refresh':'model-invalid'},history=[success]))
            self.assertEqual(state['sent'][str(self.run['id'])]['resolved_at'],success['updated_at'])

    def test_private_workflow_coverage_is_explicit_and_main_only(self):
        for filename in m.PRIVATE_IMPACT:
            run = dict(self.run,path=filename,_private_report=True)
            self.assertTrue(m.production(run),filename)
            self.assertIsNone(m.production(dict(run,head_branch='preview')))
            self.assertIsNone(m.production(dict(run,event='pull_request')))
        self.assertIsNone(m.production(dict(self.run,path='automation-preflight.yml')))
        self.assertTrue(m.production(dict(self.run,path='automation-preflight.yml',_audit_report=True)))

    def test_exact_private_parent_child_and_retry_attribution(self):
        child = dict(self.run,path='league-audit.yml',display_title='Private league audit - guardian - source 42-1-guardian')
        self.assertEqual(m.private_parent(child),('42',1,'guardian'))
        self.assertIsNone(m.private_parent(dict(child,display_title='Private league audit - guardian - source 42-1-contracts')))
        parent = dict(self.run,id=42,path='automation-preflight.yml')
        name,step=m.PRIVATE_PARENT_STEPS['guardian']
        job=dict(id=50,name=name)
        record=dict(audit_parent='42',audit_attempt=1)
        with patch.object(m.subprocess,'run') as command:
            command.return_value.stdout='Private audit: https://github.com/'+m.GUARDIAN+'/actions/runs/43'
            for location in ('sent','linked_reports'):
                state={'sent':{},location:{m.GUARDIAN+':43:1':record}}
                self.assertTrue(m.delivered_private_child(state,m.COMMISSIONER,parent,{name:job},name+': '+step))
                self.assertFalse(m.delivered_private_child(state,m.COMMISSIONER,dict(parent,id=44),{name:job},name+': '+step))
                self.assertFalse(m.delivered_private_child(state,m.COMMISSIONER,parent,{name:job},name+': Different failure'))
            command.return_value.stdout='Dispatch failed before any child started'
            self.assertFalse(m.delivered_private_child(state,m.COMMISSIONER,parent,{name:job},name+': '+step))

    def test_exact_recovered_child_also_resolves_parent_not_independent_failures(self):
        parent=dict(self.run,id=43801278899,path='automation-preflight.yml')
        name,step=m.PRIVATE_PARENT_STEPS['contracts']
        job=dict(id=50,name=name)
        key=m.GUARDIAN+':43801293546:1'
        state={'sent':{},'checked':{key:'resolved before notification; verified recovery: https://github.com/recovered'}}
        with patch.object(m,'private_child_link',return_value='43801293546'):
            self.assertTrue(m.delivered_private_child(state,m.COMMISSIONER,parent,{name:job},name+': '+step))
        with patch.object(m,'private_child_link',return_value='999'):
            self.assertFalse(m.delivered_private_child(state,m.COMMISSIONER,parent,{name:job},name+': '+step))
        with patch.object(m,'private_child_link',return_value=None):
            self.assertFalse(m.delivered_private_child(state,m.COMMISSIONER,parent,{name:job},name+': Authentication failure'))
        state['checked'][key]='success'
        with patch.object(m,'private_child_link',return_value='43801293546'):
            self.assertFalse(m.delivered_private_child(state,m.COMMISSIONER,parent,{name:job},name+': '+step))

    def test_read_only_coverage_checks_never_send_or_write_state(self):
        with patch.dict(m.os.environ,{'WEEKLY_REPORT_EMAIL_TO':m.OWNER}), \
             patch.object(sys,'argv',['report','--verify-coverage']), \
             patch.object(m,'api',return_value=self.run), \
             patch.object(m,'jobs',return_value=[dict(name='failed',conclusion='failure')]), \
             patch.object(m.mail,'send_email') as send,patch.object(m,'save') as save:
            m.main()
        send.assert_not_called()
        save.assert_not_called()

    def test_log_classifier_does_not_use_job_id_as_cause(self):
        with patch.object(m.subprocess,'run') as command:
            command.return_value.stdout='2026-11-12T09:36:59Z ##[error]Process completed with exit code 1.'
            for job_id in (131093267662,131103283357):
                job = dict(id=job_id, name='refresh', conclusion='failure')
                self.assertEqual(m.failure_evidence(self.repo, self.run, [job]),
                                 ({'refresh':'unclassified'}, {'refresh':'unclassified'}))

    def test_transient_grace_is_bounded_and_keeps_failure_pending(self):
        ended=m.datetime.fromisoformat(self.run['updated_at'].replace('Z','+00:00'))
        self.assertTrue(m.notification_pending(self.repo,self.run,ended+m.timedelta(minutes=14)))
        self.assertFalse(m.notification_pending(self.repo,self.run,ended+m.timedelta(minutes=15)))
        guardian=dict(self.run,path='guardian.yml')
        self.assertTrue(m.notification_pending(m.GUARDIAN,guardian,ended+m.timedelta(minutes=9)))
        self.assertFalse(m.notification_pending(m.GUARDIAN,guardian,ended+m.timedelta(minutes=10)))

    def test_private_read_failure_does_not_skip_public_scan(self):
        scanned=[]
        def history(repo):
            scanned.append(repo)
            if repo==m.GUARDIAN:raise RuntimeError('Unavailable')
            return []
        with patch.dict(m.os.environ,{'WEEKLY_REPORT_EMAIL_TO':m.OWNER,'GITHUB_REPOSITORY':m.COMMISSIONER,'PRIVATE_FAILURE_REPORTING_SINCE':'2026-11-12T00:00:00Z'}), \
             patch.object(sys,'argv',['report','--dry-run']),patch.object(m,'runs',side_effect=history), \
             patch.object(m.mail,'document',return_value={'sent':{},'checked':{}}), \
             patch.object(m.mail,'send_email') as send:
            with self.assertRaisesRegex(RuntimeError,'coverage unavailable'):
                m.main()
        self.assertEqual(set(scanned),set(m.REPOS+[m.GUARDIAN]))
        send.assert_not_called()


if __name__ == '__main__':
    unittest.main()
