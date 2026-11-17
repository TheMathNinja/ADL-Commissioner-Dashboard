# Guardian Scheduling Handoff

Private Guardian remains the sole lineup/IR/acquisition worker. Its numerical
logic, source, projections and authorization policy stay private. No pre-kickoff
frequency reduction is included in this change.

## Public Scheduling Only

The existing reporter timer and an independent tiny public native-cron workflow
use the same scheduling gate. The separate public clock remains usable when the
email reporter itself fails. Both read only public MFL inputs and private opaque
health metadata, never private source, projections or roster-audit payloads.

- Inside any league's real 90-minute kickoff window, request a backup when its
  last verified monitor read is at least five minutes old or absent. Respect fresh
  known-live in-flight checks and a durable five-minute dispatch lease.
- Outside games, unchanged public roster/injury/starter fields request no private
  job. A score update, player name or projection change cannot change this hash.
- Keep one morning health read, after 6 a.m. Eastern, for early roster warnings and
  ordinary maintenance. Actual public roster or injury changes can request work
  between morning reads, preserving FAFL IR handling and early warning behavior.
- On the first game day, route the 6 a.m. safety check to the initial-lineup
  worker and require its own verified receipt. Off-day native initial-lineup jobs
  allocate no private runner after the same ownership handoff.
- A failed background read of the same changed inputs is retried no more than
  hourly. Missing public feeds use cached future kickoff windows and a bounded
  hourly private safety check, rather than silently declaring there is no work.
- Direct Apps Script, manual and delayed-pickup dispatches remain enabled, sharing
  the existing private worker's write concurrency and all acquisition safeguards.
- Pending private work exports only a next-check timestamp. Due pickups and
  one-hour IR retry deadlines are checked even without a public-input change;
  an unverified acquisition attempt never schedules a blind add retry.
- Scheduling claims never become successful health receipts. The separate
  ten-minute required-check assessment and its single-delivery owner are unchanged.

The public-input fingerprint helper is identical in both repositories, checked by
the full release gate. Private export uses the latest verified snapshot's public
fields and exports only a hash, week and timestamp. No player data or formula is
placed in the private health metadata consumed by the public scheduling job.

## Activation And Rollback

First deploy the backwards-compatible public ledger reader. Run the full local
four-repository gate, then publish the exporter and scheduling gate with dispatch
disabled by default. Verify live input hash agreement, off-hours no-op behavior,
missing-primary dispatch decisions and unchanged missed-check detection in memory.

The dispatch selects `use_native_policy`; the private workflow reads its own live
write policy, so no public copy of this permission can drift. Arm public
`GUARDIAN_NATIVE_FALLBACK=public-scheduler-v1`. Observe successful public
timer execution before setting the same ownership variable on Guardian. That
private variable skips native scheduled runner allocation, not direct dispatches.

Rollback clears the private variable first, restoring the original native backup,
then clears public ownership. Native Google/GitHub safety-net email settings remain
enabled. GitHub cron is still best-effort, not a guaranteed independent clock SLA.

## Three-Checkpoint Precision Ownership

The shared guardian_check_policy.py is identical in public and private checkouts.
Each kickoff group requires checks at 75, 45 and 15 minutes before
kickoff. Both leagues share one private worker. The public clocks still wake at
their existing cadence; a current receipt suppresses duplicate paid workers.
A required slot without a verified receipt is reportable ten minutes after it
was due. The initial 6 a.m. safety check retains its own ten-minute deadline.
Kickoff groups from November 17, 06:00 UTC use this cadence. Earlier windows
retain their historical fifteen-minute or original coverage standard, so a
cadence change cannot manufacture recovery. A 1 p.m. Eastern kickoff therefore
has target checks at 11:45 a.m., 12:15 p.m. and 12:45 p.m. Scheduler delivery is
best-effort; a dispatch alone never counts as completed protection.

GUARDIAN_PRECISION_OWNER=public-scheduler-v2 can be armed through GitHub after
the full local four-repository gate and live scheduling verification. Set it on
Commissioner and private Guardian. Legacy gas-* monitor requests then allocate
no private runner and use a separate concurrency group, leaving genuine private
write checks serialized. Queued retired requests cannot suppress a public backup.
Manual, public-backup, delayed-pickup and the separate initial-lineup worker are
not disabled. The existing Apps Script reporter timer and native public fallback
remain the scheduling clocks. No Apps Script editor or new account is required.

The old Apps Script precision trigger may keep submitting acknowledged no-runner
wakeups. Its Google source has not thereby been redeployed; scheduler/Code.gs
contains the optional equivalent 75/45/15-minute policy for a later manual update.
Rollback clears precision ownership to restore legacy direct monitor dispatches.
Do not clear it merely to fix an unrelated data issue. Neither GitHub cron nor
Google timers guarantee punctuality; existing reporter-health monitoring stays on.

## Historical Cost Account

The change removes the configured 144/day private native fallback allocations
and two/day native initial-lineup allocations when those checks are not due.
Remaining precision windows imply about 263 jobs through the assumed December 1
UTC reset, about 17.7/day. Add roughly one morning read/day, plus change-driven
checks, outage retries and occasional races. Budget about 20/day for Guardian,
not a guaranteed ceiling.

Public scheduling and required-check assessment add zero private Actions minutes.
Unchanged private CHI synchronization is still scheduled 96 times/day. Including
that configured exposure and other components, the whole system remains roughly
122-124/day, not within the reported 13.3/day remaining-cycle allowance. No spending
increase or paid overage is authorized by this handoff.
