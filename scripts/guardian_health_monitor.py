"""Deadline assessment from a private, allowlisted timestamp ledger.

This module does not fetch Guardian source, roster snapshots or projections.
All fetched state and calculated details remain in memory or the private repo.
"""
import base64
import copy
import json
import os
import re
from datetime import datetime, timedelta, timezone
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

REPO = 'TheMathNinja/Chicago-Bears-Lineup-Guardian'
STATE = 'data/guardian_coverage.json'
LEDGER = 'data/guardian_health.json'
GRACE = timedelta(minutes=10)


def stamp(value):
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise ValueError('Timezone required')
    return parsed.astimezone(timezone.utc)


def decode(value):
    return json.loads(base64.b64decode(value['content'], validate=False))


def validate(ledger, now):
    required = {'schemaVersion', 'generatedAt', 'leagues', 'checks'}
    if not required <= set(ledger) or set(ledger) - required - {'publicInputs'} or ledger['schemaVersion'] != 1:
        raise ValueError('Unsupported health ledger schema')
    if stamp(ledger['generatedAt']) > now:
        raise ValueError('Future health ledger')
    if {row['key'] for row in ledger['leagues']} != {'ADL', 'FAFL'} or len(ledger['leagues']) != 2:
        raise ValueError('Both leagues required')
    for row in ledger['leagues']:
        if set(row) != {'key', 'leagueId', 'franchiseId'} or not all(str(row[k]).isdigit() for k in ('leagueId', 'franchiseId')):
            raise ValueError('Unexpected league metadata')
    for row in ledger['checks']:
        if (set(row) != {'league', 'week', 'mode', 'checkedAt'} or row['league'] not in {'ADL', 'FAFL'}
                or type(row['week']) is not int or not 1 <= row['week'] <= 18
                or row['mode'] not in {'initial', 'monitor'} or stamp(row['checkedAt']) > now):
            raise ValueError('Invalid health receipt')
    for league, row in ledger.get('publicInputs', {}).items():
        if (league not in {'ADL', 'FAFL'} or not {'week', 'checkedAt', 'fingerprint'} <= set(row)
                or set(row) - {'week', 'checkedAt', 'fingerprint', 'nextCheckAt'}
                or type(row['week']) is not int or not 1 <= row['week'] <= 18
                or stamp(row['checkedAt']) > now or not re.fullmatch('[a-f0-9]{64}', row['fingerprint'])):
            raise ValueError('Invalid public-input fingerprint receipt')
        if row.get('nextCheckAt'):
            stamp(row['nextCheckAt'])
    return ledger


def public_json(url):
    # URL is constructed here from fixed MFL hosts and numeric metadata only.
    with urlopen(Request(url, headers={'User-Agent': 'League-health-monitor'}), timeout=20) as response:
        return json.load(response)


def schedule(row, now):
    season = now.year if now.month > 2 else now.year - 1
    root = f'https://api.myfantasyleague.com/{season}/export?JSON=1&'
    roster = public_json(root + f'TYPE=rosters&L={row["leagueId"]}&FRANCHISE={row["franchiseId"]}')['rosters']['franchise']
    roster = roster if isinstance(roster, list) else [roster]
    team, = [team for team in roster if str(team['id']) == row['franchiseId']]
    week = int(team['week'])
    if not 1 <= week <= 18:
        raise ValueError('Invalid active week')
    feed = public_json(root + f'TYPE=nflSchedule&W={week}')['nflSchedule']
    if int(feed['week']) != week:
        raise ValueError('Schedule week mismatch')
    rows = feed['matchup'] if isinstance(feed['matchup'], list) else [feed['matchup']]
    times = sorted({datetime.fromtimestamp(int(item['kickoff']), timezone.utc) for item in rows})
    if not times or any(t.year not in (season, season + 1) for t in times):
        raise ValueError('Invalid kickoff schedule')
    return {'week': week, 'kickoffs': [t.isoformat() for t in times]}


