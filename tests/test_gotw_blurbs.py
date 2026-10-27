import copy
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import gotw_blurbs as b
import email_weekly_completion as email


def matchup(**changes):
    row = dict(through_week='7', target_week='8', team_a='Buffalo Bills', team_b='Miami Dolphins',
               team_a_id='0017', team_b_id='0018', a_elo_rank=3, b_elo_rank=2,
               a_elo=1600, b_elo=1610, combined_seed_swing=2,
               team_a_playoff_if_win=80, team_a_playoff_if_loss=60, team_a_swing=20,
               team_b_playoff_if_win=85, team_b_playoff_if_loss=70, team_b_swing=15)
    return dict(row, **changes)


def game(week, a='0017', c='0018', result='L'):
    points = {'L': (100, 120), 'W': (120, 100), 'T': (100, 100)}[result]
    return dict(week=str(week), matchup=[dict(franchise=[
        dict(id=a, score=str(points[0]), result=result),
        dict(id=c, score=str(points[1]), result={'W':'L', 'L':'W', 'T':'T'}[result])])])


def context(games=None):
    return dict(league=dict(franchises=dict(franchise=[
        dict(id='0017', division='04'), dict(id='0018', division='04')]),
        divisions=dict(division=[dict(id='04', name='East', conference='01')]),
        conferences=dict(conference=[dict(id='01', name='AFC')])),
        schedule=dict(weeklySchedule=games or []))


