"""Run-scoped reliability evidence for the ADL and FAFL weekly digests."""
from collections import Counter
import re
import urllib.request
import os

COMPONENTS = {
    'ADL': {'source', 'extension_calculator', 'elo', 'bonus_and_playoff_forecast',
            'playoff_bracket', 'bonus_dashboard', 'bonus_mfl', 'payouts', 'official_cap_snapshot'},
    'FAFL': {'source', 'elo', 'bonus_games', 'playoff_forecast', 'playoff_bracket',
             'bonus_dashboard', 'bonus_mfl', 'payouts'},
}
FAILURES = {'failure', 'timed_out', 'cancelled', 'action_required', 'startup_failure', 'stale'}
UNAVAILABLE = (OSError, ValueError, RuntimeError, KeyError, TypeError, AttributeError)
ANSI = re.compile(r'\x1b\[[0-9;]*m')
STAMP = re.compile(r'^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.\d+)?Z\s+(.*)$')
CHECK_ONLY = re.compile(
    r'^(?:set up job|complete job|post |run actions/|install .*(?:dependencies|packages)|'
    r'verify (?:playoff qualification|league rules)|test\b|run .*tests?\b|'
    r'validate (?:publication contracts|weekly workflow|workflow contracts)|'
    r'install and validate shared quarterly model)', re.I
)
LOG_SIGNALS = (
    ('timeout or deadline', re.compile(
        r'\b(?:timed[ -]out|timeouts?\s+(?:occurred|expired|exceeded)|time[ -]out(?: error| while| after)|'
        r'(?:connect|read|write|socket)timeout|timeout(?:error|exception)|deadline exceeded|'
        r'exceeded (?:its |the )?time limit|HTTP (?:408|504)|'
        r'operation was canceled|no response within)\b', re.I)),
    ('fallback or retained values', re.compile(
        r'\b(?:falling back|fallback (?:inputs|used|mode|source|values)|using (?:a |the )?fallback|'
        r'retaining (?:the )?(?:last|previous)|'
        r'preserving (?:the )?(?:last |previous |published )?(?:fallback|prior data)|stale (?:data|inputs|scores|results))\b', re.I)),
    ('incomplete or unverified data', re.compile(
        r'\b(?:unverified|degraded|partial (?:results?|data|coverage)|'
        r'(?:data|inputs?|scores?|projections?|receipts?|feed|export) (?:is |are )?(?:unavailable|missing)|'
        r'missing (?:required|verified|official|source|score)|could not (?:verify|reconcile|confirm)|'
        r'results? (?:withheld|incomplete)|left unresolved)\b', re.I)),
    ('retry reported', re.compile(r'\b(?:retrying|will retry|retry attempt)\b', re.I)),
)
CLINCH_LINE = re.compile(r'\bClinch certificates: \d+ proved; (\d+) unresolved queries\b', re.I)
SHA = re.compile(r'[a-f0-9]{40}')


def fetch_job_log(repo, job_id):
    token = (os.environ.get('WEEKLY_ORCHESTRATION_TOKEN') or os.environ['GH_TOKEN']).strip()
    request = urllib.request.Request(
        f'https://api.github.com/repos/{repo}/actions/jobs/{int(job_id)}/logs',
        headers={'User-Agent': 'League-weekly-reliability'},
    )
    # GitHub redirects to a signed temporary URL. Do not forward the API token.
    request.add_unredirected_header('Authorization', 'Bearer ' + token)
    limit = 10_000_000
    with urllib.request.urlopen(request, timeout=20) as response:
        payload = response.read(limit + 1)
    if len(payload) > limit:
        raise ValueError('Job log exceeds the inspection limit')
    return payload.decode('utf-8-sig', errors='replace')


