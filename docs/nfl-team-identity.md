# NFL Team Identity Contract

All internal NFL identity fields and current display abbreviations use the 32
MFL codes in `config/nfl_teams.json`. Verified against MFL's 2026 player export
and ADL franchise export on November 18, 2026. The live ADL league already uses
JAC; old fallback code used JAX. No league rename is needed. Keep accepting JAX
and historical aliases at input, then emit JAC. FA and missing values are not
NFL clubs and must not be padded or invented.

The Commissioner repository owns the reviewed dictionary. Matching copies and
Python helpers live in all four repositories; R helpers are shared by both R
applications. Guardian's JS adapter reads the same dictionary. Provider codes
are converted immediately on ingestion. Only named output adapters may produce
nflverse/ESPN codes for external calls or asset URLs. Historical raw archives
and stable franchise/player IDs remain unchanged.

For an approved dictionary/helper upgrade, run
`scripts/sync_nfl_team_contract.py --repo NAME=PATH` with all four checkouts.
The default is read-only verification. Explicit `--write` synchronizes only the
dictionary and shared Python/R adapters, never application code, models or data.
Then run focused tests and the full release gate on the combined candidate.

## Required Checks

Run `scripts/check_nfl_team_codes.py --repo NAME=PATH` with all four repository
names and current candidate paths. `scripts/check_automation_contracts.py`
already invokes it, without adding a cloud workflow or recurring job. It checks
dictionary/helper drift and production source literals. Exact-line exceptions
in `config/nfl_team_boundaries.json` describe non-team collisions: SF is MFL's
safety statistic, SD is a salary contract class, NO is a boolean, and GB means
Games Behind. Whole-file exceptions are not accepted. Test fixtures may use
provider aliases to verify normalization.

Run Python `tests/test_nfl_team_codes.py`, R `tests/test_nfl_teams.R`, and
Guardian `test/nfl-teams.test.js`. The release/email contract gate includes the
Python regressions; the Commissioner recipient test includes the R replay.
These cover all 32 clubs, every documented alias, all provider round trips,
unknown identities, new-source violations, drift, HOU's Matt Gay mismatch,
actual OUT/bye warnings and missing schedule evidence. Missing schedule evidence
holds a GM warning rather than accusing a team of lacking a starter.

The literal screen is a regression guard, not a proof about arbitrary dynamic
data. New team-bearing sources still require normalization, strict validation
at verified boundaries and behavior tests. Do not approve an exception just to
make a failed check pass. Do not alter projections, salary formulas, email
ownership or Guardian coverage as part of an identity-format migration.
