"""Bounded recovery for the public, generated-only FAFL dashboard rebuild."""
from datetime import timedelta
import hashlib
import json
import re
from urllib.request import Request, urlopen

REPO = 'TheMathNinja/FAFL-GM-Dashboard'
PATH = '.github/workflows/rebuild_bonus_games.yml'
WORKFLOW = 'rebuild_bonus_games.yml'
BLOB = 'c74b1f016cc4a95ed970203653346b0dccb64e79'
INDEX = 'docs/bonus-games/matchups/index.json'
BUILD = 'rebuild: Build and validate selected module from published score cache'
SAVE = 'rebuild: Save generated module'
STEPS = {BUILD.partition(': ')[2], SAVE.partition(': ')[2], 'Request Pages publication'}
LIMIT = timedelta(minutes=45)
FAILURES = {BUILD: {'live-watch-read-exhausted'}, SAVE: {'fafl-rebuild-branch-race', 'live-watch-read-exhausted'}}


def sha(value):
    return isinstance(value, str) and re.fullmatch(r'[a-f0-9]{40}', value) is not None


def owns_retry(state, repo, run):
    return (repo == REPO and run.get('path') == PATH and run.get('event') == 'workflow_dispatch'
            and any(row.get('run_id') == run['id']
                    for row in state.get('fafl_rebuild_repairs', {}).values()))


def descends(repo, first, second, read):
    if not sha(first) or not sha(second):
        return False
    if first == second:
        return True
    comparison = read(repo, f'compare/{first}...{second}')
    return comparison.get('status') == 'ahead' and comparison.get('behind_by') == 0


def published_index():
    from time import time
    url = 'https://themathninja.github.io/FAFL-GM-Dashboard/bonus-games/matchups/index.json?recovery=' + str(int(time())//60)
    request = Request(url, headers={'User-Agent':'FAFL-rebuild-verifier', 'Cache-Control':'no-cache'})
    with urlopen(request, timeout=8) as response:
        raw = response.read(65537)
    if len(raw) > 65536:
        raise ValueError('FAFL matchup index is oversized')
    return raw


def git_blob(raw):
    return hashlib.sha1(f'blob {len(raw)}\0'.encode() + raw).hexdigest()


def verified_rebuild(original, candidate, completed, read, stamp, read_live=published_index):
    """A green job or accepted Pages request alone is not publication evidence."""
    if (candidate.get('path') != PATH or candidate.get('head_branch') != 'main'
            or candidate.get('event') not in ('push', 'workflow_dispatch')
            or candidate.get('conclusion') != 'success'):
        return False
    for job in completed:
        if (job.get('name') != 'rebuild' or job.get('conclusion') != 'success'
                or not STEPS <= {s['name'] for s in job.get('steps', []) if s.get('conclusion') == 'success'}):
            continue
        try:
            began = stamp(job['started_at'])
            if began <= stamp(original['updated_at']):
                continue
            if not descends(REPO, original.get('head_sha'), candidate.get('head_sha'), read):
                continue
            main = read(REPO, 'git/ref/heads/main')['object']['sha']
            if not descends(REPO, candidate.get('head_sha'), main, read):
                continue
            expected = read(REPO, f'contents/{INDEX}?ref={main}').get('sha')
            raw = read_live()
            index = json.loads(raw)
            if (git_blob(raw) == expected and index.get('league') == 'FAFL'
                    and type(index.get('season')) is int and type(index.get('currentWeek')) is int
                    and 1 <= index['currentWeek'] <= 17
                    and began <= stamp(index['generatedAt']) <= stamp(candidate['updated_at'])):
                return True
        except (OSError, RuntimeError, ValueError, KeyError, TypeError, AttributeError):
            continue
    return False


def consider_rebuild(state, repo, run, failed, diagnoses, now, *, dry, read, dispatch, save, stamp):
    if (repo != REPO or run.get('path') != PATH or run.get('head_branch') != 'main'
            or run.get('event') not in ('push', 'workflow_dispatch') or run.get('run_attempt', 1) != 1
            or run.get('status') != 'completed' or run.get('conclusion') != 'failure'
            or type(run.get('id')) is not int or len(failed) != 1
            or diagnoses.get('rebuild') not in FAILURES.get(failed[0], ())):
        return None
    if owns_retry(state, repo, run):
        return None
    repairs = state.get('fafl_rebuild_repairs', {})
    key = str(run['id'])
    previous = repairs.get(key)
    if previous:
        if previous['status'] == 'rejected':
            return 'replay_rejected'
        return 'pending' if now < stamp(previous['deadline']) else 'retry_deadline'
    ended = stamp(run['updated_at'])
    if dry or not timedelta(0) <= now - ended < LIMIT:
        return None
    if any(now - stamp(row['requested_at']) < timedelta(hours=24) for row in repairs.values()):
        return 'replay_limit'
    try:
        repository = read(repo, '')
        if repository.get('private') is not False or repository.get('default_branch') != 'main':
            return None
        workflow = read(repo, f'actions/workflows/{WORKFLOW}')
        if workflow.get('state') != 'active' or workflow.get('path') != PATH:
            return None
        main = read(repo, 'git/ref/heads/main')['object']['sha']
        if not descends(repo, run.get('head_sha'), main, read):
            return None
        if read(repo, f'contents/{PATH}?ref={main}').get('sha') != BLOB:
            return None
        fresh = read(repo, f'actions/workflows/{WORKFLOW}/runs?branch=main&per_page=10')['workflow_runs']
        if any(item.get('status') != 'completed' and type(item.get('id')) is int for item in fresh):
            return 'pending'
    except (OSError, RuntimeError, ValueError, KeyError, TypeError, AttributeError):
        return 'replay_unavailable'
    receipt = {'status': 'sending', 'requested_at': now.isoformat(),
               'deadline': (ended + LIMIT).isoformat(), 'source': main}
    state.setdefault('fafl_rebuild_repairs', {})[key] = receipt
    save(state)
    status, run_id = dispatch()
    receipt['status'] = status
    if type(run_id) is int:
        receipt['run_id'] = run_id
    save(state)
    return 'replay_rejected' if status == 'rejected' else 'pending'
