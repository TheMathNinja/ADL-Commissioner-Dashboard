"""Build the annual ADL draft-capital deposit email after the Week 11 cutoff."""
import argparse
from collections import Counter
from datetime import datetime, time, timedelta
from decimal import Decimal
from functools import partial
from html import escape, unescape
import json
import os
from pathlib import Path
import re
from string import Template
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

import email_weekly_completion as mail
from email_delivery_state import deliver_once
from nfl_teams import MFL_TEAMS, mfl_team

ET = ZoneInfo('America/New_York')
OWNER = 'fili.mikey@gmail.com'
FIRST_SCHEDULED_SEASON = 2027
STATE = 'data/adl_deposit_email_state.json'
DASHBOARD = 'https://themathninja.github.io/ADL-GM-Dashboard'
BYLAWS = 'https://docs.google.com/document/d/12l8eriNPrC1aY9LRgPlXQHJtNxSfOzmnfv0zJBUY1jU'
SECTION = BYLAWS + '/edit#heading=h.6onepavz6xeh'
PAYOUTS = DASHBOARD + '/payouts/'
TEMPLATE = Path(__file__).with_name('templates') / 'adl_deposit_email.html'
PRICES = {1: 4, 2: 2, 3: 1}  # Half-point units avoid rounding at the cutoff.


def read(url):
    request = Request(url, headers={'User-Agent': 'ADL-deposit-report/1.0'})
    with urlopen(request, timeout=25) as response:
        return response.read().decode('utf-8-sig')


def mfl(season, kind, **params):
    query = urlencode(dict(TYPE=kind, JSON=1, **params))
    data = json.loads(read(f'https://api.myfantasyleague.com/{season}/export?{query}'))
    if data.get('error'):
        raise ValueError(f'MFL rejected the {kind} export')
    return data[kind]


def cutoff_dates(season, schedule):
    matchups = schedule.get('matchup', [])
    if str(schedule.get('week')) != '11' or not matchups:
        raise ValueError('Missing NFL Week 11 schedule')
    days = {datetime.fromtimestamp(int(game['kickoff']), ET).date() for game in matchups}
    sundays = {day for day in days if day.year == season and day.weekday() == 6}
    if len(sundays) != 1:
        raise ValueError('Could not verify the ADL trade cutoff Sunday')
    sunday = sundays.pop()
    return (datetime.combine(sunday, time(13), ET),
            datetime.combine(sunday + timedelta(days=8), time(23, 59), ET))


def verify_bylaws(plain, html):
    text = ' '.join(plain.split())
    required = (
        r'Sunday of Week 11 @ 1 p\.m\. ET Player/Cash Trade Deadline',
        r'Monday of Week 12 @ 11:59 p\.m\. ET Future League Fee Deposits \(Draft Capital\) Due',
        r'less than 6 .Draft Capital Points. will owe a security deposit',
        r'Future 1st Round Pick = 2 points Future 2nd Round Pick = 1 point Future 3rd Round Pick = 0\.5 points',
        r'tradeable picks are limited to two years into the future',
        r'secured at least the league fee amount in current year winnings',
    )
    if not all(re.search(rule, text, re.I) for rule in required):
        raise ValueError('ADL cutoff, draft-capital or winnings rules have changed; review § XIV-D and the calendar')
    if not re.search(r'<h2\b[^>]*\bid="h\.6onepavz6xeh"[^>]*>.*?XIV-D\. FUTURE LEAGUE DEPOSITS', html, re.S):
        raise ValueError('The direct link to ADL Bylaws § XIV-D requires review')
    fee = re.search(r'Each ADL owner is required to pay an annual \$(\d+(?:\.\d+)?) ADL fantasy football league fee', text)
    berth = re.search(r'\$(\d+(?:\.\d+)?)\) Playoff Participant', text)
    prize = re.search(r'Highest Weekly Point-Scorer in Conference \(2 x 17 x \$(\d+(?:\.\d+)?)\)', text)
    if not (fee and berth and prize):
        raise ValueError('Unable to verify the league fee or winnings amounts')
    # The bylaws list the total payout pool for all 14 playoff berths.
    return Decimal(fee[1]), Decimal(berth[1]) / 14, Decimal(prize[1])


def franchises(league):
    name = re.sub(r'<[^>]+>', '', league['name'])
    if 'Analytics Dynasty League' not in unescape(name):
        raise ValueError('MFL returned the wrong league')
    rows = league['franchises']['franchise']
    teams = {str(row['id']): mfl_team(row['abbrev'], strict=True) for row in rows}
    if len(rows) != 32 or len(teams) != 32 or set(teams.values()) != MFL_TEAMS:
        raise ValueError('Incomplete or unknown ADL franchise identities')
    return teams


