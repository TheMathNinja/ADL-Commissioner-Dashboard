"""Replay Nov 12 retry identities without GitHub writes or SMTP."""
import copy
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import email_workflow_failures as m


class IncidentReplay(unittest.TestCase):
    def setUp(self):
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
                self.assertEqual(m.cause_codes(self.repo,self.run,[dict(id=job_id,name='refresh',conclusion='failure')]),{'refresh':'unclassified'})

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
