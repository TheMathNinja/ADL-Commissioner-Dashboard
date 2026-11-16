"""Free scheduling gate. Private workers run only for due or changed inputs.

Reads public MFL feeds and opaque private health metadata, not Guardian source,
personal projections, private snapshots or formulas. A dispatch is never coverage.
"""
import argparse
import hashlib
import json
import os
import time
from datetime import datetime, timedelta, timezone
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

from guardian_health_monitor import REPO, LEDGER, STATE, decode, persist, stamp, validate
from guardian_input_watch import fingerprint

PATH = 'data/guardian_dispatch.json'
ET = ZoneInfo('America/New_York')
LEASE = timedelta(minutes=5)


def get_json(url, private=False):
    headers = {'User-Agent': 'League-Guardian-scheduling-gate', 'Accept': 'application/vnd.github+json'}
    if private:
        headers['Authorization'] = 'Bearer ' + os.environ['PRIVATE_REPORT_TOKEN']
    for attempt in range(2):
        try:
            with urlopen(Request(url, headers=headers), timeout=8) as response:
                return json.load(response)
        except (URLError, TimeoutError, json.JSONDecodeError) as error:
            transient = not isinstance(error, HTTPError) or error.code in (408, 429, 500, 502, 503, 504)
            if not transient or attempt:
                raise
            time.sleep(1)


def private(path):
    return get_json(f'https://api.github.com/repos/{REPO}/{path}', private=True)


def document(path, optional=False):
    try:
        value = private('contents/' + path + '?ref=main')
        return decode(value), value
    except HTTPError as error:
        if error.code != 404 or not optional:
            raise
        return {}, {'sha': None}


def rows(value):
    return value if isinstance(value, list) else [value] if isinstance(value, dict) else []


def observe(league, now):
    season = now.year if now.month > 2 else now.year - 1
    root = f'https://api.myfantasyleague.com/{season}/export?JSON=1&'
    roster = get_json(root + f'TYPE=rosters&L={league["leagueId"]}&FRANCHISE={league["franchiseId"]}')
    team, = [p for p in rows(roster['rosters']['franchise']) if str(p['id']) == league['franchiseId']]
    week = int(team['week'])
    if not 1 <= week <= 18:
        raise ValueError('Unrecognized active roster week')
    results = get_json(root + f'TYPE=weeklyResults&L={league["leagueId"]}&W={week}')['weeklyResults']
    if 'week' in results and int(results['week']) != week:
        raise ValueError('Weekly results week mismatch')
    franchises = [f for matchup in rows(results.get('matchup')) for f in rows(matchup.get('franchise'))
                  if str(f['id']) == league['franchiseId']]
    if not franchises:
        raise ValueError('Franchise is absent from weekly results')
    franchise = franchises[0]
    starters = set(str(franchise.get('starters', '')).split(','))
    injury = get_json(root + f'TYPE=injuries&W={week}')['injuries']
    if 'week' in injury and int(injury['week']) != week:
        raise ValueError('Injury feed week mismatch')
    injured = {str(p['id']): p.get('status') for p in rows(injury.get('injury'))}
    players = [{'id': str(p['id']), 'rosterStatus': p.get('status'),
                'reportedInjuryStatus': injured.get(str(p['id'])), 'starter': str(p['id']) in starters}
               for p in rows(team.get('player'))]
    feed = get_json(root + f'TYPE=nflSchedule&W={week}')['nflSchedule']
    if int(feed['week']) != week:
        raise ValueError('Schedule week mismatch')
    kickoffs = sorted({datetime.fromtimestamp(int(p['kickoff']), timezone.utc) for p in rows(feed.get('matchup'))})
    if not kickoffs or any(k.year not in (season, season + 1) for k in kickoffs):
        raise ValueError('Invalid schedule')
    return {'week': week, 'kickoffs': [k.isoformat() for k in kickoffs]}, fingerprint(week, players)


