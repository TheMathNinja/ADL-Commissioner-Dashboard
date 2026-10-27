import copy
import os
from pathlib import Path
import sys
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch, MagicMock

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import email_weekly_completion as m


def bonus_receipt(week=3,run_id='123',league='ADL'):
    due=[w for w in (3,6,9,12) if w<=week]
    rows=lambda w:[dict(id=f'{i:04}',week=w,W=(1 if i<=15 else 0)*(2 if w==12 else 1),L=(1 if i>=18 else 0)*(2 if w==12 else 1),T=(1 if 16<=i<=17 else 0)*(2 if w==12 else 1)) for i in range(1,33)]
    return dict(status='success',mode='official',league=league,season=2026,week=week,run_id=run_id,source_sha256='a'*64,verified_at='2026-10-22T18:00:00Z',due_weeks=due,results=[dict(week=w,rows=rows(w)) for w in due])

class CompletionEmailTest(unittest.TestCase):
    def setUp(self):
        self.receipt = dict(payouts_verified=True, season=2026, week=3, league_id='60206', status='success',
                            process='preliminary', run_id='123',
                            triggered_at='2026-09-29T04:30:05+00:00')
        self.bonus=bonus_receipt()
        self.payout = dict(status='success', run_id='123', through_week=3, season=2026, league='ADL', logos=dict(status='success',run_id='123'))
        self.run = dict(status='completed', conclusion='success', created_at='2026-09-29T04:30:06Z', html_url='https://github.com/example/run/123')
        self.marker = dict(run_id='123', season=2026, week=3)
        self.job = dict(status='completed', conclusion='success', started_at='2026-09-29T04:31:00Z', completed_at='2026-09-29T04:40:00Z')
        self.feed = dict(week='3', playerScore=[dict(id='1', score='4')])
        self.baseline = dict(season=2026, league_id='60206', weeks={'3': m.snapshot(self.feed, 2026, '60206', 3)})

    def verify(self, active=False):
        def api(url):
            if '/workflows/' in url: return {'workflow_runs': [dict(status='in_progress')] if active else []}
            if '/jobs?' in url: return {'jobs': [self.job]}
            if 'weekly-refresh-status' in url: return self.marker
            return self.run
        with patch.object(m, 'get_json', side_effect=api), patch.object(m, 'document', side_effect=lambda repo, path: self.payout if path.endswith('payouts_sync_metadata.json') else self.bonus if path.endswith('bonus_mfl_sync_metadata.json') else self.baseline), patch.object(m, 'mfl', return_value=self.feed):
            return m.published('ADL', self.receipt)

    def test_both_leagues_required_for_preliminary(self):
        self.assertIsNone(m.choose_receipts('preliminary', {'ADL': {'preliminary': self.receipt}, 'FAFL': {}}))

    def test_correction_requires_official_other_league(self):
        correction = dict(self.receipt, process='corrections')
        chosen = m.choose_receipts('corrections', {'ADL': {'corrections': correction}, 'FAFL': {'preliminary': self.receipt}})
        self.assertIsNone(chosen)

    def test_wrong_week_or_failed_receipt_holds(self):
        for other in [dict(self.receipt, week=2), dict(self.receipt, status='failure')]:
            self.assertIsNone(m.choose_receipts('preliminary', {'ADL': {'preliminary': self.receipt}, 'FAFL': {'preliminary': other}}))

    def test_missing_or_stale_core_payouts_hold_email_but_logos_do_not(self):
        self.payout['run_id'] = 'old'
        self.assertIsNone(self.verify())
        self.payout['run_id'] = '123'
        self.payout['logos']['status'] = 'failure'
        self.assertIsNotNone(self.verify())
        self.payout['logos']['status'] = 'success'
        self.receipt.pop('payouts_verified')
        self.assertIsNone(self.verify())

    def test_unverified_mfl_entries_hold_correction_email(self):
        self.receipt.update(process='corrections',bonus_mfl_verified=False)
        self.assertIsNone(self.verify())

    def test_verified_correction_receipt_is_authoritative(self):
        self.receipt.update(process='corrections', bonus_mfl_verified=True)
        self.assertIsNotNone(self.verify())

    def test_queued_or_stale_bonus_metadata_blocks_even_if_completion_flag_true(self):
        self.receipt.update(process='corrections',bonus_mfl_verified=True)
        for key,value in [('status','queued'),('status','failure'),('run_id','old'),('week',2),('results',[])]:
            self.bonus=bonus_receipt();self.bonus[key]=value
            self.assertIsNone(self.verify())

    def test_success_and_live_site_pass(self):
        self.assertEqual(self.verify()['finished'], self.job['completed_at'])

    def test_unrelated_running_workflow_does_not_hold_completed_run(self):
        self.assertIsNotNone(self.verify(active=True))
        self.run['conclusion'] = 'failure'
        self.assertIsNone(self.verify())

    def test_old_or_missing_deployment_holds(self):
        self.marker['run_id'] = '122'
        self.assertIsNone(self.verify())
        self.marker = None
        self.assertIsNone(self.verify())

    def test_unprocessed_correction_holds(self):
        self.feed['playerScore'][0]['score'] = '5'
        self.assertIsNone(self.verify())

    def test_unfinished_job_holds(self):
        self.job['status'] = 'in_progress'
        self.assertIsNone(self.verify())

    def test_eastern_time_and_duration(self):
        result = self.verify()
        subject, body = m.message('preliminary', [result])
        self.assertEqual(subject, 'ADL 2026 Week 3: Weekly publication package complete')
        self.assertIn('weekly publication package completed successfully', body)
        self.assertIn('- Extension Calculator data', body)
        self.assertIn('- Official salary cap snapshot and Contract Admin Cap Rollover update', body)
        self.assertNotIn('Preliminary scores', body)
        self.assertIn('12:30:05 AM EDT', body)
        self.assertIn('9.0 minutes', body)
        self.assertNotIn('\nADL\n', body)
        self.assertNotIn('Shiny hosting delays', body)
        self.assertIn('01:00:00 AM EST', m.local_time('2026-11-12T06:00:00Z'))

    def test_fafl_weekly_scope_excludes_adl_only_components(self):
        result = self.verify()
        result['league'] = 'FAFL'
        result['receipt'] = dict(result['receipt'], league_id='22686')
        subject, body = m.message('preliminary', [result])
        self.assertEqual(subject, 'FAFL 2026 Week 3: Weekly publication package complete')
        self.assertNotIn('Extension Calculator', body)
        self.assertNotIn('salary cap snapshot', body)

    def test_manual_run_does_not_invent_scrape_trigger(self):
        self.receipt['triggered_at'] = ''
        _, body = m.message('preliminary', [self.verify()])
        self.assertIn('no MFL-check trigger', body)

    def test_recipient_list_and_no_cc(self):
        env = dict(WEEKLY_REPORT_EMAIL_TO='owner@example.com', ADL_ALERT_EMAIL_FROM='Sender <sender@example.com>',
                   ADL_SMTP_SERVER='smtp://smtp.example.com:587', ADL_SMTP_USERNAME='user', ADL_SMTP_PASSWORD='test-only')
        with patch.dict(os.environ, env), patch.object(m.smtplib, 'SMTP') as factory:
            m.send_email('Report', 'Body', 'key')
            smtp = factory.return_value.__enter__.return_value
            smtp.starttls.assert_called_once()
            call = smtp.send_message.call_args
            self.assertEqual(call.kwargs['to_addrs'], ['owner@example.com'])
            self.assertIsNone(call.args[0]['Cc'])
            self.assertIsNone(call.args[0]['Bcc'])
        with patch.dict(os.environ, env), patch.object(m.smtplib, 'SMTP') as factory:
            m.send_email('Report', 'Body', 'key', 'one@example.com,two@example.com')
            call = factory.return_value.__enter__.return_value.send_message.call_args
            self.assertEqual(call.kwargs['to_addrs'], ['one@example.com', 'two@example.com'])

    def test_sent_pair_is_not_sent_again(self):
        fafl = dict(self.receipt, league_id='22686', run_id='456')
        chosen = {'ADL': self.receipt, 'FAFL': fafl}
        keys = {m.report_key('preliminary', [dict(league=l, receipt=r)]) for l, r in chosen.items()}
        def doc(repo, path):
            if path == m.STATE_PATH: return {'sent': {key: {} for key in keys}}
            if path.endswith('corrections.json'): return None
            return self.receipt if 'ADL-' in repo else fafl
        with patch.dict(os.environ, {'GITHUB_REPOSITORY': 'TheMathNinja/ADL-GM-Dashboard'}), patch.object(sys, 'argv', ['report']), \
                patch.object(m, 'document', side_effect=doc), patch.object(m, 'maybe_send_gotw'), \
                patch.object(m, 'send_email') as send, patch.object(m, 'published') as live:
            m.main()
            send.assert_not_called()
            live.assert_not_called()

    def test_completed_run_older_than_six_hours_is_suppressed(self):
        old = (datetime.now(timezone.utc) - timedelta(hours=7)).isoformat().replace('+00:00', 'Z')
        recent = (datetime.now(timezone.utc) - timedelta(minutes=15)).isoformat().replace('+00:00', 'Z')
        self.assertTrue(m.completion_is_stale(old))
        self.assertFalse(m.completion_is_stale(recent))

    def test_correction_message_lists_material_impacts(self):
        result = self.verify()
        result['receipt'] = dict(result['receipt'], process='corrections')
        result['impact'] = dict(run_id='123', week=3,
            ext_pr=[dict(player='James Conner', player_team='ARI', position='RB', old_score=12,
                         new_score=13, old_rank=7, new_rank=6)],
            all_play=[dict(franchise='Seattle Seahawks', franchise_id='0025', old_wins=12, new_wins=13,
                           score_corrected=False),
                      dict(franchise='Carolina Panthers', franchise_id='0001', old_wins=13, new_wins=12,
                           score_corrected=True)],
            bonus_games=[dict(franchise='Carolina Panthers', event='Q1', old_result='T', new_result='L')])
        subject, body = m.message('corrections', [result])
        self.assertEqual(subject, 'ADL 2026 Week 3: Thursday correction publication complete')
        self.assertIn('Week 3 ADL EXT PR changes (rostered, eligible players only)', body)
        self.assertIn('James Conner ARI RB correction: 12 to 13 points | 2026 PR update: RB7 to RB6.', body)
        self.assertIn('Week 3 All-Play changes', body)
        self.assertIn('* CAR correction: 13 to 12 APW.', body)
        self.assertIn('SEA correction: 12 to 13 APW.', body)
        self.assertLess(body.index('* CAR correction'), body.index('SEA correction'))
        self.assertIn('unmarked teams changed only because', body)
        self.assertIn('Q1 Bonus Game changed from T to L', body)

    def test_correction_message_rejects_stale_equal_score_pr_change(self):
        result = self.verify()
        result['receipt'] = dict(result['receipt'], process='corrections')
        result['impact'] = dict(run_id='123', week=3,
            ext_pr=[dict(player='Nolan Smith', position='DE', old_score=8.6, new_score=8.6,
                         old_rank=42, new_rank=43)],
            all_play=[], bonus_games=[])
        _, body = m.message('corrections', [result])
        self.assertNotIn('Nolan Smith', body)
        self.assertIn('No EXT PR', body)

    def test_correction_message_rejects_pr_change_below_starter_floor(self):
        result = self.verify()
        result['receipt'] = dict(result['receipt'], process='corrections')
        result['impact'] = dict(run_id='123', season=2026, week=4,
            ext_pr=[dict(player='Tarheeb Still', player_team='LAC', position='CB',
                         old_score=8, new_score=9.2, old_rank=70, new_rank=65)],
            all_play=[], bonus_games=[])
        _, body = m.message('corrections', [result])
        self.assertNotIn('Tarheeb Still', body)
        self.assertIn('No EXT PR', body)

    def test_other_week_corrections_render_at_bottom(self):
        result = self.verify()
        result['receipt'] = dict(result['receipt'], process='corrections')
        result['impact'] = dict(run_id='123', week=4, ext_pr=[], all_play=[], bonus_games=[],
            other_weeks=[dict(week=2, ext_pr=[], all_play=[dict(
                franchise='New York Giants', old_wins=27, new_wins=26)])])
        _, body = m.message('corrections', [result])
        self.assertIn('Corrections outside the current week', body)
        self.assertIn('Week 2 All-Play changes', body)
        self.assertIn('NYG correction: 27 to 26 APW.', body)

    def test_game_of_week_ranking_and_message(self):
        swing=[];elo=[];franchises=[]
        for i in range(32):
            name=f'Team {i+1}'
            elo.append(dict(week='4',franchise_name=name,elo=str(1600-i)))
            franchises.append(dict(id=f'{i+1:04}',h2hw='3',h2hl='1',h2ht='0'))
        for game in range(16):
            a=2*game;b=a+1
            swing.append(dict(season='2026',through_week='4',target_week='5',
                team_a_id=f'{a+1:04}',team_a=f'Team {a+1}',team_b_id=f'{b+1:04}',team_b=f'Team {b+1}',
                team_a_playoff_if_win='70',team_a_playoff_if_loss='50',team_b_playoff_if_win='60',team_b_playoff_if_loss='50',
                team_a_swing=str(20-game/2),team_b_swing='10',combined_swing=str(30-game/2),
                team_a_seed_if_win='1.8',team_a_seed_if_loss='4.2',team_b_seed_if_win='3',team_b_seed_if_loss='4',
                team_a_seed_swing='2.4',team_b_seed_swing='1',combined_seed_swing='3.4',
                team_a_draft_if_win='12',team_a_draft_if_loss='10',team_b_draft_if_win='10',team_b_draft_if_loss='9',combined_draft_swing='3'))
        week,candidates=m.gotw_candidates('ADL',swing,elo,dict(franchise=franchises))
        self.assertEqual(week,5)
        self.assertEqual(candidates[0]['team_a'],'Team 1')
        history={league:[dict(season=2026,week=4,team_a='Kansas City Chiefs',team_b='Indianapolis Colts')]
                 for league in ('ADL','FAFL')}
        subject,body=m.gotw_message(2026,5,{'ADL':candidates,'FAFL':candidates},history)
        self.assertIn('Week 5',subject)
        self.assertIn('Playoff Percentage Points Up For Grabs: 30.0 (#1 of 16)',body)
        self.assertIn('Team 1 (3-1-0 | #1 Elo: 1600) vs. Team 2 (3-1-0 | #2 Elo: 1599)',body)
        self.assertIn('30% playoff percentage-point swing, 20% average seed swing, 30% average Elo, and 20% Elo closeness.',body)
        self.assertIn('Combined Average Seed Swing: 3.40 positions',body)
        self.assertIn('average seed 1.80 with win / 4.20 with loss (2.40-position swing)',body)
        self.assertIn('Seed averages count missed playoffs as seed 8.',body)
        expected=.3*(17-candidates[0]['impact_rank'])+.2*(17-candidates[0]['seed_rank'])+.2*(17-candidates[0]['draft_rank'])+.2*(17-candidates[0]['combined_rank'])+.1*(17-candidates[0]['difference_rank'])
        self.assertAlmostEqual(candidates[0]['selection_score'],expected)
        self.assertIn('Combined Projected Draft-Order Swing: 3.00 slots',body)
        _,fafl=m.gotw_candidates('FAFL',swing,elo,dict(franchise=franchises))
        self.assertNotIn('draft_rank',fafl[0])
        self.assertAlmostEqual(fafl[0]['selection_score'],.3*(17-fafl[0]['impact_rank'])+.2*(17-fafl[0]['seed_rank'])+.3*(17-fafl[0]['combined_rank'])+.2*(17-fafl[0]['difference_rank']))
        changed=copy.deepcopy(swing)
        for row in changed:row['combined_swing']='30'
        changed[-1]['combined_seed_swing']='6.5'
        equal_elo=[dict(row,elo='1500') for row in elo]
        _,reranked=m.gotw_candidates('ADL',changed,equal_elo,dict(franchise=franchises))
        self.assertEqual(reranked[0]['team_a'],'Team 31')
        self.assertIn('Average Elo: 1600 (#1 of 16)',body)
        self.assertNotIn('Combined Elo:',body)
        self.assertEqual(body.count('Blurb:'), 8)
        self.assertNotIn('Rationale:',body)
        self.assertTrue(all(not line.endswith('.') for line in body.splitlines() if line.startswith('Blurb:')))
        self.assertIn('Week 4: KCC vs. IND',body)
        self.assertIn('2026 ADL Game of the Week Archive',body)
        self.assertIn('2026 FAFL Game of the Week Archive',body)
        self.assertLess(body.index('2026 ADL Game of the Week Archive'), body.index('1. Team 1'))
        self.assertIn('Features: NFC 0 | AFC 1',body)
        self.assertIn('Teams: IND 1, KCC 1',body)

    def test_quarter_opening_week_adds_preliminary_bonus_to_records(self):
        swing=[];elo=[];franchises=[];bonus=[]
        for i in range(32):
            name=f'Team {i+1}'
            elo.append(dict(week='6',franchise_name=name,elo=str(1600-i)))
            franchises.append(dict(id=f'{i+1:04}',h2hw='3',h2hl='3',h2ht='0'))
            bonus.append(dict(franchise_id=f'{i+1:04}',pred_q2_bonus_wins='1' if i == 0 else '.5' if i == 1 else '0'))
        for game in range(16):
            a=2*game;b=a+1
            swing.append(dict(season='2026',through_week='6',target_week='7',
                team_a_id=f'{a+1:04}',team_a=f'Team {a+1}',team_b_id=f'{b+1:04}',team_b=f'Team {b+1}',
                team_a_playoff_if_win='70',team_a_playoff_if_loss='50',team_b_playoff_if_win='60',team_b_playoff_if_loss='50',
                team_a_swing='20',team_b_swing='10',combined_swing='30',
                team_a_seed_if_win='2',team_a_seed_if_loss='3',team_b_seed_if_win='3',team_b_seed_if_loss='4',
                team_a_seed_swing='1',team_b_seed_swing='1',combined_seed_swing='2',
                team_a_draft_if_win='12',team_a_draft_if_loss='10',team_b_draft_if_win='10',team_b_draft_if_loss='9',combined_draft_swing='3'))
        week,candidates=m.gotw_candidates('ADL',swing,elo,dict(franchise=franchises),bonus)
        self.assertEqual(week,7)
        self.assertEqual(candidates[0]['a_record'],'4-3-0*')
        self.assertEqual(candidates[0]['b_record'],'3-3-1*')
        _,body=m.gotw_message(2026,7,{'ADL':candidates,'FAFL':candidates})
        self.assertIn('* Records include unofficial Q2 Bonus Game results.',body)

    def test_published_game_of_week_is_parsed_from_homepage(self):
        html=b'<img alt="ADL Game of the Week, Week 6: Miami Dolphins at Houston Texans &mdash; Big game">'
        response=MagicMock(); response.__enter__.return_value.read.return_value=html
        with patch.object(m.urllib.request,'urlopen',return_value=response):
            self.assertEqual(m.published_gotw('ADL',2026),dict(
                season=2026,week=6,team_a='Miami Dolphins',team_b='Houston Texans'))

    def test_archive_counts_features_and_uses_mfl_franchise_order(self):
        lines='\n'.join(m.gotw_history_lines('ADL',m.GOTW_SEED['ADL']))
        self.assertIn('2026 ADL Game of the Week Archive',lines)
        self.assertIn('Features: NFC 1 | AFC 2',lines)
        self.assertIn('Teams: NOS 1, TBB 1, MIA 1, HOU 1, IND 1, KCC 1',lines)

    def test_homepage_timeout_is_retried_with_bounded_reads(self):
        response=MagicMock()
        response.__enter__.return_value.read.return_value=b'<img alt="ADL Game of the Week, Week 7: San Francisco 49ers at Philadelphia Eagles &mdash; Game">'
        with patch.object(m.urllib.request,'urlopen',side_effect=[TimeoutError('slow MFL'),response]) as fetch, patch.object(m.time,'sleep'):
            self.assertEqual(m.published_gotw('ADL',2026)['week'],7)
        self.assertEqual(fetch.call_count,2)
        self.assertTrue(all(call.kwargs['timeout']==15 for call in fetch.call_args_list))

    def test_complete_archive_does_not_depend_on_homepage(self):
        state={'gotw_history':copy.deepcopy(m.GOTW_SEED)}
        for league in m.LEAGUES:
            state['gotw_history'][league].append(dict(season=2026,week=7,team_a='San Francisco 49ers',team_b='Philadelphia Eagles'))
        with patch.object(m,'published_gotw',side_effect=TimeoutError('MFL unavailable')) as fetch:
            history=m.gotw_history(state,2026,7)
        fetch.assert_not_called()
        self.assertEqual(history['ADL'][-1]['week'],7)

    def test_upcoming_published_selection_is_preserved_but_not_shown_as_history(self):
        state={'gotw_history':copy.deepcopy(m.GOTW_SEED)}
        state['gotw_history']['ADL'].append(dict(season=2026,week=8,team_a='Buffalo Bills',team_b='Miami Dolphins'))
        with patch.object(m,'published_gotw',return_value=None):
            history=m.gotw_history(state,2026,6)
        self.assertEqual(history['ADL'][-1]['week'],6)
        self.assertEqual(state['gotw_history']['ADL'][-1]['week'],8)

    def test_failed_history_fetch_preserves_known_rows_and_labels_gap(self):
        state={'gotw_history':copy.deepcopy(m.GOTW_SEED)}
        with patch.object(m,'published_gotw',side_effect=TimeoutError('MFL unavailable')):
            history=m.gotw_history(state,2026,7)
        self.assertEqual([r['week'] for r in history['ADL']],[4,5,6])
        lines='\n'.join(m.gotw_history_lines('ADL',history['ADL'],7))
        self.assertIn('Archive incomplete: MFL selection unverified for Week 7.',lines)
        self.assertIn('verified selections only',lines)

    def test_history_is_deduplicated_by_league_and_week(self):
        state={'sent':{},'gotw_history':{'ADL':[dict(season=2026,week=6,team_a='Old',team_b='Value')]}}
        with patch.object(m,'published_gotw',side_effect=lambda league,season: None):
            history=m.gotw_history(state,2026,6)
        self.assertEqual([row['week'] for row in history['ADL']],[4,5,6])
        self.assertEqual(history['ADL'][-1]['team_a'],'Miami Dolphins')

    def test_game_of_week_uses_shadow_elo_when_official_export_is_stale(self):
        stale = [dict(week='5', franchise_name=f'Team {i}', elo='1500') for i in range(32)]
        current = [dict(week='6', franchise_name=f'Team {i}', elo='1500') for i in range(32)]
        with patch.object(m, 'csv_document', side_effect=[stale, current]):
            self.assertEqual(m.gotw_elo('example/repo', 6), current)

    def test_game_of_week_prefers_current_official_elo(self):
        current = [dict(week='6', franchise_name=f'Team {i}', elo='1500') for i in range(32)]
        with patch.object(m, 'csv_document', return_value=current) as rows:
            self.assertEqual(m.gotw_elo('example/repo', 6), current)
            rows.assert_called_once_with('example/repo', 'data/elo_ratings.csv')

    def test_game_of_week_is_sent_only_once(self):
        state={'sent': {'gotw:2026:5': {}}}
        with patch.object(m, 'csv_document') as csv_rows, patch.object(m, 'mfl'), \
                patch.object(m, 'gotw_candidates', return_value=(5, [])), patch.object(m, 'send_email') as send:
            csv_rows.side_effect = lambda repo, path: (
                [{'season':'2026','through_week':'4','target_week':'5'}]
                if path.endswith('playoff_swing.csv') else
                [dict(week='4', franchise_name=f'Team {i}', elo='1500') for i in range(32)]
            )
            self.assertFalse(m.maybe_send_gotw(state))
            send.assert_not_called()

    def test_missing_league_dispatches_calculation_only_repair(self):
        state={'sent': {}}
        swing=[{'season':'2026','through_week':'4','target_week':'5'}]
        elo=[{'week':'4','franchise_name':'Team 1','elo':'1500'}]
        def rows(repo, path):
            if 'ADL-' in repo: return swing if path.endswith('playoff_swing.csv') else elo
            return []
        with patch.object(m, 'csv_document', side_effect=rows), \
                patch.object(m, 'ensure_swing_refresh') as repair:
            self.assertFalse(m.maybe_send_gotw(state))
            repair.assert_called_once_with('FAFL', 4)

    def test_lagging_league_dispatches_only_that_repair(self):
        state={'sent': {}}
        def rows(repo, path):
            through = '4' if 'ADL-' in repo else '3'
            if path.endswith('playoff_swing.csv'):
                return [{'season':'2026','through_week':through,'target_week':str(int(through)+1)}]
            return [{'week':through,'franchise_name':'Team 1','elo':'1500'}]
        with patch.object(m, 'csv_document', side_effect=rows), \
                patch.object(m, 'ensure_swing_refresh') as repair:
            self.assertFalse(m.maybe_send_gotw(state))
            repair.assert_called_once_with('FAFL', 4)

    def test_active_repair_is_not_dispatched_twice(self):
        runs={'workflow_runs':[{'status':'in_progress','display_title':'FAFL manual preview'}]}
        with patch.object(m, 'orchestration_json', return_value=runs) as api:
            self.assertFalse(m.ensure_swing_refresh('FAFL', 4))
            self.assertEqual(api.call_count, 1)


if __name__ == '__main__':
    unittest.main()
