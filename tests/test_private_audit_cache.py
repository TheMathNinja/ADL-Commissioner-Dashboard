import copy
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import private_audit_cache as cache


def trees():
    return {k: {'tree': [{'path': 'scripts/worker.py', 'type': 'blob', 'sha': 'source', 'mode': '100644'}]}
            for k in cache.REPOS}


class AuditCacheTests(unittest.TestCase):
    def setUp(self):
        policy = patch('private_actions_policy.paused', return_value=False)
        policy.start()
        self.addCleanup(policy.stop)
    def test_launcher_rechecks_success_and_reuses_without_dispatch(self):
        import run_private_preflight as launcher
        now = datetime.now(timezone.utc)
        good = {'schemaVersion': 1, 'fingerprint': 'match', 'conclusion': 'success', 'runId': '123', 'completedAt': now.isoformat()}
        with patch.object(cache, 'inputs', return_value=({'guardian': 'sha'}, 'match')), patch.object(cache, 'load', return_value=({'contracts': good}, 'sha')), patch.object(launcher, 'read_state', return_value={'status': 'completed', 'conclusion': 'success'}), patch.object(launcher.subprocess, 'check_output') as dispatch:
            launcher.run('contracts', use_cache=True)
            dispatch.assert_not_called()

    def test_all_four_repositories_and_models_invalidate_cache(self):
        original = trees()
        expected = cache.fingerprint(original)
        for key in cache.REPOS:
            changed = copy.deepcopy(original)
            changed[key]['tree'][0]['sha'] = 'changed'
            self.assertNotEqual(expected, cache.fingerprint(changed))
        changed = copy.deepcopy(original)
        changed['adl']['tree'].append({'path': 'data/adl_scoring_model.json', 'type': 'blob', 'sha': 'new'})
        self.assertNotEqual(expected, cache.fingerprint(changed))

    def test_only_declared_operational_receipts_are_excluded(self):
        original = trees()
        changed = copy.deepcopy(original)
        changed['guardian']['tree'].extend({'path': p, 'type': 'blob', 'sha': 'changed'} for p in ('data/guardian_health.json', 'data/audits/run.json', 'docs/audits/run.html'))
        self.assertEqual(cache.fingerprint(original), cache.fingerprint(changed))
        changed['guardian']['tree'].append({'path': 'test/fixtures/audit.json', 'type': 'blob', 'sha': 'changed'})
        self.assertNotEqual(cache.fingerprint(original), cache.fingerprint(changed))

    def test_missing_failed_stale_future_or_changed_receipts_never_reused(self):
        now = datetime(2026, 11, 16, tzinfo=timezone.utc)
        good = {'schemaVersion': 1, 'fingerprint': 'match', 'conclusion': 'success', 'runId': '123', 'completedAt': now.isoformat()}
        self.assertTrue(cache.reusable(good, 'match', now))
        for value in ({}, dict(good, conclusion='failure'), dict(good, fingerprint='different'),
                      dict(good, completedAt=(now - timedelta(hours=24)).isoformat()),
                      dict(good, completedAt=(now + timedelta(seconds=1)).isoformat())):
            self.assertFalse(cache.reusable(value, 'match', now))

    def test_truncated_git_metadata_fails_closed(self):
        value = trees()
        value['guardian']['truncated'] = True
        with self.assertRaises(RuntimeError):
            cache.fingerprint(value)

    def test_existing_exact_input_audit_recovers_lost_receipt(self):
        now = datetime.now(timezone.utc)
        run = dict(id=123, event='workflow_dispatch', status='in_progress', conclusion=None,
                   display_title='Private league audit - contracts - source parent - inputs ' + 'a'*64,
                   created_at=now.isoformat())
        with patch.object(cache, 'api', return_value={'workflow_runs': [run]}):
            self.assertEqual(cache.existing('contracts', 'a'*64)['id'], 123)
            self.assertIsNone(cache.existing('guardian', 'a'*64))
            self.assertIsNone(cache.existing('contracts', 'b'*64))
            run.update(status='completed', conclusion='failure')
            self.assertIsNone(cache.existing('contracts', 'a'*64))
            run['conclusion'] = 'success'
            self.assertEqual(cache.existing('contracts', 'a'*64)['id'], 123)
            run['created_at'] = (now - timedelta(days=2)).isoformat()
            self.assertIsNone(cache.existing('contracts', 'a'*64))

    def test_paused_launcher_never_dispatches_or_records_a_pass(self):
        import run_private_preflight as launcher
        with patch('private_actions_policy.paused', return_value=True), patch.object(cache, 'inputs') as inputs, patch.object(cache, 'record') as record, patch.object(launcher.subprocess, 'check_output') as dispatch:
            launcher.run('contracts', use_cache=True)
        inputs.assert_not_called()
        dispatch.assert_not_called()
        record.assert_not_called()


if __name__ == '__main__':
    unittest.main()
