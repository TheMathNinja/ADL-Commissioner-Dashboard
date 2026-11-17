"""Shared Guardian cadence: dispatch timing and missed-check deadlines."""
from datetime import datetime, timedelta, timezone

CHECK_OFFSETS_MINUTES = (75, 45, 15)
INTERVAL_MINUTES = 30
INTERVAL = timedelta(minutes=INTERVAL_MINUTES)
LOOKAHEAD = timedelta(minutes=90)
GRACE = timedelta(minutes=10)
CUTOVER = datetime(2026, 11, 16, 18, tzinfo=timezone.utc)
THREE_CHECK_CUTOVER = datetime(2026, 11, 17, 6, tzinfo=timezone.utc)


def first_monitor_slot(start, activated=None):
    first = start + (timedelta(minutes=15) if start + LOOKAHEAD >= THREE_CHECK_CUTOVER else timedelta())
    return max(first, activated) if activated else first


def monitor_slot(start, end, activated=None, grace=False):
    """Latest required slot, with no extra slot at kickoff itself."""
    kickoff = start + LOOKAHEAD
    if kickoff >= THREE_CHECK_CUTOVER:
        if activated is not None and activated >= kickoff:
            return None
        slots = [max(kickoff - timedelta(minutes=offset), activated) if activated else
                 kickoff - timedelta(minutes=offset) for offset in CHECK_OFFSETS_MINUTES]
        effective = min(end, kickoff - timedelta(microseconds=1)) - (GRACE if grace else timedelta())
        return max((slot for slot in slots if slot <= effective), default=None)
    first = max(start, activated) if activated is not None else start
    effective = min(end, start + LOOKAHEAD - timedelta(microseconds=1))
    elapsed = effective - first - (GRACE if grace else timedelta())
    if elapsed < timedelta():
        return None
    legacy_interval = timedelta(minutes=15)
    return first + legacy_interval * (elapsed // legacy_interval)


def monitor_missing(checks, start, end, activated):
    recent = [value for value in checks if start <= value <= end]
    # Changing cadence cannot retroactively clear a genuinely missed old window.
    if start + LOOKAHEAD < CUTOVER:
        first = max(start, activated)
        return end >= first + GRACE and end - max(recent, default=first) >= GRACE
    required = monitor_slot(start, end, activated, grace=True)
    return required is not None and not any(value >= required for value in recent)
