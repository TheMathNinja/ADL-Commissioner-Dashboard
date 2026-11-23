from datetime import datetime
from decimal import Decimal
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import adl_deposit_report as report


class AnnualDepositTests(unittest.TestCase):
    def setUp(self):
        self.cutoff = datetime(2026, 11, 22, 13, tzinfo=report.ET)
        self.due = datetime(2026, 11, 30, 23, 59, tzinfo=report.ET)
        self.teams = {f'{i:04}': code for i, code in enumerate(sorted(report.MFL_TEAMS), 1)}

    def test_uses_nfl_week_eleven_sunday_and_week_twelve_monday(self):
        games = [dict(kickoff=int(datetime(2026, 11, day, 16, tzinfo=report.ET).timestamp()))
                 for day in (19, 22, 23)]
        self.assertEqual(report.cutoff_dates(2026, dict(week='11', matchup=games)), (self.cutoff, self.due))
        with self.assertRaises(ValueError):
            report.cutoff_dates(2026, dict(week='12', matchup=games))

    def test_future_pick_after_cutoff_is_rolled_back(self):
        holders = {
            team: [dict(year=year, round=rd, originalPickFor=team)
                   for year in (2027, 2028) for rd in range(1, 6)]
            for team in self.teams
        }
        holders['0002'].append(holders['0001'].pop(0))
        export = {'franchise': [dict(id=team, futureDraftPick=picks) for team, picks in holders.items()]}
        trade = dict(type='TRADE', franchise='0001', franchise2='0002',
                     franchise1_gave_up='FP_0001_2027_1,', franchise2_gave_up='')
        timestamp = int(self.cutoff.timestamp())
        def rows(when):
            return report.cutoff_rows(2026, self.teams, export,
                                      {'transaction':[dict(trade, timestamp=when)]}, self.cutoff)
        self.assertEqual(rows(timestamp+1), [])
        self.assertEqual(rows(timestamp), [(self.teams['0001'], 3, 7)])
        holders['0002'].pop()
        with self.assertRaises(ValueError):
            rows(timestamp)

    def test_confirmed_berth_in_payout_total_is_not_added_again(self):
        fee, berth = Decimal(125), Decimal(105)
        odds = {'LVR': (100, 'p'), 'PHI': (97, ''), 'NYJ': (6, '')}
        payouts = ({'LVR': fee, 'PHI': Decimal(20), 'NYJ': Decimal(20)}, {'LVR'})
        now, projection = report.winnings_cells('LVR', odds, payouts, fee, berth)
        self.assertEqual(now, '<strong>Yes</strong> · $125 secured')
        self.assertIn('Yes · secured', projection)
        self.assertIn('pending confirmation', report.winnings_cells('PHI', odds, payouts, fee, berth)[1])
        self.assertIn('$125 if in', report.winnings_cells('NYJ', odds, payouts, fee, berth)[1])
        self.assertIn('Unverified', report.winnings_cells('NYJ', None, None, fee, berth)[0])

    def test_html_matches_approved_columns_links_and_scope(self):
        html = report.render(2026, self.due, [('LVR', 2, 6)], Decimal(125), Decimal(105),
                             Decimal(20), {'LVR': (100, 'p')}, ({'LVR': Decimal(125)}, {'LVR'}),
                             'https://www46.myfantasyleague.com/2026/options?L=60206&O=100',
                             report.DASHBOARD + '/playoff-picture/')
        for value in ('2027 Draft Capital Points', '2028 Draft Capital Points',
                      'Total Draft Capital Points', 'May deposit from winnings',
                      'Deposit from proj winnings?', 'Monday, November 30, 2026 at 11:59 p.m. ET',
                      'heading=h.6onepavz6xeh', '>Playoff outlook<', report.PAYOUTS):
            self.assertIn(value, html)
        self.assertIn('Monday night’s', html)
        self.assertNotIn('>GM<', html)
        self.assertNotIn('Winnings as of', html)
        reminder, draft = html.split('<main>', 1)
        self.assertIn('href="https://www.leaguesafe.com/dashboard"', reminder)
        self.assertIn('Renew League', reminder)
        self.assertNotIn('leaguesafe.com', draft)

    def test_2026_scheduled_run_skips_before_any_api_or_email(self):
        class Frozen(datetime):
            @classmethod
            def now(cls, tz=None):
                return cls(2026, 11, 22, 13, 5, tzinfo=tz)
        with patch.object(sys, 'argv', ['report', '--scheduled', '--send']), \
             patch.object(report, 'datetime', Frozen), patch.object(report, 'mfl') as network:
            report.main()
        network.assert_not_called()

    def test_only_owner_receives_explicit_send_and_state_uses_fee_year(self):
        class Frozen(datetime):
            @classmethod
            def now(cls, tz=None):
                return cls(2026, 11, 23, 2, tzinfo=tz)
        with patch.object(sys, 'argv', ['report', '--send']), patch.object(report, 'datetime', Frozen), \
             patch.object(report, 'cutoff_dates', return_value=(self.cutoff, self.due)), \
             patch.object(report, 'mfl', return_value={'baseURL':'https://www46.myfantasyleague.com'}), \
             patch.object(report, 'verify_bylaws', return_value=(Decimal(125), Decimal(105), Decimal(20))), \
             patch.object(report, 'read', return_value='{}'), \
             patch.object(report, 'franchises', return_value=self.teams), \
             patch.object(report, 'cutoff_rows', return_value=[('LVR', 2, 6)]), \
             patch.object(report.mail, 'document', return_value={}), \
             patch.object(report.mail, 'send_email') as send, patch.object(report.mail, 'save_state') as save:
            report.main()
        self.assertEqual(send.call_args.args[2:], ('adl-deposit:2027', report.OWNER))
        self.assertEqual(send.call_args.kwargs, {'html':True})
        self.assertEqual(save.call_count, 2)
        self.assertEqual(save.call_args.args[1], report.STATE)


if __name__ == '__main__':
    unittest.main()
