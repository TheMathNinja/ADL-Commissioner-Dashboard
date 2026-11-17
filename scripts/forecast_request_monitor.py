"""Poll only private request metadata; never fetch CHI source or forecast values."""
import copy
import json
import os
import re
from datetime import timedelta
from urllib.request import Request, urlopen

from guardian_health_monitor import REPO, decode, persist, stamp
from private_actions_policy import paused

PATH = 'data/chi_forecast_request.json'


def missing(error):
    while error.__cause__ is not None:
        error = error.__cause__
    return getattr(error, 'code', None) == 404


def read(api):
    try:
        original = api(REPO, 'contents/' + PATH + '?ref=main')
    except (OSError, RuntimeError) as error:
        if missing(error):
            return None, None
        raise
    return decode(original), original


def validate(value):
    if (value.get('schemaVersion') != 1 or not re.fullmatch('[a-f0-9]{64}', value.get('signature', ''))
            or not re.fullmatch('[a-f0-9]{64}', value.get('episode', ''))
            or value.get('status') not in ('pending', 'attention', 'verified')
            or type(value.get('week')) is not int or not 1 <= value['week'] <= 16):
        raise RuntimeError('Invalid private forecast request metadata')
    for name in ('deadlineAt', 'requestedAt', 'nextPollAt'):
        stamp(value[name])


def problem(value, now):
    if value['status'] == 'verified':
        return False
    claim, checked = value.get('pollClaimedAt'), value.get('lastCheckedAt')
    missed = (claim and (not checked or stamp(checked) < stamp(claim))
              and now >= stamp(claim) + timedelta(minutes=10))
    return bool(missed or value['status'] == 'attention' or now >= stamp(value['deadlineAt']))


def dispatch(signature, week):
    body = {'ref': 'main', 'inputs': {'resume_signature': signature, 'through_week': str(week)}}
    request = Request(f'https://api.github.com/repos/{REPO}/actions/workflows/refresh_chi_team_tools.yml/dispatches',
                      method='POST', headers={'Authorization': 'Bearer ' + os.environ['PRIVATE_REPORT_TOKEN'],
                                              'Content-Type': 'application/json', 'Accept': 'application/vnd.github+json'},
                      data=json.dumps(body).encode())
    # A persisted lease owns this ambiguous dispatch. Never blindly resend it.
    with urlopen(request, timeout=30) as response:
        response.read()


def review(api, now, dry, report):
    value, original = read(api)
    if value is None:
        return
    validate(value)
    if problem(value, now):
        report(value)
    if value['status'] == 'verified' or now < stamp(value['nextPollAt']):
        return value
    if paused(api):
        print('Private forecast status dispatch deferred for budget conservation; completion and deadlines remain unverified.')
        return value
    claim, checked = value.get('pollClaimedAt'), value.get('lastCheckedAt')
    if claim and (not checked or stamp(checked) < stamp(claim)) and now < stamp(claim) + timedelta(minutes=10):
        return value
    if not dry:
        claimed = copy.deepcopy(value)
        claimed.update(pollClaimedAt=now.isoformat(), nextPollAt=(now + timedelta(minutes=20)).isoformat())
        persist(PATH, original, claimed)
        dispatch(value['signature'], value['week'])
    return value


