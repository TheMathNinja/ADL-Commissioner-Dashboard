"""Read-only authoritative billing. Financial values stay in private budget state."""
from decimal import Decimal, InvalidOperation
import json
import os
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

OWNER = 'TheMathNinja'
STANDARD_SKUS = {'actions_linux', 'actions_linux_slim', 'actions_linux_arm',
                 'actions_windows', 'actions_windows_arm', 'actions_macos'}
PLAN_MINUTES = {'free': 2000, 'pro': 3000}
LINUX_RATE = Decimal('0.006')


class BillingUnavailable(RuntimeError):
    pass


def get(path):
    token = os.environ.get('ACTIONS_BILLING_TOKEN')
    if not token:
        raise BillingUnavailable('billing_read_credential_missing')
    request = Request('https://api.github.com/' + path, headers={
        'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2026-03-10', 'User-Agent': 'League-budget-monitor'})
    try:
        with urlopen(request, timeout=25) as response:
            return json.load(response)
    except HTTPError as error:
        # Do not log response bodies, financial values, tokens or account details.
        raise BillingUnavailable('billing_http_' + str(error.code)) from error
    except (URLError, TimeoutError, ValueError) as error:
        raise BillingUnavailable('billing_read_unavailable') from error


def number(value):
    try:
        result = Decimal(str(value))
    except (InvalidOperation, TypeError) as error:
        raise BillingUnavailable('billing_invalid_amount') from error
    if not result.is_finite() or result < 0:
        raise BillingUnavailable('billing_invalid_amount')
    return result


def read(repository_api, now, fetch=None):
    fetch = fetch or get
    profile = fetch('user')
    if profile.get('login', '').lower() != OWNER.lower():
        raise BillingUnavailable('billing_wrong_account')
    plan = profile.get('plan', {}).get('name', '').lower()
    if plan not in PLAN_MINUTES:
        raise BillingUnavailable('billing_plan_not_verified')
    report = fetch(f'users/{OWNER}/settings/billing/usage?year={now.year}&month={now.month}')
    rows = report.get('usageItems')
    if not isinstance(rows, list) or report.get('truncated') or report.get('next'):
        raise BillingUnavailable('billing_incomplete_report')
    period = report.get('timePeriod', {})
    if period.get('year', now.year) != now.year or period.get('month', now.month) != now.month:
        raise BillingUnavailable('billing_wrong_period')
    private = {}
    compute = Decimal(0)
    billed = Decimal(0)
    nonstandard = Decimal(0)
    for row in rows:
        if str(row.get('product', '')).lower() not in ('actions', 'actions runners'):
            continue
        if not str(row.get('date', '')).startswith(now.strftime('%Y-%m')):
            raise BillingUnavailable('billing_wrong_period')
        gross, net = number(row.get('grossAmount')), number(row.get('netAmount'))
        billed += net
        if str(row.get('unitType', '')).lower() not in ('minute', 'minutes'):
            continue
        sku = str(row.get('sku', '')).lower().replace(' ', '_').replace('-', '_')
        if sku not in STANDARD_SKUS:
            raise BillingUnavailable('billing_compute_sku_not_verified')
        repository = row.get('repositoryName')
        if not isinstance(repository, str) or not repository:
            raise BillingUnavailable('billing_repository_evidence_missing')
        if '/' not in repository:
            repository = OWNER + '/' + repository
        if repository.split('/')[0].lower() != OWNER.lower():
            raise BillingUnavailable('billing_unexpected_repository_owner')
        if repository not in private:
            metadata = repository_api(repository, '')
            if not isinstance(metadata.get('private'), bool):
                raise BillingUnavailable('billing_repository_visibility_unknown')
            private[repository] = metadata['private']
        if private[repository]:
            compute += gross
    allowance = LINUX_RATE * PLAN_MINUTES[plan]
    remaining = max(Decimal(0), allowance - compute)
    return {'status': 'verified', 'source': 'GitHub billing usage API', 'checkedAt': now.isoformat(),
            'month': now.strftime('%Y-%m'), 'plan': plan, 'includedMinutes': PLAN_MINUTES[plan],
            'includedComputeUSD': float(allowance), 'eligibleComputeUSD': float(compute),
            'remainingComputeUSD': float(remaining), 'billedActionsUSD': float(billed),
            'nonstandardComputeUSD': float(nonstandard),
            'usedLinuxEquivalentMinutes': float(compute / LINUX_RATE),
            'remainingLinuxEquivalentMinutes': float(remaining / LINUX_RATE),
            'linuxMinuteRateUSD': float(LINUX_RATE),
            'providerMayLag': True}
