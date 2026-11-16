"""Opaque change detection over public MFL fields, never projection values."""
import hashlib
import json


def fingerprint(week, players):
    if type(week) is not int or not 1 <= week <= 18 or not players:
        raise ValueError('A current week and nonempty roster are required')
    selected = [{'id': str(p['id']), 'rosterStatus': p.get('rosterStatus'),
                 'reportedInjuryStatus': p.get('reportedInjuryStatus'), 'starter': bool(p['starter'])}
                for p in players]
    selected.sort(key=lambda p: p['id'])
    value = json.dumps({'week': week, 'players': selected}, sort_keys=True, separators=(',', ':'), ensure_ascii=True)
    return hashlib.sha256(value.encode()).hexdigest()
