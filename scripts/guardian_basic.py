"""Projection-free, read-only MFL checks. Never import or fetch the private engine.

Raw feeds stay in memory. Receipts and warning details go only to the existing
private health store; stdout contains no roster details. Delivery belongs to the
central reporter, not this checker. A warning is a completed check, not a crash.
"""
import copy
import re
from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode
from zoneinfo import ZoneInfo

from guardian_health_monitor import LEDGER, decode, persist, public_json, stamp, validate

HEALTH = 'data/guardian_basic_health.json'
WARNINGS = 'data/guardian_basic_warnings.json'
FEEDS = {'league', 'rosters', 'weeklyResults', 'players', 'injuries', 'nflSchedule', 'nflByeWeeks'}


def submit_link(league, week, now):
    season = now.year if now.month > 2 else now.year - 1
    return f'https://www.myfantasyleague.com/{season}/options?' + urlencode(
        dict(L=league['leagueId'], O='02', F=league['franchiseId'], W=week))


def rows(value):
    if value is None:
        return []
    if isinstance(value, dict):
        return [value]
    if isinstance(value, list) and all(isinstance(row, dict) for row in value):
        return value
    raise ValueError('Malformed public MFL feed')


def feed(season, kind, **params):
    if kind not in FEEDS or set(params) - {'L', 'W', 'FRANCHISE'}:
        raise ValueError('Feed is outside the basic checker allowlist')
    if not 2000 <= int(season) <= 2100 or any(not str(v).isdigit() for v in params.values()):
        raise ValueError('Numeric MFL metadata required')
    return public_json(f'https://api.myfantasyleague.com/{int(season)}/export?' +
                       urlencode(dict(TYPE=kind, JSON=1, **params)))


