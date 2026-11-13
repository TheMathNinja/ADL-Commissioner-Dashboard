"""Offline release gate for all shared email delivery contracts."""
import argparse
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--guardian', required=True, type=Path)
    args = parser.parse_args()
    commissioner = Path(__file__).resolve().parents[1]
    guardian = args.guardian.resolve()
    for name in ('smtp_delivery.py', 'email_delivery_state.py', 'github_email_receipt.py'):
        canonical = (commissioner / 'scripts' / name).read_text()
        if canonical != (guardian / 'scripts' / name).read_text():
            raise SystemExit('Shared delivery policies differ: ' + name + '; do not publish')
    suites = ('test_email_delivery_state.py', 'test_github_email_receipt.py', 'test_email_state_save.py',
              'test_incident_replay.py', 'test_workflow_failure_email.py',
              'test_alert_transport.py', 'test_weekly_completion_email.py',
              'test_gotw_blurbs.py')
    for suite in suites:
        subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-p', suite],
                       cwd=commissioner, check=True)
    env = dict(os.environ)
    env['PYTHONPATH'] = str(guardian / 'scripts') + os.pathsep + env.get('PYTHONPATH', '')
    subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'test', '-p', 'test_notifications.py'],
                   cwd=guardian, env=env, check=True)
    subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts', '-p', 'test_guardian_coverage.py'],
                   cwd=guardian, env=env, check=True)
    subprocess.run(['node', '--test', 'test/warning-delivery.test.js', 'test/warning-days.test.js',
                    'test/notifications.test.js'], cwd=guardian, check=True)
    print('Shared delivery, crash recovery, incident replay, and Guardian warning tests passed.')


if __name__ == '__main__':
    main()
