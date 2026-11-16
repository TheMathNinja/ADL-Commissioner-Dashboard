"""Propagate reviewed display policy, never infer expectations from implementation."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BEGIN = ' // BEGIN GENERATED LIVE DISPLAY POLICY'
END = ' // END GENERATED LIVE DISPLAY POLICY'


def read_contract(path=ROOT / 'contracts/live_display.json'):
    contract = json.loads(path.read_text(encoding='utf-8'))
    if contract.get('schemaVersion') != 1 or not contract.get('policyVersion'):
        raise ValueError('Unsupported or unversioned live display contract')
    policy = contract['policy']
    if not 0 < policy['lowCutoff'] < policy['highCutoff'] < 1:
        raise ValueError('Invalid probability thresholds')
    if not 0 <= policy['tieMinimumExclusive'] < 1:
        raise ValueError('Invalid tie threshold')
    if not contract['probabilities'] or not contract['ties']:
        raise ValueError('Reviewed behavior examples are required')
    return contract


def generated_policy(contract):
    settings = dict(contract['policy'], version=contract['policyVersion'])
    return BEGIN + '\n const liveDisplayPolicy=Object.freeze(' + json.dumps(settings, separators=(',', ':'), ensure_ascii=True) + ');\n' + END


def synchronize(repo, contract, write=False):
    asset = repo / 'docs/assets/bonus-live-watch.js'
    source = asset.read_text(encoding='utf-8')
    if source.count(BEGIN) != 1 or source.count(END) != 1:
        raise ValueError(f'{repo}: missing or ambiguous generated policy region')
    start, end = source.index(BEGIN), source.index(END) + len(END)
    proposed = source[:start] + generated_policy(contract) + source[end:]
    fixture = repo / 'tests/fixtures/live_display_contract.json'
    expected = json.dumps(contract, indent=2, ensure_ascii=True) + '\n'
    stale = source != proposed or not fixture.exists() or fixture.read_text(encoding='utf-8') != expected
    if write and fixture.exists():
        previous = json.loads(fixture.read_text(encoding='utf-8'))
        if previous != contract and previous.get('policyVersion') == contract['policyVersion']:
            raise ValueError('Display specification changed without a policyVersion bump')
    if stale and not write:
        raise ValueError(f'{repo}: display contract drift; run sync_live_display_contract.py with both league paths and --write')
    if write:
        if source != proposed:
            asset.write_text(proposed, encoding='utf-8')
        fixture.parent.mkdir(parents=True, exist_ok=True)
        if not fixture.exists() or fixture.read_text(encoding='utf-8') != expected:
            fixture.write_text(expected, encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('repositories', nargs=2, type=Path, help='ADL and FAFL checkouts')
    parser.add_argument('--write', action='store_true', help='Propagate the reviewed contract; default is check-only')
    args = parser.parse_args()
    contract = read_contract()
    for repo in args.repositories:
        synchronize(repo, contract, args.write)
    print('Both league display contracts are synchronized.')