def inspect(league, now, read=feed):
    """Return rule/injury findings only. Do not read, calculate or rank projections."""
    season = now.year if now.month > 2 else now.year - 1
    league_id, franchise_id = league['leagueId'], league['franchiseId']
    roster = read(season, 'rosters', L=league_id, FRANCHISE=franchise_id)['rosters']
    team, = [x for x in rows(roster['franchise']) if str(x['id']) == franchise_id]
    week = int(team['week'])
    if not 1 <= week <= 18:
        raise ValueError('Invalid roster week')
    result = read(season, 'weeklyResults', L=league_id, W=week)['weeklyResults']
    if 'week' in result and int(result['week']) != week:
        raise ValueError('Lineup week mismatch')
    lineup, = [f for m in rows(result.get('matchup')) for f in rows(m.get('franchise'))
               if str(f['id']) == franchise_id]
    if not isinstance(lineup.get('starters'), str):
        raise ValueError('Missing starter evidence')
    ids = [value for value in lineup['starters'].split(',') if value]
    if len(set(ids)) != len(ids) or any(not value.isdigit() for value in ids):
        raise ValueError('Invalid starter identity')
    players = {str(x['id']): x for x in rows(read(season, 'players')['players']['player'])}
    rostered = {str(x['id']): x for x in rows(team.get('player'))}
    if not set(ids) <= players.keys():
        raise ValueError('Incomplete player/roster evidence')
    rules = read(season, 'league', L=league_id)['league']['starters']
    counts = {}
    for identity in ids:
        position = players[identity]['position']
        counts[position] = counts.get(position, 0) + 1
    issues = {}
    def rule(key, actual, minimum, maximum):
        if not 0 <= minimum <= maximum <= 100:
            raise ValueError('Unsupported starter bounds')
        if not minimum <= actual <= maximum:
            issues['rule:' + key] = f'{key}: requires {minimum}-{maximum}; currently {actual}. Adjust the lineup to meet this limit.'
    for key, actual, field in (
        ('total starters', len(ids), 'count'),
        ('offensive starters', sum(counts.get(p, 0) for p in ('QB', 'RB', 'WR', 'TE')), 'iop_starters'),
        ('defensive starters', sum(counts.get(p, 0) for p in ('DT', 'DE', 'LB', 'CB', 'S')), 'idp_starters')):
        required = int(rules[field])
        rule(key, actual, required, required)
    allowed = set()
    for position in rows(rules['position']):
        name, limits = position['name'], str(position['limit'])
        if not re.fullmatch(r'\d+(?:-\d+)?', limits) or name in allowed:
            raise ValueError('Unsupported position rule')
        allowed.add(name)
        low, _, high = limits.partition('-')
        rule(name, counts.get(name, 0), int(low), int(high or low))
    if not allowed or set(counts) - allowed:
        raise ValueError('Unknown lineup position')
    injury_feed = read(season, 'injuries', W=week)['injuries']
    if 'week' in injury_feed and int(injury_feed['week']) != week:
        raise ValueError('Injury week mismatch')
    injuries = {str(x['id']): str(x['status']).upper().strip().strip('()')
                for x in rows(injury_feed.get('injury'))}
    byes = {x['id'] for x in rows(read(season, 'nflByeWeeks', W=week)['nflByeWeeks'].get('team'))}
    schedule = read(season, 'nflSchedule', W=week)['nflSchedule']
    if int(schedule['week']) != week:
        raise ValueError('Schedule week mismatch')
    games = rows(schedule['matchup'])
    kickoffs = {t['id']: datetime.fromtimestamp(int(g['kickoff']), timezone.utc)
                for g in games for t in rows(g['team'])}
    if not kickoffs:
        raise ValueError('Missing kickoff evidence')
    for identity in ids:
        player = players[identity]
        team_id, status = player['team'], injuries.get(identity, '')
        if team_id not in byes and team_id not in kickoffs:
            raise ValueError('Starter has no verified game or bye')
        # Already locked starters cannot be replaced; do not suggest an impossible move.
        if team_id in kickoffs and kickoffs[team_id] <= now:
            continue
        unavailable = (team_id in byes or status in {'O', 'OUT', 'I', 'H', 'HOLDOUT', 'S', 'SUSPENDED', 'SUSPENSION'}
                       or status.startswith('IR') or 'PUP' in status or 'INJURED' in status)
        roster_status = rostered[identity]['status'] if identity in rostered else 'NOT_ON_ROSTER'
        if unavailable or roster_status != 'ROSTER':
            reason = 'BYE' if team_id in byes else status if unavailable else roster_status
            issues['starter:' + identity] = (f'Remove {player["name"]} ({player["position"]}; {reason}) from the starting lineup. '
                'Select an eligible replacement in private CHI Tools, then submit the revised lineup before the replacement locks.')
            if roster_status == 'TAXI_SQUAD' and not unavailable:
                issues['starter:' + identity] = (f'Move {player["name"]} ({player["position"]}) from Taxi to Active before starting him, '
                    'or replace him with an eligible active player selected in private CHI Tools. Submit the revised lineup before kickoff.')
        elif status in {'Q', 'QUESTIONABLE', 'D', 'DOUBTFUL'}:
            issues['starter:' + identity] = (f'{player["name"]} ({player["position"]}) is {status}. '
                'Check availability before kickoff and review replacement options in private CHI Tools; no replacement has been ranked here.')
    rule_findings = [issues.pop(k) for k in list(issues) if k.startswith('rule:')]
    if rule_findings:
        issues['lineup-rules'] = '\n'.join(rule_findings)
    return week, issues


def record_warnings(previous, league, week, issues, now):
    value = copy.deepcopy(previous)
    incidents = value.setdefault('incidents', {})
    prefix = f'{league}:{week}:'
    for key, item in incidents.items():
        if item['league'] == league and item['status'] == 'open' and key not in {prefix + k for k in issues}:
            item.update(status='resolved', resolvedAt=now.isoformat())
    for kind, detail in issues.items():
        key = prefix + kind
        existing = incidents.get(key, {})
        if existing.get('status') != 'open':
            incidents[key] = dict(league=league, week=week, status='open', openedAt=now.isoformat(), detail=detail)
        else:
            incidents[key]['detail'] = detail
    return value


