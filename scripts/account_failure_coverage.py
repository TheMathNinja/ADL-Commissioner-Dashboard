"""Discover public owner repositories without reading their source or formulas."""
import re
import base64
import json
from datetime import datetime, timedelta

OWNER = 'TheMathNinja'


def repositories(get_json):
    result = set()
    for page in range(1, 101):
        batch = get_json(f'https://api.github.com/users/{OWNER}/repos?type=owner&per_page=100&page={page}')
        if not isinstance(batch, list):
            raise RuntimeError('Account repository inventory unavailable')
        for repo in batch:
            name = repo.get('full_name', '')
            if (repo.get('owner', {}).get('login', '').lower() != OWNER.lower()
                    or not re.fullmatch(OWNER + r'/[A-Za-z0-9_.-]+', name, re.I)
                    or repo.get('private') is not False):
                raise RuntimeError('Unexpected repository in public owner inventory')
            result.add(name)
        if len(batch) < 100:
            if not result:
                raise RuntimeError('Empty account repository inventory')
            return sorted(result)
    raise RuntimeError('Account repository inventory pagination did not finish')


def recovered_live_watch_cancellation(repo, run, jobs, api, now):
    leagues = {'TheMathNinja/ADL-GM-Dashboard':'ADL', 'TheMathNinja/FAFL-GM-Dashboard':'FAFL'}
    if (repo not in leagues or run.get('path') != '.github/workflows/live_bonus_watch.yml'
            or run.get('conclusion') != 'cancelled' or jobs):
        return False
    try:
        head = api(repo, 'git/ref/heads/live-bonus-watch')['object']['sha']
        item = api(repo, 'contents/live.json?ref=' + head)
        if item.get('encoding') == 'none':
            item = api(repo, 'git/blobs/' + item['sha'])
        snapshot = json.loads(base64.b64decode(item['content']))
        fetched = datetime.fromisoformat(snapshot['fetchedAt'].replace('Z', '+00:00'))
        ended = datetime.fromisoformat(run['updated_at'].replace('Z', '+00:00'))
        teams = snapshot['teams']
        return (snapshot['league'] == leagues[repo]
                and snapshot['season'] == now.year - int(now.month < 3)
                and isinstance(snapshot['week'], int) and 1 <= snapshot['week'] <= 17
                and snapshot['source'] == 'MFL fresh live raw stats with liveScoring fallback'
                and len(teams) == 32 and len({team['id'] for team in teams}) == 32
                and 0 <= (now - fetched).total_seconds() <= timedelta(minutes=10).total_seconds()
                and fetched > ended)
    except (OSError, RuntimeError, ValueError, KeyError, TypeError):
        return False
