"""Archive small, timestamped MFL injury reads on the existing public reporter."""
import base64
import json
import re
from datetime import datetime, timedelta, timezone
from http.client import HTTPException
from urllib.error import HTTPError
from urllib.parse import urlencode
from zoneinfo import ZoneInfo

from guardian_health_monitor import nfl_week_schedule, stamp

REPO = 'TheMathNinja/ADL-Commissioner-Dashboard'
DIRECTORY = 'data/commissioner_alerts/mfl_pregame_designations'
GRACE = timedelta(minutes=15)
LEADS = (120, 90, 60, 30)
CUTOFF = timedelta(hours=48)
CUTOFF_OFFSETS = (-15, 1)


def due_slots(kickoffs, now, *, cutoff_only=False):
    slots = set()
    for kickoff in map(stamp, kickoffs):
        cutoff = kickoff - CUTOFF
        slots.update(cutoff + timedelta(minutes=offset) for offset in CUTOFF_OFFSETS)
        if not cutoff_only:
            slots.update(kickoff - timedelta(minutes=lead) for lead in LEADS)
    return sorted(slot for slot in slots if timedelta(0) <= now - slot < GRACE)


def capture(coverage, now, request, clock=lambda: datetime.now(timezone.utc), next_schedule=nfl_week_schedule):
    """One injury feed read per due week, and an immutable file per verified slot."""
    if not coverage or 'ADL' in coverage.get('scheduleFailures', {}):
        return 0
    info = coverage.get('schedules', {}).get('ADL')
    if not info or not 1 <= int(info['week']) <= 18:
        return 0
    week = int(info['week'])
    local = now.astimezone(ZoneInfo('America/New_York'))
    season = local.year if local.month > 2 else local.year - 1
    if local.month not in (9, 10, 11, 12, 1):
        return 0
    stored = capture_week(season, week, due_slots(info['kickoffs'], now), request, clock)
    last = max(map(stamp, info['kickoffs']), default=None)
    # The first cutoff of the next week can arrive before the current roster week rolls over.
    if week < 18 and last and last - CUTOFF <= now <= last + timedelta(days=7):
        try:
            following = next_schedule(week + 1, now)
            if following is not None:
                if following['week'] != week + 1:
                    raise ValueError('Upcoming MFL schedule week mismatch')
                slots = due_slots(following['kickoffs'], now, cutoff_only=True)
                stored += capture_week(season, week + 1, slots, request, clock)
        except (OSError, HTTPException, ValueError, TypeError, KeyError) as error:
            print(f'::warning::Upcoming MFL cutoff archive not verified ({type(error).__name__}).')
    return stored


def capture_week(season, week, slots, request, clock):
    root = f'https://api.github.com/repos/{REPO}/contents/{DIRECTORY}/{season}/week{week:02}'
    missing = []
    for slot in slots:
        url = f'{root}/mfl_{slot:%Y%m%dT%H%M%SZ}.json'
        if request(url + '?ref=main') is None:
            missing.append((slot, url))
    if not missing:
        return 0
    query = urlencode(dict(TYPE='injuries', W=week, JSON=1))
    feed = request(f'https://api.myfantasyleague.com/{season}/export?{query}')['injuries']
    observed = clock()
    if int(feed['week']) != week or not isinstance(feed.get('injury'), list) or not feed['injury']:
        raise ValueError('Incomplete MFL injury feed')
    injury = {}
    for row in feed['injury']:
        identity = str(row['id'])
        status = str(row['status']).strip()
        if not re.fullmatch(r'[0-9]+', identity) or not re.fullmatch(r'[A-Za-z ()/-]{1,40}', status):
            raise ValueError('Invalid MFL injury designation')
        if identity in injury and injury[identity] != status:
            raise ValueError('Ambiguous MFL injury designation')
        injury[identity] = status
    result = 0
    for slot, url in missing:
        if not timedelta(0) <= observed - slot < GRACE:
            continue  # We cannot backfill an observation after the slot.
        document = dict(source='mfl-injuries', season=season, week=week, slot=slot.isoformat(),
                        observedAt=observed.isoformat(),
                        injuries=[dict(player_id=i, player_status=s) for i, s in sorted(injury.items())])
        content = base64.b64encode(json.dumps(document, separators=(',', ':')).encode()).decode()
        try:
            request(url, dict(branch='main', message='Record MFL pregame injury observation', content=content), method='PUT')
        except HTTPError as err:
            if err.code not in (409, 422) or request(url + '?ref=main') is None:
                raise
        result += 1
    return result