def log_findings(text, steps):
    windows = sorted((s['started_at'][:19], s['completed_at'][:19], s['name'])
                     for s in steps if s.get('started_at') and s.get('completed_at')
                     and s['started_at'] != s['completed_at'])
    findings = Counter()
    clinch_peak = 0
    in_command = False
    observed_step = False
    launched_step = None
    for line in text.splitlines():
        match = STAMP.match(line)
        if not match:
            continue
        stamp, content = match.groups()
        content = ANSI.sub('', content)
        candidates = [name for start, end, name in windows if start <= stamp <= end]
        if content.startswith('##[group]Run '):
            launched_step = candidates[-1] if candidates else None
            in_command = True
            continue
        if content.startswith('##[endgroup]'):
            in_command = False
            continue
        if in_command or content.lstrip().startswith(('test_', '+ ', '#', '::group::')):
            continue
        # The API rounds step boundaries to seconds but log lines include
        # fractions. A line before the next command group can belong to the
        # step that is ending in the same second (including unit test output).
        step = launched_step if launched_step in candidates else next(iter(candidates), None)
        if not step or CHECK_ONLY.search(step):
            continue
        observed_step = True
        match = CLINCH_LINE.search(content)
        if match:
            clinch_peak = max(clinch_peak, int(match[1]))
            continue
        for label, pattern in LOG_SIGNALS:
            if pattern.search(content):
                findings[step, label] += 1
                break
        else:
            if content.startswith(('##[warning]', '##[error]', '::warning::', '::error::')) \
                    and not re.search(r'\b(?:deprecat|Node\.js|already exists)\w*', content, re.I):
                findings[step, 'Actions warning or error'] += 1
    if not observed_step:
        raise ValueError('Job log did not match its production step timestamps')
    return findings, clinch_peak


def certificate_notes(certificate, season, week):
    if certificate.get('season') != season or certificate.get('week') != week:
        raise ValueError('Wrong clinching snapshot')
    queries = certificate['queries']
    if not isinstance(queries, list) or not queries or any(
        q.get('status') not in {'proved', 'counterexample', 'unknown'} for q in queries
    ):
        raise ValueError('Incomplete clinch query evidence')
    unresolved = [q for q in queries if q['status'] == 'unknown']
    if certificate.get('complete') is not (not unresolved):
        raise ValueError('Clinch certificate completeness disagrees with its queries')
    if not unresolved:
        return []
    timed_out = sum(str(q.get('reason', '')).lower() in {'timeout', 'timed out', 'canceled', 'cancelled'}
                    for q in unresolved)
    suffix = f', including {timed_out} solver timeouts/cancellations' if timed_out else ''
    return [f'Playoff clinching: {len(unresolved)} unresolved checks{suffix}. '
            'Affected clinch or elimination labels are unverified.']


def component_notes(rows, league, receipt):
    selected = [r for r in rows if str(r.get('run_id')) == str(receipt['run_id'])]
    components = [r['component'] for r in selected]
    if not COMPONENTS[league].issubset(components) or len(components) != len(set(components)):
        raise ValueError('Missing or mismatched component status')
    notes = []
    for row in selected:
        component, status = row['component'], row.get('status') or 'unverified'
        intentionally_skipped = (
            (component == 'bonus_mfl' and receipt['process'] == 'preliminary'
             and not receipt.get('bonus_mfl_verified')
             and row.get('score_status') in {'preliminary', 'unofficial'})
            or (component == 'official_cap_snapshot' and receipt['process'] == 'corrections')
        )
        if status == 'success' or status == 'skipped' and intentionally_skipped:
            continue
        notes.append(f'{component.replace("_", " ").capitalize()}: {status.replace("_", " ")}.')
    return notes


