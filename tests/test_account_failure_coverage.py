import copy
import io
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import account_failure_coverage as catalog
import email_workflow_failures as m


class AccountCoverage(unittest.TestCase):
    def run_record(self, **changes):
        return dict(dict(id=42, workflow_id=123, path='.github/workflows/daily-values.yml',
            name='Daily values', display_title='Update values', event='schedule',
            head_branch='master', status='completed', conclusion='failure', run_attempt=1,
            created_at='2026-11-14T09:00:00Z', updated_at='2026-11-14T09:02:00Z',
            html_url='https://github.com/TheMathNinja/data/actions/runs/42'), **changes)

    def job(self, conclusion='failure'):
        return [dict(name='values', conclusion=conclusion,
                     steps=[dict(name='Refresh source data', conclusion=conclusion)])]

    def test_discovery_paginates_and_rejects_incomplete_or_foreign_inventory(self):
        repo=lambda name: dict(full_name='TheMathNinja/'+name, private=False, owner={'login':'TheMathNinja'})
        with patch.object(m.mail, 'get_json', side_effect=[[repo(str(i)) for i in range(100)], [repo('data')]]) as get:
            self.assertEqual(len(catalog.repositories(get)), 101)
            self.assertIn('page=2', get.call_args.args[0])
        for value in (None, {}, [], [dict(repo('data'), private=True)],
                      [dict(repo('data'), owner={'login':'someone-else'})]):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                catalog.repositories(lambda _: value)

    def test_unlisted_workflow_and_branch_have_stable_but_isolated_identity(self):
        old=self.run_record(_account_report=True)
        later=dict(old, id=43, display_title='A different commit title')
        self.assertEqual(m.incident_key('TheMathNinja/data', old), m.incident_key('TheMathNinja/data', later))
        self.assertNotEqual(m.incident_key('TheMathNinja/data', old),
                            m.incident_key('TheMathNinja/data', dict(later, head_branch='feature')))
        self.assertTrue(m.production(old))
        self.assertIsNone(m.production(self.run_record()))

    def test_recovery_requires_same_workflow_branch_and_actual_failed_work(self):
        old=self.run_record(_account_report=True)
        later=self.run_record(id=43, conclusion='success', display_title='Manual repair',
            created_at='2026-11-15T09:00:00Z', updated_at='2026-11-15T09:02:00Z')
        with patch.object(m, 'jobs', return_value=self.job('success')):
            self.assertEqual(m.verified_recovery('TheMathNinja/data', old, self.job(), [later])['id'],43)
            for change in ({'workflow_id':999}, {'head_branch':'feature'}, {'conclusion':'failure'}):
                self.assertIsNone(m.verified_recovery('TheMathNinja/data', old, self.job(), [dict(later,**change)]))
        for job in (self.job('skipped'), [], [dict(name='values',conclusion='success',steps=[])]):
            with patch.object(m, 'jobs', return_value=job):
                self.assertIsNone(m.verified_recovery('TheMathNinja/data', old, self.job(), [later]))
        with patch.object(m, 'jobs', side_effect=RuntimeError('unavailable')):
            self.assertIsNone(m.verified_recovery('TheMathNinja/data', old, self.job(), [later]))

    def test_repeated_issue_is_one_email_independent_step_and_recurrence_still_alert(self):
        repo='TheMathNinja/data';old=self.run_record(_account_report=True)
        failed=['values: Refresh source data'];scope=m.incident_scope(repo,old)
        state={'sent':{'first':dict(incident_key=m.incident_key(repo,old),scope=scope,
            failed_steps=failed,affected_jobs={'values':'failure'},failed_at=old['updated_at'])}}
        retry=dict(old,id=43,display_title='Another title',updated_at='2026-11-15T10:00:00Z')
        self.assertEqual(m.unreported_steps(state,repo,retry,[],failed)[1],[])
        self.assertEqual(m.unreported_steps(state,repo,retry,[],['publish: Upload data'])[1],['publish: Upload data'])
        success=dict(old,id=44,conclusion='success',updated_at='2026-11-15T09:00:00Z')
        with patch.object(m,'jobs',return_value=self.job('success')):
            self.assertEqual(m.unreported_steps(state,repo,retry,[success],failed)[1],failed)

    def invoke(self, state, discovery=None, run_reader=None):
        with patch.dict(os.environ, {'ACCOUNT_FAILURE_COVERAGE':'true','PRIVATE_FAILURE_REPORTING_SINCE':'',
                'GUARDIAN_ALERT_OWNER':'','ACTIONS_BUDGET_MONITOR':'','CHI_FORECAST_REQUEST_MONITOR':'',
                'WEEKLY_REPORT_EMAIL_TO':m.OWNER,'GITHUB_REPOSITORY':m.COMMISSIONER}), \
             patch.object(sys,'argv',['report']),patch.object(m,'REPOS',[]),patch.object(m,'GUARDIAN','TheMathNinja/data'), \
             patch.object(catalog,'repositories',side_effect=discovery or (lambda _: ['TheMathNinja/data'])), \
             patch.object(m,'runs',side_effect=run_reader or (lambda _: [self.run_record()])), \
             patch.object(m,'jobs',return_value=self.job()),patch.object(m,'cause_codes',return_value={}), \
             patch.object(m.mail,'document',return_value=state),patch.object(m,'save'), \
             patch.object(m.mail,'deliver_once',side_effect=lambda s,k,send,persist: send()), \
             patch.object(m.mail,'send_email') as send:
            m.main()
            return send.call_count

    def test_full_scan_delivers_once_and_records_inventory_health(self):
        state={'sent':{},'checked':{}}
        self.assertEqual(self.invoke(state),1)
        self.assertEqual(self.invoke(state),0)
        self.assertEqual(state['accountCoverage']['repositories'],['TheMathNinja/data'])
        self.assertTrue(state['healthyAt'])

    def test_discovery_and_repository_errors_cannot_claim_healthy_coverage(self):
        for kwargs in ({'discovery':lambda _: (_ for _ in ()).throw(RuntimeError('inventory unavailable'))},
                       {'run_reader':lambda _: (_ for _ in ()).throw(RuntimeError('runs unavailable'))}):
            state={'sent':{},'checked':{}}
            with self.assertRaises(RuntimeError):
                self.invoke(state,**kwargs)
            self.assertNotIn('healthyAt',state)

    def test_all_branch_scan_is_only_enabled_with_account_coverage(self):
        for enabled in ('true',''):
            with patch.dict(os.environ,{'ACCOUNT_FAILURE_COVERAGE':enabled}), \
                 patch.object(m,'api',return_value={'workflow_runs':[]}) as api:
                list(m.runs('TheMathNinja/data'))
            self.assertEqual('branch=main' in api.call_args.args[1],enabled!='true')

    def test_only_completed_exact_attempt_job_evidence_is_reused(self):
        m.COMPLETED_JOB_EVIDENCE.clear()
        run=self.run_record()
        jobs=[dict(self.job('success')[0],status='completed')]
        with patch.object(m,'api',return_value={'jobs':jobs}) as api:
            m.jobs('TheMathNinja/data',run);m.jobs('TheMathNinja/data',run)
            self.assertEqual(api.call_count,1)
            m.jobs('TheMathNinja/data',dict(run,run_attempt=2))
            self.assertEqual(api.call_count,2)
            m.jobs('TheMathNinja/data',dict(run,status='in_progress'))
            self.assertEqual(api.call_count,3)
        m.COMPLETED_JOB_EVIDENCE.clear()

    def test_account_reads_use_existing_cross_repository_credential_not_job_quota(self):
        with patch.dict(os.environ,{'ACCOUNT_FAILURE_COVERAGE':'true','PRIVATE_REPORT_TOKEN':'test-existing-token'}), \
             patch.object(m.urllib.request,'urlopen',return_value=io.BytesIO(b'{}')) as request:
            self.assertEqual(m.api('TheMathNinja/data','actions/runs'),{})
            self.assertEqual(request.call_args.args[0].get_header('Authorization'),'Bearer test-existing-token')
        with patch.dict(os.environ,{'ACCOUNT_FAILURE_COVERAGE':'true','PRIVATE_REPORT_TOKEN':''}), \
             patch.object(m.urllib.request,'urlopen') as request:
            with self.assertRaises(RuntimeError):
                m.api('TheMathNinja/data','actions/runs')
            request.assert_not_called()


if __name__ == '__main__':
    unittest.main()
