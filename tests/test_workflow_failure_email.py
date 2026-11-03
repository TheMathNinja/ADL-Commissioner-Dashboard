import copy
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import email_workflow_failures as m


class FailureReports(unittest.TestCase):
    def setUp(self):
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
                self.assertEqual(saved, 0)
                self.assertFalse(state['sent'])

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
        state, count, _ = self.exercise(dry=True)
        self.assertEqual(count, 0)
        self.assertFalse(state['sent'])
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


    def test_distinct_step_recovery_and_next_day_reopen(self):
        repo=m.REPOS[1];scope,_=m.unreported_steps({'sent':{}},repo,self.run,[],['a'])
        state={'sent':{'old':dict(scope=scope,failed_steps=['a'],failed_at=self.run['updated_at'])}}
        later=dict(self.run,updated_at='2026-10-01T16:00:00Z')
        self.assertEqual(m.unreported_steps(state,repo,later,[],['a','b'])[1],['b'])
        success=dict(self.run,conclusion='success',updated_at='2026-10-01T15:00:00Z')
        self.assertEqual(m.unreported_steps(state,repo,later,[success],['a'])[1],['a'])
        self.assertEqual(m.unreported_steps(state,repo,dict(later,created_at='2026-10-02T14:00:00Z'),[],['a'])[1],['a'])

    def test_failed_smtp_is_retried_not_recorded_as_sent(self):
        # Unaccepted mail must not suppress a future delivery attempt.
        state, _, saved = self.exercise(send_error=RuntimeError('SMTP unavailable'))
        self.assertFalse(state['sent'])
        self.assertEqual(saved, 0)

    def test_missing_dispatch_and_receipts_notify_once_per_delivery(self):
        now=m.datetime.fromisoformat('2026-11-03T16:00:00+00:00')
        state={'sent':{}}
        with patch.object(m,'api',return_value={'workflow_runs':[]}),patch.object(m.mail,'document',return_value=None),patch.object(m,'save'),patch.object(m.mail,'send_email')as send:
            m.check_deadlines(state,False,now);m.check_deadlines(state,False,now)
            self.assertEqual(send.call_count,3)

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
             patch.object(m, 'jobs', side_effect=[self.jobs, []]), \
             patch.object(m.mail, 'document', return_value=None), \
             patch.object(m.mail, 'send_email') as send, patch.object(m, 'save'):
            m.main()
            self.assertEqual(send.call_count, 1)
            self.assertIn('later run', send.call_args.args[1])
            self.assertTrue(send.call_args.args[2].endswith(':1:1'))

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


if __name__ == '__main__':
    unittest.main()
