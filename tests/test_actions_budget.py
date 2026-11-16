from datetime import datetime, timezone
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import actions_budget as budget


class BudgetTests(unittest.TestCase):
    def test_first_run_handles_api_wrapped_not_found(self):
        def api(repo, path):
            try:
                raise HTTPError('https://example.test', 404, 'Not Found', {}, None)
            except HTTPError as error:
                raise RuntimeError('GitHub resource unavailable') from error
        with patch.object(budget, 'collect', return_value={'estimate': True}), patch.object(budget, 'persist') as persist:
            self.assertEqual(budget.review(api, datetime.now(timezone.utc), dry=True), {'estimate': True})
            persist.assert_not_called()

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
