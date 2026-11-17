"""Discretionary dispatch policy; never applied to Guardian or coverage checks."""
from guardian_health_monitor import REPO

VARIABLE = 'PRIVATE_DISCRETIONARY_ACTIONS'


def paused(api):
    # Listing avoids treating an absent variable as an API failure. Read failures
    # propagate: do not spend discretionary minutes on an unknown policy.
    response = api(REPO, 'actions/variables?per_page=100')
    if response.get('total_count', len(response['variables'])) > len(response['variables']):
        raise RuntimeError('Incomplete discretionary policy inventory')
    return any(row['name'] == VARIABLE and row['value'] == 'paused'
               for row in response['variables'])
