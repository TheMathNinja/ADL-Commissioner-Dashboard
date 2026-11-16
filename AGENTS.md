# Automation audit requirements

## Coordinated behavior changes

For shared display labels or thresholds, edit the reviewed, versioned
`contracts/live_display.json` specification first. Follow `contracts/README.md`
and run `scripts/sync_live_display_contract.py` against BOTH GM checkouts with
`--write`. Do not independently hard-code new labels into downstream tests or
change Guardian business rules for a presentation-only request. Run the complete
four-repository candidate audit before pushing. Deploy compatible consumer files
before a checker which requires them. Add explicit shared contracts for new
cross-repository behaviors instead of making tests accept current output.

A request for a "full audit" includes Chicago-Bears-Lineup-Guardian, even though
it is a personal tool in a separate repository. Never limit the scope to the GM
and Commissioner dashboards or treat a cross-repository contract check as a
complete operational audit.

Required Guardian coverage:
- Both ADL and FAFL: credentials, franchise ownership, fresh roster/status/bye/
  projection inputs, current lineup week, and explicit weekly kickoff schedule.
- Both initial-lineup safety net and game-day substitutions; first-game-day
  6 a.m. Eastern gate, every kickoff group, international/unusual game days, DST,
  late statuses, week rollover, retries, and missing or stale data.
- Legal cross-position optimization, unavailable-player exclusion, preservation
  of locked starters, verified Taxi-to-Active promotion before lineup submission,
  promotion failure fallback, concurrent/manual changes, and exact read-back.
- Deployed Apps Script code and triggers, GitHub fallback, shared write queue,
  live-write setting, recent automatic executions, and notifications.
- Run the Guardian test suite and live read-only preflight. Do not make roster or
  lineup changes solely to audit unless separately authorized.

Report pass/fail/not-verified separately for code tests, live reads, scheduler
deployment/executions, write-path evidence, and notification delivery. Include
verification run links. A green dry run is not proof of future trigger execution,
actual Taxi promotion, or email delivery. State any unverified coverage instead
of claiming a full audit completed. Never promise immunity to third-party outages.

The automation-preflight workflow includes an independent guardian-audit job on
push, scheduled, and manual runs. Keep it read-only and do not make it dependent
on another component's success. This is a baseline, not a substitute for the
deployment, trigger, write-path, and notification checks above.