def decision(ledger, coverage, dispatch_state, observations, now):
    """Same roster-week/90-minute rule; independent leagues and cached future games."""
    active = []
    initial_due = []
    changed = []
    unknown = False
    for league in ledger['leagues']:
        key = league['key']
        observed = observations.get(key)
        schedules = [coverage.get('schedules', {}).get(key)]
        schedules += [item['schedule'] for item in coverage.get('schedule_history', {}).values() if item['league'] == key]
        if observed:
            schedules.append(observed[0])
            prior = ledger.get('publicInputs', {}).get(key, {})
            if prior.get('week') != observed[0]['week'] or prior.get('fingerprint') != observed[1]:
                changed.append((key, observed[0]['week'], observed[1]))
        else:
            unknown = True
        for schedule in filter(None, schedules):
            first_day = min(map(stamp, schedule['kickoffs'])).astimezone(ET).date()
            local = now.astimezone(ET)
            initial_reads = [c for c in ledger['checks'] if c['league'] == key and c['week'] == schedule['week']
                             and c['mode'] == 'initial' and stamp(c['checkedAt']) <= now
                             and stamp(c['checkedAt']).astimezone(ET).date() == first_day
                             and 6 <= stamp(c['checkedAt']).astimezone(ET).hour < 7]
            if local.date() == first_day and 6 <= local.hour < 7 and not initial_reads:
                initial_due.append(key)
            for kickoff in map(stamp, schedule['kickoffs']):
                if kickoff - timedelta(minutes=90) <= now < kickoff:
                    checks = [stamp(c['checkedAt']) for c in ledger['checks'] if c['league'] == key
                              and c['week'] == schedule['week'] and c['mode'] == 'monitor'
                              and kickoff - timedelta(minutes=90) <= stamp(c['checkedAt']) <= now]
                    if not checks or now - max(checks) >= timedelta(minutes=5):
                        active.append((key, schedule['week']))
    if initial_due:
        return {'reason': 'initial_safety', 'key': 'initial:' + str(now.astimezone(ET).date()),
                'workflow': 'initial-lineup.yml'}
    if active:
        return {'reason': 'required_window', 'key': 'window:' + str(int(now.timestamp() // 300))}
    pending = [row['nextCheckAt'] for row in ledger.get('publicInputs', {}).values()
               if row.get('nextCheckAt') and stamp(row['nextCheckAt']) <= now]
    previous_work = dispatch_state.get('workAttemptedAt')
    if pending and (not previous_work or now - stamp(previous_work) >= timedelta(minutes=10)):
        return {'reason': 'pending_private_work', 'key': 'work:' + min(pending)}
    local = now.astimezone(ET)
    morning = local.replace(hour=6, minute=0, second=0, microsecond=0)
    daily_reads = [c for c in ledger['checks'] if morning <= stamp(c['checkedAt']).astimezone(ET) <= local]
    if 6 <= local.hour < 18 and any(not any(c['league'] == key for c in daily_reads) for key in ('ADL', 'FAFL')):
        return {'reason': 'morning_health', 'key': 'daily:' + str(local.date())}
    if changed:
        identity = hashlib.sha256(json.dumps(sorted(changed), separators=(',', ':')).encode()).hexdigest()
        previous = dispatch_state.get('background', {})
        if previous.get('key') != identity or now - stamp(previous['attemptedAt']) >= timedelta(hours=1):
            return {'reason': 'public_inputs_changed', 'key': identity}
    if unknown:
        previous = dispatch_state.get('degradedAt')
        if not previous or now - stamp(previous) >= timedelta(hours=1):
            return {'reason': 'schedule_or_inputs_unavailable', 'key': 'degraded:' + str(int(now.timestamp() // 3600))}
    return None


def recent_inflight(runs, now):
    return any(r.get('status') in ('queued', 'in_progress', 'pending', 'requested', 'waiting')
               and timedelta(0) <= now - stamp(r['created_at']) < LEASE
               and (r.get('event') == 'schedule' or any(tag in r.get('display_title', '') for tag in ('gas-', 'public-backup-')))
               for r in runs)


def dispatch(identifier, workflow='guardian.yml'):
    if workflow not in ('guardian.yml', 'initial-lineup.yml'):
        raise ValueError('Unrecognized Guardian workflow')
    body = {'ref': 'main', 'inputs': {'live': False, 'use_native_policy': True, 'dispatch_id': identifier}}
    request = Request(f'https://api.github.com/repos/{REPO}/actions/workflows/{workflow}/dispatches', method='POST',
                      headers={'Authorization': 'Bearer ' + os.environ['PRIVATE_REPORT_TOKEN'], 'Content-Type': 'application/json'},
                      data=json.dumps(body).encode())
    # The durable lease owns ambiguous acceptance; do not resend this POST.
    with urlopen(request, timeout=15) as response:
        response.read()


def run(dry=True, now=None):
    fixed_clock = now is not None
    now = now or datetime.now(timezone.utc)
    if now.astimezone(ET).month not in (1, 9, 10, 11, 12):
        print('Guardian scheduling gate: offseason; no private runner requested.')
        return
    ledger, _ = document(LEDGER)
    validate(ledger, now)
    coverage, _ = document(STATE)
    saved, original = document(PATH, optional=True)
    observations = {}
    for league in ledger['leagues']:
        try:
            observations[league['key']] = observe(league, now)
        except (OSError, ValueError, KeyError, TypeError):
            pass  # Cached kickoff windows still work; uncertainty is never called coverage.
    # A primary run may have completed while the public feeds were being read.
    latest, _ = document(LEDGER)
    if latest['leagues'] != ledger['leagues']:
        raise RuntimeError('League metadata changed during the scheduling assessment')
    now = now if fixed_clock else datetime.now(timezone.utc)
    ledger = validate(latest, now)
    wanted = decision(ledger, coverage, saved, observations, now)
    if not wanted:
        print('Guardian scheduling gate: no due work; no private runner requested.')
        return
    claim = saved.get('claim', {})
    if claim.get('at') and timedelta(0) <= now - stamp(claim['at']) < LEASE:
        print('Guardian scheduling gate: recent dispatch lease; no duplicate requested.')
        return
    workflow = wanted.get('workflow', 'guardian.yml')
    if recent_inflight(private(f'actions/workflows/{workflow}/runs?per_page=10&branch=main')['workflow_runs'], now):
        print('Guardian scheduling gate: a known live check is already queued or running.')
        return
    if dry:
        print('Guardian scheduling gate preview: ' + wanted['reason'] + '; no dispatch or state writes.')
        return
    saved['schemaVersion'] = 1
    saved['claim'] = {'at': now.isoformat(), 'key': wanted['key'], 'reason': wanted['reason']}
    if wanted['reason'] == 'public_inputs_changed':
        saved['background'] = {'key': wanted['key'], 'attemptedAt': now.isoformat()}
    elif wanted['reason'] == 'morning_health':
        last_daily = saved.get('daily', {})
        if last_daily.get('key') == wanted['key'] and now - stamp(last_daily['attemptedAt']) < timedelta(hours=1):
            return
        saved['daily'] = {'key': wanted['key'], 'attemptedAt': now.isoformat()}
    elif wanted['reason'] == 'schedule_or_inputs_unavailable':
        saved['degradedAt'] = now.isoformat()
    elif wanted['reason'] == 'pending_private_work':
        saved['workAttemptedAt'] = now.isoformat()
    try:
        persist(PATH, original, saved)
    except HTTPError as error:
        if error.code not in (409, 422):
            raise
        latest, _ = document(PATH)
        claimed = latest.get('claim', {}).get('at')
        if not claimed or not timedelta(0) <= now - stamp(claimed) < LEASE:
            raise
        print('Guardian scheduling gate: another dispatcher owns the fresh lease.')
        return
    try:
        dispatch('public-backup-' + str(int(now.timestamp())), workflow)
    except (URLError, TimeoutError) as error:
        if isinstance(error, HTTPError) and error.code not in (408, 429, 500, 502, 503, 504):
            raise
        print('::warning::Dispatch acceptance is uncertain; the persisted lease prevents a blind resend. Coverage still requires a verified check.')
        return
    print('Guardian scheduling gate: requested a private check for ' + wanted['reason'] + '.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--live', action='store_true', help='Allow dispatch, not direct roster writes')
    args = parser.parse_args()
    run(dry=not args.live)
