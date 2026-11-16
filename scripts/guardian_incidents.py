"""One delivery owner for required-check gaps and their exact failed checks."""
from datetime import datetime, timedelta, timezone
from pathlib import PurePosixPath
import hashlib

OWNER = 'commissioner-v1'


def stamp(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def validate_coverage(coverage, now):
    if coverage.get('alertOwner') != OWNER:
        raise RuntimeError('Shared Guardian incident ownership is not active')
    age = now - stamp(coverage['checkedAt'])
    if not timedelta(0) <= age <= timedelta(minutes=10):
        raise RuntimeError('Guardian coverage evidence is stale; do not mute safety nets')
    return [item for item in coverage['incidents'].values() if item['status'] == 'open']


def owned_check_failure(run, jobs, audit, coverage):
    """Match check-only errors to an open protection gap, never independent writes/mail."""
    mode = {'guardian.yml': 'monitor', 'initial-lineup.yml': 'initial'}.get(PurePosixPath(run.get('path', '')).name)
    if not mode or audit.get('id') != f'{run["id"]}-{run.get("run_attempt", 1)}-{mode}':
        return False
    bad = [(job.get('name'), step.get('name')) for job in jobs for step in job.get('steps', [])
           if step.get('conclusion') not in ('success', 'skipped', None)]
    if bad != [('guardian' if mode == 'monitor' else 'initial-lineup', 'Run npm run check')]:
        return False
    if (audit.get('dryRun') is not False or audit.get('runMode') != mode or not audit.get('completedAt')
            or audit.get('rosterManagement', {}).get('status') == 'error'
            or audit.get('lineupChanges') or audit.get('error')):
        return False
    # Unknown/ambiguous write errors remain separate failures. Only failed reads
    # explicitly classified by the worker can belong to a coverage gap.
    errors = [r for r in audit.get('results', []) if r.get('status') == 'error']
    if not errors or any(r.get('failureClass') != 'read_only_check' for r in errors):
        return False
    for result in errors:
        matched = [p for p in coverage['incidents'].values() if p['status'] == 'open'
                   and p['mode'] == mode and p['league'] == result['key'] and p['week'] == result['week']
                   and stamp(p.get('lastVerified') or coverage['activatedAt']) <= stamp(run['created_at'])
                   and stamp(run['created_at']) <= stamp(p['kickoff']) + (timedelta(hours=1) if mode == 'initial' else timedelta())]
        if not matched:
            return False
    return True


def owned_startup_failure(run, jobs, coverage):
    """A failed pre-check gate belongs to its protection gap, not a second email."""
    mode = {'guardian.yml':'monitor', 'initial-lineup.yml':'initial'}.get(PurePosixPath(run.get('path', '')).name)
    if not mode or run.get('conclusion') != 'failure':
        return False
    expected = 'guardian' if mode == 'monitor' else 'initial-lineup'
    if len(jobs) != 1 or jobs[0].get('name') != expected:
        return False
    steps = jobs[0].get('steps', [])
    bad = [s for s in steps if s.get('conclusion') not in ('success', 'skipped', None)]
    if len(bad) != 1 or bad[0].get('name') not in ('Run npm test', 'Check configuration'):
        return False
    checks = [s for s in steps if s.get('name') == 'Run npm run check']
    if len(checks) != 1 or checks[0].get('conclusion') != 'skipped':
        return False
    # No effect-producing or notification step may have started after the gate.
    gate = steps.index(bad[0])
    if any(s.get('conclusion') not in ('skipped', None) and s.get('name') != 'Archive exact roster checks'
           and not s.get('name', '').startswith(('Post ', 'Complete job'))
           for s in steps[gate + 1:]):
        return False
    created = stamp(run['created_at'])
    for incident in coverage['incidents'].values():
        if incident['mode'] != mode or incident['status'] not in ('open', 'resolved'):
            continue
        start = stamp(incident.get('lastVerified') or coverage['activatedAt'])
        end = stamp(incident.get('resolvedAt') or incident['kickoff'])
        if mode == 'initial' and not incident.get('resolvedAt'):
            end += timedelta(hours=1)
        if start <= created <= end:
            return True
    return False


def report_missing_checks(coverage, state, dry, deliver, save, send):
    pending = []
    for item in coverage['incidents'].values():
        key = 'guardian-coverage:' + item['key']
        if item['status'] == 'open' and key not in state['sent']:
            # Preserve delivery receipts made before ownership migration.
            if item.get('delivery') == 'sent':
                state['sent'][key] = {'subject': 'Legacy Guardian coverage notification', 'migrated': True}
            elif item.get('delivery') in ('sending', 'uncertain'):
                raise RuntimeError('Guardian coverage delivery requires manual review')
            else:
                pending.append((key, item))
    groups = state.setdefault('guardian_coverage_groups', {})
    claimed = {key for keys in groups.values() for key in keys}
    new = sorted(key for key, _ in pending if key not in claimed)
    if new:
        groups['guardian-gap:' + hashlib.sha256('\n'.join(new).encode()).hexdigest()[:24]] = new
    current = dict(pending)
    for group, keys in groups.items():
        active = [(key, current[key]) for key in keys if key in current]
        if not active:
            continue
        subject = '[Guardian needs attention] Required lineup protection is missing'
        details = [f'{item["league"]} Week {item["week"]}: {item["mode"]}; window reference (UTC): {item["kickoff"]}'
                   for _, item in active]
        body = ('No verified Guardian check within the required deadline.\n\n' + '\n'.join(details) + '\n\n'
                'Please inspect your lineup manually until protection resumes. Automatic checks will continue.\n'
                'This unresolved incident will not send repeated emails. No roster changes were made by this monitor.')
        if not dry:
            save(state)
            deliver(state, 'failure:' + group, lambda: send(subject, body, 'failure:' + group), lambda: save(state))
        for key, item in active:
            state['sent'][key] = {'subject': subject, 'coverage_key': item['key'], 'group': group}
        if not dry:
            save(state)
        else:
            print(subject)
