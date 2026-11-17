"""Relay owner refresh metadata only. All model work stays in private Actions."""
import json
import os
import uuid
from datetime import timedelta
from urllib.request import Request, urlopen

from guardian_health_monitor import REPO, stamp
from private_actions_policy import paused

URL = 'https://chi-team-tools.fili-mikey.chatgpt.site/api/chi-sync?worker=1'
WORKFLOW = 'sync_chi_team_tools.yml'


def exchange(body=None):
    request = Request(URL, data=None if body is None else json.dumps(body).encode(), headers={
        'OAI-Sites-Authorization': 'Bearer ' + os.environ['CHI_SITE_SERVICE_TOKEN'], 'Content-Type': 'application/json'})
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def dispatch(request_id, owner_requested=False):
    request = Request(f'https://api.github.com/repos/{REPO}/actions/workflows/{WORKFLOW}/dispatches',
                      method='POST', data=json.dumps({'ref': 'main', 'inputs': {'request_id': request_id,
                                                   'owner_requested': owner_requested}}).encode(),
                      headers={'Authorization': 'Bearer ' + os.environ['PRIVATE_REPORT_TOKEN'],
                               'Content-Type': 'application/json'})
    with urlopen(request, timeout=30) as response:
        response.read()


def review(api, now, dry, report, site=exchange, launch=dispatch):
    current = site().get('current')
    if not current or current.get('status') in ('completed', 'failed'):
        return current
    request_id = current['id']
    if str(uuid.UUID(request_id)) != request_id or str(uuid.UUID(current['episode'])) != current['episode']:
        raise ValueError('Invalid sync request identity')
    if current['status'] == 'queued' and current.get('reason') != 'manual' and paused(api):
        print('Automatic CHI sync intentionally deferred; explicit owner refreshes remain eligible.')
        return current
    due = now >= stamp(current['requestedAt']) + timedelta(minutes=25)
    if current['status'] in ('claimed', 'dispatched'):
        # A failed/completed worker has its own reporter. Never create a second
        # missed-start incident or resend an ambiguously accepted dispatch.
        runs = api(REPO, f'actions/workflows/{WORKFLOW}/runs?per_page=100')['workflow_runs']
        run = next((item for item in runs if item.get('display_title') ==
                    'Sync private CHI Team Tools trades - request ' + request_id), None)
        if run and run.get('status') == 'completed':
            if run.get('conclusion') != 'success' and not dry:
                site({'action': 'finish', 'id': request_id, 'outcome': 'failure'})
            elif due and run.get('conclusion') == 'success':
                # A successful run without its fresh receipt is not recovery.
                report(current)
            return current
        if run:
            # The existing workflow reporter owns worker timeouts/failures.
            return current
    if due:
        report(current)
        if not dry:
            site({'action': 'finish', 'id': request_id, 'outcome': 'failure'})
        return current
    if current['status'] != 'queued' or dry:
        return current
    claim_id = str(uuid.uuid4())
    claimed = site({'action': 'claim', 'id': request_id, 'claimId': claim_id}).get('current', {})
    if claimed.get('claimId') != claim_id or claimed.get('status') != 'claimed':
        return current
    if current.get('reason') == 'manual':
        launch(request_id, owner_requested=True)
    else:
        launch(request_id)
    site({'action': 'dispatched', 'id': request_id, 'claimId': claim_id})
    return current
