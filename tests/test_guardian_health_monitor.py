import copy
import io
import ssl
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import os
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import guardian_health_monitor as monitor

NOW = datetime(2026, 11, 15, 17, 0, tzinfo=timezone.utc)


def ledger():
    return {'schemaVersion': 1, 'generatedAt': NOW.isoformat(), 'checks': [],
            'leagues': [{'key': k, 'leagueId': '1', 'franchiseId': '0005'} for k in ('ADL', 'FAFL')]}


def state():
    return {'activatedAt': NOW.isoformat(), 'incidents': {}, 'schedules': {}}


def schedule(row, now):
    return {'week': 10, 'kickoffs': [(NOW + timedelta(minutes=90)).isoformat()]}


class MonitorTests(unittest.TestCase):
    def test_public_get_recovers_after_tls_timeout_and_truncated_payload(self):
        with patch.object(monitor, 'urlopen', side_effect=[
            URLError(TimeoutError('handshake timed out')), io.BytesIO(b'{'), io.BytesIO(b'{"week":12}')
        ]) as fetch, patch.object(monitor.time, 'sleep') as sleep:
            self.assertEqual(monitor.public_json('https://api.myfantasyleague.com'), {'week':12})
        self.assertEqual([c.kwargs['timeout'] for c in fetch.call_args_list], [8, 10, 12])
        self.assertEqual([c.args[0] for c in sleep.call_args_list], [1, 2])

    def test_public_get_retries_only_transient_errors(self):
        denied = HTTPError('https://api.myfantasyleague.com', 403, 'Forbidden', {}, None)
        for error, attempts in ((TimeoutError(), 3), (denied, 1),
                                (URLError(ssl.SSLCertVerificationError('invalid certificate')), 1)):
            with self.subTest(error=error), patch.object(monitor, 'urlopen', side_effect=error) as fetch, \
                    patch.object(monitor.time, 'sleep'):
                with self.assertRaises(type(error)):
                    monitor.public_json('https://api.myfantasyleague.com')
                self.assertEqual(fetch.call_count, attempts)

    def test_failed_schedule_refresh_still_assesses_cached_window(self):
        original = dict(state(), schedules={'FAFL': schedule({}, NOW)})
        def fail_fafl(league, now):
            if league['key'] == 'FAFL':
                raise TimeoutError()
            return schedule(league, now)
        first = monitor.evaluate(ledger(), original, NOW, fail_fafl)
        later = monitor.evaluate(ledger(), first, NOW + timedelta(minutes=15), fail_fafl)
        self.assertEqual(later['schedules']['FAFL']['week'], 10)
        self.assertEqual({p['mode'] for p in later['incidents'].values() if p['league']=='FAFL'},
                         {'monitor','schedule'})
        recovered = monitor.evaluate(ledger(), later, NOW + timedelta(minutes=16), schedule)
        self.assertEqual(recovered['scheduleFailures'], {})
        self.assertEqual({p['mode']: p['status'] for p in recovered['incidents'].values() if p['league']=='FAFL'},
                         {'monitor':'open','schedule':'resolved'})

    def test_fifteen_minute_reads_are_healthy_but_a_missed_slot_is_not(self):
        start = datetime(2026, 11, 16, 19, tzinfo=timezone.utc)
        schedules = {'ADL': {'week':10,'kickoffs':[(start+timedelta(minutes=90)).isoformat()]}}
        checks = [{'league':'ADL','week':10,'mode':'monitor','checkedAt':(start+timedelta(minutes=m,seconds=1)).isoformat()}
                  for m in range(0, 90, 15)]
        for minute in range(1, 101):
            visible = [c for c in checks if monitor.stamp(c['checkedAt']) <= start+timedelta(minutes=minute)]
            self.assertEqual(monitor.assess(visible, schedules, start+timedelta(minutes=minute), start), [])
        missing = checks[:1]
        self.assertEqual(monitor.assess(missing,schedules,start+timedelta(minutes=24),start),[])
        self.assertEqual(len(monitor.assess(missing,schedules,start+timedelta(minutes=25),start)),1)
        # The first check never starting is still detected in ten minutes.
        self.assertEqual(len(monitor.assess([],schedules,start+timedelta(minutes=10),start)),1)
        # A missed final slot cannot be cleared by earlier healthy checks.
        self.assertEqual(len(monitor.assess(checks[:-1],schedules,start+timedelta(minutes=90),start)),1)

    def test_optional_opaque_input_hash_is_backward_compatible(self):
        value = ledger()
        self.assertIs(monitor.validate(value, NOW), value)
        value['publicInputs'] = {'ADL': {'week': 10, 'checkedAt': NOW.isoformat(), 'fingerprint': 'a' * 64}}
        self.assertIs(monitor.validate(value, NOW), value)
        value['publicInputs']['ADL']['nextCheckAt'] = (NOW + timedelta(minutes=15)).isoformat()
        self.assertIs(monitor.validate(value, NOW), value)
        value['publicInputs']['ADL']['players'] = ['not allowed']
        with self.assertRaises(ValueError):
            monitor.validate(value, NOW)

    def test_new_cadence_matches_private_engine_and_preserves_old_missed_windows(self):
        root = os.environ.get('GUARDIAN_TEST_ROOT')
        if not root:
            self.skipTest('Private reference is supplied to the full audit')
        sys.path.insert(0, str(Path(root) / 'scripts'))
        from check_guardian_coverage import assess as reference
        from export_health_receipts import export
        for start, slots in ((datetime(2026,11,16,19,tzinfo=timezone.utc), range(0,90,15)),
                             (datetime(2026,11,22,16,30,tzinfo=timezone.utc), (15,45,75))):
          scopes={'ADL':{'week':10,'kickoffs':[(start+timedelta(minutes=90)).isoformat()]}}
          for missing_slot in (None, *slots):
            audits=[]
            for minute in slots:
                if minute == missing_slot: continue
                checked=start+timedelta(minutes=minute,seconds=1)
                audits.append({'runMode':'monitor','dryRun':False,'completedAt':(checked+timedelta(seconds=2)).isoformat(),
                               'results':[{'key':'ADL','week':10,'status':'ok','checkedAt':checked.isoformat()}],
                               'snapshots':[{'league':'ADL','week':10,'players':[1],'capturedAt':(checked+timedelta(seconds=1)).isoformat()}]})
            for minute in range(0,101):
                now=start+timedelta(minutes=minute)
                visible=[a for a in audits if monitor.stamp(a['completedAt']) <= now]
                with patch('export_health_receipts.datetime', wraps=datetime) as clock:
                    clock.now.return_value=now
                    checks=export(visible,ledger()['leagues'])['checks']
                self.assertEqual(monitor.assess(checks,scopes,now,start),reference(visible,scopes,now,start))
        old_checks=[{'league':'ADL','week':10,'mode':'monitor','checkedAt':NOW.isoformat()}]
        self.assertEqual(len(monitor.assess(old_checks,{'ADL':schedule({},NOW)},NOW+timedelta(minutes=11),NOW)),1)
    def test_matches_private_deadline_engine(self):
        root = os.environ.get('GUARDIAN_TEST_ROOT')
        if not root:
            self.skipTest('Private reference is supplied only to the local/private cross-repository gate')
        sys.path.insert(0, str(Path(root) / 'scripts'))
        from check_guardian_coverage import assess as reference
        from export_health_receipts import export
        for mode in ('monitor', 'initial'):
            for status in ('ok', 'changed', 'idle', 'warning', 'error'):
                for offset in (-100, -10, 0, 5, 15):
                    checked = NOW + timedelta(minutes=offset)
                    audit = {'runMode': mode, 'dryRun': False,
                             'completedAt': (checked + timedelta(seconds=2)).isoformat(),
                             'results': [{'key': 'ADL', 'week': 10, 'status': status,
                                          'reason': 'roster_needs_attention', 'checkedAt': checked.isoformat()}],
                             'snapshots': [{'league': 'ADL', 'week': 10, 'players': [1],
                                            'capturedAt': (checked + timedelta(seconds=1)).isoformat()}]}
                    checks = export([audit], ledger()['leagues'])['checks']
                    schedules = {'ADL': schedule({}, NOW)}
                    activated = NOW - timedelta(days=2)
                    for minute in (9, 10, 20, 90, 120):
                        now = NOW + timedelta(minutes=minute)
                        self.assertEqual(monitor.assess(checks, schedules, now, activated),
                                         reference([audit], schedules, now, activated))

    def test_never_started_both_leagues_at_ten_minutes(self):
        for minute, count in ((9, 0), (10, 2)):
            result = monitor.evaluate(ledger(), state(), NOW + timedelta(minutes=minute), schedule)
            self.assertEqual(sum(i['status'] == 'open' for i in result['incidents'].values()), count)

    def test_recovery_and_independent_initial_failure(self):
        value = ledger()
        original = monitor.evaluate(value, state(), NOW + timedelta(minutes=10), schedule)
        value['checks'] = [{'league': k, 'week': 10, 'mode': 'monitor',
                            'checkedAt': (NOW + timedelta(minutes=11)).isoformat()} for k in ('ADL', 'FAFL')]
        recovered = monitor.evaluate(value, original, NOW + timedelta(minutes=12), schedule)
        self.assertTrue(all(i['status'] == 'resolved' for i in recovered['incidents'].values()))
        value['checks'].pop()
        still_failed = monitor.evaluate(value, original, NOW + timedelta(minutes=12), schedule)
        self.assertEqual([i['league'] for i in still_failed['incidents'].values() if i['status'] == 'open'], ['FAFL'])

    def test_stale_ledger_is_not_a_new_success(self):
        value = ledger()
        value['generatedAt'] = (NOW - timedelta(days=5)).isoformat()
        result = monitor.evaluate(value, state(), NOW + timedelta(minutes=10), schedule)
        self.assertEqual(len(result['incidents']), 2)

    def test_missed_window_survives_week_rollover(self):
        original = monitor.evaluate(ledger(), state(), NOW + timedelta(minutes=100), schedule)
        next_schedule = lambda row, now: {'week': 11, 'kickoffs': [(NOW + timedelta(days=7)).isoformat()]}
        result = monitor.evaluate(ledger(), original, NOW + timedelta(days=1), next_schedule)
        self.assertEqual(sum(i['status'] == 'open' and i['week'] == 10 for i in result['incidents'].values()), 2)

    def test_refuse_unknown_payload_and_future_receipt(self):
        value = ledger()
        value['rosters'] = 'private'
        with self.assertRaises(ValueError):
            monitor.validate(value, NOW)
        value = ledger()
        value['checks'] = [{'league': 'ADL', 'week': 10, 'mode': 'monitor',
                            'checkedAt': (NOW + timedelta(seconds=1)).isoformat()}]
        with self.assertRaises(ValueError):
            monitor.validate(value, NOW)

    def test_dry_refresh_never_writes(self):
        import base64, json
        def api(repo, path):
            value = ledger() if 'guardian_health' in path else dict(state(), schedules={'ADL': schedule({}, NOW), 'FAFL': schedule({}, NOW)})
            return {'sha': 'test', 'content': base64.b64encode(json.dumps(value).encode()).decode()}
        with patch.object(monitor, 'persist') as persist, patch.object(monitor, 'schedule', schedule):
            # evaluate's injectable default is bound at definition; no network is needed here.
            with patch.object(monitor, 'public_json', side_effect=OSError('offline')):
                monitor.refresh(api, NOW + timedelta(minutes=10), dry=True)
            persist.assert_not_called()

    # Production reporter 45649967655: coverage assessment got HTTP 500,
    # and the next phase found only a stale receipt.
    def test_ambiguous_coverage_write_uses_exact_readback_before_retry(self):
        import base64, json
        from urllib.error import HTTPError

        def error(code):
            return HTTPError('https://api.github.com', code, 'GitHub contents write', {}, None)

        value = {'generatedAt': NOW.isoformat(), 'incidents': []}
        def response(sha, document):
            return {'sha': sha, 'content': base64.b64encode(json.dumps(document).encode()).decode()}
        original = response('old', {'generatedAt': 'old'})
        for responses, writes, expected in (
            ([response('accepted', value)], [error(500)], None),
            ([original], [error(500), None], None),
            ([original, response('accepted', value)], [error(500), error(503)], None),
            ([response('newer', {'generatedAt': 'newer'})], [error(500)], 500),
            ([original, original], [error(500), error(500)], 500),
            ([], [error(403)], 403),
        ):
            with self.subTest(writes=[item.code if item else None for item in writes], expected=expected):
                with patch.object(monitor, 'persist', side_effect=writes) as persist, \
                     patch.object(monitor, 'decode', wraps=monitor.decode):
                    read = unittest.mock.Mock(side_effect=responses)
                    if expected:
                        with self.assertRaises(HTTPError) as raised:
                            monitor.persist_verified(read, original, value)
                        self.assertEqual(raised.exception.code, expected)
                    else:
                        monitor.persist_verified(read, original, value)
                    self.assertEqual(persist.call_count, len(writes))
                    self.assertEqual(read.call_count, len(responses))
                    self.assertTrue(all(call.args[1] == original for call in persist.call_args_list))


if __name__ == '__main__':
    unittest.main()
