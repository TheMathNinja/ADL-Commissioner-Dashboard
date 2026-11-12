"""Report production failures separately from successful-publication emails."""
import argparse
import copy
import hashlib
import subprocess
from datetime import datetime, timedelta, timezone
import http.client
import json
import os
import re
import urllib.request
from pathlib import PurePosixPath
import email_weekly_completion as mail
from zoneinfo import ZoneInfo

STATE_PATH = 'data/workflow_failure_email_state.json'
LOOKBACK_DAYS = 7
OWNER = 'fili.mikey@gmail.com'
REPOS = ['TheMathNinja/ADL-GM-Dashboard', 'TheMathNinja/FAFL-GM-Dashboard', 'TheMathNinja/ADL-Commissioner-Dashboard']
GUARDIAN = 'TheMathNinja/Chicago-Bears-Lineup-Guardian'
PRIVATE_IMPACT = {
    'guardian.yml': 'A Guardian check did not complete; lineup protection may be unavailable.',
    'initial-lineup.yml': 'The initial-lineup safety check did not complete.',
    'delayed-pickup.yml': 'The delayed IR pickup recheck did not complete.',
    'preflight.yml': 'The read-only Guardian readiness audit did not complete.',
    'league-audit.yml': 'The private cross-repository or Guardian readiness audit did not complete.',
    'model_contract_preflight.yml': 'Private model compatibility checks did not complete.',
    'refresh_chi_team_tools.yml': 'The private forecast and matching prepared-value refresh did not complete.',
    'sync_chi_team_tools.yml': 'The private trade synchronization did not complete.',
}
IMPACT = {
    'automation-preflight.yml': 'The cross-repository or Guardian readiness audit did not complete.',
    'fafl-inactivity-watch.yml': 'FAFL inactivity evidence checks or owner/commissioner notifications did not complete. Existing watch deadlines remain recorded; no ownership changes were made.',
    'daily_adl_league_maintenance.yml': 'The combined morning SalAdj, waiver-correction, roster/Extension, or Commissioner-alert package did not complete.',
    'refresh_extension_calculator.yml': 'ADL Elo, Bonus Games/MFL entries, Playoffs, Payouts, or EXT may be incomplete. See the failed components below.',
    'refresh.yml': 'FAFL Elo, Bonus Games/MFL entries, Playoffs, or Payouts may be incomplete. See the failed components below.',
    'poll_preliminary_scores.yml': 'The preliminary-score readiness check failed; the weekly refresh may not have been triggered.',
    'verify_bonus_mfl.yml': 'Due MFL Bonus Games did not pass full standings readback; completion email remains withheld.',
    'poll_score_corrections.yml': 'The correction freshness check failed. This does not establish that an earlier Thursday publication failed or was undone; this run could not check for newer changes.',
    'refresh_rosters.yml': 'Published roster-dependent tools may be stale.',
    'deploy_dashboard.yml': 'The latest dashboard changes may not be live.',
    'rebuild_playoff_model.yml': 'The requested live playoff model rebuild/publication did not complete.',
    'elo_chart_range.yml': 'Elo graph maintenance or verification did not complete.',
    'daily-commissioner-alerts.yml': 'Commissioner rule checks or their notifications did not complete.',
    'dashboard_watchdog.yml': 'The Commissioner dashboard freshness check failed; its data may be stale.',
    'lineup-designation-snapshots.yml': 'The scheduled MFL lineup/injury designation snapshot may be missing.',
    'offseason-inactivity-monitor.yml': 'League inactivity monitoring or its notifications did not complete.',
    'update_dashboard.yml': 'Commissioner dashboard / salary-adjustment processing may be incomplete.',
    'waiver-cap-corrections.yml': 'Waiver salary-cap corrections or their notifications may be incomplete.',
    'weekly_salary_cap_accounting.yml': 'Official salary-cap snapshots/accounting may be incomplete.',
    'email_weekly_completion.yml': 'The owner completion report could not be delivered or verified.',
    'email_workflow_failures.yml': 'A failure-report delivery attempt failed. This notice comes from a later reporter run.',
}
BAD = {'failure', 'timed_out', 'action_required', 'startup_failure', 'stale', 'cancelled'}
COMMISSIONER = 'TheMathNinja/ADL-Commissioner-Dashboard'
DAILY_REPO = 'TheMathNinja/ADL-GM-Dashboard'
DAILY_CHILDREN = {
    'update_dashboard.yml': ('Commissioner data', 'Refresh SalAdj and Commissioner data', 'Dispatch Commissioner-owned data refresh'),
    'waiver-cap-corrections.yml': ('Waiver corrections', 'Apply waiver cap corrections', 'Dispatch Commissioner-owned waiver corrections'),
    'daily-commissioner-alerts.yml': ('Commissioner alerts', 'Run Commissioner alerts', 'Dispatch Commissioner-owned alerts'),
}
PRIVATE_PARENT_STEPS = {
    'guardian': ('Audit Guardian behavior and both MFL memberships (read-only)', 'Dispatch and verify Guardian read-only audit privately'),
    'contracts': ('Verify cross-repository automation contracts', 'Dispatch and verify the complete private contract audit'),
}


