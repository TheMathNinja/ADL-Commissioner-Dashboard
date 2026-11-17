from datetime import datetime, timezone
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import actions_budget as budget
import actions_billing as billing
import actions_runtime as runtime


class BudgetTests(unittest.TestCase):
    def test_slim_keeps_check_count_and_reserves_two_rounded_minutes_per_check(self):
        now = datetime(2026, 11, 17, 6, tzinfo=timezone.utc)
        kickoff = datetime(2026, 11, 22, 18, tzinfo=timezone.utc)
        value = budget.configured_projection(now, [kickoff], conservation=True, runner='ubuntu-slim')
        self.assertEqual(value['checkpointJobsRemaining'], 3)
        self.assertEqual(value['componentsThroughReset']['preKickoff'], 2)
        self.assertAlmostEqual(value['componentsThroughReset']['morningProtection'], 14 * 2 / 3)
        slower = budget.configured_projection(now, [kickoff], runner='ubuntu-slim',
                    measurements={'guardian.yml': {'meanRoundedMinutes': 1.5}})
        self.assertEqual(slower['componentsThroughReset']['preKickoff'], 4.5)

    def test_standard_arm_runner_uses_actual_price_without_removing_checks(self):
        now = datetime(2026, 11, 17, 6, tzinfo=timezone.utc)
        kickoff = datetime(2026, 11, 22, 18, tzinfo=timezone.utc)
        value = budget.configured_projection(now, [kickoff], conservation=True, runner='ubuntu-24.04-arm')
        self.assertEqual(value['checkpointJobsRemaining'], 3)
        self.assertEqual(value['componentsThroughReset']['preKickoff'], 2.5)
        self.assertAlmostEqual(value['componentsThroughReset']['morningProtection'], 14 * 5 / 6)
    def test_conservation_keeps_all_required_slots_and_honest_recovery_reserve(self):
        now = datetime(2026, 11, 17, 6, tzinfo=timezone.utc)
        kickoff = datetime(2026, 11, 22, 18, tzinfo=timezone.utc)
        normal = budget.configured_projection(now, [kickoff])
        held = budget.configured_projection(now, [kickoff], conservation=True)
        for key in ('preKickoff', 'morningProtection'):
            self.assertEqual(normal['componentsThroughReset'][key], held['componentsThroughReset'][key])
        for key in ('chiSync', 'weeklyCloudAudits', 'additionalUpgradePreflights'):
            self.assertEqual(held['componentsThroughReset'][key], 0)
        self.assertEqual(held['componentsThroughReset']['forecastRequestsAndInspections'], 4)
        self.assertEqual(held['componentsThroughReset']['changesRetriesAndColdTestRuns'], 4)
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
        with patch.object(billing, 'read', side_effect=billing.BillingUnavailable('billing_read_credential_missing')), patch.object(runtime, 'measure', return_value={}), patch.object(budget, 'upcoming_kickoffs', return_value=[]), patch.object(budget, 'persist') as persist:
            value = budget.review(api, datetime.now(timezone.utc), dry=True)
            self.assertEqual(value['billing']['status'], 'unavailable')
            self.assertIsNone(value['estimatedUsed'])
            self.assertIsNone(value['projectedMonthEnd'])
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

    def test_measurements_raise_checkpoint_and_audit_forecast(self):
        now = datetime(2026, 11, 17, 6, tzinfo=timezone.utc)
        kickoff = datetime(2026, 11, 22, 18, tzinfo=timezone.utc)
        measurements = {name: {'meanRoundedMinutes': value} for name, value in
                        [('guardian.yml', 2), ('initial-lineup.yml', 2), ('sync_chi_team_tools.yml', 3),
                         ('league-audit.yml:contracts', 2), ('league-audit.yml:guardian', 3)]}
        value = budget.configured_projection(now, [kickoff], measurements=measurements)
        self.assertEqual(value['componentsThroughReset']['preKickoff'], 6)
        self.assertEqual(value['componentsThroughReset']['weeklyCloudAudits'], 10)
        self.assertEqual(value['unmeasuredScheduledWorkflows'], [])

    def test_billing_excludes_public_discounts_and_storage_from_compute_pool(self):
        now = datetime(2026, 11, 17, tzinfo=timezone.utc)
        def row(repo, gross, unit='minutes', sku='Actions Linux', net=0):
            return dict(product='Actions', date='2026-11-16', repositoryName=repo,
                        sku=sku, grossAmount=gross, netAmount=net, unitType=unit)
        rows = [row('private', 11.14), row('public', 100), row('private', .24, 'GB', 'storage')]
        def fetch(path):
            return {'login': 'TheMathNinja', 'plan': {'name': 'free'}} if path == 'user' else {'usageItems': rows}
        value = billing.read(lambda repo, path: {'private': repo.endswith('/private')}, now, fetch)
        self.assertEqual(value['remainingComputeUSD'], .86)
        self.assertAlmostEqual(value['remainingLinuxEquivalentMinutes'], 143.333333, places=5)
        self.assertEqual(value['billedActionsUSD'], 0)

    def test_billing_rejects_wrong_account_missing_visibility_and_malformed_reports(self):
        now = datetime(2026, 11, 17, tzinfo=timezone.utc)
        profile = {'login': 'TheMathNinja', 'plan': {'name': 'free'}}
        for report in ({}, {'usageItems': [], 'truncated': True}, {'usageItems': [dict(
                product='Actions', date='2026-11-01', sku='Actions Linux', grossAmount=1,
                netAmount=0, unitType='minutes', repositoryName='private')]}):
            with self.subTest(report=report), self.assertRaises(billing.BillingUnavailable):
                billing.read(lambda *args: {}, now, lambda path: profile if path == 'user' else report)
        with self.assertRaises(billing.BillingUnavailable):
            billing.read(None, now, lambda path: {'login': 'someone-else'})
        for value in ('NaN', -1, None, 'garbage'):
            with self.assertRaises(billing.BillingUnavailable):
                billing.number(value)

    def test_unknown_compute_sku_never_becomes_a_false_zero_balance(self):
        now = datetime(2026, 11, 17, tzinfo=timezone.utc)
        profile = {'login': 'TheMathNinja', 'plan': {'name': 'free'}}
        report = {'usageItems': [dict(product='Actions', date='2026-11-01', sku='new runner',
                    grossAmount=11, netAmount=0, unitType='minutes', repositoryName='private')]}
        with self.assertRaisesRegex(billing.BillingUnavailable, 'sku_not_verified'):
            billing.read(lambda *args: {'private': True}, now, lambda path: profile if path == 'user' else report)

    def test_billing_transport_retries_but_credentials_fail_immediately(self):
        from urllib.error import URLError
        import io
        from unittest.mock import MagicMock
        response = MagicMock()
        response.__enter__.return_value = io.StringIO('{"ok":true}')
        with patch.dict('os.environ', ACTIONS_BILLING_TOKEN='test-only'), patch.object(
                billing, 'urlopen', side_effect=[URLError('temporary'), response]) as request, patch.object(billing.time, 'sleep'):
            self.assertEqual(billing.get('user'), {'ok': True})
            self.assertEqual(request.call_count, 2)
        with patch.dict('os.environ', ACTIONS_BILLING_TOKEN='test-only'), patch.object(
                billing, 'urlopen', side_effect=HTTPError('https://example.test', 403, 'Forbidden', {}, None)) as request:
            with self.assertRaisesRegex(billing.BillingUnavailable, 'billing_http_403'):
                billing.get('user')
            self.assertEqual(request.call_count, 1)

    def test_repository_visibility_uses_root_endpoint_without_trailing_slash(self):
        import email_workflow_failures as reporter
        import io
        from unittest.mock import MagicMock
        response = MagicMock()
        response.__enter__.return_value = io.StringIO('{"private":true}')
        with patch.dict('os.environ', PRIVATE_REPORT_TOKEN='test-only'), patch.object(
                reporter.urllib.request, 'urlopen', return_value=response) as request:
            self.assertTrue(reporter.api(reporter.GUARDIAN, '')['private'])
        self.assertEqual(request.call_args.args[0].full_url, 'https://api.github.com/repos/' + reporter.GUARDIAN)

    def test_runtime_rounds_each_allocated_job_before_averaging(self):
        job = dict(runner_id=1, labels=['ubuntu-24.04'], conclusion='success',
                   started_at='2026-11-17T00:00:00Z', completed_at='2026-11-17T00:01:01Z')
        self.assertEqual(runtime.job_minutes([job, job]), 4)
        self.assertEqual(runtime.job_minutes([dict(job, runner_id=0)]), 0)
        with self.assertRaises(ValueError):
            runtime.job_minutes([dict(job, labels=['unknown'])])

    def test_runtime_fingerprint_ignores_generated_data_but_not_scheduler_changes(self):
        def tree(sha):
            return {'tree': [dict(path='scheduler/Code.gs', sha=sha, type='blob', mode='100644'),
                             dict(path='data/live.json', sha=sha, type='blob', mode='100644')]}
        self.assertNotEqual(runtime.fingerprint(tree('a'), 'guardian.yml'), runtime.fingerprint(tree('b'), 'guardian.yml'))
        one = tree('a')
        two = tree('a')
        two['tree'][1]['sha'] = 'changed'
        self.assertEqual(runtime.fingerprint(one, 'guardian.yml'), runtime.fingerprint(two, 'guardian.yml'))

    def test_measure_ignores_skips_and_cache_probes_and_old_software(self):
        now = datetime(2026, 11, 17, 6, tzinfo=timezone.utc)
        def run(identifier, sha='new', conclusion='success'):
            return dict(id=identifier, head_sha=sha, conclusion=conclusion, status='completed',
                        created_at='2026-11-17T00:00:00Z')
        calls = []
        def api(repo, endpoint):
            calls.append(endpoint)
            if endpoint.startswith('commits/'):
                return {'commit': {'tree': {'sha': endpoint.split('/')[-1]}}}
            if endpoint.startswith('git/trees/'):
                sha = 'old' if '/old?' in endpoint else 'new'
                return {'tree': [dict(path='src/main.js', sha=sha, type='blob')]}
            if '/runs?' in endpoint:
                return {'workflow_runs': [run(i, conclusion='skipped') for i in range(20)] +
                        [run(21, 'old'), run(22), run(23)]}
            steps = [] if '/22/' in endpoint else [{'name': 'Run npm run check', 'conclusion': 'success'}]
            return {'jobs': [dict(runner_id=1, labels=['ubuntu-24.04'], name='guardian', steps=steps,
                                 started_at='2026-11-17T00:00:00Z', completed_at='2026-11-17T00:01:01Z')]}
        with patch.object(runtime, 'WORKFLOWS', ('guardian.yml',)):
            measured = runtime.measure(api, now)
        self.assertEqual(measured['guardian.yml']['sampleCount'], 1)
        self.assertEqual(measured['guardian.yml']['meanRoundedMinutes'], 2)
        self.assertFalse(any('/21/jobs' in endpoint for endpoint in calls))

    def test_review_uses_actual_billing_not_prior_sampled_usage(self):
        now = datetime(2026, 11, 17, 6, tzinfo=timezone.utc)
        actual = dict(status='verified', checkedAt=now.isoformat(), includedMinutes=2000,
                      usedLinuxEquivalentMinutes=1800, remainingLinuxEquivalentMinutes=200)
        with patch.object(budget, 'decode', return_value={'estimatedUsed': 2365}), patch.object(
                billing, 'read', return_value=actual), patch.object(runtime, 'measure', return_value={}), patch.object(
                budget, 'upcoming_kickoffs', return_value=[]), patch.object(budget, 'persist') as persist:
            value = budget.review(lambda *args: {'sha': 'old'}, now, dry=True)
        self.assertEqual(value['estimatedUsed'], 1800)
        self.assertEqual(value['remainingMinutes'], 200)
        self.assertEqual(value['projectedMonthEnd'], 1800 + value['planProjection']['minutesThroughReset'])
        self.assertFalse(value['forecastVerified'])
        persist.assert_not_called()

    def test_failed_billing_retains_but_never_relabels_last_verified_balance(self):
        now = datetime(2026, 11, 17, 6, tzinfo=timezone.utc)
        old = {'status': 'verified', 'checkedAt': '2026-11-15T06:00:00Z', 'remainingLinuxEquivalentMinutes': 200}
        with patch.object(budget, 'decode', return_value={'billing': old}), patch.object(
                billing, 'read', side_effect=billing.BillingUnavailable('billing_http_403')), patch.object(
                runtime, 'measure', return_value={}), patch.object(budget, 'upcoming_kickoffs', return_value=[]):
            value = budget.review(lambda *args: {'sha': 'old'}, now, dry=True)
        self.assertEqual(value['billing']['lastVerified'], old)
        self.assertIsNone(value['remainingMinutes'])
        self.assertIsNone(value['projectedMonthEnd'])

    def test_new_billing_month_invalidates_daily_cache(self):
        now = datetime(2026, 12, 1, 6, tzinfo=timezone.utc)
        prior = dict(schemaVersion=2, month='2026-11', checkedAt='2026-11-30T23:59:00Z',
                     planProjection={'version': 3}, billing={'status': 'verified'})
        actual = dict(status='verified', checkedAt=now.isoformat(), includedMinutes=2000,
                      usedLinuxEquivalentMinutes=0, remainingLinuxEquivalentMinutes=2000)
        with patch.object(budget, 'decode', return_value=prior), patch.object(
                billing, 'read', return_value=actual) as read, patch.object(runtime, 'measure', return_value={}), patch.object(
                budget, 'upcoming_kickoffs', return_value=[]):
            value = budget.review(lambda *args: {'sha': 'old'}, now, dry=True)
        read.assert_called_once()
        self.assertEqual(value['month'], '2026-12')
        self.assertEqual(value['estimatedUsed'], 0)


if __name__ == '__main__':
    unittest.main()
