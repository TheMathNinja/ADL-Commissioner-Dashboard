# Zero-spend incident recovery

The existing **Email league workflow failures** job owns detection, verified
recovery, incident deduplication and email. It does not dispatch a second
repair workflow, invoke a model, add a runner, or send separate fixer mail.

The reporter can recover safe, known cases using deterministic routines. In
particular, it reads oversized state by its immutable Git blob and compacts
routine success acknowledgements when the serialized state reaches 950 KB.
It keeps failure evidence, exact recovery and association records, and every
SMTP reservation and receipt. It rereads and merges on write conflicts. The
size threshold is a guard, not a guarantee: if the retained evidence itself
outgrows the inline API, the independent reader still needs the blob fallback.

The normal owner email can identify a prior incident with the same failed
step and known error fingerprint. That context neither suppresses the current
incident nor asserts recovery. Unrecognized failures follow the existing
reporting rules. Only explicitly implemented and tested repairs run on their
own. New fixes and anything that could change functionality, run with elevated
permissions, or replay business writes require review. No model or bot has
been granted production write access as a result of this integration.

Guardian's safety phase runs independently of the ordinary email tests, using
the same serialized workflow and delivery ledger. Only the ordinary phase
can record a successful reporter heartbeat, and only after the delivery tests
pass. A Guardian safety phase failure also makes the whole scan unhealthy.

The independent timer uses completion receipts, not dispatch acceptance. It
coalesces recent or queued ordinary work outside protected kickoff windows,
and preserves attempts when kickoff evidence is missing. A prolonged outage
claims one notification. A fresh read does not rearm it: both receipts must
advance during at least ten minutes of recovery without another stale read.
Ordinary incidents wait up to thirty minutes for a matching in-flight retry.
The escalation states whether the retry did not verify recovery or no safe
automatic replay was available.

The reporter uses the repository workflow credential for the high-volume
public league reads. Guardian and the wider owner inventory retain their
existing credential and coverage. A quota response pauses that route until its reset; an ordinary 403
is actionable and isn't retried blindly. The weekly scheduler reads only
allowlisted public receipt files without a token, shares one run-history
fetch for its two queue checks, and leaves rate-limited dispatches pending.

Both weekly jobs install the same pinned Playwright release before any live
writes. The cache is an optimization, never proof of readiness: headless
Chromium must run JavaScript on a warm or cold start. Host packages are only
installed after a missing-library launch error. A transient cold download
gets one bounded repeat; the generated and live page checks still gate
successful publication.

Before retiring the desktop schedule, verify the normal reporter on the exact
release, all four repository reads, exact Guardian completion and missed-check
handling, scrape freshness, and the separately scheduled Apps Script health
reader. A GitHub run or successful dispatch does not prove Apps Script read the
receipts. Keep native safety-net email settings unchanged.
