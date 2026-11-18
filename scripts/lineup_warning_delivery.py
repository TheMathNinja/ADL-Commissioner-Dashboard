"""One durable notification owner for GM lineup/readiness warning episodes."""
import base64
import hashlib
import json
import os

from email_delivery_state import deliver_once, DeliveryUncertain
from github_email_receipt import api


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def accepted_legacy(key, request):
    identity = digest('r-alert:' + key)
    url = f'https://api.github.com/repos/{os.environ["GITHUB_REPOSITORY"]}/contents/data/email_delivery_receipts/{identity}.json?ref=main'
    record = request(url)
    if not record:
        return False
    state = json.loads(base64.b64decode(record['content']))
    status = state.get('delivery_receipts', {}).get(identity, {}).get('status')
    if status in ('sending', 'uncertain', 'partial'):
        raise DeliveryUncertain('Legacy readiness delivery requires review')
    return status == 'accepted'


def coordinate(state, payload, send, save, legacy=lambda key: False):
    checked_at = payload.get('lineup_checked_at', 0)
    if checked_at < state.get('checked_at', 0):
        return False
    state['checked_at'] = checked_at
    entries = payload['lineup_entries']
    if any(not entry.get('keys') or not all(isinstance(key, str) and key for key in entry['keys']) for entry in entries):
        raise ValueError('Every coordinated warning needs explicit issue identities')
    active = set().union(*(set(entry['keys']) for entry in entries)) if entries else set()
    held = set(payload.get('lineup_held', []))
    resolved = set(payload.get('lineup_resolved', [])) - active - held
    issues = state.setdefault('issues', {})
    for key in resolved:
        issue = issues.setdefault(key, {'epoch': 0, 'active': False})
        if issue['active']:
            issue['active'] = False
        # Positive repair evidence prevents importing an older warning on recurrence.
        issue['verified_repair'] = True
    for key in active | held:
        if key not in issues:
            issues[key] = {'epoch': 0, 'active': True}
        elif not issues[key]['active']:
            issues[key].update(epoch=issues[key]['epoch'] + 1, active=True)
        issue = issues[key]
        old_key = payload.get('lineup_legacy', {}).get(key)
        if old_key and issue['epoch'] == 0 and not issue.get('verified_repair') and 'notified' not in issue:
            if legacy(old_key):
                issue.update(notified=0, legacy_accepted=True)
    blocked = set()
    for batch, members in state.get('batches', {}).items():
        status = state.get('delivery_receipts', {}).get(batch, {}).get('status')
        if status in ('sending', 'uncertain', 'partial'):
            blocked.update(key for key, epoch in members if key in issues and issues[key]['epoch'] == epoch)
    new = sorted(key for key in active - held - blocked if issues[key].get('notified') != issues[key]['epoch'])
    if not new:
        save()
        if active & blocked:
            raise DeliveryUncertain('Previous lineup warning delivery requires review')
        return False
    members = [[key, issues[key]['epoch']] for key in new]
    batch = digest(json.dumps(members, separators=(',', ':')))
    state.setdefault('batches', {})[batch] = members
    selected = [entry['body'] for entry in entries if set(entry['keys']) & set(new)]
    message = dict(payload, body='\n\n'.join([payload['lineup_header'], *dict.fromkeys(selected), payload['lineup_footer']]), cc=[])
    def save_batch():
        if state.get('delivery_receipts', {}).get(batch, {}).get('status') == 'accepted':
            for key in new:
                issues[key]['notified'] = issues[key]['epoch']
        save()

    delivered = deliver_once(state, batch, lambda: send(message), save_batch)
    for key in new:
        issues[key]['notified'] = issues[key]['epoch']
    save()
    return delivered


def deliver_lineup(payload, send, request=api):
    if payload.get('cc'):
        raise ValueError('GM lineup warnings must not CC commissioners')
    scope = digest(json.dumps([payload['lineup_season'], payload['lineup_week'], payload['lineup_franchise'],
                               sorted(payload['to'])], separators=(',', ':')))
    url = f'https://api.github.com/repos/{os.environ["GITHUB_REPOSITORY"]}/contents/data/email_delivery_receipts/lineup-{scope}.json'
    record = request(url + '?ref=main')
    if not record and not payload['lineup_entries']:
        return False
    sha = record['sha'] if record else None
    state = json.loads(base64.b64decode(record['content'])) if record else {}
    previous = json.dumps(state, sort_keys=True)

    def save():
        nonlocal sha, previous
        serialized = json.dumps(state, sort_keys=True)
        if serialized == previous:
            return
        update = dict(branch='main', message='Record coordinated GM warning state',
                      content=base64.b64encode((serialized + '\n').encode()).decode())
        if sha:
            update['sha'] = sha
        result = request(url, update)
        sha = result['content']['sha']
        previous = serialized

    return coordinate(state, payload, send, save, legacy=lambda key: accepted_legacy(key, request))