def private_parent(run):
    if PurePosixPath(run.get('path','')).name != 'league-audit.yml':
        return None
    match = re.fullmatch(r'Private league audit - (guardian|contracts) - source (\d+)-(\d+)-\1', run.get('display_title',''))
    return (match[2],int(match[3]),match[1]) if match else None


def private_child_link(repo, run, job, step):
    if (repo != COMMISSIONER or PurePosixPath(run.get('path','')).name != 'automation-preflight.yml'
            or (job.get('name'),step) not in PRIVATE_PARENT_STEPS.values() or not job.get('id')):
        return None
    try:
        log = subprocess.run(['gh','run','view',str(run['id']),'--repo',repo,'--job',str(job['id']),
            '--attempt',str(run.get('run_attempt',1)),'--log-failed'],capture_output=True,text=True,
            encoding='utf8',errors='replace',timeout=30,check=True).stdout
    except (OSError,subprocess.SubprocessError):
        return None
    ids = set(re.findall(r'Private audit: https://github.com/TheMathNinja/Chicago-Bears-Lineup-Guardian/actions/runs/(\d+)',log))
    return ids.pop() if len(ids)==1 else None


def delivered_private_child(state, repo, run, jobs_by_name, line):
    name, _, step = line.partition(': ')
    job = jobs_by_name.get(name,{})
    child_id = private_child_link(repo,run,job,step)
    return bool(child_id and any(key.startswith(GUARDIAN+':'+child_id+':') and
        entry.get('audit_parent') == str(run['id']) and entry.get('audit_attempt') == run.get('run_attempt',1)
        for key,entry in reported_records(state).items()))


def reported_records(state):
    return {**state.get('linked_reports',{}),**state['sent']}


def daily_child(run):
    spec = DAILY_CHILDREN.get(PurePosixPath(run.get('path', '')).name)
    if spec and run.get('event') == 'workflow_dispatch' and run.get('head_branch') == 'main':
        match = re.fullmatch(r'Daily maintenance (\d+) - ' + spec[0], run.get('display_title', ''))
        if match:
            return match[1], spec


