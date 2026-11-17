"""Reuse only successful, pinned audits of identical input content, for <=24h.

Git tree metadata contains hashes and paths, not private file contents. No private
source is downloaded, logged or uploaded by the public audit launcher.
"""
import base64
import hashlib
import json
import subprocess
from datetime import datetime, timedelta, timezone

PRIVATE = 'TheMathNinja/Chicago-Bears-Lineup-Guardian'
PATH = 'data/automation_audit_receipts.json'
REPOS = {key: 'TheMathNinja/' + name for key, name in (
    ('guardian', 'Chicago-Bears-Lineup-Guardian'), ('commissioner', 'ADL-Commissioner-Dashboard'),
    ('adl', 'ADL-GM-Dashboard'), ('fafl', 'FAFL-GM-Dashboard'))}
OPERATIONAL = {
    'guardian': {'data/state.json', 'data/weekly_projection_cache.json', 'data/guardian_coverage.json',
                 'data/guardian_health.json', 'data/actions_budget.json', 'data/chi_forecast_request.json',
                 'data/guardian_dispatch.json', 'docs/index.html', PATH},
    'commissioner': {'data/workflow_failure_email_state.json', 'data/weekly_completion_email_state.json'},
}


def api(path, method='GET', body=None):
    args = ['gh', 'api', path]
    if method != 'GET':
        args += ['--method', method, '--input', '-']
    result = subprocess.run(args, input=json.dumps(body) if body is not None else None,
                            capture_output=True, text=True, timeout=45, check=True)
    return json.loads(result.stdout)


def fingerprint(trees):
    rows = []
    for key in sorted(REPOS):
        tree = trees[key]
        if tree.get('truncated'):
            raise RuntimeError('Cannot reuse an audit with incomplete Git tree evidence')
        for item in tree['tree']:
            path = item['path']
            if path in OPERATIONAL.get(key, set()):
                continue
            if key == 'guardian' and path.startswith(('data/audits/', 'docs/audits/')):
                continue
            if item['type'] in ('blob', 'commit'):
                rows.append((key, path, item['sha'], item.get('mode')))
    return hashlib.sha256(json.dumps(sorted(rows), separators=(',', ':')).encode()).hexdigest()


def inputs():
    revisions, trees = {}, {}
    for key, repo in REPOS.items():
        commit = api(f'repos/{repo}/commits/main')
        revisions[key] = commit['sha']
        trees[key] = api(f'repos/{repo}/git/trees/{commit["commit"]["tree"]["sha"]}?recursive=1')
    return revisions, fingerprint(trees)


def load():
    try:
        original = api(f'repos/{PRIVATE}/contents/{PATH}')
    except subprocess.CalledProcessError as error:
        if 'HTTP 404' not in (error.stderr or ''):
            raise
        return {}, None
    return json.loads(base64.b64decode(original['content'])), original['sha']


def existing(audit, digest):
    """Reuse an identical live/successful run, including after a lost receipt write."""
    suffix = ' - inputs ' + digest
    prefix = 'Private league audit - ' + audit + ' - source '
    now = datetime.now(timezone.utc)
    response = api(f'repos/{PRIVATE}/actions/workflows/league-audit.yml/runs?per_page=100&branch=main')
    for run in response['workflow_runs']:
        title = run.get('display_title', '')
        age = (now - datetime.fromisoformat(run['created_at'].replace('Z', '+00:00'))).total_seconds()
        if (run.get('event') != 'workflow_dispatch' or not title.startswith(prefix)
                or not title.endswith(suffix) or not 0 <= age < 86400):
            continue
        if run.get('status') != 'completed' or run.get('conclusion') == 'success':
            return run
    return None


def reusable(receipt, digest, now):
    try:
        finished = datetime.fromisoformat(receipt['completedAt'].replace('Z', '+00:00'))
        return (receipt.get('schemaVersion') == 1 and receipt['fingerprint'] == digest
                and receipt['conclusion'] == 'success' and 0 <= (now - finished).total_seconds() < 86400
                and str(receipt['runId']).isdigit())
    except (KeyError, ValueError, TypeError):
        return False


def record(audit, digest, revisions, run_id):
    value, sha = load()
    value[audit] = {'schemaVersion': 1, 'fingerprint': digest, 'revisions': revisions,
                    'runId': str(run_id), 'conclusion': 'success',
                    'completedAt': datetime.now(timezone.utc).isoformat()}
    body = {'message': 'Record pinned private audit receipt', 'branch': 'main',
            'content': base64.b64encode((json.dumps(value, indent=2) + '\n').encode()).decode()}
    if sha:
        body['sha'] = sha
    # Cache publication is optional; conflicts never convert a failed audit to success.
    api(f'repos/{PRIVATE}/contents/{PATH}', 'PUT', body)
