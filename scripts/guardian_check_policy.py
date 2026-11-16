"""Shared Guardian cadence: dispatch timing and missed-check deadlines."""
from datetime import datetime, timedelta, timezone

INTERVAL_MINUTES = 15
INTERVAL = timedelta(minutes=INTERVAL_MINUTES)
LOOKAHEAD = timedelta(minutes=90)
GRACE = timedelta(minutes=10)
CUTOVER = datetime(2026, 11, 16, 18, tzinfo=timezone.utc)


def monitor_slot(start, end, activated=None, grace=False):
    """Latest required slot, with no extra slot at kickoff itself."""
    first = max(start, activated) if activated is not None else start
    effective = min(end, start + LOOKAHEAD - timedelta(microseconds=1))
    elapsed = effective - first - (GRACE if grace else timedelta())
    if elapsed < timedelta():
        return None
    return first + INTERVAL * (elapsed // INTERVAL)


def monitor_missing(checks, start, end, activated):
    recent = [value for value in checks if start <= value <= end]
    # Changing cadence cannot retroactively clear a genuinely missed old window.
    if start + LOOKAHEAD < CUTOVER:
        first = max(start, activated)
        return end >= first + GRACE and end - max(recent, default=first) >= GRACE
    required = monitor_slot(start, end, activated, grace=True)
    return required is not None and not any(value >= required for value in recent)
