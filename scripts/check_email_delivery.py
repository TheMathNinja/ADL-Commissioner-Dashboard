"""Offline release gate for all shared email delivery contracts."""
import argparse
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--guardian', required=True, type=Path)
    parser.add_argument('--adl', type=Path)
    args = parser.parse_args()
    commissioner = Path(__file__).resolve().parents[1]
    guardian = args.guardian.resolve()
    test_env = dict(os.environ, GUARDIAN_ALERT_OWNER='', GUARDIAN_TEST_ROOT=str(guardian))
    for name in ('smtp_delivery.py', 'email_delivery_state.py', 'github_email_receipt.py', 'guardian_input_watch.py', 'guardian_check_policy.py'):
        canonical = (commissioner / 'scripts' / name).read_text()
        if canonical != (guardian / 'scripts' / name).read_text():
            raise SystemExit('Shared delivery policies differ: ' + name + '; do not publish')
    suites = ('test_email_delivery_state.py', 'test_github_email_receipt.py', 'test_email_state_save.py',
              'test_incident_replay.py', 'test_workflow_failure_email.py', 'test_account_failure_coverage.py', 'test_maintenance_failure_links.py',
              'test_alert_transport.py', 'test_weekly_completion_email.py',
              'test_gotw_blurbs.py', 'test_guardian_incidents.py',
              'test_guardian_health_monitor.py', 'test_guardian_check_policy.py', 'test_guardian_backup_recovery.py',
              'test_guardian_collision_contract.py', 'test_actions_budget.py',
              'test_forecast_request_monitor.py', 'test_chi_sync_request_monitor.py', 'test_private_audit_cache.py', 'test_private_actions_policy.py', 'test_guardian_fallback.py')
    for suite in suites:
        subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-p', suite],
                       cwd=commissioner, env=test_env, check=True)
    # Exercise runner-only branches locally as well, without inheriting credentials.
    ci_env = {key: value for key, value in test_env.items()
              if key not in ('GH_TOKEN', 'GITHUB_TOKEN') and not key.startswith(('ADL_SMTP_', 'ADL_ALERT_EMAIL_'))}
    ci_env.update(GITHUB_ACTIONS='true', GITHUB_REPOSITORY='test/offline')
    subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_alert_transport.py'],
                   cwd=commissioner, env=ci_env, check=True)
    env = dict(os.environ)
    adl = args.adl.resolve() if args.adl else guardian.parent / 'adl'
    env['PYTHONPATH'] = os.pathsep.join((str(guardian / 'scripts'), str(adl / 'scripts'), env.get('PYTHONPATH', '')))
    subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'test', '-p', 'test_notifications.py'],
                   cwd=guardian, env=env, check=True)
    subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts', '-p', 'test_guardian_coverage.py'],
                   cwd=guardian, env=env, check=True)
    subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts', '-p', 'test_health_receipts.py'],
                   cwd=guardian, env=env, check=True)
    subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'test', '-p', 'test_chi_forecast*.py'],
                   cwd=guardian, env=env, check=True)
    # Exercise both deployed ownership settings, not just the developer's environment.
    subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'test', '-p', 'test_chi_sync_completion.py'],
                   cwd=guardian, env=env, check=True)
    for owner in ('', 'commissioner-v1'):
        node_env = dict(ci_env, GUARDIAN_ALERT_OWNER=owner)
        subprocess.run(['node', '--test', 'test/warning-delivery.test.js', 'test/warning-days.test.js',
                        'test/notifications.test.js', 'test/check-outcome.test.js',
                        'test/fafl-roster.test.js'], cwd=guardian, env=node_env, check=True)
    subprocess.run(['node', 'scheduler/test_league_alert_health.cjs'], cwd=guardian, check=True)
    print('Shared delivery, crash recovery, incident replay, and Guardian warning tests passed.')


if __name__ == '__main__':
    main()