def check(ledger, warnings, mode, now, read=feed):
    validate(ledger, now)
    result = copy.deepcopy(ledger)
    for league in ledger['leagues']:
        try:
            week, issues = inspect(league, now, read)
        except (OSError, ValueError, KeyError, TypeError):
            continue  # No receipt and no warning resolution after an incomplete read.
        warnings = record_warnings(warnings, league['key'], week, issues, now)
        result['checks'].append(dict(league=league['key'], week=week, mode=mode, checkedAt=now.isoformat()))
    result['generatedAt'] = now.isoformat()
    result['checks'] = [r for r in result['checks'] if now - stamp(r['checkedAt']) <= timedelta(days=35)]
    validate(result, now)
    return result, warnings


def run(ledger, mode, now, dry, document):
    saved, original = document(HEALTH, optional=True)
    warning, warning_original = document(WARNINGS, optional=True)
    warning.setdefault('activatedAt', now.isoformat())
    # Exact old receipts retain their history; no synthetic new check on handoff.
    saved = saved or ledger
    result, warning = check(saved, warning, mode, now)
    if not dry:
        persist(WARNINGS, warning_original, warning)
        persist(HEALTH, original, result)
    print('Projection-free Guardian assessment completed; details remain private.')
    return result


def report(api, now, state, dry, deliver, save, send):
    from guardian_health_monitor import REPO, STATE
    warning = decode(api(REPO, 'contents/' + WARNINGS + '?ref=main'))
    coverage = decode(api(REPO, 'contents/' + STATE + '?ref=main'))
    for key, item in warning.get('incidents', {}).items():
        if item['status'] != 'open':
            continue
        receipt = 'guardian-basic:' + key + ':' + item['openedAt']
        if receipt in state['sent']:
            continue
        legacy = item.get('legacyDelivery')
        if legacy:
            required = {'source', 'file', 'id', 'status', 'sentAt', 'receiptHash', 'inputsFingerprint'}
            if (set(legacy) != required or legacy['source'] != 'verified-local-smtp-migration'
                    or legacy['status'] != 'sent'
                    or not re.fullmatch(r'data/notifications/\d+-\d+-monitor\.json', legacy['file'])
                    or not re.fullmatch(re.escape(legacy['file'].split('/')[-1][:-5]) + r':\d+', legacy['id'])
                    or any(not re.fullmatch('[a-f0-9]{64}', legacy[field]) for field in ('receiptHash', 'inputsFingerprint'))
                    or stamp(legacy['sentAt']) > stamp(item['openedAt'])):
                raise ValueError('Legacy warning delivery requires exact verified evidence')
            if not dry:
                state['sent'][receipt] = dict(subject='Previously delivered private Guardian roster warning',
                    sent_at=legacy['sentAt'], migrated=True, legacy_delivery=legacy)
                save(state)
            continue
        schedule = coverage.get('schedules', {}).get(item['league'], {})
        if schedule.get('week') != item['week']:
            continue
        kickoffs = [stamp(k) for k in schedule['kickoffs']]
        local = now.astimezone(ZoneInfo('America/New_York'))
        morning = bool(kickoffs and local.date() == min(kickoffs).astimezone(local.tzinfo).date() and 6 <= local.hour < 7)
        if not morning and not any(timedelta(0) < kickoff - now <= timedelta(minutes=90) for kickoff in kickoffs):
            continue  # No off-hours mail flood on handoff or routine daily reads.
        # Do not email a stale warning when no current read could confirm it.
        health = decode(api(REPO, 'contents/' + HEALTH + '?ref=main'))
        if not any(r['league'] == item['league'] and r['week'] == item['week']
                   and timedelta(0) <= now - stamp(r['checkedAt']) <= timedelta(minutes=15) for r in health['checks']):
            continue
        league = next(r for r in health['leagues'] if r['key'] == item['league'])
        subject = f'[{item["league"]} Bears] Lineup needs attention'
        link = submit_link(league, item['week'], now)
        body = item['detail'] + '\n\nSubmit New Lineup: ' + link + '\n\nRead-only check: no roster changes were made. Projections and replacement rankings remain in private CHI Tools.'
        if not dry:
            deliver(state, receipt, lambda: send(subject, body, receipt), lambda: save(state))
            state['sent'][receipt] = {'subject': subject, 'sent_at': now.isoformat()}
            save(state)
