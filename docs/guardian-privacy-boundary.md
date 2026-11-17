# Guardian execution boundary

`GUARDIAN_BASIC_OWNER=public-basic-v1` selects the projection-free checker.
It is independent code in `scripts/guardian_basic.py`, not a checkout or copy of
the private Guardian engine. Its MFL feed allowlist excludes projected scores.
It never receives the CHI service credential, ranks replacements, submits
lineups, acquires players, or uploads roster/model artifacts. Detailed receipts
and warning text are persisted only in the existing private health repository.

The public worker performs generic position/group/count validation and checks
unlocked starters for public MFL unavailable/bye/roster statuses. Its morning
receipt means those reads and validations completed, not that a private optimum
was calculated or a lineup was automatically submitted. The private engine and
its projection-based decisions remain private and explicitly invoked.

Both free scheduling clocks use the same durable lease and successful-check
ledger. The separate coverage assessment still checks the 75/45/15-minute
deadlines even when the worker never starts. A dispatch, incomplete feed read,
or failed private-state write is never a successful-check receipt. Roster
warnings are successful checks and use the central durable email-delivery
owner. Native safety-net notification settings are unchanged.

Owner manual CHI sync requests may bypass the discretionary budget hold, but
page-open polling and scheduled private syncs may not. Claimed requests are
never blindly redispatched. Private Actions usage remains demand-dependent.
The public checker does not make private forecast/model refreshes free.

Rollout order: pass the full four-repository local gate and private Site gate;
publish inactive code; seed and validate the private basic-check ledger;
activate the public owner; verify public execution and independent coverage;
then retire private automatic workers with the same owner flag. Never change
repository visibility or mute safety nets as part of this handoff.
