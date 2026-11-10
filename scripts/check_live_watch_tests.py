"""Run the watcher's declared tests without collecting or publishing live data."""
import argparse
from pathlib import Path
import shlex
import subprocess
import sys

import yaml


def test_commands(repo):
    workflow = yaml.safe_load((repo / '.github/workflows/live_bonus_watch.yml').read_text(encoding='utf-8'))
    commands = []
    for step in workflow['jobs']['watch']['steps']:
        for line in step.get('run', '').splitlines():
            if not line.strip().startswith(('python3 -m unittest ', 'node tests/')):
                continue
            args = shlex.split(line.strip())
            if args[:6] == ['python3', '-m', 'unittest', 'discover', '-s', 'tests']:
                if len(args) not in (8, 9) or args[6] != '-p' or (len(args) == 9 and args[8] != '-v'):
                    raise ValueError('Unsupported unittest command: ' + line)
                test = args[7]
                if Path(test).name != test or not test.startswith('test_') or not test.endswith('.py'):
                    raise ValueError('Invalid test filename: ' + test)
                args[0] = sys.executable
            elif len(args) == 2 and args[0] == 'node' and args[1].startswith('tests/test_') and args[1].endswith('.cjs') and '..' not in args[1]:
                pass
            else:
                raise ValueError('Unsupported test command: ' + line)
            commands.append(args)
    if not commands:
        raise ValueError('No Live Bonus Game Watch tests found')
    return commands


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('repositories', nargs='+', type=Path)
    args = parser.parse_args()
    for repo in args.repositories:
        for command in test_commands(repo):
            print(f'{repo.name}: {shlex.join(command)}', flush=True)
            subprocess.run(command, cwd=repo, check=True)
