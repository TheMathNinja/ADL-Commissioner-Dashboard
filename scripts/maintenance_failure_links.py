"""Exact maintenance-component notification ownership, shared with the watchdog."""
import re
import subprocess

PARENT_REPO = 'TheMathNinja/ADL-GM-Dashboard'
CHILD_REPO = 'TheMathNinja/ADL-Commissioner-Dashboard'
WATCHDOG_STEP = "check-dashboard-freshness: Check today's maintenance result and alert ownership"
CHILD_STEPS = {
    'Refresh SalAdj and Commissioner data': 'Dispatch Commissioner-owned data refresh',
    'Apply waiver cap corrections': 'Dispatch Commissioner-owned waiver corrections',
    'Run Commissioner alerts': 'Dispatch Commissioner-owned alerts',
}


def child_from_log(parent, job):
    step = CHILD_STEPS.get(job['name'])
    if not job.get('id') or not step or not any(
            s['name'] == step and s.get('conclusion') == 'failure' for s in job.get('steps', [])):
        return None
    try:
        log = subprocess.run(['gh', 'run', 'view', str(parent['id']), '--repo', PARENT_REPO,
            '--job', str(job['id']), '--attempt', str(parent.get('run_attempt', 1)), '--log-failed'],
            capture_output=True, text=True, encoding='utf8', errors='replace', timeout=30, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    ids = set(re.findall(r'Child workflow (\d+) completed with conclusion: (?:failure|timed_out|cancelled|action_required)\.(?=\s|$)', log))
    return ids.pop() if len(ids) == 1 else None


def covered_components(state, parent, job_list, child_link=child_from_log):
    """Only delivered reports count; uncertain SMTP claims cannot suppress alerts."""
    parent_key = f"{PARENT_REPO}:{parent['id']}:{parent.get('run_attempt', 1)}"
    notice = state.get('sent', {}).get(parent_key, {})
    records = {**state.get('linked_reports', {}), **state.get('sent', {})}
    covered = set()
    for job in job_list:
        name, status = job['name'], job.get('conclusion')
        if status not in {'failure', 'timed_out', 'cancelled', 'action_required'}:
            continue
        if any(entry.get('maintenance_parent') == str(parent['id']) and
               entry.get('maintenance_attempt') == parent.get('run_attempt', 1) and
               entry.get('maintenance_components', {}).get(name) == status and
               WATCHDOG_STEP in entry.get('failed_steps', [])
               for entry in state.get('sent', {}).values()):
            covered.add(name)
            continue
        # affected_jobs includes failures that were removed from the email as
        # duplicates; require an actually reported step as well.
        if (notice.get('affected_jobs', {}).get(name) == status and
                any(line.startswith(name + ': ') for line in notice.get('failed_steps', []))):
            covered.add(name)
            continue
        child_id = child_link(parent, job)
        if child_id and any(
                key.startswith(f'{CHILD_REPO}:{child_id}:') and
                entry.get('daily_parent') == str(parent['id']) and entry.get('daily_job') == name and
                job.get('started_at', '~') <= entry.get('failed_at', '') <= job.get('completed_at', '')
                for key, entry in records.items()):
            covered.add(name)
    # This is the sole success-only dependency in the maintenance workflow.
    # Roster refresh and Commissioner alerts run independently even after failure.
    by_name = {j['name']: j for j in job_list}
    if ('Refresh SalAdj and Commissioner data' in covered and
            by_name.get('Apply waiver cap corrections', {}).get('conclusion') == 'skipped'):
        covered.add('Apply waiver cap corrections')
    return covered
