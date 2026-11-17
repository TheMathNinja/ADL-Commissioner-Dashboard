"""Daily private usage estimate inside the existing free public reporter job.

GitHub billing is authoritative. Job timing estimates include per-job rounding;
they are not an invoice. Never publish financial details into public run output.
"""
import math
import json
from pathlib import Path
from zoneinfo import ZoneInfo
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from calendar import monthrange

from guardian_health_monitor import REPO, STATE, decode, persist, stamp
from guardian_check_policy import CHECK_OFFSETS_MINUTES

PATH = 'data/actions_budget.json'
ALLOWANCE = 2000
PLAN_PATH = Path(__file__).resolve().parents[1] / 'contracts/actions_budget_plan.json'


def configured_projection(now, schedules, plan=None):
    """Forward schedule model, independent of expensive historical job averages."""
    plan = plan or json.loads(PLAN_PATH.read_text())
    if tuple(plan['checkpointOffsetsMinutes']) != CHECK_OFFSETS_MINUTES:
        raise ValueError('Budget plan and Guardian checkpoints disagree')
    zone = ZoneInfo(plan['resetTimezoneAssumption'])
    local = now.astimezone(zone)
    reset = local.replace(year=local.year + (local.month == 12), month=local.month % 12 + 1,
                          day=1, hour=0, minute=0, second=0, microsecond=0)
    days = (reset - now).total_seconds() / 86400
    slots = {kickoff - timedelta(minutes=offset) for kickoff in schedules
             for offset in CHECK_OFFSETS_MINUTES
             if now <= kickoff - timedelta(minutes=offset) < reset}
    audit_dates = []
    day = local.date()
    while day < reset.date():
        if day.weekday() == plan['weeklyAuditWeekday']:
            audit_dates.append(day.isoformat())
        day += timedelta(days=1)
    components = {'preKickoff': len(slots) * plan['minutesPerCheckpointJob'],
                  'weeklyCloudAudits': len(audit_dates) * plan['minutesPerWeeklyAudit']}
    for name, settings in plan['dailyScheduledComponents'].items():
        scheduled = local.replace(hour=settings['hourEastern'], minute=0, second=0, microsecond=0)
        count = 0
        while scheduled < reset:
            count += scheduled >= now
            scheduled += timedelta(days=1)
        components[name] = count * math.ceil(settings['minutesPerJob'])
    components.update({name: math.ceil(days * rate) for name, rate in plan['dailyAllowances'].items()})
    total = sum(components.values())
    return {'version': plan['version'], 'source': 'configured checkpoints and explicit planning allowances; not a cap',
            'resetAtAssumed': reset.isoformat(), 'daysRemaining': round(days, 2),
            'checkpointOffsetsMinutes': list(CHECK_OFFSETS_MINUTES), 'checkpointJobsRemaining': len(slots),
            'minutesPerCheckpointJob': plan['minutesPerCheckpointJob'],
            'componentsThroughReset': components, 'minutesThroughReset': total,
            'projectedDailyMinutes': round(total / max(days, 1), 2),
            'weeklyAuditDates': audit_dates, 'additionalDemandExcluded': True}


def upcoming_kickoffs(api, now):
    from guardian_fallback import get_json, rows
    coverage = decode(api(REPO, 'contents/' + STATE + '?ref=main'))
    weeks = [int(value['week']) for value in coverage['schedules'].values()]
    if not weeks or not 1 <= min(weeks) <= 18:
        raise ValueError('No valid active-week budget schedule')
    # Include a rollover buffer, but avoid fetching the entire season every day.
    count = math.ceil((monthrange(now.year, now.month)[1] - now.day + 1) / 7) + 2
    season = now.year if now.month > 2 else now.year - 1
    result = set()
    for week in range(min(weeks), min(19, min(weeks) + count)):
        value = get_json(f'https://api.myfantasyleague.com/{season}/export?TYPE=nflSchedule&W={week}&JSON=1')['nflSchedule']
        if int(value['week']) != week:
            raise ValueError('Budget schedule week mismatch')
        for matchup in rows(value.get('matchup')):
            result.add(datetime.fromtimestamp(int(matchup['kickoff']), timezone.utc))
    if not result:
        raise ValueError('No usable kickoff schedule for budget projection')
    return result


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


def collect(api, now, runner_handoff=False, prior=None, projection=None):
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
    previous = {row['workflow']: row for row in (prior or {}).get('workflows', [])}
    for path, runs in groups.items():
        latest = sorted(runs, key=lambda r: (r['created_at'], r['id']), reverse=True)
        samples = [minutes(api(REPO, f'actions/runs/{r["id"]}/jobs?filter=all&per_page=100')['jobs'])
                   for r in latest[:3]]
        average = sum(samples) / len(samples)
        estimate = average * len(runs)
        # A faster deployment changes future pace, not minutes already consumed.
        old = previous.get(path) if (prior or {}).get('month') == now.strftime('%Y-%m') else None
        if old:
            estimate = old['estimatedMinutes'] + max(0, len(runs) - old['runs']) * average
        estimated += estimate
        recent = sum(stamp(r['created_at']) >= now - timedelta(days=7) for r in runs)
        future_daily = recent / min(7, max(1, (now - start).total_seconds() / 86400)) * average
        if runner_handoff and path.endswith('/guardian-coverage.yml'):
            future_daily = 0
        daily += future_daily
        details.append({'workflow': path, 'runs': len(runs), 'sampleMinutes': samples,
                        'estimatedMinutes': round(estimate, 1), 'projectedDailyMinutes': round(future_daily, 1)})
    remaining_days = max(0, monthrange(now.year, now.month)[1] - now.day + (24 - now.hour) / 24)
    result = {'schemaVersion': 1, 'checkedAt': now.isoformat(), 'month': now.strftime('%Y-%m'),
            'source': 'sampled rounded job timing; estimate, not GitHub billing',
            'allowance': ALLOWANCE, 'target': 1500, 'estimatedUsed': round(estimated, 1),
            'projectedDailyMinutes': round(daily, 1), 'daysRemaining': round(remaining_days, 1),
            'projectedMonthEnd': round(estimated + daily * remaining_days, 1),
            'coverageHandoffAssumed': runner_handoff, 'workflows': details}
    if projection:
        result.update(historicalDailyMinutes=result['projectedDailyMinutes'],
                      planProjection=projection,
                      projectedDailyMinutes=projection['projectedDailyMinutes'],
                      projectedMonthEnd=round(estimated + projection['minutesThroughReset'], 1))
    return result


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
    plan = json.loads(PLAN_PATH.read_text())
    if (prior.get('checkedAt') and now - stamp(prior['checkedAt']) < timedelta(hours=24)
            and prior.get('planProjection', {}).get('version') == plan['version']):
        return prior
    import os
    projection = configured_projection(now, upcoming_kickoffs(api, now), plan)
    value = collect(api, now, os.environ.get('GUARDIAN_COVERAGE_RUNNER') == 'public-reporter-v1', prior, projection)
    if not dry:
        persist(PATH, original, value)
    return value
