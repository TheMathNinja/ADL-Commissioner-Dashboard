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
from guardian_check_policy import monitor_slot

PATH = 'data/guardian_dispatch.json'
ET = ZoneInfo('America/New_York')
LEASE = timedelta(minutes=5)
PUBLIC_BASIC = 'public-basic-v1'


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
                    required = monitor_slot(kickoff - timedelta(minutes=90), now)
                    if required is not None and not any(check >= required for check in checks):
                        active.append((key, schedule['week']))
    if initial_due:
        return {'reason': 'initial_safety', 'key': 'initial:' + str(now.astimezone(ET).date()),
                'workflow': 'initial-lineup.yml'}
    if active:
        return {'reason': 'required_window', 'key': 'window:' + str(int(now.timestamp() // 300))}
    pending = [row['nextCheckAt'] for row in ledger.get('publicInputs', {}).values()
               if row.get('nextCheckAt') and stamp(row['nextCheckAt']) <= now]
    previous_work = dispatch_state.get('workAttemptedAt')
    if (pending and os.environ.get('GUARDIAN_BASIC_OWNER') != 'public-basic-v1'
            and (not previous_work or now - stamp(previous_work) >= timedelta(minutes=10))):
        return {'reason': 'pending_private_work', 'key': 'work:' + min(pending)}
    local = now.astimezone(ET)
    morning = local.replace(hour=6, minute=0, second=0, microsecond=0)
    daily_reads = [c for c in ledger['checks'] if morning <= stamp(c['checkedAt']).astimezone(ET) <= local]
    if 6 <= local.hour < 18 and any(not any(c['league'] == key for c in daily_reads) for key in ('ADL', 'FAFL')):
        return {'reason': 'morning_health', 'key': 'daily:' + str(local.date())}
    if os.environ.get('GUARDIAN_COALESCE_BACKGROUND') == 'true':
        # Free clocks still observe inputs. Required slots, morning safety and
        # pending private work above retain priority; only off-hours wakeups wait.
        return None
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


def recent_inflight(runs, now, workflow='guardian.yml'):
    return any(r.get('status') in ('queued', 'in_progress', 'pending', 'requested', 'waiting')
               and not (workflow == 'guardian.yml' and os.environ.get('GUARDIAN_PRECISION_OWNER') == 'public-scheduler-v2'
                        and ' - gas-' in r.get('display_title', ''))
               and timedelta(0) <= now - stamp(r['created_at']) < LEASE
               and (r.get('event') == 'schedule' or any(tag in r.get('display_title', '') for tag in ('gas-', 'public-backup-')))
               for r in runs)


def standard_fallback(runs, now):
    return any(run.get('status') == 'completed' and run.get('conclusion') in ('failure', 'timed_out', 'cancelled')
               and (run.get('event') == 'schedule' or 'public-backup-' in run.get('display_title', ''))
               and timedelta(0) <= now - stamp(run['created_at']) < timedelta(minutes=15)
               for run in runs)


def dispatch(identifier, workflow='guardian.yml', force_standard=False):
    if workflow not in ('guardian.yml', 'initial-lineup.yml'):
        raise ValueError('Unrecognized Guardian workflow')
    body = {'ref': 'main', 'inputs': {'live': False, 'use_native_policy': True, 'dispatch_id': identifier}}
    if force_standard:
        body['inputs']['force_standard_runner'] = True
    request = Request(f'https://api.github.com/repos/{REPO}/actions/workflows/{workflow}/dispatches', method='POST',
                      headers={'Authorization': 'Bearer ' + os.environ['PRIVATE_REPORT_TOKEN'], 'Content-Type': 'application/json'},
                      data=json.dumps(body).encode())
    # The durable lease owns ambiguous acceptance; do not resend this POST.
    with urlopen(request, timeout=15) as response:
        response.read()


def run(dry=True, now=None, verify_basic=False):
    public_basic = os.environ.get('GUARDIAN_BASIC_OWNER') == PUBLIC_BASIC
    if verify_basic and not public_basic:
        raise ValueError('Basic verification requires the public read-only owner')
    fixed_clock = now is not None
    now = now or datetime.now(timezone.utc)
    if now.astimezone(ET).month not in (1, 9, 10, 11, 12):
        print('Guardian scheduling gate: offseason; no private runner requested.')
        return
    ledger, _ = document(LEDGER)
    if public_basic:
        from guardian_basic import HEALTH
        basic, _ = document(HEALTH, optional=True)
        ledger = basic or ledger
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
    health_path = LEDGER
    has_basic_ledger = False
    if public_basic:
        from guardian_basic import HEALTH
        basic, _ = document(HEALTH, optional=True)
        health_path = HEALTH if basic else LEDGER
        has_basic_ledger = bool(basic)
    latest, _ = document(health_path)
    if latest['leagues'] != ledger['leagues']:
        raise RuntimeError('League metadata changed during the scheduling assessment')
    now = now if fixed_clock else datetime.now(timezone.utc)
    ledger = validate(latest, now)
    if verify_basic:
        from guardian_basic import run as basic_check
        basic_check(ledger, 'monitor', now, dry, document)
        return
    wanted = decision(ledger, coverage, saved, observations, now)
    if not wanted:
        print('Guardian scheduling gate: no due work; no private runner requested.')
        return
    claim = saved.get('claim', {})
    if claim.get('at') and timedelta(0) <= now - stamp(claim['at']) < LEASE:
        # The basic ledger is written after the pass, even when one league gave
        # no receipt. This frees the lease, not the unmet coverage requirement.
        completed_read_only_pass = (
            has_basic_ledger and claim.get('owner') == PUBLIC_BASIC
            and stamp(ledger['generatedAt']) >= stamp(claim['at'])
            and wanted['reason'] in ('required_window', 'initial_safety')
        )
        if not completed_read_only_pass:
            print('Guardian scheduling gate: recent dispatch lease; no duplicate requested.')
            return
        print('Guardian scheduling gate: public pass finished, but a required check is still due.')
    workflow = wanted.get('workflow', 'guardian.yml')
    if public_basic:
        if wanted['reason'] == 'pending_private_work':
            # Projection-based acquisitions and replacement ranking stay manual/private.
            return
        if not dry:
            saved['claim'] = {'at': now.isoformat(), 'key': wanted['key'], 'reason': wanted['reason'],
                              'owner': PUBLIC_BASIC}
            persist(PATH, original, saved)
        from guardian_basic import run as basic_check
        basic_check(ledger, 'initial' if workflow == 'initial-lineup.yml' else 'monitor', now, dry, document)
        return
    runs = private(f'actions/workflows/{workflow}/runs?per_page=10&branch=main')['workflow_runs']
    if recent_inflight(runs, now, workflow):
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
        if standard_fallback(runs, now):
            dispatch('public-backup-' + str(int(now.timestamp())), workflow, force_standard=True)
        else:
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
    parser.add_argument('--verify-basic', action='store_true', help='Verify the public read-only worker now; never dispatch a private model')
    args = parser.parse_args()
    run(dry=not args.live, verify_basic=args.verify_basic)
