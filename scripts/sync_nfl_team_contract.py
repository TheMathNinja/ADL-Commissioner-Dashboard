"""Synchronize only reviewed, non-proprietary NFL team adapters to local checkouts."""
import argparse
from pathlib import Path
from check_nfl_team_codes import audit_team_contracts, REPOS


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', action='append', required=True, metavar='NAME=PATH')
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    roots = {name: Path(raw).resolve() for name, raw in (x.split('=', 1) for x in args.repo)}
    if set(roots) != set(REPOS):
        parser.error('Supply all four repository checkouts')
    owner = Path(__file__).resolve().parents[1]
    for name, root in roots.items():
        files = ['config/nfl_teams.json', 'scripts/nfl_teams.py']
        if name in REPOS[:2]:
            files.append('R/nfl_teams.R')
        for relative in files:
            source, target = owner / relative, root / relative
            if source.resolve() == target.resolve():
                continue
            if args.write:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.read_bytes())
            elif not target.is_file() or target.read_text() != source.read_text():
                raise SystemExit('Shared NFL contract drift: ' + name + '/' + relative)
    errors = audit_team_contracts(roots)
    if errors:
        raise SystemExit('\n'.join(errors))
    print('Reviewed MFL team contract synchronized and source boundaries verified.')


if __name__ == '__main__':
    main()
