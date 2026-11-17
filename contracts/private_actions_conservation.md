# Private Actions Conservation

`PRIVATE_DISCRETIONARY_ACTIONS=paused` in the private Guardian repository prevents
allocation of private sync, optional forecast polling/rebuild, model preflight,
and cloud diagnostic jobs. Mirror the variable in Commissioner so its forecast
reflects the same hold. Missing configuration retains normal operation; an
unreadable policy cannot authorize a discretionary dispatch.

The public reporter, independent health clock, required Guardian workers,
backup dispatch and missed-check assessments are never gated by this setting.
New weekly forecast requests with an explicit completed week remain available
because Guardian acquisition readiness depends on them. Deferred owner sync
requests stay queued; they are not acknowledged as completed. Already claimed
workers remain monitored, and a never-started forecast verifier still reaches
its real deadline and the existing durable incident reporter.

This is a temporary demand hold, not a paid-spending authorization or a hard
provider billing cap. Verify the provider's zero-spend budget separately. Resume
only after a fresh billing read, current remaining-cycle projection and approval
of the resulting pace. A billing reset alone does not silently re-enable work.

All production changes still require the complete local four-repository gate.
A deferred cloud diagnostic does not create a passing audit receipt. Identical
running or successful pinned cloud audits can be reused for at most 24 hours;
failed, changed, stale and future-dated runs cannot be reused as passes.

Current billing, projected demand and balances are retained only in private
records. If required work and incident reserves exceed the remaining balance,
do not claim a demonstrated fit, suppress protection or authorize paid overage.

`GUARDIAN_RUNNER=ubuntu-slim` is a separate opt-in after a successful private
read-only compatibility probe. It changes compute class, not check cadence or
test requirements. The budget reserves two rounded slim minutes per required
job, and raises that estimate when measured jobs exceed it. Mirror the runner
selection in Commissioner for accounting. Clearing the variable restores the
standard runner without changing required checks or the discretionary hold.

The standard two-core ARM runner (`ubuntu-24.04-arm`) is another opt-in, only
after a private compatibility probe and startup-latency check. Its documented
price is five-sixths of the standard x64 price per rounded minute. A failed real
check is eligible for the existing independent dispatch on standard x64; this
does not change native write permissions or serialize writes differently.

During the hold, both public clocks coalesce off-hours input-change and degraded
feed wakeups into the daily safety assessment. They continue observing feeds and
cached schedules for free. Kickoff windows, first-game safety, morning checks,
and pending private acquisition work are evaluated before this coalescing rule.
Missed-check assessment remains independent and never treats a deferred wakeup
as a verified check.
