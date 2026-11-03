"""Read-only replay of the Nov 3 incident; uses gh for evidence, never SMTP."""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import email_workflow_failures as reporter


def get(repo, path):
    return json.loads(subprocess.check_output(['gh', 'api', f'repos/{repo}/{path}']))


if __name__ == '__main__':
    parent, child = reporter.DAILY_REPO, reporter.COMMISSIONER
    run, jobs = {}, {}
    for repo, number in [(parent, 41618310247), (child, 41618363455)]:
        path = f'actions/runs/{number}/attempts/1'
        run[repo] = get(repo, path)
        jobs[repo] = get(repo, path + '/jobs')['jobs']

    for label, repos, extra, expected in [
        ('linked', [parent, child], False, 1), ('parent alone', [parent], False, 1),
        ('child alone', [child], False, 1), ('independent parent failure', [parent, child], True, 2),
    ]:
        job_lists = copy.deepcopy(jobs)
        if extra:
            job_lists[parent].append(dict(name='Independent verification', conclusion='failure', steps=[]))
        output = io.StringIO()
        with patch.dict(os.environ, WEEKLY_REPORT_EMAIL_TO=reporter.OWNER, GITHUB_REPOSITORY=child), \
             patch.object(sys, 'argv', ['reporter', '--dry-run']), \
             patch.object(reporter, 'runs', lambda r: [run[r]] if r in repos else []), \
             patch.object(reporter, 'jobs', lambda r, _: job_lists[r]), \
             patch.object(reporter.mail, 'document', return_value={}), \
             patch.object(reporter, 'cause_codes', return_value={}), \
             patch.object(reporter.mail, 'send_email', side_effect=AssertionError), \
             patch.object(reporter, 'save', side_effect=AssertionError), contextlib.redirect_stdout(output):
            reporter.main()
        body = output.getvalue()
        assert body.count('[League automation FAILED]') == expected, body
        assert all(run[r]['html_url'] in body for r in repos), body
        if extra:
            assert 'Independent verification: failure' in body, body
        print(f'{label}: {expected} alert(s)')
