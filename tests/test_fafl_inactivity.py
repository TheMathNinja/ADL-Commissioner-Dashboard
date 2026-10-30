import copy,json,sys,unittest
from datetime import datetime,timedelta,timezone
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parents[1]/'scripts'))
import fafl_inactivity as m
from unittest.mock import Mock,patch

class InactivityTests(unittest.TestCase):
    def setUp(self):
        self.now=datetime.fromisoformat('2026-10-30T00:00:00+00:00')
        self.f={'id':'0001','name':'Test Franchise','owner_name':'Test Owner','username':'owner','email':'owner@example.com','lastVisit':str(int((self.now-timedelta(hours=1)).timestamp()))}
        self.config={'season':2026,'lineup_tracking_from_week':8,'initial_auction':{'starts_at':None,'ends_at':None}}
        self.windows={1:{'first':self.now-timedelta(days=50),'close':self.now-timedelta(days=45)},8:{'first':self.now-timedelta(hours=1),'close':self.now+timedelta(days=4)},17:{'first':self.now+timedelta(days=60),'close':self.now+timedelta(days=65)}}
        self.lineups={8:{'0001':{'status':'submitted','submitted_at':m.iso(self.now-timedelta(minutes=30))}}}
    def run_check(self,state=None,now=None,bids=None):
        return m.evaluate(state or{},[self.f],self.lineups,self.windows,bids,self.config,now or self.now)
    def stale(self):self.f['lastVisit']=str(int((self.now-timedelta(days=7)).timestamp()))
    def test_seven_days_exact_threshold_and_no_early_violation(self):
        self.f['lastVisit']=str(int((self.now-timedelta(days=7)+timedelta(seconds=1)).timestamp()))
        self.assertFalse(self.run_check()['incidents']);self.stale()
        self.assertEqual(len(self.run_check()['incidents']),1)
    def test_repeated_checks_are_one_incident_and_timer_waits_for_delivery(self):
        self.stale();first=self.run_check();again=self.run_check(first,self.now+timedelta(hours=8))
        self.assertEqual(len(again['incidents']),1);incident=next(iter(again['incidents'].values()))
        self.assertEqual(incident['count'],1);self.assertNotIn('deadline',incident)
    def test_login_recovers_and_new_episode_gets_another_warning_not_immediate_forfeiture(self):
        self.stale();state=self.run_check();self.f['lastVisit']=str(int(self.now.timestamp()))
        state=self.run_check(state,self.now+timedelta(seconds=1));self.assertEqual(next(iter(state['incidents'].values()))['status'],'resolved')
        state=self.run_check(state,self.now+timedelta(days=7));self.assertEqual(len(state['incidents']),2)
        self.assertTrue(any(i['count']==2 and i['status']=='pending_notice'for i in state['incidents'].values()))
    def test_overdue_requires_fresh_evidence_and_late_login_is_not_silently_cleared(self):
        self.stale();state=self.run_check();incident=next(iter(state['incidents'].values()));incident.update(status='watch',deadline=m.iso(self.now+timedelta(hours=120)))
        later=self.now+timedelta(hours=121);self.f['lastVisit']=''
        unknown=self.run_check(state,later);self.assertEqual(next(iter(unknown['incidents'].values()))['status'],'watch');self.assertTrue(unknown['coverage'])
        self.f['lastVisit']=str(int((later-timedelta(minutes=10)).timestamp()))
        late=self.run_check(state,later);self.assertEqual(next(iter(late['incidents'].values()))['status'],'resolved_late')
    def test_upcoming_missing_lineup_is_not_an_infraction(self):
        self.lineups[8]['0001']={'status':'missing','submitted_at':None}
        self.assertFalse(self.run_check()['incidents'])
    def test_completed_missing_lineup_is_one_infraction(self):
        self.lineups[8]['0001']={'status':'missing','submitted_at':None}
        state=self.run_check(now=self.now+timedelta(days=5));self.assertEqual(len(state['incidents']),1)
        again=self.run_check(state,self.now+timedelta(days=6));self.assertEqual(len(again['incidents']),1)
    def test_auction_and_lineup_counts_are_separate(self):
        self.config['initial_auction']={'starts_at':m.iso(self.now-timedelta(hours=24)),'ends_at':m.iso(self.now+timedelta(days=10))}
        state=self.run_check(bids=[]);self.assertEqual(next(iter(state['incidents'].values()))['rule'],'auction')
        self.lineups[8]['0001']={'status':'missing','submitted_at':None};self.config['initial_auction']={'starts_at':None,'ends_at':None}
        state=self.run_check(state,self.now+timedelta(days=5));lineup=next(i for i in state['incidents'].values()if i['rule']=='lineup')
        self.assertEqual(lineup['count'],1);self.assertNotEqual(lineup['status'],'review')
    def test_losing_auction_bid_resets_activity_and_unknown_history_does_not_accuse(self):
        self.config['initial_auction']={'starts_at':m.iso(self.now-timedelta(days=3)),'ends_at':m.iso(self.now+timedelta(days=3))}
        bid={'franchise':'0001','timestamp':str(int((self.now-timedelta(hours=1)).timestamp())),'type':'AUCTION_BID'}
        self.assertFalse(self.run_check(bids=[bid])['incidents'])
        unknown=self.run_check(bids=None);self.assertFalse(unknown['incidents']);self.assertTrue(unknown['coverage'])
    def test_initial_auction_inactive_has_no_retroactive_bid_check(self):
        self.assertFalse(self.run_check(bids=[])['incidents'])
    def test_second_same_rule_requires_review_even_if_rectified(self):
        self.lineups[8]['0001']={'status':'missing','submitted_at':None}
        state=self.run_check(now=self.now+timedelta(days=5));self.windows[9]={'first':self.now+timedelta(days=6),'close':self.now+timedelta(days=11)}
        self.lineups[9]={'0001':{'status':'missing','submitted_at':None}}
        state=self.run_check(state,self.now+timedelta(days=12));second=next(i for i in state['incidents'].values()if i['rule']=='lineup'and i['count']==2)
        self.assertEqual(second['status'],'review')
        self.lineups[17]={'0001':{'status':'submitted','submitted_at':m.iso(self.now+timedelta(days=12,minutes=1))}}
        state=self.run_check(state,self.now+timedelta(days=12,minutes=2));self.assertTrue(any(i['count']==2 and i['status']=='review'for i in state['incidents'].values()))
    def test_missing_source_is_unknown_not_a_violation(self):
        self.f['lastVisit']='0';self.lineups={}
        state=self.run_check(now=self.now+timedelta(days=5));self.assertFalse(state['incidents']);self.assertTrue(state['coverage'])
    def test_owner_replacement_does_not_inherit_old_counts(self):
        self.stale();state=self.run_check();self.f['username']='replacement'
        state=self.run_check(state,self.now+timedelta(hours=1));self.assertTrue(all(i['status']=='retired_owner'for i in state['incidents'].values()))
    def test_120_hours_is_elapsed_time_across_dst(self):
        issued=datetime.fromisoformat('2026-10-30T20:00:00+00:00');deadline=issued+timedelta(hours=120)
        self.assertEqual((deadline-issued).total_seconds(),432000)
        self.assertNotEqual(issued.astimezone(m.EASTERN).hour,deadline.astimezone(m.EASTERN).hour)
    def test_owner_warning_text_uses_correct_grace_and_repeat_policy(self):
        incident={'franchise':'Team','rule':'auction','count':1,'observed':'No bid'}
        _,body=m.owner_message(incident,m.iso(self.now+timedelta(hours=24)));self.assertIn('24 hours',body)
        incident.update(rule='lineup');_,body=m.owner_message(incident,m.iso(self.now+timedelta(hours=120)));self.assertIn('120 hours',body)
        incident['count']=2;_,body=m.owner_message(incident,None);self.assertIn('without an additional warning period',body);self.assertNotIn('Rectification deadline',body)
    def test_commissioner_recipient_resolution_is_exact_and_owner_email_is_separate(self):
        commissioners=[dict(self.f,owner_name=name,email=email)for name,email in [('Mike Filicicchia','m@example.com'),('Russ Mataya','r@example.com'),('Tim Shields','t@example.com')]]
        self.assertEqual(m.commissioner_addresses(commissioners),['m@example.com','r@example.com','t@example.com'])
        with self.assertRaises(ValueError):m.commissioner_addresses(commissioners[:2])

    def test_owner_delivery_starts_timer_only_after_acceptance_and_does_not_repeat(self):
        self.stale();state=self.run_check();send=Mock();saved=[]
        def save():saved.append(copy.deepcopy(state))
        m.deliver_owner_notices(state,[self.f],send,save,clock=lambda:self.now)
        first=next(iter(saved[0]['incidents'].values()));final=next(iter(state['incidents'].values()))
        self.assertEqual(first['notice']['status'],'sending');self.assertNotIn('deadline',first)
        self.assertEqual(final['deadline'],m.iso(self.now+timedelta(hours=120)))
        self.assertEqual(send.call_args.kwargs['to'],'owner@example.com')
        m.deliver_owner_notices(state,[self.f],send,save,clock=lambda:self.now);self.assertEqual(send.call_count,1)

    def test_uncertain_delivery_has_no_deadline_or_automatic_duplicate(self):
        self.stale();state=self.run_check();send=Mock(side_effect=TimeoutError('lost SMTP acknowledgement'))
        problems=m.deliver_owner_notices(state,[self.f],send,lambda:None,clock=lambda:self.now)
        incident=next(iter(state['incidents'].values()));self.assertNotIn('deadline',incident)
        self.assertEqual(incident['notice']['status'],'delivery_uncertain');self.assertTrue(problems)
        m.deliver_owner_notices(state,[self.f],send,lambda:None,clock=lambda:self.now);self.assertEqual(send.call_count,1)

