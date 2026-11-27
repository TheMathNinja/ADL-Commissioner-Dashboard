import copy
from datetime import datetime, timezone
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from guardian_incidents import validate_coverage, owned_check_failure, owned_startup_failure, report_missing_checks
from email_delivery_state import deliver_once, DeliveryUncertain


class GuardianIncidents(unittest.TestCase):
    def test_nov15_failed_test_runs_and_both_leagues_share_one_delivery(self):
        self.coverage['activatedAt']='2026-11-15T20:00:00Z'
        for incident in self.coverage['incidents'].values():
            incident.update(lastVerified='2026-11-15T20:30:32Z', kickoff='2026-11-15T21:25:00Z')
        jobs=[{'name':'guardian','steps':[{'name':'Run npm test','conclusion':'failure'},
              {'name':'Check configuration','conclusion':'skipped'},
              {'name':'Run npm run check','conclusion':'skipped'},
              {'name':'Commit audit state','conclusion':'skipped'},
              {'name':'Archive exact roster checks','conclusion':'success'},
              {'name':'Publish private roster audit','conclusion':'skipped'},
              {'name':'Send private Guardian notifications','conclusion':'skipped'},
              {'name':'Preserve notification delivery receipts','conclusion':'skipped'},
              {'name':'Post Run actions/checkout@v5','conclusion':'success'},
              {'name':'Complete job','conclusion':'success'}]}]
        for run_id, minute in [(43758870359,34),(43759326271,39),(43759782849,44),(43760237046,49)]:
            run=dict(self.run,id=run_id,conclusion='failure',created_at=f'2026-11-15T20:{minute}:44Z')
            self.assertTrue(owned_startup_failure(run,jobs,self.coverage))
            self.report()
        self.assertEqual(len(self.messages),1)
        for incident in self.coverage['incidents'].values():
            incident.update(status='resolved',resolvedAt='2026-11-15T20:56:01Z')
        self.assertTrue(owned_startup_failure(run,jobs,self.coverage))
        self.report();self.assertEqual(len(self.messages),1)
        self.assertFalse(owned_startup_failure(dict(run,created_at='2026-11-15T21:00:00Z'),jobs,self.coverage))

    def test_startup_ownership_never_hides_independent_failure(self):
        jobs=[{'name':'guardian','steps':[{'name':'Run npm test','conclusion':'failure'},
              {'name':'Run npm run check','conclusion':'skipped'}]}]
        run=dict(self.run,conclusion='failure')
        self.assertTrue(owned_startup_failure(run,jobs,self.coverage))
        for name in ['Run npm run check','Commit audit state','Send private Guardian notifications']:
            changed=copy.deepcopy(jobs);changed[0]['steps'][0]['name']=name
            self.assertFalse(owned_startup_failure(run,changed,self.coverage))
        changed=copy.deepcopy(jobs);changed[0]['steps'][1]['conclusion']='success'
        self.assertFalse(owned_startup_failure(run,changed,self.coverage))
        self.assertFalse(owned_startup_failure(dict(run,path='preflight.yml'),jobs,self.coverage))
        self.assertFalse(owned_startup_failure(run,jobs,dict(self.coverage,incidents={})))

    def setUp(self):
        self.coverage = {'alertOwner':'commissioner-v1', 'checkedAt':'2026-11-15T17:00:00Z',
                         'activatedAt':'2026-11-15T16:00:00Z', 'incidents':{}}
        for league in ('ADL', 'FAFL'):
            self.coverage['incidents'][league] = {'key':league, 'league':league, 'week':10,
                'mode':'monitor', 'kickoff':'2026-11-15T18:00:00Z', 'status':'open', 'delivery':'pending'}
        self.state = {'sent':{}}
        self.messages = []
        self.saves = []
        self.run = {'id':100, 'run_attempt':1, 'path':'.github/workflows/guardian.yml', 'created_at':'2026-11-15T16:58:00Z'}
        self.jobs = [{'name':'guardian', 'steps':[{'name':'Run npm run check', 'conclusion':'failure'}]}]
        self.audit = {'id':'100-1-monitor', 'dryRun':False, 'runMode':'monitor', 'completedAt':'2026-11-15T16:59:00Z',
                      'results':[{'key':'ADL', 'week':10, 'status':'error', 'failureClass':'read_only_check'}]}

    def report(self, sender=None, dry=False):
        report_missing_checks(self.coverage, self.state, dry, deliver_once,
                              lambda s:self.saves.append(copy.deepcopy(s)), sender or (lambda *m:self.messages.append(m)))

    def test_both_leagues_one_message_with_durable_claim(self):
        self.report(); self.report()
        self.assertEqual(len(self.messages),1)
        self.assertIn('ADL Week 10', self.messages[0][1])
        self.assertIn('FAFL Week 10', self.messages[0][1])
        self.assertEqual(len(self.state['sent']),2)
        self.assertTrue(any(v['status']=='sending' for s in self.saves for v in s.get('delivery_receipts',{}).values()))

    def test_schedule_placeholder_is_not_reported_as_a_missed_check(self):
        del self.coverage['incidents']['ADL']
        self.coverage['incidents']['FAFL'].update(
            week=0, mode='schedule', kickoff='2026-11-26T19:57:10-05:00')
        self.report(); self.report()
        self.assertEqual(len(self.messages), 1)
        subject, body, _ = self.messages[0]
        self.assertIn('Schedule verification unavailable', subject)
        self.assertIn('FAFL: schedule lookup unavailable since 2026-11-27T00:57:10+00:00', body)
        self.assertNotIn('Week 0', body)
        self.assertNotIn('No verified Guardian check', body)

    def test_schedule_and_real_deadline_failure_are_distinct_in_same_email(self):
        self.coverage['incidents']['FAFL'].update(week=0, mode='schedule')
        self.report()
        self.assertEqual(len(self.messages), 1)
        body = self.messages[0][1]
        self.assertIn('No verified Guardian check within the required deadline', body)
        self.assertIn('ADL Week 10: monitor', body)
        self.assertIn('FAFL: schedule lookup unavailable', body)
        self.assertNotIn('FAFL Week 0', body)

    def test_crash_after_acceptance_does_not_resend(self):
        self.report()
        self.state['sent'] = {}
        self.report()
        self.assertEqual(len(self.messages),1)

    def test_ambiguous_send_not_retried(self):
        def fail(*args):
            self.messages.append(args)
            raise TimeoutError('SMTP accepted but connection lost')
        with self.assertRaises(TimeoutError):self.report(fail)
        with self.assertRaises(DeliveryUncertain):self.report()
        self.assertEqual(len(self.messages),1)

    def test_recovery_before_scan_and_legacy_delivery(self):
        self.coverage['incidents']['ADL']['status']='resolved'
        self.coverage['incidents']['FAFL']['delivery']='sent'
        self.report()
        self.assertEqual(self.messages,[])
        self.assertTrue(self.state['sent']['guardian-coverage:FAFL']['migrated'])

    def test_legacy_uncertainty_not_replayed(self):
        self.coverage['incidents']['ADL']['delivery']='sending'
        with self.assertRaises(RuntimeError):self.report()
        self.assertEqual(self.messages,[])

    def test_dry_run_no_delivery_or_saves(self):
        self.report(dry=True)
        self.assertEqual(self.messages,[]); self.assertEqual(self.saves,[])

    def test_stale_unknown_future_ownership_refused(self):
        now=datetime(2026,11,15,17,5,tzinfo=timezone.utc)
        self.assertEqual(len(validate_coverage(self.coverage,now)),2)
        for key,value in [('alertOwner','unknown'),('checkedAt','2026-11-15T16:00:00Z'),('checkedAt','2026-11-15T18:00:00Z')]:
            with self.subTest(key=key,value=value):
                with self.assertRaises(RuntimeError):validate_coverage({**self.coverage,key:value},now)

    def test_exact_read_only_failure_owned_by_gap(self):
        self.assertTrue(owned_check_failure(self.run,self.jobs,self.audit,self.coverage))
        for change in [{'dryRun':True},{'id':'100-2-monitor'},{'completedAt':None},{'error':'login error'},
                       {'rosterManagement':{'status':'error'}},{'lineupChanges':[{'league':'ADL'}]}]:
            with self.subTest(change=change):
                self.assertFalse(owned_check_failure(self.run,self.jobs,{**self.audit,**change},self.coverage))

    def test_independent_and_unknown_failures_retained(self):
        for change in [{'failureClass':'write_attempted'},{'failureClass':None},{'week':9},{'key':'other'}]:
            audit={**self.audit,'results':[{**self.audit['results'][0],**change}]}
            self.assertFalse(owned_check_failure(self.run,self.jobs,audit,self.coverage))
        self.jobs[0]['steps'].append({'name':'Send notifications','conclusion':'failure'})
        self.assertFalse(owned_check_failure(self.run,self.jobs,self.audit,self.coverage))

    def test_unrelated_times_and_resolved_gap_not_claimed(self):
        for created in ['2026-11-15T15:00:00Z','2026-11-15T19:00:00Z']:
            self.assertFalse(owned_check_failure({**self.run,'created_at':created},self.jobs,self.audit,self.coverage))
        self.coverage['incidents']['ADL']['status']='resolved'
        self.assertFalse(owned_check_failure(self.run,self.jobs,self.audit,self.coverage))


if __name__ == '__main__':unittest.main()
