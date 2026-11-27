"""Projection-free, read-only MFL checks. Never import or fetch the private engine.

Raw feeds stay in memory. Receipts and warning details go only to the existing
private health store; stdout contains no roster details. Delivery belongs to the
central reporter, not this checker. A warning is a completed check, not a crash.
"""
import copy
import hashlib
import re
from collections import Counter
from datetime import datetime, timedelta, timezone
from http.client import IncompleteRead
from typing import NamedTuple
from urllib.parse import urlencode
from zoneinfo import ZoneInfo

from guardian_health_monitor import LEDGER, decode, persist, public_json, stamp, validate
from nfl_teams import mfl_team

HEALTH = 'data/guardian_basic_health.json'
WARNINGS = 'data/guardian_basic_warnings.json'
FEEDS = {'league', 'rosters', 'weeklyResults', 'players', 'injuries', 'nflSchedule', 'nflByeWeeks'}
RISKY = {'Q', 'QUESTIONABLE', 'D', 'DOUBTFUL'}
OFFENSE = ('QB', 'RB', 'WR', 'TE')
DEFENSE = ('DT', 'DE', 'LB', 'CB', 'S')
LEGACY_ADVISORY = re.compile(r'\) is (Q|QUESTIONABLE|D|DOUBTFUL)\. Check availability before kickoff ')


class Finding(NamedTuple):
    detail: str
    severity: str = 'confirmed'
    push_until: str | None = None
    shortage_risk: bool = False


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


def unavailable(status):
    return (status in {'O', 'OUT', 'INACTIVE', 'I', 'H', 'HOLDOUT', 'S', 'SUSP', 'SUSPENDED', 'SUSPENSION'}
            or status.startswith('IR') or 'PUP' in status or 'INJURED' in status)


def can_fill(bounds, required, locked, available):
    limits = {}
    for position, (minimum, maximum) in bounds.items():
        low = max(minimum, locked[position])
        high = min(maximum, locked[position] + available[position])
        if low > high:
            return False
        limits[position] = low, high

    def spans(positions, count):
        return sum(limits[p][0] for p in positions) <= count <= sum(limits[p][1] for p in positions)

    return (spans(set(bounds) & set(OFFENSE), required[1])
            and spans(set(bounds) & set(DEFENSE), required[2])
            and spans(set(bounds) - set(OFFENSE) - set(DEFENSE), required[0] - required[1] - required[2]))


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
    violated_bounds = {}
    def rule(key, actual, minimum, maximum, positions=None):
        if not 0 <= minimum <= maximum <= 100:
            raise ValueError('Unsupported starter bounds')
        if not minimum <= actual <= maximum:
            issues['rule:' + key] = f'{key}: requires {minimum}-{maximum}; currently {actual}. Adjust the lineup to meet this limit.'
            violated_bounds[key] = (maximum, positions)
    for key, field, positions in (
        ('total starters', 'count', None),
        ('offensive starters', 'iop_starters', OFFENSE),
        ('defensive starters', 'idp_starters', DEFENSE)):
        required = int(rules[field])
        actual = len(ids) if positions is None else sum(counts.get(p, 0) for p in positions)
        rule(key, actual, required, required, positions)
    bounds = {}
    for position in rows(rules['position']):
        name, limits = position['name'], str(position['limit'])
        if not re.fullmatch(r'\d+(?:-\d+)?', limits) or name in bounds:
            raise ValueError('Unsupported position rule')
        low, _, high = limits.partition('-')
        bounds[name] = int(low), int(high or low)
        rule(name, counts.get(name, 0), *bounds[name], (name,))
    if not bounds or set(counts) - bounds.keys():
        raise ValueError('Unknown lineup position')
    injury_feed = read(season, 'injuries', W=week)['injuries']
    if 'week' in injury_feed and int(injury_feed['week']) != week:
        raise ValueError('Injury week mismatch')
    injuries = {str(x['id']): str(x['status']).upper().strip().strip('()')
                for x in rows(injury_feed.get('injury'))}
    byes = {mfl_team(x['id'], strict=True) for x in rows(read(season, 'nflByeWeeks', W=week)['nflByeWeeks'].get('team'))}
    schedule = read(season, 'nflSchedule', W=week)['nflSchedule']
    if int(schedule['week']) != week:
        raise ValueError('Schedule week mismatch')
    games = rows(schedule['matchup'])
    kickoffs = {mfl_team(t['id'], strict=True): datetime.fromtimestamp(int(g['kickoff']), timezone.utc)
                for g in games for t in rows(g['team'])}
    if not kickoffs:
        raise ValueError('Missing kickoff evidence')
    next_kickoff = min((time for time in kickoffs.values() if time > now), default=None)
    locked_positions = []
    risky_starters = {}
    for identity in ids:
        player = players[identity]
        team_id, status = mfl_team(player['team'], strict=True), injuries.get(identity, '')
        if team_id not in byes and team_id not in kickoffs:
            raise ValueError('Starter has no verified game or bye')
        # Already locked starters cannot be replaced; do not suggest an impossible move.
        if team_id in kickoffs and kickoffs[team_id] <= now:
            locked_positions.append(player['position'])
            continue
        is_out = team_id in byes or unavailable(status)
        roster_status = rostered[identity]['status'] if identity in rostered else 'NOT_ON_ROSTER'
        if is_out or roster_status != 'ROSTER':
            reason = 'BYE' if team_id in byes else status if is_out else roster_status
            deadline = next_kickoff if team_id in byes else kickoffs[team_id]
            push_until = deadline.isoformat() if deadline else None
            issues['starter:' + identity] = Finding(
                f'Remove {player["name"]} ({player["position"]}; {reason}) from the starting lineup. '
                'Select an eligible replacement in private CHI Tools, then submit the revised lineup before the replacement locks.',
                push_until=push_until)
            if roster_status == 'TAXI_SQUAD' and not is_out:
                issues['starter:' + identity] = Finding(
                    f'Move {player["name"]} ({player["position"]}) from Taxi to Active before starting him, '
                    'or replace him with an eligible active player selected in private CHI Tools. Submit the revised lineup before kickoff.',
                    push_until=push_until)
        elif status in RISKY:
            risky_starters[identity] = status
    if risky_starters and not issues and rostered.keys() <= players.keys():
        choices = Counter()
        for identity, row in rostered.items():
            player = players[identity]
            if row['status'] != 'ROSTER' or player['position'] not in bounds:
                continue
            team_id = mfl_team(player['team'])
            if (team_id not in byes and team_id in kickoffs and kickoffs[team_id] > now
                    and injuries.get(identity, '') not in RISKY and not unavailable(injuries.get(identity, ''))):
                choices[player['position']] += 1
        required = tuple(int(rules[field]) for field in ('count', 'iop_starters', 'idp_starters'))
        locked = Counter(locked_positions)
        if not can_fill(bounds, required, locked, choices):
            for identity, status in risky_starters.items():
                player = players[identity]
                issues['starter:' + identity] = Finding(
                    f'{player["name"]} ({player["position"]}) is {status}. '
                    'If the at-risk starters cannot play, your current Active roster may not cover a full legal lineup.',
                    'advisory', shortage_risk=True)
    rule_findings = [issues.pop(k) for k in list(issues) if k.startswith('rule:')]
    if rule_findings:
        can_address_rule = any(sum(positions is None or p in positions for p in locked_positions) <= maximum
                               for maximum, positions in violated_bounds.values())
        issues['lineup-rules'] = Finding('\n'.join(rule_findings),
            push_until=next_kickoff.isoformat() if next_kickoff and can_address_rule else None)
    return week, issues


