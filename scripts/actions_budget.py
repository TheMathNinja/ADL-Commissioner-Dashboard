"""Daily private usage estimate inside the existing free public reporter job.

GitHub billing is authoritative. Job timing estimates include per-job rounding;
they are not an invoice. Never publish financial details into public run output.
"""
import math
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from calendar import monthrange

from guardian_health_monitor import REPO, decode, persist, stamp

PATH = 'data/actions_budget.json'
ALLOWANCE = 2000


def minutes(jobs):
    total = 0
    for job in jobs:
        if not job.get('started_at') or not job.get('completed_at') or job.get('conclusion') == 'skipped':
            continue
        duration = max(0, (stamp(job['completed_at']) - stamp(job['started_at'])).total_seconds())
        labels = ' '.join(job.get('labels', [])).lower()
        multiplier = 10 if 'macos' in labels else 2 if 'windows' in labels else 1
        total += math.ceil(duration / 60) * multiplier
    return total


def collect(api, now, runner_handoff=False):
    groups = defaultdict(list)
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    # Daily queries avoid GitHub's 1,000-run search cap during a dispatch storm.
    day = start
    while day <= now:
        for page in range(1, 51):
            value = api(REPO, f'actions/runs?created={day:%Y-%m-%d}&per_page=100&page={page}')
            runs = value['workflow_runs']
            for run in runs:
                if run.get('status') == 'completed' and run.get('conclusion') != 'skipped':
                    groups[run['path']].append(run)
            if len(runs) < 100:
                break
        else:
            raise RuntimeError('Usage scan exceeded its bounded daily limit')
        day += timedelta(days=1)
    estimated = 0
    daily = 0
    details = []
    for path, runs in groups.items():
        latest = sorted(runs, key=lambda r: (r['created_at'], r['id']), reverse=True)
        samples = [minutes(api(REPO, f'actions/runs/{r["id"]}/jobs?filter=all&per_page=100')['jobs'])
                   for r in latest[:3]]
        average = sum(samples) / len(samples)
        estimate = average * len(runs)
        estimated += estimate
        recent = sum(stamp(r['created_at']) >= now - timedelta(days=7) for r in runs)
        future_daily = recent / min(7, max(1, (now - start).total_seconds() / 86400)) * average
        if runner_handoff and path.endswith('/guardian-coverage.yml'):
            future_daily = 0
        daily += future_daily
        details.append({'workflow': path, 'runs': len(runs), 'sampleMinutes': samples,
                        'estimatedMinutes': round(estimate, 1), 'projectedDailyMinutes': round(future_daily, 1)})
    remaining_days = max(0, monthrange(now.year, now.month)[1] - now.day + (24 - now.hour) / 24)
    return {'schemaVersion': 1, 'checkedAt': now.isoformat(), 'month': now.strftime('%Y-%m'),
            'source': 'sampled rounded job timing; estimate, not GitHub billing',
            'allowance': ALLOWANCE, 'target': 1500, 'estimatedUsed': round(estimated, 1),
            'projectedDailyMinutes': round(daily, 1), 'daysRemaining': round(remaining_days, 1),
            'projectedMonthEnd': round(estimated + daily * remaining_days, 1),
            'coverageHandoffAssumed': runner_handoff, 'workflows': details}


def review(api, now, dry=False):
    try:
        original = api(REPO, 'contents/' + PATH + '?ref=main')
    except (OSError, RuntimeError) as error:
        cause = error
        while cause.__cause__ is not None:
            cause = cause.__cause__
        if getattr(cause, 'code', None) != 404:
            raise
        original = {'sha': None}
    prior = decode(original) if original.get('sha') else {}
    if prior.get('checkedAt') and now - stamp(prior['checkedAt']) < timedelta(hours=24):
        return prior
    import os
    value = collect(api, now, os.environ.get('GUARDIAN_COVERAGE_RUNNER') == 'public-reporter-v1')
    if not dry:
        persist(PATH, original, value)
    return value
