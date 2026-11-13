"""Per-message compare-and-swap receipts, using the existing GitHub repository."""
import base64
import hashlib
import json
import os
import urllib.error
import urllib.request
from email_delivery_state import deliver_once


def api(url, payload=None):
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if not token:
        raise RuntimeError('A writable GitHub token is required before sending email')
    headers = {'Authorization': 'Bearer '+token, 'Accept': 'application/vnd.github+json',
               'User-Agent': 'league-email-receipts'}
    request = urllib.request.Request(url, headers=headers,
        data=None if payload is None else json.dumps(payload).encode(),
        method='GET' if payload is None else 'PUT')
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404 and payload is None:
            return None
        raise


def deliver(key, send, request=api):
    repo = os.environ['GITHUB_REPOSITORY']
    digest = hashlib.sha256(key.encode()).hexdigest()
    url = f'https://api.github.com/repos/{repo}/contents/data/email_delivery_receipts/{digest}.json'
    current = request(url+'?ref=main')
    sha = current['sha'] if current else None
    state = json.loads(base64.b64decode(current['content'])) if current else {}

    def save():
        nonlocal sha
        # Do not overwrite another worker's claim after a CAS conflict. A failed
        # response may hide a successful write, so the next run must re-read it.
        payload = {'branch': 'main', 'message': 'Record email delivery receipt',
                   'content': base64.b64encode((json.dumps(state, sort_keys=True)+'\n').encode()).decode()}
        if sha:
            payload['sha'] = sha
        result = request(url, payload)
        sha = result['content']['sha']

    return deliver_once(state, digest, send, save)
