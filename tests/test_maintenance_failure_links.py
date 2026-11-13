"""Offline replay of the Nov 13 parent/child/watchdog incident graph."""
import copy
import json
import io
import os
from pathlib import Path
import sys
import unittest
import textwrap
from datetime import datetime, timezone
from unittest.mock import patch, mock_open

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import email_workflow_failures as m
import maintenance_failure_links as links

DATA = 'Refresh SalAdj and Commissioner data'
ROSTER = 'Refresh rosters, EXT and Salary Cap Manager / refresh'
WAIVER = 'Apply waiver cap corrections'
CHECK = "Check today's maintenance result and alert ownership"
FRESH = 'Verify SalAdjCurator checked in recently'


def job(name, step, number, status='failure'):
    return dict(name=name, id=number, conclusion=status, started_at='2026-11-13T10:19:38Z',
                completed_at='2026-11-13T10:27:00Z', steps=[dict(name=step, conclusion=status)])


class MaintenanceLinks(unittest.TestCase):
    def setUp(self):
        common = dict(event='workflow_dispatch', head_branch='main', status='completed',
            conclusion='failure', run_attempt=1, created_at='2026-11-13T10:19:38Z',
            updated_at='2026-11-13T10:27:00Z', workflow_id=1)
        self.parent = dict(common, id=43408271069, name='Daily ADL League Maintenance',
            display_title='Daily ADL League Maintenance', path='daily_adl_league_maintenance.yml')
        self.child = dict(common, id=43408314983, name='Update Dashboard', path='update_dashboard.yml',
            display_title='Daily maintenance 43408271069 - Commissioner data', updated_at='2026-11-13T10:20:28Z')
        self.watch = dict(common, id=43421428617, name='Dashboard Watchdog', path='dashboard_watchdog.yml',
            display_title='Dashboard Watchdog', created_at='2026-11-13T11:59:00Z', updated_at='2026-11-13T11:59:10Z')
        for run, repo in [(self.parent, m.DAILY_REPO), (self.child, m.COMMISSIONER), (self.watch, m.COMMISSIONER)]:
            run['html_url'] = f"https://github.com/{repo}/actions/runs/{run['id']}"
        self.parent_jobs = [job(DATA, links.CHILD_STEPS[DATA], 1), job(WAIVER, '', 2, 'skipped'),
            job(ROSTER, 'Refresh rosters, EXT and Salary Cap Manager data', 3, 'success'),
            job('Run Commissioner alerts', 'Dispatch Commissioner-owned alerts', 4, 'success'),
            job('Verify daily maintenance package', 'Summarize component results', 5)]
        self.child_jobs = [job('build-dashboard', 'Verify salary-adjustment notification rules before live processing', 6)]
        self.watch_jobs = [job('check-dashboard-freshness', CHECK, 7)]

    def replay(self, independent=False, freshness=False, missing_link=False, state=None, child_only=False):
        state = state if state is not None else {'sent': {}, 'checked': {}}
        parent_jobs = copy.deepcopy(self.parent_jobs)
        if independent:
            parent_jobs[2]['conclusion'] = parent_jobs[2]['steps'][0]['conclusion'] = 'failure'
        unresolved = {j['name']: j['conclusion'] for j in parent_jobs[:4] if j['conclusion'] != 'success'}
        evidence = dict(parent=str(self.parent['id']), attempt=1, unresolved=unresolved)
        watch_jobs = copy.deepcopy(self.watch_jobs)
        if freshness:
            watch_jobs[0]['steps'].append(dict(name=FRESH, conclusion='failure'))
        def logs(args, **kwargs):
            from types import SimpleNamespace
            if '--job' in args and args[args.index('--job') + 1] == '7':
                value = '' if missing_link else 'MAINTENANCE_FAILURE_EVIDENCE=' + json.dumps(evidence)
                return SimpleNamespace(stdout=value + "\nToday's daily maintenance has unresolved component failures: test")
            return SimpleNamespace(stdout='Child workflow 43408314983 completed with conclusion: failure.')
        def history(repo):
            if repo == m.COMMISSIONER:
                return [self.watch, self.child]
            return [self.parent] if repo == m.DAILY_REPO and not child_only else []
        def jobs(repo, run):
            return {self.parent['id']: parent_jobs, self.child['id']: self.child_jobs,
                    self.watch['id']: watch_jobs}[run['id']]
        with patch.dict(os.environ, {'WEEKLY_REPORT_EMAIL_TO': m.OWNER,
                'GITHUB_REPOSITORY': m.COMMISSIONER, 'PRIVATE_FAILURE_REPORTING_SINCE': ''}), \
             patch.object(sys, 'argv', ['report']), \
             patch.object(m, 'runs', side_effect=history), patch.object(m, 'jobs', side_effect=jobs), \
             patch.object(m, 'api', return_value=self.parent), patch.object(m.subprocess, 'run', side_effect=logs), \
             patch.object(m, 'notification_pending', return_value=False), \
             patch.object(m, 'verified_recovery', return_value=None), patch.object(m, 'cause_codes', return_value={}), \
             patch.object(m, 'correction_publication', return_value=None), \
             patch.object(m.mail, 'document', return_value=state), patch.object(m, 'save'), \
             patch.object(m.mail, 'deliver_once', side_effect=lambda state, key, send, save: send()), \
             patch.object(m.mail, 'send_email') as send:
            m.main()
        return state, [call.args[1] for call in send.call_args_list]

    def test_child_parent_watchdog_one_email_and_replay_sends_none(self):
        state, emails = self.replay()
        self.assertEqual(len(emails), 1)
        self.assertIn('build-dashboard', emails[0])
        self.assertEqual(self.replay(state=state)[1], [])

    def test_actual_nov13_two_independent_failures_not_three(self):
        state, emails = self.replay(independent=True)
        self.assertEqual(len(emails), 2)
        self.assertIn(ROSTER, emails[1])
        self.assertNotIn(DATA + ': ' + links.CHILD_STEPS[DATA], emails[1])
        self.assertEqual(self.replay(independent=True, state=state)[1], [])

    def test_independent_freshness_failure_still_emails(self):
        _, emails = self.replay(freshness=True)
        self.assertEqual(len(emails), 2)
        self.assertIn(FRESH, emails[-1])
        self.assertNotIn('check-dashboard-freshness: ' + CHECK, emails[-1])

    def test_missing_evidence_does_not_hide_watchdog_failure(self):
        _, emails = self.replay(missing_link=True)
        self.assertEqual(len(emails), 2)
        self.assertIn(CHECK, emails[-1])

    def test_child_receipt_alone_covers_dependency_but_not_roster(self):
        self.assertEqual(len(self.replay(child_only=True)[1]), 1)
        self.assertEqual(len(self.replay(child_only=True, independent=True)[1]), 2)

    def test_watchdog_discovers_parent_before_listing_no_later_duplicate(self):
        state, emails = self.replay(child_only=True, independent=True)
        self.assertEqual(len(emails), 2)
        self.assertEqual(self.replay(independent=True, state=state)[1], [])

    def test_watchdog_receipt_before_child_does_not_hide_new_parent_attempt(self):
        state = {'sent': {'watchdog': dict(maintenance_parent=str(self.parent['id']),
            maintenance_attempt=1, maintenance_components={DATA: 'failure'}, failed_steps=[m.WATCHDOG_STEP])}, 'checked': {}}
        self.assertEqual(self.replay(state=state)[1], [])
        self.assertEqual(links.covered_components(state, dict(self.parent, run_attempt=2), self.parent_jobs, lambda *a: None), set())

    def test_exact_identity_and_delivery_required(self):
        record = dict(daily_parent=str(self.parent['id']), daily_job=DATA, failed_at=self.child['updated_at'])
        state = {'sent': {f"{m.COMMISSIONER}:{self.child['id']}:1": record}}
        link = lambda parent, job: str(self.child['id']) if job['name'] == DATA else None
        self.assertEqual(links.covered_components(state, self.parent, self.parent_jobs, link), {DATA, WAIVER})
        for changes in [dict(daily_parent='99'), dict(daily_job=ROSTER), dict(failed_at='2026-11-12T10:20:28Z')]:
            altered = copy.deepcopy(state)
            next(iter(altered['sent'].values())).update(changes)
            self.assertEqual(links.covered_components(altered, self.parent, self.parent_jobs, link), set())
        self.assertEqual(links.covered_components({'delivery_incidents': state['sent']}, self.parent, self.parent_jobs, link), set())
        parent_state = {'sent': {f"{m.DAILY_REPO}:{self.parent['id']}:1":
            dict(affected_jobs={DATA: 'failure'}, failed_steps=[DATA + ': ' + links.CHILD_STEPS[DATA]])}}
        self.assertEqual(links.covered_components(parent_state, dict(self.parent, run_attempt=2), self.parent_jobs, lambda *a: None), set())
        parent_state['sent'][f"{m.DAILY_REPO}:{self.parent['id']}:1"]['failed_steps'] = []
        self.assertEqual(links.covered_components(parent_state, self.parent, self.parent_jobs, lambda *a: None), set())

    def test_deployed_watchdog_step_uses_same_evidence_and_fails_closed(self):
        source = (Path(__file__).parents[1] / '.github/workflows/dashboard_watchdog.yml').read_text()
        code = textwrap.dedent(source.split('        run: |\n', 1)[1].split('\n      - name:', 1)[0])
        class Clock(datetime):
            @classmethod
            def now(cls, tz=None):
                return datetime(2026, 11, 13, 12, 0, tzinfo=timezone.utc).astimezone(tz)
        parent = dict(self.parent, jobs_url='https://api.github.com/jobs')
        record = dict(daily_parent=str(parent['id']), daily_job=DATA, failed_at=self.child['updated_at'])
        state = {'sent': {f"{m.COMMISSIONER}:{self.child['id']}:1": record}}
        def response(request, **kwargs):
            url = request.full_url
            payload = {'workflow_runs': []}
            if 'daily_adl_league_maintenance.yml' in url:
                payload = {'workflow_runs': [parent]}
            elif '/jobs?' in url:
                payload = {'jobs': self.parent_jobs}
            return io.BytesIO(json.dumps(payload).encode())
        for covered in (True, False):
            with self.subTest(covered=covered), patch('datetime.datetime', Clock), \
                 patch('urllib.request.urlopen', side_effect=response), \
                 patch.dict(os.environ, {'GH_TOKEN': 'offline', 'GITHUB_STEP_SUMMARY': 'offline-summary'}), \
                 patch('builtins.open', mock_open(read_data=json.dumps(state if covered else {'sent': {}}))), \
                 patch.object(links.subprocess, 'run') as command:
                command.return_value.stdout = 'Child workflow 43408314983 completed with conclusion: failure.'
                if covered:
                    exec(compile(code, 'watchdog-step', 'exec'), {})
                else:
                    with self.assertRaisesRegex(SystemExit, 'unresolved component failures'):
                        exec(compile(code, 'watchdog-step', 'exec'), {})


if __name__ == '__main__':
    unittest.main()