class BlurbTest(unittest.TestCase):
    def test_revenge_uses_latest_meeting_and_heavyweight_rivalry(self):
        story = b.make_blurb('ADL', matchup(), context([game(1)]))
        self.assertEqual(story['kind'], 'revenge')
        self.assertIn('Bills seek Week 1 vengeance', story['text'])
        self.assertIn('divisional heavyweight rematch', story['text'])
        later = b.make_blurb('ADL', matchup(), context([game(1), game(4, result='W')]))
        self.assertIn('Dolphins seek Week 4 vengeance', later['text'])

    def test_future_incomplete_and_inconsistent_results_do_not_create_revenge(self):
        bad = game(1)
        bad['matchup'][0]['franchise'][0]['score'] = '150'
        incomplete = game(2)
        incomplete['matchup'][0]['franchise'][1].pop('result')
        story = b.make_blurb('ADL', matchup(), context([game(8), bad, incomplete]))
        self.assertNotIn('vengeance', story['text'])

    def test_tied_latest_meeting_is_not_revenge_for_an_older_loss(self):
        story = b.make_blurb('ADL', matchup(), context([game(1), game(4, result='T')]))
        self.assertNotIn('vengeance', story['text'])

    def test_four_game_skid_vs_elo_leader_not_standings_leader(self):
        row = matchup(team_a='San Francisco 49ers', team_b='Philadelphia Eagles', b_elo_rank=1)
        story = b.make_blurb('ADL', row, context([game(w, c='0032') for w in range(4, 8)]))
        self.assertEqual(story['text'], "The Niners seek to snap a 4-game skid against ADL's Elo leader")
        self.assertNotIn('new #1', story['text'])

    def test_missing_week_tie_and_ambiguous_doubleheader_break_streak(self):
        for games in ([game(4), game(5), game(7)], [game(5), game(6, result='T'), game(7)],
                      [game(5), game(6), game(6, c='0032', result='W'), game(7)]):
            self.assertEqual(b.streak(b.history_games(dict(weeklySchedule=games), 7), '0017', 7), ('L', 1))

    def test_duplicates_do_not_double_count_streak(self):
        games = [game(6), game(6), game(7)]
        self.assertEqual(b.streak(b.history_games(dict(weeklySchedule=games), 7), '0017', 7), ('L', 2))

    def test_uphill_path_and_bayou_color_need_strong_opponent(self):
        row = matchup(team_a='Philadelphia Eagles', team_b='New Orleans Saints',
                      team_a_playoff_if_win=40, team_a_playoff_if_loss=15,
                      team_b_playoff_if_win=98, team_b_playoff_if_loss=90)
        story = b.make_blurb('FAFL', row)
        self.assertEqual(story['text'], "The Eagles' uphill playoff climb runs through a Bayou buzzsaw")
        row['b_elo_rank'] = 20
        self.assertNotIn('buzzsaw', b.make_blurb('FAFL', row)['text'])

    def test_division_bubble_without_false_clinch_claim(self):
        row = matchup(team_a_playoff_if_win=55, team_a_playoff_if_loss=25,
                      team_b_playoff_if_win=45, team_b_playoff_if_loss=20)
        story = b.make_blurb('FAFL', row, context())
        self.assertEqual(story['kind'], 'division_bubble')
        self.assertIn('playoff breathing room in the AFC East', story['text'])
        self.assertNotIn('title', story['text'])

    def test_fantasy_divisions_are_not_inferred_from_nfl_names(self):
        ctx = context()
        ctx['league']['franchises']['franchise'][1]['division'] = '05'
        story = b.make_blurb('ADL', matchup(), ctx)
        self.assertNotIn('divisional', story['text'])
        self.assertNotIn('rivalry', story['text'])

    def test_league_history_is_isolated(self):
        adl = b.make_blurb('ADL', matchup(), context([game(1)]))
        fafl = b.make_blurb('FAFL', matchup(), context([game(1, result='W')]))
        self.assertIn('Bills seek', adl['text'])
        self.assertIn('Dolphins seek', fafl['text'])

    def test_missing_context_preserves_supported_swing_copy(self):
        story = b.make_blurb('ADL', matchup())
        self.assertEqual(story['kind'], 'playoff_crossroads')
        self.assertFalse(story['text'].endswith('.'))
        self.assertLessEqual(len(story['text'].split()), 24)

    def test_malformed_optional_context_does_not_break_email_copy(self):
        for ctx in [dict(league=None, schedule=None), dict(league={'franchises': None}),
                    dict(schedule={'weeklySchedule': [None, {}, {'week': 1, 'matchup': [None]}]})]:
            self.assertTrue(b.make_blurb('ADL', matchup(), ctx)['text'])

    def test_streak_and_division_stakes_can_share_one_short_caption(self):
        ctx = context([game(w, c='0032', result='W') for w in (5, 6, 7)])
        ctx['league']['franchises']['franchise'] += [dict(id=i, division='04') for i in ('0019', '0020')]
        ctx['standings'] = dict(franchise=[dict(id=i, h2hw=w, h2hl=9-w, h2ht=0)
                                          for i, w in zip(('0017', '0018', '0019', '0020'), (6, 5, 4, 2))])
        story = b.make_blurb('ADL', matchup(), ctx)
        self.assertEqual(story['kind'], 'streak_in_division_race')
        self.assertIn('3-game surge', story['text'])
        self.assertIn('AFC East race', story['text'])
        self.assertLessEqual(len(story['text'].split()), 24)

    def test_timeout_and_bad_payload_do_not_block_blurb(self):
        with patch.object(b.urllib.request, 'urlopen', side_effect=TimeoutError('offline')) as fetch:
            self.assertEqual(b.fetch_context(2026, '60206'), {})
            self.assertEqual(fetch.call_count, 2)
            self.assertEqual(fetch.call_args.kwargs['timeout'], 10)
        response = MagicMock()
        response.__enter__.side_effect = lambda: io.StringIO('{"error":"unavailable"}')
        with patch.object(b.urllib.request, 'urlopen', return_value=response):
            self.assertEqual(b.fetch_context(2026, '60206'), {})

    def test_singleton_xml_json_shapes_supported(self):
        g = game(1)
        g['matchup'] = g['matchup'][0]
        parsed = b.history_games(dict(weeklySchedule=g), 7)
        self.assertEqual(parsed[(1, '0017')]['result'], 'L')

    def test_stale_streak_does_not_extend_to_current_week(self):
        parsed = b.history_games(dict(weeklySchedule=[game(w) for w in range(1, 5)]), 7)
        self.assertEqual(b.streak(parsed, '0017', 7), (None, 0))

    def test_close_division_race_requires_complete_current_records(self):
        ctx = context([game(1)])
        ctx['league']['franchises']['franchise'] += [dict(id=i, division='04') for i in ('0019', '0020')]
        ctx['standings'] = dict(franchise=[dict(id=i, h2hw=w, h2hl=9-w, h2ht=0)
                                          for i, w in zip(('0017', '0018', '0019', '0020'), (6, 5, 4, 2))])
        row = matchup(a_elo_rank=12, b_elo_rank=14)
        self.assertEqual(b.make_blurb('ADL', row, ctx)['kind'], 'division_race')
        ctx['schedule']['weeklySchedule'].append(game(8))
        self.assertNotEqual(b.make_blurb('ADL', row, ctx)['kind'], 'division_race')
        ctx['schedule']['weeklySchedule'].pop()
        ctx['standings']['franchise'].pop()
        self.assertNotEqual(b.make_blurb('ADL', row, ctx)['kind'], 'division_race')

    def test_repeated_storylines_vary_wording_without_changing_the_facts(self):
        story = b.make_blurb('ADL', matchup(), context([game(1)]), ['revenge'])
        self.assertEqual(story['kind'], 'revenge')
        self.assertIn('Dolphins won the last meeting', story['text'])
        self.assertIn('Bills come looking to settle the score', story['text'])
        self.assertEqual(story['evidence']['prior_week'], 1)

    def test_full_generation_dry_run_has_no_send_save_or_repair(self):
        base = matchup()
        row = dict(base, season=2026, a_record='5-2-0', b_record='6-1-0',
                   combined_elo=3210, impact_rank=1, combined_rank=1, difference_rank=1,
                   seed_rank=1, draft_rank=1, elo_difference=10, combined_swing=35,
                   team_a_seed_if_win=2, team_a_seed_if_loss=3, team_a_seed_swing=1,
                   team_b_seed_if_win=2, team_b_seed_if_loss=3, team_b_seed_swing=1,
                   combined_draft_swing=2, team_a_draft_if_win=12, team_a_draft_if_loss=11,
                   team_b_draft_if_win=12, team_b_draft_if_loss=11)
        elo = [dict(week=7, franchise_name=f'Team {i}', elo=1500) for i in range(32)]
        with patch.object(email, 'csv_document', return_value=[row]), \
                patch.object(email, 'gotw_elo', return_value=elo), patch.object(email, 'mfl', return_value={}), \
                patch.object(email, 'gotw_candidates', side_effect=lambda *args: (8, [copy.deepcopy(row)])), \
                patch.object(email, 'fetch_context', return_value=context([game(1)])), \
                patch.object(email, 'gotw_history', return_value={'ADL': [], 'FAFL': []}), \
                patch.object(email, 'send_email') as send, patch.object(email, 'save_state') as save, \
                patch.object(email, 'ensure_swing_refresh') as repair, patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertFalse(email.maybe_send_gotw({'sent': {}}, dry_run=True))
            self.assertEqual(output.getvalue().count('Blurb: The Bills seek Week 1 vengeance'), 2)
            send.assert_not_called()
            save.assert_not_called()
            repair.assert_not_called()


if __name__ == '__main__':
    unittest.main()
