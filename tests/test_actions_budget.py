from datetime import datetime, timezone
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import actions_budget as budget


class BudgetTests(unittest.TestCase):
    def test_faster_jobs_do_not_erase_historical_consumption(self):
        now = datetime(2026, 11, 1, 12, tzinfo=timezone.utc)
        path = '.github/workflows/refresh_chi_team_tools.yml'
        previous = {'month': '2026-11', 'workflows': [{'workflow': path, 'runs': 2, 'estimatedMinutes': 180}]}
        def api(repo, endpoint):
            if '/jobs?' in endpoint:
                return {'jobs': [{'started_at': '2026-11-01T00:00:00Z', 'completed_at': '2026-11-01T00:00:01Z'}]}
            return {'workflow_runs': [{'id': n, 'path': path, 'status': 'completed', 'conclusion': 'success', 'created_at': '2026-11-01T00:00:00Z'} for n in (1, 2, 3)]}
        self.assertEqual(budget.collect(api, now, prior=previous)['estimatedUsed'], 181)
    def test_first_run_handles_api_wrapped_not_found(self):
        def api(repo, path):
            try:
                raise HTTPError('https://example.test', 404, 'Not Found', {}, None)
            except HTTPError as error:
                raise RuntimeError('GitHub resource unavailable') from error
        with patch.object(budget, 'collect', return_value={'estimate': True}), patch.object(budget, 'upcoming_kickoffs', return_value=[]), patch.object(budget, 'persist') as persist:
            self.assertEqual(budget.review(api, datetime.now(timezone.utc), dry=True), {'estimate': True})
            persist.assert_not_called()

    def test_forward_plan_uses_three_slots_and_rounds_allowances_not_old_pace(self):
        now = datetime(2026, 11, 17, 6, tzinfo=timezone.utc)
        kickoff = datetime(2026, 11, 22, 18, tzinfo=timezone.utc)
        value = budget.configured_projection(now, [kickoff, kickoff])
        self.assertEqual(value['checkpointJobsRemaining'], 3)
        self.assertEqual(value['componentsThroughReset']['preKickoff'], 3)
        self.assertEqual(value['weeklyAuditDates'], ['2026-11-18', '2026-11-25'])
        self.assertEqual(value['componentsThroughReset']['weeklyCloudAudits'], 6)
        self.assertEqual(value['resetAtAssumed'], '2026-12-01T00:00:00-05:00')
        self.assertTrue(value['additionalDemandExcluded'])

    def test_budget_configuration_cannot_drift_from_checkpoint_policy(self):
        import json
        plan = json.loads(budget.PLAN_PATH.read_text())
        plan['checkpointOffsetsMinutes'] = [90, 45, 15]
        with self.assertRaisesRegex(ValueError, 'disagree'):
            budget.configured_projection(datetime.now(timezone.utc), [], plan)

    def test_removed_cloud_audit_duplicate_and_worker_test_cache_are_contracts(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / '.github/workflows/automation-preflight.yml').read_text()
        self.assertIn('30 8 * * 3', source)
        self.assertNotIn('30 8 * * *', source)

    def test_authentication_failure_is_not_treated_as_empty_history(self):
        def api(repo, path):
            raise HTTPError('https://example.test', 403, 'Forbidden', {}, None)
        with self.assertRaises(HTTPError):
            budget.review(api, datetime.now(timezone.utc))

    def test_round_each_job_and_skip_unassigned(self):
        rows = [{'started_at': '2026-11-01T00:00:00Z', 'completed_at': '2026-11-01T00:00:01Z',
                 'labels': ['ubuntu-24.04'], 'conclusion': 'success'}] * 2
        self.assertEqual(budget.minutes(rows), 2)
        self.assertEqual(budget.minutes([dict(rows[0], conclusion='skipped')]), 0)
        self.assertEqual(budget.minutes([dict(rows[0], labels=['windows-latest'])]), 2)

    def test_handoff_excludes_only_coverage_from_future_not_history(self):
        now = datetime(2026, 11, 2, 12, tzinfo=timezone.utc)
        def api(repo, path):
            if '/jobs?' in path:
                return {'jobs': [{'started_at': '2026-11-01T00:00:00Z', 'completed_at': '2026-11-01T00:00:01Z'}]}
            return {'workflow_runs': [{'id': 1, 'path': '.github/workflows/guardian-coverage.yml',
                     'status': 'completed', 'conclusion': 'success', 'created_at': '2026-11-01T00:00:00Z'}]}
        value = budget.collect(api, now, runner_handoff=True)
        self.assertGreater(value['estimatedUsed'], 0)
        self.assertEqual(value['projectedDailyMinutes'], 0)
        self.assertIn('not GitHub billing', value['source'])


if __name__ == '__main__':
    unittest.main()
