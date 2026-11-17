from copy import deepcopy
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import email_workflow_failures as reporter


def run(identifier, title, created, updated, conclusion='success'):
    return dict(id=identifier, workflow_id=123, run_attempt=1, _private_report=True,
                path='.github/workflows/guardian.yml', head_branch='main', status='completed',
                event='workflow_dispatch', display_title=title, conclusion=conclusion,
                created_at=created, updated_at=updated, html_url=f'https://example.test/runs/{identifier}')


def live_jobs():
    return [dict(name='guardian', conclusion='success', runner_id=1, steps=[
        dict(name=name, conclusion='success') for name in (
            'Verify Guardian software before live processing', 'Run npm run check',
            'Send private Guardian notifications', 'Preserve notification delivery receipts')])]


class GuardianBackupRecovery(unittest.TestCase):
    def setUp(self):
        self.old = run(44131638199, 'Chicago Bears Lineup Guardian - public-backup-1794934653',
                       '2026-11-17T16:57:35Z', '2026-11-17T17:02:42Z', 'cancelled')
        self.later = run(44132573249, 'Chicago Bears Lineup Guardian - public-backup-1794934956',
                         '2026-11-17T17:02:39Z', '2026-11-17T17:05:55Z')

    def test_actual_cancelled_pending_backup_recovers_from_real_overlapping_replacement(self):
        with patch.object(reporter, 'jobs', return_value=live_jobs()):
            self.assertEqual(reporter.verified_recovery(reporter.GUARDIAN, self.old, [], [self.later]), self.later)

    def test_nonce_changes_share_scope_but_diagnostics_do_not(self):
        self.assertFalse(reporter.guardian_operational_run(dict(self.old, display_title=None)))
        self.assertEqual(reporter.recovery_scope(reporter.GUARDIAN, self.old),
                         reporter.recovery_scope(reporter.GUARDIAN, self.later))
        for title in ('Chicago Bears Lineup Guardian - budget-slim-readonly-20261117',
                      'Chicago Bears Lineup Guardian - arbitrary-test'):
            other = dict(self.later, display_title=title)
            self.assertNotEqual(reporter.recovery_scope(reporter.GUARDIAN, self.old),
                                reporter.recovery_scope(reporter.GUARDIAN, other))

    def test_green_diagnostic_skipped_worker_or_missing_notification_receipt_cannot_recover(self):
        variants = []
        for name in ('Run npm run check', 'Send private Guardian notifications', 'Preserve notification delivery receipts'):
            value = live_jobs()
            next(s for s in value[0]['steps'] if s['name'] == name)['conclusion'] = 'skipped'
            variants.append(value)
        variants += [[], [dict(name='guardian', conclusion='success', steps=[dict(name='Run npm test', conclusion='success')])]]
        for value in variants:
            with self.subTest(jobs=value), patch.object(reporter, 'jobs', return_value=value):
                self.assertIsNone(reporter.verified_recovery(reporter.GUARDIAN, self.old, [], [self.later]))

    def test_started_uncertain_worker_cannot_use_overlapping_replacement(self):
        old_jobs = [dict(name='guardian', runner_id=1, conclusion='cancelled', steps=[])]
        with patch.object(reporter, 'jobs', return_value=live_jobs()):
            self.assertIsNone(reporter.verified_recovery(reporter.GUARDIAN, self.old, old_jobs, [self.later]))

    def test_delivered_incident_is_closed_without_resending_or_erasing_delivery(self):
        entry = {'subject': 'Already sent', 'sent_at': '2026-11-17T17:15:00Z'}
        with patch.object(reporter, 'jobs', side_effect=lambda repo, value: [] if value['id'] == self.old['id'] else live_jobs()):
            self.assertTrue(reporter.reconcile_guardian_delivery(reporter.GUARDIAN, self.old, [self.later], entry))
        self.assertEqual(entry['sent_at'], '2026-11-17T17:15:00Z')
        self.assertEqual(entry['resolved_at'], self.later['updated_at'])
        self.assertEqual(entry['recovery_url'], self.later['html_url'])
        with patch.object(reporter, 'jobs') as read:
            self.assertFalse(reporter.reconcile_guardian_delivery(reporter.GUARDIAN, self.old, [self.later], entry))
            read.assert_not_called()

    def test_missing_recovery_evidence_does_not_close_delivered_incident(self):
        entry = {'subject': 'Already sent'}
        with patch.object(reporter, 'jobs', side_effect=RuntimeError('API unavailable')):
            self.assertFalse(reporter.reconcile_guardian_delivery(reporter.GUARDIAN, self.old, [self.later], entry))
        self.assertNotIn('resolved_at', entry)

    def test_other_day_branch_workflow_mode_and_failed_replacements_do_not_recover(self):
        for later in (dict(self.later, created_at='2026-11-18T17:02:39Z', updated_at='2026-11-18T17:05:55Z'),
                      dict(self.later, head_branch='preview'), dict(self.later, workflow_id=456),
                      dict(self.later, path='.github/workflows/initial-lineup.yml'), dict(self.later, conclusion='failure')):
            with self.subTest(later=later), patch.object(reporter, 'jobs', return_value=live_jobs()):
                self.assertIsNone(reporter.verified_recovery(reporter.GUARDIAN, self.old, [], [later]))

    def test_diagnostic_cannot_reset_an_already_notified_real_outage(self):
        entry = dict(failed_steps=['Workflow ended with cancelled; detailed step results are unavailable.'],
                     failed_at=self.old['updated_at'])
        current = dict(self.later, id=3, created_at='2026-11-17T17:20:00Z', updated_at='2026-11-17T17:21:00Z', conclusion='failure')
        diagnostic = dict(self.later, display_title='Chicago Bears Lineup Guardian - budget-slim-readonly-20261117')
        with patch.object(reporter, 'jobs', return_value=live_jobs()):
            self.assertFalse(reporter.entry_recovered(reporter.GUARDIAN, current, deepcopy(entry), [diagnostic]))
            recovered = deepcopy(entry)
            self.assertTrue(reporter.entry_recovered(reporter.GUARDIAN, current, recovered, [self.later]))
            self.assertEqual(recovered['recovery_url'], self.later['html_url'])


if __name__ == '__main__':
    unittest.main()