class ParsingTests(unittest.TestCase):
    def html(self,message):return '<table><caption><a href="options?F=0001">Team</a> Week 8 lineup</caption><tr><td>'+message+'</td></tr></table>'
    def test_inherited_lineup_with_submission_timestamp_is_still_missing(self):
        raw='No starting lineup submitted - Initial lineup set same as last week 7<br/>Lineup copied from previous week<br/><b>Lineup submitted at</b> Mon Oct 26 11:50:46 p.m. ET 2026'
        self.assertEqual(m.parse_lineups(self.html(raw),2026,8)['0001']['status'],'missing')
    def test_real_submission_and_unknown_and_commissioner_set(self):
        stamp='Lineup submitted at Wed Oct 28 10:41:00 p.m. ET 2026'
        parsed=m.parse_lineups(self.html(stamp),2026,8)['0001'];self.assertEqual(parsed['status'],'submitted');self.assertIsNotNone(parsed['submitted_at'])
        self.assertEqual(m.parse_lineups(self.html('21 starters'),2026,8)['0001']['status'],'unknown')
        self.assertEqual(m.parse_lineups(self.html('Set by commissioner '+stamp),2026,8)['0001']['status'],'review')
    def test_duplicate_lineup_reports_are_rejected(self):
        with self.assertRaises(ValueError):m.parse_lineups(self.html('No lineup submitted')*2,2026,8)

if __name__=='__main__':unittest.main()
