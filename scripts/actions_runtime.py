"""Bounded, exact-software runtime measurements from job metadata, not source."""
import hashlib
import json
import math
from datetime import timedelta
from guardian_health_monitor import REPO, stamp

WORKFLOWS = ('guardian.yml', 'initial-lineup.yml', 'sync_chi_team_tools.yml',
             'refresh_chi_team_tools.yml', 'league-audit.yml', 'model_contract_preflight.yml')
FIXTURE = 'data/audits/43528287932-1-monitor.json'


def fingerprint(tree, workflow):
    if tree.get('truncated'):
        raise ValueError('Incomplete runtime input metadata')
    inputs = sorted((row['path'], row['sha'], row.get('mode')) for row in tree['tree']
                    if row['type'] == 'blob' and (
                        row['path'] == '.github/workflows/' + workflow or
                        row['path'].startswith(('src/', 'scripts/', 'test/', 'scheduler/', 'config/', '.github/actions/')) or
                        row['path'] in ('package.json', 'package-lock.json', FIXTURE)))
    if not inputs:
        raise ValueError('Empty runtime input metadata')
    return hashlib.sha256(json.dumps(inputs, separators=(',', ':')).encode()).hexdigest()


def job_minutes(jobs):
    total = 0
    for job in jobs:
        if not job.get('runner_id') or job.get('conclusion') == 'skipped':
            continue
        if not job.get('started_at') or not job.get('completed_at'):
            raise ValueError('Incomplete completed-job timing')
        labels = ' '.join(job.get('labels', [])).lower()
        if 'self-hosted' in labels:
            continue
        if not any(label in labels for label in ('ubuntu', 'windows', 'macos')):
            raise ValueError('Unrecognized hosted runner class')
        # Express mixed-OS usage in standard Linux-minute equivalents.
        rate = 0.062 if 'macos' in labels else 0.010 if 'windows' in labels else (
            0.002 if 'ubuntu-slim' in labels else 0.005 if 'arm64' in labels else 0.006)
        seconds = (stamp(job['completed_at']) - stamp(job['started_at'])).total_seconds()
        if seconds < 0:
            raise ValueError('Negative job duration')
        total += math.ceil(seconds / 60) * rate / 0.006
    return total


def measure(api, now, prior=None):
    trees = {}
    def tree(sha):
        if sha not in trees:
            commit = api(REPO, 'commits/' + sha)
            trees[sha] = api(REPO, 'git/trees/' + commit['commit']['tree']['sha'] + '?recursive=1')
        return trees[sha]
    current = tree('main')
    old = (prior or {}).get('runtimeMeasurements', {})
    results = {}
    for workflow in WORKFLOWS:
        digest = fingerprint(current, workflow)
        samples = {}
        runs = api(REPO, f'actions/workflows/{workflow}/runs?status=completed&per_page=100')['workflow_runs']
        inspected = 0
        for run in runs:
            if stamp(run['created_at']) < now - timedelta(days=14):
                continue
            if run.get('status') != 'completed' or run.get('conclusion') in ('skipped', 'cancelled'):
                continue
            if inspected >= 12:
                break
            inspected += 1
            if fingerprint(tree(run['head_sha']), workflow) != digest:
                continue
            observation = next((value for name, cached in old.items()
                                if name == workflow or name.startswith(workflow + ':')
                                for value in cached.get('observations', [])
                                if value['id'] == run['id'] and value.get('attempt') == run.get('run_attempt', 1)
                                and cached.get('fingerprint') == digest), None)
            if observation is None:
                # All jobs are needed: silently ignoring page two can understate cost.
                response = api(REPO, f'actions/runs/{run["id"]}/jobs?filter=latest&per_page=100')
                jobs = response['jobs']
                if response.get('total_count', len(jobs)) > len(jobs):
                    raise ValueError('Runtime job list is truncated')
                if workflow in ('guardian.yml', 'initial-lineup.yml') and not any(
                        step.get('name') == 'Run npm run check' and step.get('conclusion') in ('success', 'failure')
                        for job in jobs for step in job.get('steps', [])):
                    continue  # Test/cache-only and unconfigured runs are not live-worker evidence.
                minutes = job_minutes(jobs)
                if not minutes:
                    continue
                kind = workflow
                if workflow == 'league-audit.yml':
                    allocated = [job['name'] for job in jobs if job.get('runner_id') and job.get('conclusion') != 'skipped']
                    kind = 'league-audit.yml:guardian' if any('guardian-audit' in name for name in allocated) else 'league-audit.yml:contracts'
                observation = {'id': run['id'], 'attempt': run.get('run_attempt', 1), 'kind': kind,
                               'createdAt': run['created_at'], 'roundedMinutes': round(minutes, 4)}
            samples[run['id']] = observation
        observations = list(samples.values())
        kinds = {row['kind'] for row in observations} or {workflow}
        for kind in kinds:
            selected = [row for row in observations if row['kind'] == kind][:5]
            results[kind] = {'fingerprint': digest, 'sampleCount': len(selected),
                             'meanRoundedMinutes': (sum(row['roundedMinutes'] for row in selected) / len(selected)
                                                    if selected else None), 'observations': selected,
                             'status': 'measured' if selected else 'no_current_software_live_samples'}
    return results