def record_warnings(previous, league, week, issues, now):
    value = copy.deepcopy(previous)
    incidents = value.setdefault('incidents', {})
    prefix = f'{league}:{week}:'
    for key, item in incidents.items():
        if item['league'] == league and item['status'] == 'open' and key not in {prefix + k for k in issues}:
            item.update(status='resolved', resolvedAt=now.isoformat())
    for kind, finding in issues.items():
        key = prefix + kind
        existing = incidents.get(key, {})
        # Only recognize the exact legacy advisory template; never replay an
        # existing confirmed warning merely because it predates the severity field.
        previous = existing.get('severity')
        if previous is None and LEGACY_ADVISORY.search(existing.get('detail', '')):
            previous = 'advisory'
        escalation = previous == 'advisory' and finding.severity == 'confirmed'
        if existing.get('status') != 'open' or escalation:
            incidents[key] = dict(league=league, week=week, status='open', openedAt=now.isoformat(),
                                  detail=finding.detail, severity=finding.severity)
        else:
            existing['detail'] = finding.detail
            # A feed correction to Q does not re-arm an already confirmed warning.
            existing['severity'] = previous or 'confirmed'
            if finding.severity != existing['severity']:
                existing['currentSeverity'] = finding.severity
            else:
                existing.pop('currentSeverity', None)
        if finding.push_until:
            incidents[key]['pushUntil'] = finding.push_until
        else:
            incidents[key].pop('pushUntil', None)
        if finding.shortage_risk:
            incidents[key]['shortageRisk'] = True
        else:
            incidents[key].pop('shortageRisk', None)
    return value


def check(ledger, warnings, mode, now, read=feed):
    validate(ledger, now)
    result = copy.deepcopy(ledger)
    for league in ledger['leagues']:
        try:
            week, issues = inspect(league, now, read)
        except (OSError, IncompleteRead, ValueError, KeyError, TypeError) as error:
            print(f'Guardian check could not verify {league["key"]} ({type(error).__name__}); no receipt issued.')
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


