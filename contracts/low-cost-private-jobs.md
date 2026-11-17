# Low-Cost Private Forecast And Audit Jobs

## Forecast Requests

The private forecast workflow queues work, records a durable private request and
exits. It no longer occupies an Actions runner for a 105-minute wait. Its successful
workflow conclusion means the request/status inspection completed, not that a
forecast was published. Forecast completion requires the same private checks as
before: matching upstream signature, completed league week, generation time,
prepared-value manifest, projection report hash and finite acquisition values.

The existing public reporter reads private request metadata only. It never reads
CHI source, projection snapshots, player values or formulas. It claims a poll
before dispatching a short private status job, normally at twenty-minute intervals.
A claimed verifier that never starts is actionable after ten minutes. Forecast
or value deadlines remain 105/45 minutes. The last private inspection must observe
the deadline; queue acceptance cannot create a false completion or recovery.

One episode survives coalesced request upgrades without resetting its original
deadline. Notifications use the reporter's existing durable single-delivery claim.
Unresolved requests back off from hourly to six-hourly checks for verified recovery. All acquisition
eligibility and current-value gates remain in the private Guardian worker.

## Audit Receipts

The launcher compares hashes and paths from all four repositories, not private file
contents. Reuse requires identical input content, a successful recorded run whose
success is checked again in GitHub, and age below 24 hours. Source, configuration,
workflow, fixture, model or published league-input changes invalidate the receipt.
Only the enumerated operational mail/check/budget state and generated private audit
history are excluded. Truncated metadata or unavailable evidence cannot authorize
reuse. Manual preflights force a fresh audit.

New audits pin the four source checkouts to the exact collected revisions. A cache
write conflict cannot turn a failed audit into a pass. This cache applies only to
automatic cloud diagnostics. It never replaces the full local pre-publication gate.

## Budget Limits

The public automation preflight runs weekly on Wednesday at 08:30 UTC and after
relevant software/configuration changes. Its independent Guardian audit still
runs even if the contracts audit fails. The private read-only preflight remains
callable/manual, but its duplicate Wednesday timer is removed. Exact-input audit
reuse is still limited to 24 hours and verified successful runs. Required local
four-repository publication gates are unchanged and never skipped or cached.

Guardian monitor and initial jobs reuse private passing npm test evidence only
for identical software, configuration, workflows, tests, the declared historical
regression fixture, Node runtime, OS and behavioral flags. Live MFL reads, lineup
checks, write verification and notification delivery are never cached. Missing,
invalid or changed evidence reruns the full suite before the live worker. Cache
service failures fall back to full tests; save failures do not block protection.
New regression fixtures belong under test/ so their contents enter the key.

The budget monitor now stores the configured future checkpoint schedule and
explicit workload allowances separately from historical averages. It assumes a
conservative Eastern midnight month reset, includes per-job rounding, and does
not treat the last sampled historical estimate as an authoritative billing total.
Forecast/model changes, extra owner refreshes, outages and releases remain variable
costs, not promises that the planning allowance is a hard spending cap.

Forecast waiting should fall from up to 105 private runner minutes to several short
checks. Repeated audits of unchanged inputs avoid allocating another private job.
Actual usage still depends on requests, failures and runner rounding. Neither
change reduces Guardian check frequency, changes native safety-net email settings,
publishes personal tools, buys minutes or guarantees the remaining monthly budget.
