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
from pathlib import PurePosixPath
import email_weekly_completion as mail
from zoneinfo import ZoneInfo

STATE_PATH = 'data/workflow_failure_email_state.json'
LOOKBACK_DAYS = 7
OWNER = 'fili.mikey@gmail.com'
REPOS = ['TheMathNinja/ADL-GM-Dashboard', 'TheMathNinja/FAFL-GM-Dashboard', 'TheMathNinja/ADL-Commissioner-Dashboard']
IMPACT = {
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
    is_orchestrated_dispatch = event == 'workflow_dispatch' and any(
        pattern.search(title) for pattern in PRODUCTION_DISPATCH_NAMES
    )
    if run.get('head_branch') != 'main' or not (is_scheduled or is_orchestrated_dispatch):
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


def message(repo, run, impact, failed, later_success, publication=None):
    title = re.sub(r'\b[a-f0-9]{40,64}\b', '', run.get('display_title') or run['name']).strip()
    status = 'CANCELLED' if run.get('conclusion') == 'cancelled' else 'FAILED'
    subject = f'[League automation {status}] {repo.split("/")[-1]} — {title}'
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
        lines += ['Catch-up notice: a later run of this workflow has succeeded.',
                  'Later successful run: ' + later_success['html_url']]
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
        # Keep only a fingerprint in state, never raw log text. Unclassified
        # failures stay independently reportable rather than hiding a new fault.
        code=f"unclassified:{job['id']}"
        try:
            cmd=['gh','run','view',str(run['id']),'--repo',repo,'--job',str(job['id']),'--log-failed']
            log=subprocess.run(cmd,capture_output=True,text=True,timeout=25,encoding='utf8',errors='replace',check=True).stdout
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
    title = run.get('display_title') or run.get('name','')
    recovery = max((r['updated_at'] for r in history if r['workflow_id']==run['workflow_id']
                    and (r.get('display_title') or r.get('name',''))==title
                    and r.get('conclusion')=='success' and r['updated_at']<run['updated_at']), default='')
    scope = incident_scope(repo,run)
    seen = {step for entry in state['sent'].values() if entry.get('scope')==scope
            and entry.get('failed_at','')>recovery for step in entry.get('failed_steps',[])
            if not codes or entry.get('cause_codes',{}).get(step.split(': ',1)[0])==codes.get(step.split(': ',1)[0])}
    return scope,[step for step in failed if step not in seen]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--deadlines', action='store_true')
    args = parser.parse_args()
    if os.environ.get('WEEKLY_REPORT_EMAIL_TO') != OWNER:
        raise ValueError('Failure reports must be addressed only to ' + OWNER)
    state = mail.document(os.environ['GITHUB_REPOSITORY'], STATE_PATH) or {'sent': {}, 'checked': {}}
    state.setdefault('checked', {})
    original = copy.deepcopy(state)
    histories={}
    for repo in REPOS:
        history = list(runs(repo))
        histories[repo]=history
        for latest in reversed(history):
            impact = production(latest)
            if not impact:
                continue
            # Inspect earlier attempts too: successful retries must not hide failures.
            for attempt in range(1, latest.get('run_attempt', 1) + 1):
                key = f'{repo}:{latest["id"]}:{attempt}'
                if key in state['sent'] or key in state['checked']:
                    continue
                run = latest if attempt == latest.get('run_attempt', 1) else api(repo, f'actions/runs/{latest["id"]}/attempts/{attempt}')
                if run['status'] != 'completed':
                    continue
                if str(run['id']) == os.environ.get('GITHUB_RUN_ID') and repo == os.environ['GITHUB_REPOSITORY']:
                    continue
                # A superseded cancellation does not imply an outstanding missed
                # dependency when the same workflow already completed afterward.
                later = next((r for r in history if r.get('conclusion')=='success' and r['updated_at']>run['updated_at'] and incident_scope(repo,r)==incident_scope(repo,run)),None)
                if run.get('conclusion') == 'cancelled' and later:
                    state['checked'][key] = 'cancelled; replaced by successful run'
                    continue
                job_list = jobs(repo, run)
                if cancelled_without_runner_after_same_day_success(run, job_list, history):
                    state['checked'][key] = 'cancelled before runner assignment; same-day watchdog already succeeded'
                    continue
                failed = failures(run, job_list)
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
                    continue
                try:publication=correction_publication(repo,run)
                except (OSError,RuntimeError,ValueError,KeyError,TypeError):publication=None
                subject, body = message(repo, run, impact, failed, later, publication)
                affected={j['name']:j.get('conclusion') for j in job_list if j.get('conclusion') in BAD|{'skipped'}}
                skipped=[name for name,status in affected.items() if status=='skipped']
                if run.get('name') == 'Daily ADL League Maintenance':
                    passed = [j['name'] for j in job_list if j.get('conclusion') == 'success'
                              and not j['name'].startswith('Daily intent')]
                    if passed:body+='\n\nCompleted successfully: '+', '.join(passed)
                if skipped:body+='\n\nSkipped jobs: '+', '.join(skipped)
                if args.dry_run:
                    print(body + '\n')
                    continue
                mail.send_email(subject, body, 'failure:' + key)
                state['sent'][key] = {'sent_at': datetime.now(timezone.utc).isoformat(),
                                      'subject': subject, 'incident_key': incident, 'scope': scope,
                                      'failed_steps': failed, 'cause_codes':codes,'affected_jobs':affected,'failed_at':run['updated_at']}
                week_match=re.search(r'(weekly update|correction update) · Week (\d+)',run.get('display_title',''))
                if week_match:
                    local=datetime.fromisoformat(run['created_at'].replace('Z','+00:00')).astimezone(ZoneInfo('America/New_York'))
                    process='preliminary' if week_match[1]=='weekly update' else 'corrections'
                    day=local.date()+timedelta(days=int(process=='preliminary' and local.weekday()==0))
                    state['sent'][key]['delivery']=[repo,str(day),process,int(week_match[2])]
                save(state)
                print('SMTP accepted failure report: ' + key)
    if args.deadlines:
        check_deadlines(state,args.dry_run,datetime.now(timezone.utc),histories)
    if not args.dry_run and state != original:
        save(state)
    print('Production failure scan complete.')


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
