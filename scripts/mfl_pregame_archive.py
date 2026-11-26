"""Archive small, timestamped MFL injury reads on the existing public reporter."""
import base64
import json
import re
from datetime import datetime, timedelta, timezone
from urllib.error import HTTPError
from urllib.parse import urlencode
from zoneinfo import ZoneInfo

from guardian_health_monitor import stamp

REPO = 'TheMathNinja/ADL-Commissioner-Dashboard'
DIRECTORY = 'data/commissioner_alerts/mfl_pregame_designations'
GRACE = timedelta(minutes=15)
LEADS = (120, 90, 60, 30)


def due_slots(kickoffs, now):
    return sorted({slot for kickoff in map(stamp, kickoffs) for minutes in LEADS
                   if timedelta(0) <= now - (slot := kickoff - timedelta(minutes=minutes)) < GRACE})


def capture(coverage, now, request, clock=lambda: datetime.now(timezone.utc)):
    """One live feed read per tick, and an immutable file per verified slot."""
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
    slots = due_slots(info['kickoffs'], now)
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
