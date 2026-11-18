# ADL bylaw checker coverage audit

Reviewed November 17, 2026 against the [current published bylaws](https://docs.google.com/document/d/12l8eriNPrC1aY9LRgPlXQHJtNxSfOzmnfv0zJBUY1jU/edit).
This is a source-code coverage inventory, not a claim that all league rules,
historical violations, live triggers or actual email delivery have been verified.

## Advance roster readiness: implemented

The daily Commissioner run now checks every ADL franchise's QB, PK and PN slots
against public ESPN depth charts, current MFL status/ownership, NFL kickoffs and
byes. MFL ESPN IDs plus the existing nflreadr stable-ID crosswalk establish
identity; no fuzzy name matching, projected points or CHI formulas are used.
Known unavailable primary players do not disqualify healthy depth replacements.

A GM with no expected available starter on the Active roster receives an
acquisition/activation warning. If an expected starter is already rostered,
the warning names the player to start. An announced replacement can supersede
a published depth listing; the email explicitly asks the GM to confirm that.
No zero-score inference, inactivity penalty or roster write follows from this
warning. Missing/stale/ambiguous role evidence is unknown, not proof of guilt.
Per-team source health is saved with the existing commissioner reports. A
depth source outage does not turn an otherwise successful roster check red;
unknown roles remain a documented coverage limitation and retry next daily run.

These warnings run Tuesday/Wednesday too, so an auction can be pursued before
Thursday. They are GM-only, never commissioner CC/digest. They use the existing
durable GitHub delivery receipt bridge, with a stable season/week/franchise/
position/recipient key: one readiness message per weekly positional issue,
not another message each day or retry. A new week or different positional need
is a separate action. The individual Submit New Lineup link is included.
No new workflow, timer, private job or paid service was added. Existing public
standard-runner daily processing does the work. Manual CHI refresh, Guardian
checks, missed-check alerts and safety-net settings are unchanged.

Pending acquisition protection: an open nomination, bid or named losing proxy
bid by the GM suppresses that position's acquisition warning if the candidate
is expected to play, is not out/on bye, and the auction's 24-hour high-bidder
clock expires before kickoff. Another franchise's nomination alone does not
count. Closed, cancelled, expired and wrong-conference auctions do not count;
same-leader proxy raises do not reset the clock. Unverified auction/status
evidence defers acquisition warnings, with source health recorded. This does
not suppress a later lineup-submission warning after a player is acquired,
nor does it turn a losing auction into an inactivity violation.

## In-season Coverage

| Bylaw | Current coverage | Remaining gap / ownership |
| --- | --- | --- |
| III-B, III-F roster minimum/maximum and contract years | `evaluate_roster_cap_alerts`, `evaluate_contract_years_alerts` | Snapshot/final-deadline evidence is still required for sanctions. |
| III-C position eligibility | MFL season-specific positions used | Consensus-source position requests and appeals remain commissioner decisions. |
| III-D Taxi/Temporary Eligibility | Roster-cap/exemption accounting and emergency-add checks | No complete TE-versus-active-bids 24-hour warning/rectification evaluator; repeated intentional abuse requires unanimous commissioners. |
| III-E IR eligibility/reactivation | Status evidence and MFL submission restrictions | No dedicated league-wide report enforcing every activated player's IR removal. |
| III-F salary spending / rollover | Cap accounting, snapshot reconciliation and projected-average warnings | Not equivalent to the season-end XV-B sanctions below. |
| V-A total/offense/defense/position counts | Current warnings and final structural confirmation | Final confirmation currently depends on a prior candidate report; a never-observed illegal lineup can escape this evaluator. |
| V-A expected QB/PK/PN | New advance readiness warning | Public charts can lag coach announcements; unknown roles are not adjudicated. Other rotational positions must not be judged solely by depth rank. |
| V-A backup acquisition effort | Reviewed opportunities + final MFL lineup and auction evidence | Future opportunities still need verified role/availability review; unsuccessful bids are conservatively exempt. No automatic discovery of every historical missed auction. |
| V-A injury / bye starters | Live designations, 72-hour snapshots and warnings | Final inactivity conversion covers structural issues, not all injury/bye violations. Healthy-alternative condition, late-submission-after-inactives rule, and unexpected-scratch exception require fuller historical evidence. |
| V-A Weeks 13/14 byes | General bye warnings | Playoff doubleheader versus Consolation Ladder exception is not represented by the blanket bye warning rule. |
| V-A executive corrections / Damar Hamlin rule | No automatic league-wide rewrite | Commissioner authorization, emergency-add pricing/caps and verified replacement evidence required. Never use hindsight scores. |
| V-C illegal-acquisition starters | Transaction/emergency-add review is partial | No general final-lineup-to-all-illegal-acquisitions adjudicator. |
| XV-B.1 final cutdown | Reviewed confirmed evidence | Manual evidence must exist; do not infer historical rosters from today's roster. |
| XV-B.2 illegal waivers | `evaluate_illegal_waiver_claims` | Transaction feed failures/ambiguous acquisitions cannot prove a violation. |
| XV-B.3 TE abuse | Partial (above) | Commissioner judgment, not simply an automatic cap/count condition. |
| XV-B.4 full active weekly lineup | Structural confirmation + reviewed backup opportunities | Injury/bye conversion and never-observed cases above remain gaps. |
| XV-B.5 seven-day login inactivity | Not implemented in in-season builder | Requires reliable authenticated last-login evidence, timezone handling, and durable single-incident delivery. |
| XV-B.6 two consecutive snapshot violations | `evaluate_repeated_roster_violations` | Actual consecutive snapshot evidence required; no inference across missing snapshots. |
| XV-B.7 Drop/Nomination Deadline | No dedicated in-season deadline evaluator | Must use the exact historical deadline roster, not present-day compliance. |
| XV-B.8 >=20% season-end cap space | Not implemented as inactivity sanction | Need verified final season ledger and franchise cap basis. |
| XV-B.9 negative cap rollover (double violation) | Accounting exists; sanction conversion missing | Preserve two-strike weight without two duplicate emails. |
| XV-B cumulative removal / XV-C probation | Counts/display exist; no automatic removal or probation adjudication | Commissioner review and appeals; do not remove ownership automatically. |

## Offseason And Other Sections

`R/offseason_inactivity_monitor.R` contains evaluators for first-round bylaw
voting, rookie draft timeouts, pre-UFA participation, initial UFA bid gaps,
illegal waiver/late-NG bids, repeated roster snapshots and signing/cutdown
deadline reviews. This does not establish complete XV-A coverage: ROD timeouts
and required RFA/ERFA tag use/forfeiture are not present in its candidate builder;
deadline-review outcomes still need evidence and operating-calendar validation.

Sections I-II (philosophy/governance), III-H (expansion), IV (season format),
VI/X/XII (contracts/tools/cap penalties), VII-IX (auctions/free agency/drafts),
XI (trades), XIII (calendar), XIV (funds/payouts) and XV-D:G (ownership/conduct)
are not wholly enforced by the roster checker. MFL constraints, separate
accounting/model modules and commissioners own portions of these. A green
roster run is not validation of every signing, trade, tender, fee, payout,
future deposit, appeal, team-identity change or conduct decision.

## Recommended Follow-Up Order

1. Close final-lineup injury/bye and missing-candidate evidence gaps, preserving
   the 72-hour, healthy-alternative and late-inactives exceptions.
2. Add authenticated seven-day login evidence and exact deadline snapshots.
3. Add season-end cap sanctions with one notification and explicit strike weight.
4. Complete TE/IR and offseason ROD/tender review evidence.

Each change needs focused fixtures, existing durable notification ownership,
read-only live verification and the full four-repository publication gate.
No new automatic sanctions for these remaining gaps were enabled in this release.
