"""Diagnose known failure patterns and bound replay to reviewed read-only jobs."""
from datetime import datetime, timedelta
import hashlib
import re


READ_ONLY_WORKFLOWS = {
    ('TheMathNinja/ADL-Commissioner-Dashboard', '.github/workflows/dashboard_watchdog.yml'):
        'b86b706c9ba48561254faa87326626e16d48759f',
    ('TheMathNinja/ADL-GM-Dashboard', '.github/workflows/test_trophy_room.yml'):
        '74799c3ac4dee6995ad6da827d2b466f0a1b3502',
}
DEADLINE = timedelta(minutes=30)
RULES = (
    ('live-watch-read-exhausted', r'^error: mfl public read retry exhausted: [a-z]+$',
     'The collector retried the MFL read; the reporter checked for a newer valid snapshot.'),
    ('generated-output-conflict', r'generated (?:output conflicts|publication rejected)|'
     r'main advanced again during the regenerated build|non-fast-forward|could not apply\b',
     'Inspect the publisher and verify a rebuild from current main; do not replay stale output.'),
    ('credential-or-permission', r'\b(?:http(?: error)?\s+40[13]|bad credentials|permission denied|'
     r'resource not accessible by integration|invalid_grant)\b',
     'Check the credential, access policy, or upstream authorization. Do not bypass a 403.'),
    ('stale-or-incomplete-input', r'\b(?:missing or stale|stale or unavailable|source snapshot|'
     r'incomplete (?:feed|snapshot|lineup)|target_input_pending)\b',
     'Verify the current upstream input and its publication receipt before refreshing.'),
    ('validation-regression', r'\b(?:assertionerror|schema mismatch|contract mismatch|'
     r'regression test failed|failed tests?)\b',
     'Reproduce the failed check and repair its cause before releasing.'),
    ('pages-deployment-service-error', r'\bfailed to create deployment \(status: 50[0234]\) with build version\b',
     'Wait briefly for a verified Pages deployment of this revision or a descendant.'),
    ('transient-upstream-read', r'\b(?:http(?: error|/\d(?:\.\d)?)?\s+(?:408|429|50[0234])|'
     r'connection reset|temporary failure in name resolution|econnreset|etimedout|read timed out)\b',
     'A reviewed read-only workflow may be replayed once.'),
)


def diagnose(errors):
    joined = '\n'.join(errors[-30:]).casefold()
    for code, pattern, action in RULES:
        if re.search(pattern, joined, re.MULTILINE):
            return code, action
    return 'unclassified', 'Inspect the run logs and establish a reproducible cause before changing production.'


def repair_key(repo, run):
    return f'{repo}:{run["id"]}:1'


def read_time(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def consider_replay(state, repo, run, failed, diagnoses, now, *, dry_run, read, request, save):
    """Persist intent before POST; never repeat a request with uncertain acceptance."""
    path = run.get('path')
    blob = READ_ONLY_WORKFLOWS.get((repo, path))
    first_attempt = run.get('run_attempt', 1) == 1
    if not blob or not first_attempt or type(run.get('id')) is not int:
        return None
    key = repair_key(repo, run)
    entries = state.get('automation_repairs', {})
    previous = entries.get(key)
    if previous:
        if previous['status'] == 'rejected':
            return 'replay_rejected'
        return 'pending' if now < read_time(previous['deadline']) else 'retry_deadline'
    started = state.get('automation_repair_enabled_at')
    if (dry_run or not started or run.get('head_branch') != 'main'
            or run.get('event') not in {'schedule', 'workflow_dispatch'}
            or run.get('status') != 'completed' or run.get('conclusion') != 'failure'
            or len(failed) != 1 or diagnoses.get(failed[0].partition(': ')[0]) != 'transient-upstream-read'):
        return None
    ended = read_time(run['updated_at'])
    if not read_time(started) <= ended <= now or now - ended >= DEADLINE:
        return None
    if any(item.get('requested_at', '')[:10] == now.date().isoformat() and item.get('family') == path
           for item in entries.values()):
        return 'replay_limit'
    sha = run.get('head_sha') or ''
    if not re.fullmatch(r'[a-f0-9]{40}', sha):
        return None
    try:
        if read(repo, '').get('private') is not False:
            return None  # A visibility change must not start spending private minutes.
        current = read(repo, f'actions/runs/{run["id"]}')
        if any(current.get(k) != run.get(k) for k in
               ('id', 'run_attempt', 'head_sha', 'head_branch', 'event', 'path', 'status', 'conclusion')):
            return None
        contents = read(repo, f'contents/{path}?ref={sha}')
        if contents.get('sha') != blob:
            return None
    except (OSError, RuntimeError, ValueError, KeyError):
        return 'replay_unavailable'
    receipt = {'status': 'sending', 'requested_at': now.isoformat(),
               'deadline': (ended + DEADLINE).isoformat(), 'family': path}
    state.setdefault('automation_repairs', {})[key] = receipt
    save(state)
    result = request(repo, run['id'])
    state['automation_repairs'][key]['status'] = result
    save(state)
    return 'replay_rejected' if result == 'rejected' else 'pending'


def fingerprint(errors):
    return hashlib.sha256('\n'.join(errors[-4:]).encode()).hexdigest() if errors else 'unclassified'