def propagated_child(repo, parent, job, step):
    if repo != DAILY_REPO or PurePosixPath(parent['path']).name != 'daily_adl_league_maintenance.yml':
        return None
    if not any((job['name'], step) == spec[1:] for spec in DAILY_CHILDREN.values()):
        return None
    try:
        log = subprocess.run(['gh','run','view',str(parent['id']),'--repo',repo,'--job',str(job['id']),
                              '--attempt',str(parent.get('run_attempt',1)),'--log-failed'],capture_output=True,text=True,encoding='utf8',errors='replace',
                             timeout=30,check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    ids = set(re.findall(r'Child workflow (\d+) completed with conclusion: (?:failure|timed_out|cancelled|action_required)\.(?=\s|$)', log))
    return ids.pop() if len(ids) == 1 else None


def delivered_child(state, repo, run, jobs_by_name, line):
    name, _, step = line.partition(': ')
    job = jobs_by_name.get(name)
    if not job or not job.get('id'):
        return False
    child_id = propagated_child(repo, run, job, step)
    if not child_id:
        return False
    return any(key.startswith(f'{COMMISSIONER}:{child_id}:') and
               entry.get('daily_parent') == str(run['id']) and
               entry.get('daily_job') == name and
               job.get('started_at','~') <= entry['failed_at'] <= job.get('completed_at','')
               for key, entry in reported_records(state).items())
PRODUCTION_DISPATCH_NAMES = (
    re.compile(r'^(?:Poll Thursday score corrections|Poll preliminary score readiness) \(production\)$'),
    re.compile(r'^Preliminary ADL weekly update · Week \d+ · [a-f0-9]{64}$'),
    re.compile(r'^FAFL Inactivity Watch$'),
    re.compile(r'^Daily ADL League Maintenance$'),
    re.compile(r'^Dashboard Watchdog$'),
    re.compile(r'^Synchronize MFL Bonus Games · official · source \d+(?: · attempt \d+)?$'),
    re.compile(r'^Official Week \d+ cap snapshot \(weekly package \d+\)$'),
    re.compile(r'^(?:Preliminary|Corrections) 60206 2026 week \d+'),
    re.compile(r'^Official (?:ADL|FAFL) (?:weekly update · Week \d+(?: · [a-f0-9]{64})?|correction update · Week \d+ · .+)$', re.IGNORECASE),
)


def api(repo, path):
    error = None
    for attempt in range(5):
        try:
            if repo == GUARDIAN:
                token = os.environ.get('PRIVATE_REPORT_TOKEN')
                if not token:
                    raise RuntimeError('Private failure-report coverage credential is unavailable')
                req = urllib.request.Request(f'https://api.github.com/repos/{repo}/{path}', headers={
                    'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
                    'User-Agent': 'League-incident-reporter'})
                with urllib.request.urlopen(req, timeout=45) as response:
                    value = json.load(response)
            else:
                value = mail.get_json(f'https://api.github.com/repos/{repo}/{path}')
            if value is None:
                raise RuntimeError(f'GitHub resource unavailable: {repo}/{path}')
            return value
        except (TimeoutError, OSError, http.client.IncompleteRead, json.JSONDecodeError) as exc:
            error = exc
            if attempt < 4:
                mail.time.sleep(min(8, 2 ** attempt))
    raise RuntimeError(f'GitHub API remained unavailable for {repo}/{path}') from error


def production(run):
    filename = PurePosixPath(run.get('path', '').split('@')[0]).name
    event = run.get('event')
    is_scheduled = event == 'schedule'
    title = run.get('display_title') or run.get('name', '')
    if filename == 'automation-preflight.yml' and not run.get('_audit_report'):
        return None
    if run.get('_private_report'):
        return PRIVATE_IMPACT.get(filename) if run.get('head_branch') == 'main' and event in {'schedule','workflow_dispatch','push'} else None
    is_orchestrated_dispatch = event == 'workflow_dispatch' and any(
        pattern.search(title) for pattern in PRODUCTION_DISPATCH_NAMES
    )
    audit = filename == 'automation-preflight.yml' and event in {'push','workflow_dispatch'}
    if run.get('head_branch') != 'main' or not (is_scheduled or is_orchestrated_dispatch or daily_child(run) or audit):
        return None
    return IMPACT.get(filename)


def runs(repo):
    start = (datetime.now(timezone.utc) - timedelta(days=LOOKBACK_DAYS)).strftime('%Y-%m-%dT%H:%M:%SZ')
    page = 1
    while True:
        batch = api(repo, f'actions/runs?per_page=20&page={page}&branch=main&created=%3E%3D{start}')['workflow_runs']
        yield from batch
        if len(batch) < 20:
            return
        page += 1


def jobs(repo, run):
    result = []
    page = 1
    while True:
        batch = api(repo, f'actions/runs/{run["id"]}/attempts/{run.get("run_attempt", 1)}/jobs?per_page=100&page={page}')['jobs']
        result.extend(batch)
        if len(batch) < 100:
            return result
        page += 1


def failures(run, job_list):
    found = []
    for job in job_list:
        bad_steps = [s['name'] for s in job.get('steps', []) if s.get('conclusion') in BAD]
        if bad_steps:
            found.extend(f'{job["name"]}: {s}' for s in bad_steps)
        elif job.get('conclusion') in BAD:
            found.append(job['name'] + ': ' + job['conclusion'])
    if not found and run.get('conclusion') in BAD:
        found.append('Workflow ended with ' + run['conclusion'] + '; detailed step results are unavailable.')
    if len(found)>1 and PurePosixPath(run.get('path','')).name=='daily_adl_league_maintenance.yml':
        found=[step for step in found if step!='Verify daily maintenance package: Summarize component results'] or found
    return found


def cancelled_without_runner_after_same_day_success(run, job_list, history):
    """Ignore GitHub capacity cancellations after today's watchdog already passed."""
    if run.get('conclusion') != 'cancelled' or not job_list:
        return False
    if PurePosixPath(run.get('path', '').split('@')[0]).name != 'dashboard_watchdog.yml':
        return False
    if any(job.get('runner_id') for job in job_list):
        return False
    et = ZoneInfo('America/New_York')
    run_day = datetime.fromisoformat(run['created_at'].replace('Z', '+00:00')).astimezone(et).date()
    return any(
        candidate.get('workflow_id') == run.get('workflow_id')
        and candidate.get('conclusion') == 'success'
        and datetime.fromisoformat(candidate['created_at'].replace('Z', '+00:00')).astimezone(et).date() == run_day
        for candidate in history
    )


def correction_publication(repo, run):
    if PurePosixPath(run.get('path','').split('@')[0]).name != 'poll_score_corrections.yml':return None
    local=datetime.fromisoformat(run['created_at'].replace('Z','+00:00')).astimezone(ZoneInfo('America/New_York'))
    season=local.year-1 if local.month==1 else local.year
    september=local.date().replace(year=season,month=9,day=1)
    first_monday=september+timedelta(days=(-september.weekday())%7+7)
    week=(local.date()-first_monday).days//7+1
    receipt=mail.document(repo,'data/refresh_receipts/corrections.json') or {}
    league='60206' if repo.endswith('/ADL-GM-Dashboard') else '22686'
    if not (receipt.get('season')==season and receipt.get('week')==week and str(receipt.get('league_id'))==league and receipt.get('process')=='corrections' and receipt.get('status')=='success' and receipt.get('bonus_mfl_verified') is True and receipt.get('payouts_verified') is True and receipt.get('completed_at') and receipt.get('run_id')):return None
    publication_jobs=api(repo,f'actions/runs/{receipt["run_id"]}/jobs?per_page=100')['jobs']
    if not any(job.get('name')=='refresh' and job.get('conclusion')=='success' for job in publication_jobs):return None
    return receipt


def later_daily_cycle(repo, run, history):
    child = daily_child(run)
    if repo != COMMISSIONER or not child:
        return None
    candidates = (r for r in history if r.get('workflow_id') == run['workflow_id']
                  and r.get('conclusion') == 'success' and r['created_at'] > run['updated_at']
                  and (other := daily_child(r)) and other[1] == child[1] and other[0] != child[0])
    return max(candidates, key=lambda r: r['created_at'], default=None)


def message(repo, run, impact, failed, later_success, publication=None, later_cycle=None):
    title = re.sub(r'\b[a-f0-9]{40,64}\b', '', run.get('display_title') or run['name']).strip()
    status = 'CANCELLED' if run.get('conclusion') == 'cancelled' else 'FAILED'
    subject = f'[League automation {status}] {repo.split("/")[-1]} — {title}'
    if later_cycle and not later_success:
        subject = f'[League automation history: {run["created_at"][:10]} UTC] {title}'
        impact = 'This earlier daily job did not complete. A later daily cycle passed; that does not confirm the original work or notification was completed.'
    if publication:
        impact=f'Week {publication["week"]} Thursday publication already completed successfully. Only the follow-up freshness check failed; it could not verify whether any newer changes were available.'
    lines = [subject, '', 'Impact: ' + impact]
    if publication:
        lines += ['', 'Verified Thursday publication: ' + mail.local_time(publication['completed_at']),
                  'Publication run: https://github.com/' + repo + '/actions/runs/' + str(publication['run_id'])]
    lines += ['', 'Failed steps:']
    lines += ['- ' + item for item in failed]
    lines += ['', 'Run: ' + run['html_url'], 'Attempt: ' + str(run.get('run_attempt', 1)),
              'Started (UTC): ' + run.get('run_started_at', run['created_at']),
              'Run last updated (UTC): ' + run['updated_at'], '']
    if later_success:
        lines += ['A later run succeeded, but recovery of this failed work could not be verified.',
                  'Later successful run: ' + later_success['html_url']]
    elif later_cycle:
        lines += ['Latest successful production cycle: ' + later_cycle['html_url']]
    elif publication:
        lines += ['No later successful freshness check was found at report time.',
                  'The completed Thursday publication remains recorded; follow-up freshness verification is pending.']
    else:
        lines += ['No later successful run of this workflow was found at report time.',
                  'A later retry may recover it; this email does not claim recovery.']
    lines += ['', 'This alert does not wait for the other league or for successful publication.',
              'Sent only to ' + OWNER + '.']
    return subject, '\n'.join(lines)


def incident_key(repo, run):
    """Stable identity for repeated dispatches of the same production incident."""
    return f'{repo}:{run.get("workflow_id")}:{run.get("display_title") or run.get("name", "")}'




def save(state):
    mail.STATE_PATH = STATE_PATH
    mail.save_state(state)


def cause_codes(repo,run,job_list):
    codes={}
    for job in job_list:
        if job.get('conclusion') not in BAD or not job.get('id'):continue
        # Run/job IDs identify attempts, not causes. Unknown causes retain the
        # component outage; a newly failed step remains separately reportable.
        code='unclassified'
        try:
            cmd=['gh','run','view',str(run['id']),'--repo',repo,'--job',str(job['id']),'--log-failed']
            env = dict(os.environ)
            if repo == GUARDIAN:
                env['GH_TOKEN'] = os.environ.get('PRIVATE_REPORT_TOKEN','')
            log=subprocess.run(cmd,capture_output=True,text=True,timeout=25,encoding='utf8',errors='replace',check=True,env=env).stdout
            errors=[]
            for line in log.splitlines():
                line=re.split(r'\d{4}-\d\d-\d\dT[\d:.]+Z\s+',line,maxsplit=1)[-1].strip()
                if not re.match(r'^(?:##\[error\]|(?:[\w.]*Error|fatal|error):)',line,re.I):continue
                if 'process completed with exit code' in line.lower():continue
                line=re.sub(r'actions/runs/\d+|\b[0-9a-f]{32,64}\b','<revision>',line)
                errors.append(line)
            if errors:code=hashlib.sha256('\n'.join(errors[-4:]).encode()).hexdigest()
        except (OSError,subprocess.SubprocessError):pass
        codes[job['name']]=code
    return codes

def incident_scope(repo,run):
    local = datetime.fromisoformat(run['created_at'].replace('Z','+00:00')).astimezone(ZoneInfo('America/New_York'))
    filename = PurePosixPath(run.get('path','')).name
    day = local.date()
    if filename == 'poll_preliminary_scores.yml' and local.weekday() == 1:
        day -= timedelta(days=1)
    return incident_key(repo,run)+':'+str(day)

def unreported_steps(state, repo, run, history, failed, codes=None):
    scope = incident_scope(repo,run)
    episode = notification_episode(incident_key(repo, run), run['created_at'])
    seen = set()
    for entry in state['sent'].values():
        identity = entry.get('incident_key') or re.sub(r':\d{4}-\d\d-\d\d$', '', entry.get('scope',''))
        if notification_episode(identity, entry.get('failed_at','')) != episode:
            continue
        if entry.get('resolved_at') and entry['resolved_at'] < run['updated_at']:
            continue
        if entry_recovered(repo, run, entry, history):
            continue
        observed = entry.setdefault('observed_cause_codes', dict(entry.get('cause_codes', {})))
        for step in entry.get('failed_steps', []):
            name = step.split(': ', 1)[0]
            old, new = observed.get(name), (codes or {}).get(name)
            unknown = lambda value: not value or value.startswith('unclassified')
            if not codes or unknown(old) or unknown(new) or old == new:
                seen.add(step)
                # Enrich an unknown incident, without editing the original email
                # evidence. A later *different* known cause can then alert.
                if unknown(old) and not unknown(new):
                    observed[name] = new
        if any(step in seen for step in failed):
            entry['last_seen_at'] = run['updated_at']
            entry['latest_run_url'] = run.get('html_url')
    return scope,[step for step in failed if step not in seen]


def notification_episode(identity, timestamp):
    """Deduplicate an outage across retries/midnight, but not across seasons."""
    identity = re.sub(r'\b[a-f0-9]{40,64}\b', '<input>', identity)
    identity = re.sub(r'Daily maintenance \d+ - ', 'Daily maintenance - ', identity)
    identity = re.sub(r'(Private league audit - (?:guardian|contracts)) - source .+', r'\1', identity)
    identity = re.sub(r'(Chicago Bears (?:Lineup Guardian|Initial Lineup Safety Net)) - .+', r'\1', identity)
    return identity + ':' + str(timestamp)[:4]


def entry_recovered(repo, run, entry, history):
    """A green title alone cannot reopen an already-notified outage."""
    expected = {}
    startup = False
    for step in entry.get('failed_steps', []):
        name, separator, action = step.partition(': ')
        if not separator:
            startup = True
            continue
        expected.setdefault(name, set()).add(action)
    for name in entry.get('affected_jobs', {}):
        expected.setdefault(name, set())
    for candidate in history:
        if (candidate.get('workflow_id') != run.get('workflow_id')
                or candidate.get('conclusion') != 'success'
                or candidate.get('status', 'completed') != 'completed'
                or candidate.get('head_branch', 'main') != 'main'
                or not entry.get('failed_at','') < candidate.get('updated_at','') < run['updated_at']
                or notification_episode(incident_key(repo,candidate),candidate.get('created_at','')) !=
                   notification_episode(incident_key(repo,run),run['created_at'])):
            continue
        try:
            completed = jobs(repo, candidate)
            passed = {j['name']: j for j in completed if j.get('conclusion') == 'success'}
        except (OSError, RuntimeError, ValueError, KeyError):
            continue
        full_recovery = (completed and len(passed) == len(completed) and all(
            any(s.get('conclusion') == 'success' and s['name'] not in {'Set up job','Complete job'}
                for s in j.get('steps', [])) for j in completed))
        if ((startup and full_recovery) or (not startup and expected and all(name in passed and required <= {
                s['name'] for s in passed[name].get('steps', []) if s.get('conclusion') == 'success'
                } for name, required in expected.items()))):
            entry['resolved_at'] = candidate['updated_at']
            entry['recovery_url'] = candidate.get('html_url')
            return True
    return False


def recovered_watchdog(repo, run, later):
    if (repo != COMMISSIONER or PurePosixPath(run.get('path', '')).name != 'dashboard_watchdog.yml'
            or not later or later.get('status') != 'completed' or later.get('conclusion') != 'success'
            or later.get('head_branch') != 'main' or later.get('workflow_id') != run.get('workflow_id')
            or later.get('updated_at', '') <= run.get('updated_at', '')
            or incident_scope(repo, later) != incident_scope(repo, run)):
        return False
    required = {"Check today's maintenance result and alert ownership", "Verify SalAdjCurator checked in recently"}
    successful = {step['name'] for job in jobs(repo, later) if job.get('conclusion') == 'success'
                  for step in job.get('steps', []) if step.get('conclusion') == 'success'}
    return required <= successful


def recovered_inactivity_startup(repo, run, job_list, later):
    """A verified live check supersedes a same-day check that never started."""
    if (repo != COMMISSIONER or job_list or run.get('conclusion') not in BAD
            or PurePosixPath(run.get('path', '')).name != 'fafl-inactivity-watch.yml'
            or not later or later.get('status') != 'completed'
            or later.get('conclusion') != 'success' or not production(later)
            or later.get('created_at', '') <= run.get('updated_at', '')
            or incident_scope(repo, later) != incident_scope(repo, run)):
        return False
    required = {'Test inactivity policy and source parsing',
                'Check FAFL inactivity and deliver scoped notifications'}
    successful = {step['name'] for job in jobs(repo, later) if job.get('conclusion') == 'success'
                  for step in job.get('steps', []) if step.get('conclusion') == 'success'}
    return required <= successful


def verified_recovery(repo, run, job_list, history):
    """Suppress historical alerts only when the same production work passed."""
    if run.get('conclusion') not in BAD:
        return None
    for later in history:
        retry = (later.get('id') == run.get('id') and
                 later.get('run_attempt', 1) > run.get('run_attempt', 1))
        if (later.get('status') != 'completed' or later.get('conclusion') != 'success'
                or not production(later)
                or later.get('path') != run.get('path')
                or incident_scope(repo, later) != incident_scope(repo, run)
                or later.get('updated_at', '') <= run.get('updated_at', '')
                or (not retry and later.get('created_at', '') <= run.get('updated_at', ''))):
            continue
        try:
            completed = jobs(repo, later)
        except (OSError, RuntimeError, ValueError, KeyError):
            continue  # Unavailable recovery evidence must not hide the failure.
        successful = {j['name']: j for j in completed if j.get('conclusion') == 'success'}
        affected = [j for j in job_list if j.get('conclusion') in BAD | {'skipped'}]
        if not job_list:
            # Startup failures have no step evidence: require a complete execution,
            # not a green workflow whose actual work was skipped.
            if completed and len(successful) == len(completed) and all(
                    any(s.get('conclusion') == 'success' and s['name'] not in
                        {'Set up job', 'Complete job'} for s in j.get('steps', []))
                    for j in completed):
                return later
            continue
        if not affected:
            continue
        recovered = True
        for old in affected:
            new = successful.get(old['name'])
            if not new:
                recovered = False
                break
            passed = {s['name'] for s in new.get('steps', []) if s.get('conclusion') == 'success'}
            required = {s['name'] for s in old.get('steps', []) if s.get('conclusion') in BAD | {'skipped'}}
            if not required:
                required = {s['name'] for s in old.get('steps', [])
                            if s.get('conclusion') != 'skipped'}
            if not passed or not required <= passed:
                recovered = False
                break
        if recovered:
            return later
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--deadlines', action='store_true')
    parser.add_argument('--verify-coverage', action='store_true')
    args = parser.parse_args()
    if os.environ.get('WEEKLY_REPORT_EMAIL_TO') != OWNER:
        raise ValueError('Failure reports must be addressed only to ' + OWNER)
    if args.verify_coverage:
        # Read the original attempts, not a later successful retry. Never send
        # or acknowledge emails while checking access to failure evidence.
        for repo, number in [(DAILY_REPO,43199358490),(COMMISSIONER,42471397260),(GUARDIAN,43193643494)]:
            run = api(repo,f'actions/runs/{number}/attempts/1')
            evidence = jobs(repo,run)
            if not failures(run,evidence):
                raise RuntimeError('Required failure evidence missing: '+repo+'/'+str(number))
            print('Verified failure coverage: '+repo+'/'+str(number))
        return
    state = mail.document(os.environ['GITHUB_REPOSITORY'], STATE_PATH) or {'sent': {}, 'checked': {}}
    if args.dry_run:
        state = copy.deepcopy(state)
    state.setdefault('checked', {})
    original = copy.deepcopy(state)
    histories={}
    coverage_errors=[]
    private_since = os.environ.get('PRIVATE_FAILURE_REPORTING_SINCE','')
    repositories = REPOS + ([GUARDIAN] if private_since else [])
    for repo in sorted(repositories, key=lambda r: 0 if r == GUARDIAN else 1 if r == COMMISSIONER else 2):
        try:
            history = list(runs(repo))
        except (OSError, RuntimeError, ValueError, KeyError):
            coverage_errors.append(repo)
            continue  # A private API outage must not stop public failure reporting.
        if repo == GUARDIAN:
            for run in history:
                run['_private_report'] = True
            history = [run for run in history if run['updated_at'] >= private_since]
        elif repo == COMMISSIONER and private_since:
            for run in history:
                run['_audit_report'] = run['updated_at'] >= private_since
        histories[repo]=history
        for latest in reversed(history):
            impact = production(latest)
            if not impact:
                continue
            # Inspect earlier attempts; suppress only evidence-backed recoveries.
            for attempt in range(1, latest.get('run_attempt', 1) + 1):
                key = f'{repo}:{latest["id"]}:{attempt}'
                if key in state['sent'] or key in state['checked']:
                    continue
                run = latest if attempt == latest.get('run_attempt', 1) else api(repo, f'actions/runs/{latest["id"]}/attempts/{attempt}')
                if repo == GUARDIAN:
                    run['_private_report'] = True
                elif repo == COMMISSIONER and private_since:
                    run['_audit_report'] = run['updated_at'] >= private_since
                if run['status'] != 'completed':
                    continue
                if notification_pending(repo,run,datetime.now(timezone.utc)):
                    continue  # Leave unacknowledged for the next periodic scan.
                if str(run['id']) == os.environ.get('GITHUB_RUN_ID') and repo == os.environ['GITHUB_REPOSITORY']:
                    continue
                # A superseded cancellation does not imply an outstanding missed
                # dependency when the same workflow already completed afterward.
                later = next((r for r in history if r.get('conclusion')=='success' and r['updated_at']>run['updated_at'] and incident_scope(repo,r)==incident_scope(repo,run)),None)
                if recovered_watchdog(repo, run, later):
                    state['checked'][key] = 'watchdog superseded by verified same-day checks: ' + later['html_url']
                    continue
                job_list = jobs(repo, run)
                recovery = verified_recovery(repo, run, job_list, history)
                if recovery:
                    state['checked'][key] = 'resolved before notification; verified recovery: ' + recovery['html_url']
                    continue
                if recovered_inactivity_startup(repo, run, job_list, later):
                    state['checked'][key] = 'startup failure superseded by verified live inactivity check: ' + later['html_url']
                    continue
                if cancelled_without_runner_after_same_day_success(run, job_list, history):
                    state['checked'][key] = 'cancelled before runner assignment; same-day watchdog already succeeded'
                    continue
                failed = failures(run, job_list)
                audit_parent = private_parent(run) if repo == GUARDIAN else None
                if audit_parent and failed:
                    parent_id,parent_attempt,kind = audit_parent
                    parent_key = f'{COMMISSIONER}:{parent_id}:{parent_attempt}'
                    previous = state['sent'].get(parent_key,{})
                    name,step = PRIVATE_PARENT_STEPS[kind]
                    if name+': '+step in previous.get('failed_steps',[]):
                        parent = dict(id=parent_id,run_attempt=parent_attempt,path='automation-preflight.yml')
                        parent_job = next((j for j in jobs(COMMISSIONER,parent) if j['name']==name),{})
                        if private_child_link(COMMISSIONER,parent,parent_job,step)==str(run['id']):
                            state['checked'][key]='reported by '+parent_key
                            continue
                if failed and repo == COMMISSIONER and PurePosixPath(run['path']).name == 'automation-preflight.yml':
                    by_name = {j['name']:j for j in job_list}
                    failed = [line for line in failed if not delivered_private_child(state,repo,run,by_name,line)]
                    if not failed:
                        state['checked'][key]='reported by exact private audit child'
                        continue
                child = daily_child(run) if repo == COMMISSIONER else None
                if child and failed:
                    # An older reporter may already have delivered the parent incident.
                    parent_id, (_, name, step) = child
                    for key_parent, entry in state['sent'].items():
                        if (key_parent.startswith(f'{DAILY_REPO}:{parent_id}:') and
                                name + ': ' + step in entry.get('failed_steps', []) and
                                run['updated_at'] <= entry['failed_at']):
                            attempt_parent = int(key_parent.rsplit(':', 1)[1])
                            parent = dict(id=parent_id,run_attempt=attempt_parent,path='daily_adl_league_maintenance.yml')
                            try:
                                related = next((j for j in jobs(DAILY_REPO,parent) if j['name']==name),None)
                            except (RuntimeError, OSError):
                                related = None
                            if (related and related['started_at'] <= run['updated_at'] <= related['completed_at']
                                    and propagated_child(DAILY_REPO,parent,related,step)==str(run['id'])):
                                state['checked'][key]='reported by '+key_parent
                                break
                    if key in state['checked']:continue
                if failed and repo == DAILY_REPO and 'daily_adl_league_maintenance.yml' in run['path']:
                    by_name = {j['name']:j for j in job_list}
                    failed = [line for line in failed if not delivered_child(state,repo,run,by_name,line)]
                    if not failed:
                        state['checked'][key]='reported by exact failed child'
                        continue
                if not failed:
                    # The reporter's own success and Pages builds from receipt
                    # commits must not create a perpetual state-commit/build loop.
                    if 'email_workflow_failures.yml' not in run.get('path', '') and run.get('name') != 'pages-build-deployment':
                        state['checked'][key] = run.get('conclusion')
                    continue
                incident = incident_key(repo, run)
                codes=cause_codes(repo,run,job_list)
                scope,failed = unreported_steps(state,repo,run,history,failed,codes)
                if not failed:
                    state['checked'][key] = 'duplicate notification for ' + incident
                    # Retain exact child/parent attribution even when the child
                    # retry was covered by an earlier incident email.
                    if child or audit_parent:
                        record = {'failed_at':run['updated_at']}
                        if child:
                            record.update(daily_parent=child[0],daily_job=child[1][1])
                        if audit_parent:
                            record.update(audit_parent=audit_parent[0],audit_attempt=audit_parent[1],audit_kind=audit_parent[2])
                        state.setdefault('linked_reports',{})[key]=record
                    continue
                try:publication=correction_publication(repo,run)
                except (OSError,RuntimeError,ValueError,KeyError,TypeError):publication=None
                subject, body = message(repo, run, impact, failed, later, publication, later_daily_cycle(repo,run,history))
                if child:
                    body += f'\n\nDaily maintenance parent: https://github.com/{DAILY_REPO}/actions/runs/{child[0]}'
                affected={j['name']:j.get('conclusion') for j in job_list if j.get('conclusion') in BAD|{'skipped'}}
                skipped=[name for name,status in affected.items() if status=='skipped']
                if run.get('name') == 'Daily ADL League Maintenance':
                    passed = [j['name'] for j in job_list if j.get('conclusion') == 'success'
                              and not j['name'].startswith('Daily intent')]
                    if passed:body+='\n\nCompleted successfully: '+', '.join(passed)
                if skipped:body+='\n\nSkipped jobs: '+', '.join(skipped)
                if args.dry_run:
                    print(body + '\n')
                else:
                    mail.send_email(subject, body, 'failure:' + key)
                state['sent'][key] = {'sent_at': datetime.now(timezone.utc).isoformat(),
                                      'subject': subject, 'incident_key': incident, 'scope': scope,
                                      'failed_steps': failed, 'cause_codes':codes,'affected_jobs':affected,'failed_at':run['updated_at']}
                if child:
                    state['sent'][key].update(daily_parent=child[0],daily_job=child[1][1])
                if audit_parent:
                    state['sent'][key].update(audit_parent=audit_parent[0],audit_attempt=audit_parent[1],audit_kind=audit_parent[2])
                week_match=re.search(r'(weekly update|correction update) · Week (\d+)',run.get('display_title',''))
                if week_match:
                    local=datetime.fromisoformat(run['created_at'].replace('Z','+00:00')).astimezone(ZoneInfo('America/New_York'))
                    process='preliminary' if week_match[1]=='weekly update' else 'corrections'
                    day=local.date()+timedelta(days=int(process=='preliminary' and local.weekday()==0))
                    state['sent'][key]['delivery']=[repo,str(day),process,int(week_match[2])]
                if not args.dry_run:
                    save(state)
                    print('SMTP accepted failure report: ' + key)
    if args.deadlines:
        check_deadlines(state,args.dry_run,datetime.now(timezone.utc),histories)
    if not args.dry_run and state != original:
        save(state)
    if coverage_errors:
        raise RuntimeError('Failure coverage unavailable; native notifications must remain enabled: '+', '.join(coverage_errors))
    print('Production failure scan complete.')


def notification_pending(repo, run, now):
    if run.get('conclusion') not in BAD:
        return False
    delay = 10 if repo == GUARDIAN and PurePosixPath(run.get('path','')).name in {'guardian.yml','initial-lineup.yml'} else 15
    ended = datetime.fromisoformat(run['updated_at'].replace('Z','+00:00'))
    return now - ended < timedelta(minutes=delay)


def check_deadlines(state,dry,now,histories=None):
    local=now.astimezone(ZoneInfo('America/New_York'))
    if local.hour<10:return
    day=local.date();season=day.year-(day.month==1)
    sept=day.replace(year=season,month=9,day=1)
    week=(day-(sept+timedelta(days=(-sept.weekday())%7+7))).days//7+1
    def overdue(repo,capability,detail):
        key=f'deadline:{repo}:{day}:{capability}'
        if key in state['sent']:return
        subject=f'[League automation overdue] {repo.split("/")[-1]}: {capability}'
        if dry:print(subject,detail);return
        mail.send_email(subject,detail,'failure:'+key)
        state['sent'][key]={'subject':subject,'sent_at':now.isoformat()};save(state)
    repo=REPOS[0]
    daily=api(repo,'actions/workflows/daily_adl_league_maintenance.yml/runs?branch=main&per_page=50')['workflow_runs']
    today=[r for r in daily if r.get('display_title')=='Daily ADL League Maintenance' and
           (started:=datetime.fromisoformat(r['created_at'].replace('Z','+00:00')).astimezone(local.tzinfo)).date()==day and started.hour>=5]
    if not today:
        overdue(repo,'daily maintenance','No main-branch daily maintenance run was found for '+str(day)+'. Check the scheduler.')
    elif not any(r['status']=='completed' for r in today):
        overdue(repo,'daily maintenance','Daily maintenance has not finished: '+today[0]['html_url'])
    process={1:'preliminary',3:'corrections'}.get(day.weekday())
    if not process or not 1<=week<=17:return
    for repo,league in zip(REPOS[:2],['60206','22686']):
        receipt=mail.document(repo,'data/refresh_receipts/'+process+'.json') or {}
        if (receipt.get('season'),str(receipt.get('league_id')),receipt.get('week'),receipt.get('process'),receipt.get('status'),receipt.get('payouts_verified'))==(season,league,week,process,'success',True) and (process!='corrections' or receipt.get('bonus_mfl_verified') is True):continue
        # An already-notified failure of this delivery owns the incident.
        known=[entry for entry in state['sent'].values() if entry.get('delivery')==[repo,str(day),process,week]]
        if known and not any(r.get('conclusion')=='success' and incident_scope(repo,r)==entry['scope']
                             and r['updated_at']>entry['failed_at'] for entry in known for r in (histories or {}).get(repo,[])):continue
        overdue(repo,f'Week {week} {process}',f'No verified {process} publication receipt for {season} Week {week}. Check the poller and weekly worker; publication has not been confirmed.')

if __name__ == '__main__':
    main()
