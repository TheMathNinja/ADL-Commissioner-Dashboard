"""Discover public owner repositories without reading their source or formulas."""
import re

OWNER = 'TheMathNinja'


def repositories(get_json):
    result = set()
    for page in range(1, 101):
        batch = get_json(f'https://api.github.com/users/{OWNER}/repos?type=owner&per_page=100&page={page}')
        if not isinstance(batch, list):
            raise RuntimeError('Account repository inventory unavailable')
        for repo in batch:
            name = repo.get('full_name', '')
            if (repo.get('owner', {}).get('login', '').lower() != OWNER.lower()
                    or not re.fullmatch(OWNER + r'/[A-Za-z0-9_.-]+', name, re.I)
                    or repo.get('private') is not False):
                raise RuntimeError('Unexpected repository in public owner inventory')
            result.add(name)
        if len(batch) < 100:
            if not result:
                raise RuntimeError('Empty account repository inventory')
            return sorted(result)
    raise RuntimeError('Account repository inventory pagination did not finish')
