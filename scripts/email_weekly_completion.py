"""Email the owner only after both leagues' GitHub runs and live sites are ready."""
import argparse
import base64
import csv
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from email.utils import format_datetime, getaddresses, parseaddr
from functools import lru_cache
import hashlib
import io
import json
import os
from pathlib import Path
import re
import smtplib
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

from weekly_email_support import ET, mfl, priced_rank, snapshot

LEAGUES = {
    'ADL': ('TheMathNinja/ADL-GM-Dashboard', '60206', 'refresh_extension_calculator.yml'),
    'FAFL': ('TheMathNinja/FAFL-GM-Dashboard', '22686', 'refresh.yml'),
}
STATE_PATH = 'data/weekly_email_state.json'
MAX_COMPLETION_EMAIL_AGE = timedelta(hours=6)
GOTW_SEED = {
    'ADL': [
        dict(season=2026, week=4, team_a='Kansas City Chiefs', team_b='Indianapolis Colts'),
        dict(season=2026, week=5, team_a='Tampa Bay Buccaneers', team_b='New Orleans Saints'),
        dict(season=2026, week=6, team_a='Miami Dolphins', team_b='Houston Texans'),
    ],
    'FAFL': [
        dict(season=2026, week=4, team_a='Pittsburgh Steelers', team_b='Tennessee Titans'),
        dict(season=2026, week=5, team_a='Philadelphia Eagles', team_b='New York Giants'),
        dict(season=2026, week=6, team_a='Jacksonville Jaguars', team_b='Denver Broncos'),
    ],
}
NFC_TEAMS = {'ARI', 'ATL', 'CAR', 'CHI', 'DAL', 'DET', 'GBP', 'LAR', 'MIN', 'NOS', 'NYG', 'PHI', 'SEA', 'SFO', 'TBB', 'WAS'}
MFL_FRANCHISE_ORDER = [
    'DAL', 'NYG', 'PHI', 'WAS', 'CHI', 'DET', 'GBP', 'MIN',
    'ATL', 'CAR', 'NOS', 'TBB', 'ARI', 'LAR', 'SFO', 'SEA',
    'BUF', 'MIA', 'NEP', 'NYJ', 'BAL', 'CIN', 'CLE', 'PIT',
    'HOU', 'IND', 'JAC', 'TEN', 'DEN', 'KCC', 'LVR', 'LAC',
]
FRANCHISE_ABBREVIATIONS = {
    'Arizona Cardinals': 'ARI', 'Atlanta Falcons': 'ATL', 'Baltimore Ravens': 'BAL',
    'Buffalo Bills': 'BUF', 'Carolina Panthers': 'CAR', 'Chicago Bears': 'CHI',
    'Cincinnati Bengals': 'CIN', 'Cleveland Browns': 'CLE', 'Dallas Cowboys': 'DAL',
    'Denver Broncos': 'DEN', 'Detroit Lions': 'DET', 'Green Bay Packers': 'GBP',
    'Houston Texans': 'HOU', 'Indianapolis Colts': 'IND', 'Jacksonville Jaguars': 'JAC',
    'Kansas City Chiefs': 'KCC', 'Las Vegas Raiders': 'LVR', 'Los Angeles Chargers': 'LAC',
    'Los Angeles Rams': 'LAR', 'Miami Dolphins': 'MIA', 'Minnesota Vikings': 'MIN',
    'New England Patriots': 'NEP', 'New Orleans Saints': 'NOS', 'New York Giants': 'NYG',
    'New York Jets': 'NYJ', 'Philadelphia Eagles': 'PHI', 'Pittsburgh Steelers': 'PIT',
    'San Francisco 49ers': 'SFO', 'Seattle Seahawks': 'SEA', 'Tampa Bay Buccaneers': 'TBB',
    'Tennessee Titans': 'TEN', 'Washington Commanders': 'WAS',
}


def get_json(url, payload=None, method=None):
    headers = {'User-Agent': 'Analytics-Fantasy-Labs-completion-report', 'Accept': 'application/json'}
    if url.startswith('https://api.github.com/'):
        headers['Authorization'] = 'Bearer ' + os.environ['GH_TOKEN']
    data = None if payload is None else json.dumps(payload).encode()
    if data is not None:
        headers['Content-Type'] = 'application/json'
    try:
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=45) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