def cutoff_rows(season, teams, export, transactions, cutoff):
    inventory = {}
    years = (season + 1, season + 2)
    for row in export['franchise']:
        holder = str(row['id'])
        if holder not in teams:
            raise ValueError('Unknown future pick holder')
        for pick in row.get('futureDraftPick', []):
            key = (int(pick['year']), int(pick['round']), str(pick['originalPickFor']))
            if key in inventory:
                raise ValueError('Duplicate original draft pick')
            inventory[key] = holder
    expected = {(year, rd, team) for year in years for rd in range(1, 6) for team in teams}
    if inventory.keys() != expected:
        raise ValueError('Future-pick inventory changed or is incomplete')
    if 'transaction' not in transactions:
        raise ValueError('Missing completed transaction log')
    after = sorted(
        (trade for trade in transactions['transaction'] if trade['type'] == 'TRADE'
         and int(trade['timestamp']) > cutoff.timestamp()),
        key=lambda trade: int(trade['timestamp']), reverse=True,
    )
    for trade in after:
        a, b = trade['franchise'], trade['franchise2']
        for field, sender, receiver in (('franchise1_gave_up', a, b), ('franchise2_gave_up', b, a)):
            if sender not in teams or receiver not in teams:
                raise ValueError('Unexpected team in completed trade')
            for item in trade[field].split(','):
                if not item.startswith('FP'):
                    continue
                item_match = re.fullmatch(r'FP_(\d{4})_(\d{4})_(\d+)', item)
                if not item_match:
                    raise ValueError('Unrecognized future pick in completed trade')
                original, year, rd = item_match.groups()
                key = (int(year), int(rd), original)
                if inventory.get(key) != receiver:
                    raise ValueError('Could not reverse completed post-cutoff pick trade')
                inventory[key] = sender
    totals = Counter()
    for (year, rd, _), holder in inventory.items():
        totals[holder, year] += PRICES.get(rd, 0)
    rows = [(code, *(totals[team, year] for year in years)) for team, code in teams.items()]
    return sorted((row for row in rows if sum(row[1:]) < 12), key=lambda row: (sum(row[1:]), row[0]))


def odds_from_page(page, teams, week):
    if f'Results through Week {week}</' not in page:
        raise ValueError('Outlook does not match official winnings week')
    _, separator, payload = page.partition('const data=')
    if not separator:
        raise ValueError('No published playoff standings')
    outlook = json.JSONDecoder().raw_decode(payload)[0]
    odds = {}
    for entries in outlook.values():
        for item in entries:
            code = teams[item['franchise_id']]
            clinch = item['clinch']
            chance = int(item['odds'].removesuffix('%'))
            if code in odds or not 0 <= chance <= 100 or clinch not in {'', 'b', 'd', 'p', 'e'}:
                raise ValueError('Invalid playoff status or odds')
            odds[code] = chance, clinch
    if odds.keys() != MFL_TEAMS:
        raise ValueError('Incomplete playoff outlook')
    return odds


def payouts_info(data, season, berth):
    week = data['throughWeek']
    if (data['league'], data['season']) != ('ADL', season) or week not in (10, 11, 12):
        raise ValueError('Unverified ADL payout snapshot')
    earned = {mfl_team(row['code'], strict=True): Decimal(str(row['earned'])) for row in data['teams']}
    if len(data['teams']) != 32 or earned.keys() != MFL_TEAMS or not all(v.is_finite() and v >= 0 for v in earned.values()):
        raise ValueError('Incomplete payout totals')
    awards = [prize for prize in data['prizes'] if prize['label'].startswith('Playoff Participant')]
    if len(awards) != 7 or any(Decimal(str(award['amount'])) != berth for award in awards):
        raise ValueError('Playoff prize amounts do not match the bylaws')
    # A conference winner can be listed in an unsettled row when the other
    # conference's recipient is still open. Native totals count that award.
    booked = {code for award in awards for recipients in award['recipients'].values()
              for code in recipients}
    if not booked <= MFL_TEAMS or any(earned[code] < berth for code in booked):
        raise ValueError('Playoff awards do not reconcile to earned winnings')
    return earned, booked


def dollars(amount):
    return '$' + (f'{amount:,.0f}' if amount == amount.to_integral_value() else f'{amount:,.2f}')


def winnings_cells(code, odds, payouts, fee, berth):
    if odds is None or payouts is None:
        return '<strong>Unverified</strong>', '<strong>Unverified</strong>'
    earned, booked = payouts
    chance, clinch = odds[code]
    clinched = code in booked or clinch in {'b', 'd', 'p'}
    secured = earned[code] + (berth if clinched and code not in booked else 0)
    expected = secured + (berth if not clinched and chance >= 50 else 0)
    now = 'Yes' if secured >= fee else 'No'
    projected = 'Yes · secured' if secured >= fee else 'Yes · pending confirmation' if expected >= fee else 'No'
    note = 'Clinched' if clinched else 'Eliminated' if clinch == 'e' else f'{chance}% playoff odds'
    if not clinched and clinch != 'e' and 0 < chance < 50:
        note += f' · {dollars(secured + berth)} if in'
    return (f'<strong>{now}</strong> · {dollars(secured)} secured',
            f'<strong>{projected}</strong><br>{dollars(expected)} · <small>{note}</small>')


