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


if __name__ == '__main__':
    unittest.main()
