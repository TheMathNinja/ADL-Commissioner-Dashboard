"""Report production failures separately from successful-publication emails."""
import argparse
import copy
from datetime import datetime, timedelta, timezone
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
    'daily_adl_league_maintenance.yml': 'The combined morning SalAdj, waiver-correction, roster/Extension, or Commissioner-alert package did not complete.',
    'refresh_extension_calculator.yml': 'ADL Elo, Bonus Games/MFL entries, Playoffs, Payouts, or EXT may be incomplete. See the failed components below.',
    'refresh.yml': 'FAFL Elo, Bonus Games/MFL entries, Playoffs, or Payouts may be incomplete. See the failed components below.',
    'poll_preliminary_scores.yml': 'The preliminary-score readiness check failed; the weekly refresh may not have been triggered.',
    'poll_score_corrections.yml': 'The correction check failed; corrected scores and due MFL Bonus Games may not have been processed.',
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
    re.compile(r'^Daily ADL League Maintenance$'),
    re.compile(r'^Dashboard Watchdog$'),
    re.compile(r'^Official Week \d+ cap snapshot \(weekly package \d+\)$'),
    re.compile(r'^(?:Preliminary|Corrections) 60206 2026 week \d+'),
    re.compile(r'^Official (?:ADL|FAFL) (?:weekly update · Week \d+|correction update · Week \d+ · .+)$', re.IGNORECASE),
)


def api(repo, path):
    error = None
    for attempt in range(3):
        try:
            value = mail.get_json(f'https://api.github.com/repos/{repo}/{path}')
            if value is None:
                raise RuntimeError(f'GitHub resource unavailable: {repo}/{path}')
            return value
        except (TimeoutError, OSError) as exc:
            error = exc
            if attempt < 2:
                mail.time.sleep(2 ** attempt)
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
        batch = api(repo, f'actions/runs?per_page=50&page={page}&branch=main&created=%3E%3D{start}')['workflow_runs']
        yield from batch
        if len(batch) < 50:
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


def message(repo, run, impact, failed, later_success):
    title = re.sub(r'\b[a-f0-9]{40,64}\b', '', run.get('display_title') or run['name']).strip()
    status = 'CANCELLED' if run.get('conclusion') == 'cancelled' else 'FAILED'
    subject = f'[League automation {status}] {repo.split("/")[-1]} — {title}'
    lines = [subject, '', 'Impact: ' + impact, '', 'Failed steps:']
    lines += ['- ' + item for item in failed]
    lines += ['', 'Run: ' + run['html_url'], 'Attempt: ' + str(run.get('run_attempt', 1)),
              'Started (UTC): ' + run.get('run_started_at', run['created_at']),
              'Run last updated (UTC): ' + run['updated_at'], '']
    if later_success:
        lines += ['Catch-up notice: a later run of this workflow has succeeded.',
                  'Later successful run: ' + later_success['html_url']]
    else:
        lines += ['No later successful run of this workflow was found at report time.',
                  'A later retry may recover it; this email does not claim recovery.']
    lines += ['', 'This alert does not wait for the other league or for successful publication.',
              'Sent only to ' + OWNER + '.']
    return subject, '\n'.join(lines)


def incident_key(repo, run):
    """Stable identity for repeated dispatches of the same production incident."""
    return f'{repo}:{run.get("workflow_id")}:{run.get("display_title") or run.get("name", "")}'


def incident_already_reported(state, repo, run, history):
    incident = incident_key(repo, run)
    if any(entry.get('incident_key') == incident for entry in state['sent'].values()):
        return True
    # State written before incident keys still identifies its source run. Use
    # the fetched history to coalesce exact-title retries without conflating a
    # genuinely different correction hash.
    same_title_ids = {
        str(candidate['id']) for candidate in history
        if candidate.get('workflow_id') == run.get('workflow_id')
        and (candidate.get('display_title') or candidate.get('name', '')) ==
            (run.get('display_title') or run.get('name', ''))
    }
    return any(
        key.startswith(repo + ':') and key.split(':')[-2] in same_title_ids
        for key in state['sent']
    )


def save(state):
    mail.STATE_PATH = STATE_PATH
    mail.save_state(state)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if os.environ.get('WEEKLY_REPORT_EMAIL_TO') != OWNER:
        raise ValueError('Failure reports must be addressed only to ' + OWNER)
    state = mail.document(os.environ['GITHUB_REPOSITORY'], STATE_PATH) or {'sent': {}, 'checked': {}}
    state.setdefault('checked', {})
    original = copy.deepcopy(state)
    for repo in REPOS:
        history = list(runs(repo))
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
                later = next((r for r in history if r['workflow_id'] == run['workflow_id'] and r.get('conclusion') == 'success' and r['updated_at'] > run['updated_at']), None)
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
                if incident_already_reported(state, repo, run, history):
                    state['checked'][key] = 'duplicate notification for ' + incident
                    continue
                subject, body = message(repo, run, impact, failed, later)
                if args.dry_run:
                    print(body + '\n')
                    continue
                mail.send_email(subject, body, 'failure:' + key)
                state['sent'][key] = {'sent_at': datetime.now(timezone.utc).isoformat(),
                                      'subject': subject, 'incident_key': incident}
                save(state)
                print('SMTP accepted failure report: ' + key)
    if not args.dry_run and state != original:
        save(state)
    print('Production failure scan complete.')


if __name__ == '__main__':
    main()