@lru_cache(maxsize=None)
def document(repo, path):
    item = get_json(f'https://api.github.com/repos/{repo}/contents/{path}?ref=main')
    return json.loads(base64.b64decode(item['content'])) if item else None


@lru_cache(maxsize=None)
def text_document(repo, path):
    item = get_json(f'https://api.github.com/repos/{repo}/contents/{path}?ref=main')
    return base64.b64decode(item['content']).decode('utf-8') if item else None


def csv_document(repo, path):
    value = text_document(repo, path)
    return list(csv.DictReader(io.StringIO(value))) if value else []


def orchestration_json(url, payload=None, method=None):
    token = os.environ.get('WEEKLY_ORCHESTRATION_TOKEN', '').strip()
    if not token:
        raise RuntimeError('WEEKLY_ORCHESTRATION_TOKEN is not configured')
    headers = {
        'User-Agent': 'Analytics-Fantasy-Labs-weekly-orchestrator',
        'Accept': 'application/vnd.github+json',
        'Authorization': 'Bearer ' + token,
        'X-GitHub-Api-Version': '2022-11-28',
    }
    data = None if payload is None else json.dumps(payload).encode()
    if data is not None:
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=45) as response:
        if response.status == 204:
            return None
        return json.load(response)


def ensure_swing_refresh(league, through_week):
    repo, _, workflow = LEAGUES[league]
    runs = orchestration_json(
        f'https://api.github.com/repos/{repo}/actions/workflows/{workflow}/runs?event=workflow_dispatch&per_page=20'
    ) or {}
    preview_title = f'{league} manual preview'
    active = any(
        run.get('status') in ('queued', 'in_progress', 'waiting', 'pending') and
        run.get('display_title') == preview_title
        for run in runs.get('workflow_runs', [])
    )
    if active:
        print(f'{league} Game of the Week: repair refresh already active')
        return False
    common = {
        'ready_week': str(through_week),
        'score_status': 'official',
        'authorize_official_writes': 'false',
    }
    if league == 'ADL':
        common.update(force='true', capture_cap_snapshot='false')
    orchestration_json(
        f'https://api.github.com/repos/{repo}/actions/workflows/{workflow}/dispatches',
        {'ref': 'main', 'inputs': common},
        method='POST',
    )
    print(f'{league} Game of the Week: dispatched calculation-only repair through Week {through_week}')
    return True


def choose_receipts(process, receipts):
    preferred = {league: files.get(process) for league, files in receipts.items()}
    available = [r for r in preferred.values() if r]
    if not available:
        return None
    season, week = max((r['season'], r['week']) for r in available)
    chosen = {}
    for league, files in receipts.items():
        value = files.get(process)
        if not value or (value['season'], value['week']) != (season, week):
            return None  # Both leagues must finish the official Thursday run.
        if not value or (value['season'], value['week']) != (season, week):
            return None
        if value.get('status') != 'success':
            return None
        if process == 'corrections' and not value.get('bonus_mfl_verified'):
            return None
        chosen[league] = value
    return chosen