def report(api, now, state, dry, deliver, save, send, phone=None):
    from guardian_health_monitor import REPO, STATE
    warning = decode(api(REPO, 'contents/' + WARNINGS + '?ref=main'))
    coverage = decode(api(REPO, 'contents/' + STATE + '?ref=main'))
    subject = '[Bears] Lineup needs attention'
    receipts = state.get('delivery_receipts', {})
    groups = state.get('guardian_basic_digests', {})
    held, uncertain_members, pending = set(), set(), {}
    uncertain = False
    changed = False
    health = None
    phone_pending = {}
    phone_claims = state.get('guardian_basic_phone_claims', {})
    fresh_checks = {}

    def latest_check(league, week):
        nonlocal health
        if health is None:
            health = decode(api(REPO, 'contents/' + HEALTH + '?ref=main'))
        if (league, week) not in fresh_checks:
            fresh_checks[league, week] = max((stamp(r['checkedAt']) for r in health['checks']
                if r['league'] == league and r['week'] == week
                and timedelta(0) <= now - stamp(r['checkedAt']) <= timedelta(minutes=15)), default=None)
        return fresh_checks[league, week]
    # Preserve the exact membership across a crash after SMTP accepts a digest.
    for group, members in groups.items():
        receipt = receipts.get(group, {})
        status = receipt.get('status')
        if status == 'accepted':
            for member in members:
                if member not in state['sent'] and not dry:
                    state['sent'][member] = dict(subject=subject, sent_at=receipt['accepted_at'])
                    changed = True
                held.add(member)
        elif status in ('sending', 'uncertain', 'partial'):
            uncertain_members.update(members)
    if changed:
        save(state)
    for key, item in sorted(warning.get('incidents', {}).items()):
        if item['status'] != 'open' or item.get('currentSeverity') == 'advisory':
            continue
        severity = item.get('severity')
        if (severity == 'advisory' or (severity is None and LEGACY_ADVISORY.search(item.get('detail', '')))) and item.get('shortageRisk') is not True:
            continue  # Do not revive older blanket Q/D advisories.
        receipt = 'guardian-basic:' + key + ':' + item['openedAt']
        schedule = coverage.get('schedules', {}).get(item['league'], {})
        # An early email must not consume a later, independently timed phone alert.
        if (phone is not None and not dry and not item.get('legacyDelivery')
                and item.get('severity') == 'confirmed' and schedule.get('week') == item['week']
                and item.get('pushUntil') in schedule['kickoffs']
                and timedelta(0) < stamp(item['pushUntil']) - now <= timedelta(minutes=90)
                and hashlib.sha256(receipt.encode()).hexdigest() not in phone_claims):
            checked_at = latest_check(item['league'], item['week'])
            if checked_at and checked_at >= stamp(item['openedAt']):
                league = next(r for r in health['leagues'] if r['key'] == item['league'])
                phone_pending[receipt] = (league, dict(item, pushObservedAt=checked_at.isoformat()))
        if receipt in state['sent'] or receipt in held:
            continue
        previous = receipts.get(receipt, {})
        if receipt in uncertain_members or previous.get('status') in ('sending', 'uncertain', 'partial'):
            uncertain = True
            continue
        if previous.get('status') == 'accepted':
            if not dry:
                state['sent'][receipt] = dict(subject=subject, sent_at=previous['accepted_at'])
                save(state)
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
        if schedule.get('week') != item['week']:
            continue
        kickoffs = [stamp(k) for k in schedule['kickoffs']]
        local = now.astimezone(ZoneInfo('America/New_York'))
        morning = bool(kickoffs and local.date() == min(kickoffs).astimezone(local.tzinfo).date() and 6 <= local.hour < 7)
        if not morning and not any(timedelta(0) < kickoff - now <= timedelta(minutes=90) for kickoff in kickoffs):
            continue  # No off-hours mail flood on handoff or routine daily reads.
        # Do not email a stale warning when no current read could confirm it.
        if not latest_check(item['league'], item['week']):
            continue
        league = next(r for r in health['leagues'] if r['key'] == item['league'])
        pending[receipt] = (league, item)

    if phone_pending:
        claimed = phone(phone_pending, now)
        if claimed:
            cutoff = now - timedelta(days=35)
            state['guardian_basic_phone_claims'] = {
                receipt: at for receipt, at in phone_claims.items() if stamp(at) >= cutoff}
            state['guardian_basic_phone_claims'].update(
                (hashlib.sha256(receipt.encode()).hexdigest(), now.isoformat()) for receipt in claimed)
            save(state)
    if pending and not dry:
        sections = {}
        for league, item in pending.values():
            sections.setdefault((league['key'], item['week'], submit_link(league, item['week'], now)), []).append(item['detail'])
        body = '\n\n'.join(
            f'{league} | Week {week}\n' +
            '\n'.join('- ' + detail.replace('\n', '\n  ') for detail in details) +
            f'\nSubmit New Lineup: {link}'
            for (league, week, link), details in sorted(sections.items())
        )
        body += '\n\nRead-only check: no roster changes were made. Projections and replacement rankings remain in private CHI Tools.'
        members = sorted(pending)
        digest = 'guardian-basic-digest:' + hashlib.sha256('\n'.join(members).encode()).hexdigest()
        state.setdefault('guardian_basic_digests', {})[digest] = members
        save(state)
        deliver(state, digest, lambda: send(subject, body, digest), lambda: save(state))
        for member in members:
            state['sent'][member] = dict(subject=subject, sent_at=now.isoformat())
        save(state)
    if uncertain:
        raise RuntimeError('Guardian lineup warning delivery requires manual review')