def render(season, due, rows, fee, berth, prize, odds, payouts, picks_link, outlook):
    table = ''
    for code, first, second in rows:
        now, projected = winnings_cells(code, odds, payouts, fee, berth)
        table += (
            f"<tr><th scope='row'>{escape(code)}</th><td>{first/2:g}</td><td>{second/2:g}</td>"
            f"<td><strong>{(first+second)/2:g}</strong></td><td><strong>{dollars(fee)}</strong></td>"
            f"<td>{now}</td><td>{projected}</td></tr>\n"
        )
    date = f'{due:%A, %B} {due.day}, {due.year} at {due:%I:%M %p}'.replace(' at 0', ' at ').replace(' PM', ' p.m.').replace(' AM', ' a.m.')
    label = due.strftime('%A')
    count = f'the GMs of the {len(rows)} franchises listed below must make a ' if rows else ''
    opening = (f'Under our <a href="{SECTION}">future draft capital requirement</a>, {count}'
               f'<strong>{dollars(fee)} deposit toward their {season+1} ADL league fee by {date} ET</strong>, '
               'unless the deposit has already been covered. If you’ve already paid or arranged a credit with the commissioners, please confirm it with us.')
    if not rows:
        opening = f'Under our <a href="{SECTION}">future draft capital requirement</a>, no franchise owes a draft-capital deposit toward the {season+1} ADL league fee this year.'
    return Template(TEMPLATE.read_text(encoding='utf-8')).substitute(
        opening=opening, first_year=season+1, second_year=season+2, rows=table,
        fee=dollars(fee), berth=dollars(berth), prize=dollars(prize), due_day=label,
        bylaws_link=SECTION, picks_link=escape(picks_link, quote=True), payouts_link=PAYOUTS,
        outlook_link=escape(outlook, quote=True),
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--scheduled', action='store_true')
    parser.add_argument('--send', action='store_true')
    args = parser.parse_args()
    now = datetime.now(ET)
    season = now.year
    if args.scheduled and (season < FIRST_SCHEDULED_SEASON or now.month not in (10, 11, 12)):
        return
    cutoff, due = cutoff_dates(season, mfl(season, 'nflSchedule', W=11))
    if not cutoff <= now <= due:
        print('No draft-capital deposit reporting window is open.')
        return
    key = f'adl-deposit:{season+1}'
    repository = os.environ.get('GITHUB_REPOSITORY', 'TheMathNinja/ADL-Commissioner-Dashboard')
    state = (mail.document(repository, STATE) or {}) if args.send else {}
    if state.get('delivery_receipts', {}).get(key, {}).get('status') == 'accepted':
        print(f'{key}: already sent')
        return
    fee, berth, prize = verify_bylaws(
        read(BYLAWS + '/export?format=txt'), read(BYLAWS + '/export?format=html')
    )
    league_id = os.getenv('ADL_LEAGUE_ID', '60206')
    league = mfl(season, 'league', L=league_id)
    teams = franchises(league)
    rows = cutoff_rows(season, teams, mfl(season, 'futureDraftPicks', L=league_id),
                       mfl(season, 'transactions', L=league_id), cutoff)
    outlook = DASHBOARD + '/playoff-picture/'
    try:
        ledger = json.loads(read(PAYOUTS + 'payouts-data.json'))
        payouts = payouts_info(ledger, season, berth)
        outlook += f'ADL_{season}_W{ledger["throughWeek"]+1:02d}_playoff_and_draft_forecast.html'
        odds = odds_from_page(read(outlook), teams, ledger['throughWeek'])
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        # Deposit rows are still verified by MFL. Do not present unverified
        # winnings as $0 or allow an unverified balance to qualify for credit.
        print('::warning::Winnings evidence was unavailable; affected columns are marked Unverified.')
        payouts = odds = None
    league_host = league.get('baseURL', '')
    if not re.fullmatch(r'https://www\d+\.myfantasyleague\.com', league_host):
        raise ValueError('Unable to verify the current ADL league host')
    picks = f'{league_host}/{season}/options?L={league_id}&O=100'
    body = render(season, due, rows, fee, berth, prize, odds, payouts, picks, outlook)
    subject = f'ADL {season+1} League Fee Deposits — Due {due:%B} {due.day}'
    if not args.send:
        if os.environ.get('GITHUB_ACTIONS') == 'true':
            print(f'Validated owner draft for the {season+1} fee season; no email or delivery state written.')
        else:
            print(subject)
            print(body)
        return
    sent = deliver_once(state, key, partial(mail.send_email, subject, body, key, OWNER, html=True),
                        partial(mail.save_state, state, STATE))
    print(f'{key}: owner draft accepted by SMTP' if sent else f'{key}: already sent')


if __name__ == '__main__':
    main()