def published(league, receipt):
    if not receipt.get('payouts_verified'):
        return None
    repo, league_id, workflow = LEAGUES[league]
    if receipt.get('league_id') != league_id or not str(receipt.get('run_id', '')).isdigit():
        raise ValueError('Invalid completion receipt')
    run_id = str(receipt['run_id'])
    api = f'https://api.github.com/repos/{repo}'
    run = get_json(f'{api}/actions/runs/{run_id}')
    if not run or run['status'] != 'completed' or run['conclusion'] != 'success':
        return None
    site = f'https://themathninja.github.io/{repo.split("/")[1]}/'
    marker = get_json(site + 'weekly-refresh-status.json?run=' + run_id)
    if not marker or str(marker.get('run_id')) != run_id:
        return None
    if (marker.get('season'), marker.get('week')) != (receipt['season'], receipt['week']):
        return None
    payout = document(repo, 'data/payouts_sync_metadata.json')
    if not payout or payout.get('status') != 'success' or str(payout.get('run_id')) != run_id or payout.get('through_week') != receipt['week'] or payout.get('season') != receipt['season'] or payout.get('league') != league:
        return None
    if receipt.get('process') == 'corrections':
        # The completion receipt is written only after the source run verifies its
        # exact Bonus Games child. The intermediate metadata file can be reset to
        # "queued" by a later parent commit, so it is not an authoritative veto.
        if not receipt.get('bonus_mfl_verified'):
            return None
    baseline = document(repo, 'data/processed_player_scores.json')
    if not baseline or baseline.get('season') != receipt['season'] or baseline.get('league_id') != league_id:
        return None
    processed = baseline['weeks'].get(str(receipt['week']))
    live = snapshot(mfl('playerScores', receipt['season'], league_id, receipt['week']),
                    receipt['season'], league_id, receipt['week'])
    if not processed or processed['digest'] != live['digest']:
        return None
    jobs = get_json(f'{api}/actions/runs/{run_id}/jobs?per_page=100')['jobs']
    if not jobs or any(j['status'] != 'completed' or j['conclusion'] not in ('success', 'skipped') for j in jobs):
        return None
    started = min(j['started_at'] for j in jobs if j.get('started_at'))
    finished = max(j['completed_at'] for j in jobs if j.get('completed_at'))
    return dict(league=league, receipt=receipt, started=started, finished=finished,
                created=run['created_at'], url=run['html_url'], site=site,
                verified=datetime.now(timezone.utc).isoformat(),
                impact=document(repo, 'data/correction_impact.json'))


