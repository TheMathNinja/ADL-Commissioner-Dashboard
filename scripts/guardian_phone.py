"""Send minimal, expiring hints to the owner-only CHI Tools Site."""
from datetime import timedelta
import hashlib
import json
from urllib.request import build_opener, HTTPRedirectHandler, Request

from guardian_health_monitor import stamp

URL = 'https://chi-team-tools.fili-mikey.chatgpt.site/api/lineup-push'


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def send_for_pending(pending, now, token, transport=None):
    if transport is None:
        transport = build_opener(NoRedirect).open
    claimed = set()
    for receipt, (league, item) in pending.items():
        if not item.get('pushUntil') or item.get('severity') != 'confirmed':
            continue
        try:
            expires, observed = stamp(item['pushUntil']), stamp(item.get('pushObservedAt', item['openedAt']))
            if not (timedelta(0) < expires - now <= timedelta(minutes=90)
                    and timedelta(0) <= now - observed <= timedelta(minutes=15)):
                continue
            alert = {
                'id': hashlib.sha256(receipt.encode()).hexdigest(),
                'league': league['key'],
                'observedAt': observed.isoformat(),
                'expiresAt': expires.isoformat(),
            }
            request = Request(URL, data=json.dumps(alert).encode(), method='PUT', headers={
                'Content-Type': 'application/json', 'OAI-Sites-Authorization': 'Bearer ' + token,
            })
            with transport(request, timeout=8) as response:
                result = json.load(response)
            if result.get('status') in {'accepted', 'already-claimed'}:
                claimed.add(receipt)
            if result.get('status') == 'unavailable':
                print('Owner phone push unavailable; email delivery continues.')
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            print('Owner phone push unavailable; email delivery continues.')
    return claimed