def assess(checks, schedules, now, activated):
    problems = []
    for league, info in schedules.items():
        week = info['week']
        kickoffs = sorted(stamp(k) for k in info['kickoffs'])
        if not kickoffs:
            raise ValueError('Empty schedule')
        def verified(mode, end):
            return [stamp(c['checkedAt']) for c in checks if c['league'] == league and c['week'] == week
                    and c['mode'] == mode and stamp(c['checkedAt']) <= end]
        for kickoff in kickoffs:
            start = kickoff - timedelta(minutes=90)
            if kickoff < activated or now < max(start, activated) + GRACE:
                continue
            end = min(now, kickoff)
            checked = verified('monitor', end)
            recent = [c for c in checked if c >= start]
            last = max(recent, default=max(start, activated))
            if end - last >= GRACE:
                episode = max(checked, default=activated).isoformat()
                problems.append({'key': f'{league}:{week}:monitor:{episode}', 'league': league,
                                 'week': week, 'mode': 'monitor', 'kickoff': kickoff.isoformat(),
                                 'lastVerified': last.isoformat() if recent else None})
        first = kickoffs[0].astimezone(ZoneInfo('America/New_York')).replace(hour=6, minute=0, second=0, microsecond=0)
        first = first.astimezone(timezone.utc)
        if first >= activated and now >= first + GRACE:
            if not any(first <= c < first + timedelta(hours=1) for c in verified('initial', now)):
                problems.append({'key': f'{league}:{week}:initial:{first.isoformat()}', 'league': league,
                                 'week': week, 'mode': 'initial', 'kickoff': first.isoformat(), 'lastVerified': None})
    return problems


def evaluate(ledger, original, now, get_schedule=schedule):
    validate(ledger, now)
    state = copy.deepcopy(original)
    state.setdefault('schedule_history', {})
    problems = []
    for row in ledger['leagues']:
        key = row['key']
        try:
            info = get_schedule(row, now)
            old = state.setdefault('schedules', {}).get(key)
            if old and old['week'] != info['week']:
                state['schedule_history'][key + ':' + str(old['week'])] = {'league': key, 'schedule': old}
            state['schedules'][key] = info
            state.setdefault('scheduleFailures', {}).pop(key, None)
        except (OSError, ValueError, KeyError, TypeError):
            failed = state.setdefault('scheduleFailures', {}).setdefault(key, now.isoformat())
            if now - stamp(failed) >= GRACE:
                problems.append({'key': key + ':schedule:' + failed, 'league': key, 'week': 0,
                                 'mode': 'schedule', 'kickoff': failed, 'lastVerified': None})
            if key not in state.get('schedules', {}):
                raise RuntimeError('Coverage schedule unavailable') from None
    activated = stamp(state['activatedAt'])
    problems.extend(assess(ledger['checks'], state['schedules'], now, activated))
    for item in state['schedule_history'].values():
        problems.extend(assess(ledger['checks'], {item['league']: item['schedule']}, now, activated))
    current = {p['key']: p for p in problems}
    incidents = state.setdefault('incidents', {})
    for key, item in incidents.items():
        if key not in current and item['status'] == 'open':
            item.update(status='resolved', resolvedAt=now.isoformat())
    for key, problem in current.items():
        if key not in incidents or incidents[key]['status'] == 'resolved':
            incidents[key] = dict(problem, status='open', openedAt=now.isoformat(), delivery='pending')
    state.update(checkedAt=now.isoformat(), alertOwner='commissioner-v1', assessor='public-reporter-v1')
    return state


def persist(path, original, value):
    token = os.environ['PRIVATE_REPORT_TOKEN']
    body = {'message': 'Record private health assessment', 'sha': original['sha'],
            'content': base64.b64encode((json.dumps(value, indent=2) + '\n').encode()).decode(), 'branch': 'main'}
    if body['sha'] is None:
        del body['sha']
    request = Request(f'https://api.github.com/repos/{REPO}/contents/{path}', method='PUT',
                      headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
                               'Accept': 'application/vnd.github+json'}, data=json.dumps(body).encode())
    # A conflict or ambiguous write must be re-read by the next run, not blindly replayed.
    with urlopen(request, timeout=30) as response:
        json.load(response)


def refresh(api, now, dry=False):
    ledger = decode(api(REPO, 'contents/' + LEDGER + '?ref=main'))
    original = api(REPO, 'contents/' + STATE + '?ref=main')
    state = evaluate(ledger, decode(original), now)
    if not dry:
        persist(STATE, original, state)
    return state