def local_time(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(ET).strftime('%a %b %d, %Y %I:%M:%S %p %Z')


def report_key(process, checked):
    return process + ':' + ':'.join(f'{r["league"]}-{r["receipt"]["run_id"]}' for r in checked)


def completion_is_stale(completed_at, now=None):
    completed = datetime.fromisoformat(completed_at.replace('Z', '+00:00'))
    return (now or datetime.now(timezone.utc)) - completed > MAX_COMPLETION_EMAIL_AGE


def competition_rank(values, value, reverse=False):
    rounded = [round(float(v), 6) for v in values]
    target = round(float(value), 6)
    return 1 + sum(v > target if reverse else v < target for v in rounded)


def gotw_candidates(league, swing, elo, standings, bonus_games=None):
    if len(swing) != 16:
        raise ValueError(f'{league} playoff swing must contain 16 matchups')
    weeks = {int(r['through_week']) for r in swing}
    targets = {int(r['target_week']) for r in swing}
    if len(weeks) != 1 or len(targets) != 1 or next(iter(targets)) != next(iter(weeks)) + 1:
        raise ValueError(f'{league} playoff swing has inconsistent weeks')
    through = next(iter(weeks)); target = next(iter(targets))
    latest = [r for r in elo if int(r['week']) == through]
    ratings = {r['franchise_name']: float(r['elo']) for r in latest}
    if len(ratings) != 32:
        raise ValueError(f'{league} Elo must contain 32 teams for Week {through}')
    franchises = standings.get('franchise', [])
    if isinstance(franchises, dict): franchises = [franchises]
    records = {f['id']: [int(f.get('h2hw', 0)), int(f.get('h2hl', 0)), int(f.get('h2ht', 0))]
               for f in franchises}
    preliminary_bonus = target in (4, 7, 10, 13)
    if preliminary_bonus:
        quarter = (target - 1) // 3
        field = f'pred_q{quarter}_bonus_wins'
        for row in bonus_games or []:
            franchise_id = str(row.get('franchise_id', '')).zfill(4)
            if franchise_id not in records or field not in row:
                continue
            result = float(row[field])
            records[franchise_id][0 if result >= .75 else 2 if result >= .25 else 1] += 1
    rating_values = list(ratings.values())
    enriched = []
    for row in swing:
        a, b = row['team_a'], row['team_b']
        if a not in ratings or b not in ratings:
            raise ValueError(f'{league} swing team missing from Elo: {a} or {b}')
        item = dict(row)
        item.update(a_elo=ratings[a], b_elo=ratings[b],
                    a_elo_rank=competition_rank(rating_values, ratings[a], reverse=True),
                    b_elo_rank=competition_rank(rating_values, ratings[b], reverse=True),
                    combined_elo=ratings[a]+ratings[b],
                    elo_difference=abs(ratings[a]-ratings[b]),
                    a_record=('-'.join(map(str, records[row['team_a_id']])) + ('*' if preliminary_bonus else ''))
                             if row['team_a_id'] in records else 'record unavailable',
                    b_record=('-'.join(map(str, records[row['team_b_id']])) + ('*' if preliminary_bonus else ''))
                             if row['team_b_id'] in records else 'record unavailable')
        enriched.append(item)
    combined = [r['combined_elo'] for r in enriched]
    differences = [r['elo_difference'] for r in enriched]
    impacts = [float(r['combined_swing']) for r in enriched]
    for row in enriched:
        row['combined_rank'] = competition_rank(combined, row['combined_elo'], reverse=True)
        row['difference_rank'] = competition_rank(differences, row['elo_difference'])
        row['impact_rank'] = competition_rank(impacts, row['combined_swing'], reverse=True)
        row['selection_score'] = .5*(17-row['impact_rank']) + .3*(17-row['combined_rank']) + .2*(17-row['difference_rank'])
    return target, sorted(enriched, key=lambda r:(-r['selection_score'], r['impact_rank'], r['difference_rank']))[:4]


def gotw_elo(repo, through_week):
    official = csv_document(repo, 'data/elo_ratings.csv')
    if len([row for row in official if int(row['week']) == through_week]) == 32:
        return official
    shadow = csv_document(repo, 'data/elo_shadow_ratings.csv')
    if len([row for row in shadow if int(row['week']) == through_week]) == 32:
        return shadow
    return official


def published_gotw(league, season):
    league_id = LEAGUES[league][1]
    url = f'https://www46.myfantasyleague.com/{season}/home/{league_id}'
    req = urllib.request.Request(url, headers={'User-Agent': 'Analytics-Fantasy-Labs-GoTW-history'})
    with urllib.request.urlopen(req, timeout=45) as response:
        html = response.read().decode('utf-8', errors='replace')
    match = re.search(
        rf'{league} Game of the Week, Week (\d+):\s*([^<"]+?)\s+(?:at|vs\.?)\s+(.+?)(?:\s+[\u2014-]|&mdash;|["<])',
        html, re.IGNORECASE)
    if not match:
        return None
    return dict(season=season, week=int(match.group(1)),
                team_a=match.group(2).strip(), team_b=match.group(3).strip(' .'))


def gotw_history(state, season, through_week):
    stored = state.setdefault('gotw_history', {})
    for league in LEAGUES:
        rows = list(stored.get(league, []))
        rows.extend(GOTW_SEED.get(league, []))
        try:
            current = published_gotw(league, season)
            if current and current['week'] <= through_week:
                rows.append(current)
        except (OSError, urllib.error.URLError) as exc:
            print(f'{league} Game of the Week: homepage history check unavailable: {exc}')
        deduped = {(int(r['season']), int(r['week'])): r for r in rows
                   if int(r['season']) == season and int(r['week']) <= through_week}
        stored[league] = [deduped[key] for key in sorted(deduped)]
    return stored


def gotw_history_lines(league, rows):
    abbreviations = franchise_abbreviations()
    appearances = {}
    conference = {'NFC': 0, 'AFC': 0}
    season = rows[0]['season'] if rows else datetime.now(ET).year
    lines = [f'{season} {league} Game of the Week Archive', '---------------------------------------']
    for row in rows:
        a = abbreviations.get(row['team_a'], row['team_a'])
        b = abbreviations.get(row['team_b'], row['team_b'])
        lines.append(f'Week {row["week"]}: {a} vs. {b}')
        for team in (a, b):
            appearances[team] = appearances.get(team, 0) + 1
            conference['NFC' if team in NFC_TEAMS else 'AFC'] += .5
    order = {team: index for index, team in enumerate(MFL_FRANCHISE_ORDER)}
    lines += ['',
              f'Features: NFC {format_value(conference["NFC"])} | AFC {format_value(conference["AFC"])}',
              'Teams: ' + ', '.join(f'{team} {count}' for team, count in
                                    sorted(appearances.items(), key=lambda item: order.get(item[0], 99))), '']
    return lines


def gotw_message(season, target_week, candidates, history=None):
    subject = f'{season} Week {target_week}: ADL & FAFL Game of the Week suggestions'
    lines = [subject, '',
             'Matchup ranking weights: 50% playoff percentage-point swing, 30% average Elo, and 20% Elo closeness.', '']
    if target_week in (4, 7, 10, 13):
        lines += [f'* Records include unofficial Q{(target_week - 1)//3} Bonus Game results.', '']
    for league in ('ADL', 'FAFL'):
        lines += [league, '---']
        if history is not None:
            lines += gotw_history_lines(league, history.get(league, []))
        for rank, r in enumerate(candidates[league], 1):
            lines += [
                f'{rank}. {r["team_a"]} ({r["a_record"]} | #{r["a_elo_rank"]} Elo: {r["a_elo"]:.0f}) vs. '
                f'{r["team_b"]} ({r["b_record"]} | #{r["b_elo_rank"]} Elo: {r["b_elo"]:.0f})',
                f'Playoff Percentage Points Up For Grabs: {float(r["combined_swing"]):.1f} (#{r["impact_rank"]} of 16)',
                f'{r["team_a"]}: {float(r["team_a_playoff_if_win"]):.1f}% with win / {float(r["team_a_playoff_if_loss"]):.1f}% with loss ({float(r["team_a_swing"]):.1f}-point swing)',
                f'{r["team_b"]}: {float(r["team_b_playoff_if_win"]):.1f}% with win / {float(r["team_b_playoff_if_loss"]):.1f}% with loss ({float(r["team_b_swing"]):.1f}-point swing)',
                f'Average Elo: {r["combined_elo"]/2:.0f} (#{r["combined_rank"]} of 16); Elo Difference: {r["elo_difference"]:.1f} (#{r["difference_rank"]} closest of 16)',
                f'Rationale: A high-leverage Week {target_week} matchup pairing playoff impact with proven team strength and competitiveness.',
                ''
            ]
    return subject, '\n'.join(lines)


def maybe_send_gotw(state, dry_run=False, force=False):
    started = time.perf_counter()
    candidates = {}; season = target = None; inputs = {}
    for league, (repo, league_id, _) in LEAGUES.items():
        swing = csv_document(repo, 'data/playoff_swing.csv')
        through = int(swing[0]['through_week']) if swing else -1
        elo = gotw_elo(repo, through)
        bonus_games = csv_document(repo, 'data/bonus_games.csv')
        inputs[league] = (swing, elo, bonus_games)
    ready = {
        league: (int(swing[0]['season']), int(swing[0]['through_week']), int(swing[0]['target_week']))
        for league, (swing, elo, bonus_games) in inputs.items() if swing and elo
    }
    if len(ready) < len(LEAGUES):
        if ready and not dry_run:
            through = max(value[1] for value in ready.values())
            for league in LEAGUES:
                if league not in ready:
                    ensure_swing_refresh(league, through)
        missing = ', '.join(league for league in LEAGUES if league not in ready)
        print(f'Game of the Week: waiting for swing or Elo data from {missing}')
        return False
    newest = max(ready.values())
    lagging = [league for league, value in ready.items() if value != newest]
    if lagging:
        if not dry_run:
            for league in lagging:
                ensure_swing_refresh(league, newest[1])
        print('Game of the Week: leagues are not aligned; repair requested for ' + ', '.join(lagging))
        return False
    for league, (repo, league_id, _) in LEAGUES.items():
        swing, elo, bonus_games = inputs[league]
        league_season = int(swing[0]['season']); through = int(swing[0]['through_week'])
        standings = mfl('leagueStandings', league_season, league_id, through)
        league_target, candidates[league] = gotw_candidates(league, swing, elo, standings, bonus_games)
        if season is None: season, target = league_season, league_target
        elif (season, target) != (league_season, league_target):
            print('Game of the Week: leagues are not aligned'); return False
    key = f'gotw:{season}:{target}'
    if key in state['sent'] and not force:
        print('Game of the Week: suggestions already sent'); return False
    prepared = time.perf_counter()
    history = gotw_history(state, season, target - 1)
    subject, body = gotw_message(season, target, candidates, history)
    rendered = time.perf_counter()
    if dry_run:
        print(body)
        print(f'Game of the Week timings: inputs/ranking={prepared-started:.3f}s, email preparation={rendered-prepared:.3f}s, total={rendered-started:.3f}s')
        return False
    send_email(subject, body, key)
    emailed = time.perf_counter()
    state['sent'][key] = dict(sent_at=datetime.now(timezone.utc).isoformat(), subject=subject)
    save_state(state)
    print('Game of the Week: suggestions submitted to the configured sole recipient')
    print(f'Game of the Week timings: inputs/ranking={prepared-started:.3f}s, email preparation={rendered-prepared:.3f}s, SMTP={emailed-rendered:.3f}s, total={emailed-started:.3f}s')
    return True


def format_value(value):
    return str(int(value)) if float(value).is_integer() else str(value)


@lru_cache(maxsize=1)
def franchise_abbreviations():
    return FRANCHISE_ABBREVIATIONS


@lru_cache(maxsize=1)
def player_teams():
    path = Path(__file__).parents[1] / 'data' / 'current_rosters.csv'
    if not path.exists():
        return {}
    with path.open(encoding='utf-8-sig') as source:
        return {row['player_id']: row['player_team'] for row in csv.DictReader(source)}


def correction_section_lines(impact, include_empty=True):
    week = impact['week']
    season = int(impact.get('season', os.environ.get('CURRENT_SEASON', '2026')))
    sections = []
    ext_pr = [row for row in impact.get('ext_pr', [])
              if row.get('old_score') is not None and row.get('new_score') is not None and
              float(row['old_score']) != float(row['new_score']) and
              priced_rank(row['position'], row.get('old_rank'), season) !=
              priced_rank(row['position'], row.get('new_rank'), season)]
    if ext_pr:
        heading = f'Week {week} ADL EXT PR changes (rostered, eligible players only)'
        sections += ['', heading, '-' * len(heading)]
        for row in ext_pr:
            team = row.get('player_team') or player_teams().get(str(row.get('player_id', '')), '')
            identity = ' '.join(part for part in (row['player'], team, row['position']) if part)
            sections.append(
                f'{identity} correction: {format_value(row["old_score"])} to '
                f'{format_value(row["new_score"])} points | 2026 PR update: '
                f'{row["position"]}{format_value(row["old_rank"])} to '
                f'{row["position"]}{format_value(row["new_rank"])}.'
            )
    if impact.get('all_play'):
        sections += ['', f'Week {week} All-Play changes', '-' * len(f'Week {week} All-Play changes')]
        abbreviations = franchise_abbreviations()
        rows = sorted(impact['all_play'], key=lambda row: (
            not bool(row.get('score_corrected')), str(row.get('franchise_id', '')),
            row.get('franchise', '')))
        for row in rows:
            franchise = row.get('franchise_abbr') or abbreviations.get(row['franchise'], row['franchise'])
            marker = '* ' if row.get('score_corrected') else ''
            sections.append(f'{marker}{franchise} correction: {format_value(row["old_wins"])} to {format_value(row["new_wins"])} APW.')
        if any(row.get('score_corrected') for row in rows):
            sections.append('* Team had its own weekly score corrected; unmarked teams changed only because the corrected scores altered All-Play comparisons.')
    if include_empty and not sections:
        return ['No EXT PR or weekly All-Play outcomes changed.']
    return sections


def correction_lines(result):
    impact = result.get('impact') or {}
    if str(impact.get('run_id')) != str(result['receipt']['run_id']):
        return ['Stat-correction impact details were not produced for this run.']
    sections = correction_section_lines(impact, include_empty=False)
    if impact.get('bonus_games'):
        sections += ['', 'Bonus Game changes', '------------------']
        for row in impact['bonus_games']:
            sections.append(f'{row["franchise"]} {row["event"]} Bonus Game changed from {row["old_result"]} to {row["new_result"]}.')
    other_weeks = [week for week in impact.get('other_weeks', [])
                   if correction_section_lines(week, include_empty=False)]
    if other_weeks:
        sections += ['', 'Corrections outside the current week',
                     '------------------------------------']
        for week in other_weeks:
            sections += correction_section_lines(week, include_empty=False)
    if sections:
        return sections
    if result['league'] == 'ADL':
        return ['No EXT PR, weekly All-Play, or completed Bonus Game outcomes changed.']
    return ['No weekly All-Play or completed Bonus Game outcomes changed.']


def message(process, checked):
    receipt = checked[0]['receipt']
    league = checked[0]['league']
    if process == 'preliminary':
        label = 'Weekly publication package complete'
        scope = [
            'Weekly records and Elo ratings',
            'Playoff forecast and bracket',
            'Bonus Games dashboard',
            'Payouts winners and balances',
        ]
        if league == 'ADL':
            scope += ['Extension Calculator data',
                      'Official salary cap snapshot and Contract Admin Cap Rollover update']
        intro = (f'The Week {receipt["week"]} {league} weekly publication package completed '
                 'successfully and the live dashboard was verified.')
    else:
        label = 'Thursday correction publication complete'
        scope = [
            'Corrected weekly records and Elo ratings, where applicable',
            'Playoff and Bonus Games outputs',
            'Payouts winners and balances',
        ]
        if league == 'ADL':
            scope.append('Extension Calculator data, where applicable')
        intro = (f'The Week {receipt["week"]} {league} Thursday correction publication '
                 'completed successfully and the live dashboard was verified.')
    subject = f'{league} {receipt["season"]} Week {receipt["week"]}: {label}'
    lines = [subject, '', intro, '',
             'Reconciled and verified:',
             *[f'- {item}' for item in scope], '',
             'All times are Eastern.', '']
    for result in checked:
        r = result['receipt']
        if process == 'corrections' and r['process'] != 'corrections':
            lines.append('No player-score changes requiring a new refresh; the existing published scores match MFL.')
            lines.append('Most recent completed refresh: ' + local_time(result['finished']))
        else:
            if r.get('triggered_at'):
                lines.append('MFL check triggered GitHub: ' + local_time(r['triggered_at']))
            else:
                lines.append('Manual refresh created in GitHub: ' + local_time(result['created']) + ' (no MFL-check trigger)')
            lines += ['GitHub job started: ' + local_time(result['started']),
                      'GitHub job completed: ' + local_time(result['finished'])]
            begin = datetime.fromisoformat(result['started'].replace('Z', '+00:00'))
            end = datetime.fromisoformat(result['finished'].replace('Z', '+00:00'))
            lines.append(f'Run duration: {(end-begin).total_seconds()/60:.1f} minutes')
        if process == 'corrections': lines.append('Due Bonus Games entries in MFL verified.')
        lines += ['Payouts winners and balances verified; team-logo refresh queued separately.',
                  'Live site verified: ' + local_time(result['verified']),
                  'GitHub run: ' + result['url'],
                  'Dashboard: ' + result['site'], '']
        if process == 'corrections' and r['process'] == 'corrections':
            lines += correction_lines(result) + ['']
    return subject, '\n'.join(lines)


def send_email(subject, body, key, to=None):
    to = to or os.environ['WEEKLY_REPORT_EMAIL_TO']
    addresses = getaddresses([to])
    recipients = [address for _, address in addresses if address]
    if not recipients or any('\n' in address or '\r' in address for address in recipients):
        raise ValueError('At least one valid report recipient is required')
    sender = os.environ['ADL_ALERT_EMAIL_FROM']
    msg = EmailMessage()
    msg['From'], msg['To'], msg['Subject'] = sender, ', '.join(recipients), subject
    msg['Date'] = format_datetime(datetime.now(timezone.utc))
    msg['Message-ID'] = '<' + hashlib.sha256(key.encode()).hexdigest() + '@analyticsfantasylabs.github.io>'
    msg.set_content(body)
    server = os.environ['ADL_SMTP_SERVER']
    parsed = urllib.parse.urlsplit(server if '://' in server else 'smtp://' + server)
    secure = parsed.scheme == 'smtps' or parsed.port == 465
    context = ssl.create_default_context()
    username = os.environ['ADL_SMTP_USERNAME'].strip()
    password = os.environ['ADL_SMTP_PASSWORD'].strip()
    # Gmail displays app passwords in four spaced groups; spaces are cosmetic.
    if re.fullmatch(r'(?:[a-z]{4} ){3}[a-z]{4}', password):
        password = password.replace(' ', '')
    factory = smtplib.SMTP_SSL if secure else smtplib.SMTP
    kwargs = {'context': context} if secure else {}
    with factory(parsed.hostname, parsed.port or (465 if secure else 587), timeout=45, **kwargs) as smtp:
        if not secure:
            smtp.starttls(context=context)
        # Some submission servers close the connection on an inline AUTH PLAIN
        # response. Prefer the challenge/response LOGIN flow when advertised.
        smtp.ehlo()
        if 'LOGIN' in smtp.esmtp_features.get('auth', '').upper().split():
            smtp.user = username
            smtp.password = password
            smtp.auth('LOGIN', smtp.auth_login, initial_response_ok=False)
        else:
            smtp.login(username, password, initial_response_ok=False)
        smtp.send_message(msg, from_addr=parseaddr(sender)[1], to_addrs=recipients)


def save_state(state):
    repo = os.environ['GITHUB_REPOSITORY']
    url = f'https://api.github.com/repos/{repo}/contents/{STATE_PATH}'
    current = get_json(url)
    payload = dict(message='Record delivered weekly refresh email',
                   content=base64.b64encode((json.dumps(state, indent=2)+'\n').encode()).decode(),
                   branch='main')
    if current:
        payload['sha'] = current['sha']
    get_json(url, payload, method='PUT')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--league', choices=LEAGUES)
    parser.add_argument('--process', choices=('preliminary', 'corrections'))
    parser.add_argument('--recipient-override')
    parser.add_argument('--force-resend', action='store_true')
    parser.add_argument('--force-gotw', action='store_true')
    args = parser.parse_args()
    targeted = any((args.league, args.process, args.recipient_override, args.force_resend))
    if args.force_gotw and targeted:
        parser.error('--force-gotw cannot be combined with targeted completion-report delivery')
    if targeted and not all((args.league, args.process, args.recipient_override)):
        parser.error('targeted delivery requires --league, --process, and --recipient-override')
    if args.force_resend and not targeted:
        parser.error('--force-resend is only available for targeted delivery')
    receipts = {league: {process: document(repo, f'data/refresh_receipts/{process}.json')
                        for process in ('preliminary', 'corrections')}
                for league, (repo, _, _) in LEAGUES.items()}
    state = document(os.environ['GITHUB_REPOSITORY'], STATE_PATH) or {'sent': {}}
    if not targeted:
        maybe_send_gotw(state, args.dry_run, args.force_gotw)
    if args.force_gotw:
        return
    for process in ('preliminary', 'corrections'):
        for league, files in receipts.items():
            if targeted and (league != args.league or process != args.process):
                continue
            receipt = files.get(process)
            if not receipt or receipt.get('status') != 'success' or \
                    process == 'corrections' and not receipt.get('bonus_mfl_verified'):
                print(f'{league} {process}: waiting for completion receipt')
                continue
            key = report_key(process, [dict(league=league, receipt=receipt)])
            if key in state['sent'] and not args.force_resend:
                print(f'{league} {process}: report already sent')
                continue
            result = published(league, receipt)
            if not result:
                print(f'{league} {process}: waiting for successful job, live site, or score corrections')
                continue
            if completion_is_stale(result['finished']):
                print(f'{league} {process}: stale completion receipt suppressed')
                if not args.dry_run and not args.force_resend:
                    state['sent'][key] = dict(
                        suppressed_at=datetime.now(timezone.utc).isoformat(),
                        reason='stale_completion_receipt',
                    )
                    save_state(state)
                continue
            subject, body = message(process, [result])
            if args.dry_run:
                print(body)
                continue
            recipient = args.recipient_override or (os.environ['ADL_WEEKLY_REPORT_EMAIL_TO'] if league == 'ADL'
                                                    else os.environ['FAFL_WEEKLY_REPORT_EMAIL_TO'])
            send_email(subject, body, key, recipient)
            if not args.force_resend:
                state['sent'][key] = dict(sent_at=datetime.now(timezone.utc).isoformat(), subject=subject)
                save_state(state)
            print(f'{league} {process}: report submitted')


if __name__ == '__main__':
    main()