def inspect_refresh(league, receipt, run, jobs, api, read_receipt, read_components,
                    read_certificate, read_log=fetch_job_log):
    """Keep any telemetry failure visible even when the publication is verified."""
    run_id = str(receipt['run_id'])
    run_attempt = int(run.get('run_attempt') or 1)
    process = receipt['process']
    season, week = receipt['season'], receipt['week']
    notes = []
    checked_jobs = set()
    weekly_clinch_peak = 0

    def review_jobs(items, scope):
        nonlocal weekly_clinch_peak
        for job in items:
            name = job['name']
            if name == 'Request weekly completion email' or job.get('conclusion') == 'skipped':
                continue
            outcome = job.get('conclusion')
            for step in job.get('steps', []):
                if step.get('conclusion') in FAILURES:
                    notes.append(f'{scope} / {name}: {step["name"]} {step["conclusion"].replace("_", " ")}.')
            if outcome in FAILURES:
                notes.append(f'{scope} / {name}: job {outcome.replace("_", " ")}.')
            if outcome is None and job.get('status') != 'completed':
                notes.append(f'{scope} / {name}: still running or queued at digest time.')
            if job.get('status') != 'completed' or job.get('id') in checked_jobs:
                continue
            checked_jobs.add(job.get('id'))
            try:
                findings, peak = log_findings(read_log(job['id']), job['steps'])
            except UNAVAILABLE:
                notes.append(f'{scope} / {name}: job logs or step evidence unavailable. '
                             'Warnings and timeouts could not be fully checked.')
                continue
            for (step, kind), count in findings.items():
                notes.append(f'{scope} / {step}: {kind} ({count} log messages).')
            if scope == 'Weekly refresh':
                weekly_clinch_peak = max(weekly_clinch_peak, peak)
            elif peak:
                notes.append(f'{scope} / Playoff clinching: up to {peak} unresolved checks in this job.')

    review_jobs(jobs, 'Weekly refresh')

    certificate_verified = False
    try:
        ref = api(f'commits?sha=main&path=data/refresh_receipts/{process}.json&per_page=1')[0]['sha']
        if not SHA.fullmatch(ref):
            raise ValueError('Unverified publication commit')
        pinned = read_receipt(ref)
        if any(pinned.get(k) != receipt[k] for k in ('run_id', 'process', 'season', 'week')):
            raise ValueError('Published receipt advanced')
    except (*UNAVAILABLE, IndexError):
        notes.append('Publication evidence could not be matched to this refresh. '
                     'Component and clinch reliability are unverified.')
    else:
        try:
            notes.extend(component_notes(read_components(ref), league, receipt))
        except UNAVAILABLE:
            notes.append('Run-matched component status unavailable. Some publication checks are unverified.')
        try:
            findings = certificate_notes(read_certificate(ref), season, min(week, 12))
            certificate_verified = True
            notes.extend(findings)
        except UNAVAILABLE:
            notes.append('Run-matched clinch certificate unavailable. Clinch and elimination reliability is unverified.')
    if weekly_clinch_peak and not certificate_verified:
        notes.append(f'Weekly refresh / Playoff clinching: the job log recorded up to '
                     f'{weekly_clinch_peak} unresolved checks during this refresh.')

    if receipt.get('bonus_mfl_verified'):
        try:
            child_title = f'Synchronize MFL Bonus Games · official · source {run_id} · attempt {run_attempt}'
            children = [r for r in api('actions/workflows/verify_bonus_mfl.yml/runs?per_page=30')['workflow_runs']
                        if r.get('display_title') == child_title]
            if len(children) != 1:
                raise ValueError('Bonus Games child run unavailable or ambiguous')
            child_jobs = api(f'actions/runs/{int(children[0]["id"])}/jobs?per_page=100')['jobs']
            if not child_jobs:
                raise ValueError('Bonus Games job evidence unavailable')
            # The child uses the same GitHub repository as the weekly publisher.
            review_jobs(child_jobs, 'MFL Bonus Games verification')
        except UNAVAILABLE:
            notes.append('MFL Bonus Games child logs could not be traced to this refresh. '
                         'The verification receipt was checked, but child timeouts are unverified.')

    # The failure reporter owns earlier attempts and independent failures.
    # This digest describes the verified publication and its remaining issues.
    return list(dict.fromkeys(notes))
