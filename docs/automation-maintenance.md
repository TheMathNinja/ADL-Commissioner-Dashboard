# ADL Automation Maintenance

This repo has three repeat blockers that can slow down routine commissioner automation work:

- Local commits from Codex can fail when Windows denies writes inside `.git`.
- Local R runs can fail when the repo-local `_lib` package cache is missing or stale.
- GitHub scheduled jobs can fail late if workflow edits are not tested through the same no-email paths first.

Use this rhythm for future automation changes:

1. Run `Rscript scripts/local_preflight.R` locally after code edits.
2. If packages are missing, run `Rscript scripts/setup_local_r_lib.R`, then repeat local preflight.
3. Push only the intended files. If local `.git` is blocked, use the GitHub API path rather than broad local commits.
4. Run the `ADL Automation Preflight` GitHub Action. Use the individual live-check toggles to test the path being changed.
5. Only after that succeeds, run or wait for the real daily commissioner alert / salary cap workflow.

The preflight workflow is intentionally no-email. It parses all R scripts, installs the same declared R dependencies from `DESCRIPTION`, can run commissioner alerts without sending emails, can run salary cap accounting, can reconcile MFL salary adjustments against the latest SalAdj Curator ledger, and builds the dashboard. It is meant to fail during testing instead of during an actual league data run.

MFL can rate-limit repeated live scrapes. For routine edits, run the specific live check that matches the changed area. Reserve the full live preflight for larger cross-cutting changes or times when no other MFL-heavy workflow just ran.

The SalAdj reconciliation writes `data/saladj_reconciliation.csv` for franchise totals and `data/commissioner_error_checker.csv` for entry-level errors. The entry checker compares each active curator charge with MFL by player/description, amount, and ADL franchise; it identifies missing entries, wrong amounts, and charges assigned to the wrong ADL franchise. It is read-only and never edits MFL. The daily 5:17 a.m. maintenance run emails commissioners only for newly detected item-level errors and records reported issue keys in `data/commissioner_error_checker_issued.csv` to prevent repeat mail. A total mismatch means the salary-adjustment totals visible on MFL's full-league salary adjustments page do not equal the totals implied by `data/SalAdjCurator_latest.csv`. By default mismatches are reported without failing the preflight; use the `fail_on_saladj_mismatch` toggle when you want total mismatches to block the run.

If `.git` remains blocked, the durable fix is to repair the Windows ACL on this checkout or create a fresh clone in a Codex-owned workspace. Until then, API-based commits are safer than fighting the local index lock.

## Model Update Safety

Model identity is not a wire-format version. New names and blend weights use the
existing `adl-eb-counterfactual/1` contract when their fields and calculation
semantics are unchanged. A different counterfactual method or binary layout needs
an explicit schema migration: deploy a consumer supporting both old and new
schemas first, then the producer. Do not add each new model name to a whitelist.

The ADL `Model compatibility preflight` checks the deployed consumer and builds
the actual current model with `--dry-run`, using `requirements-weekly.txt`, before
any upload. Run it for model/method/dependency changes and require a successful
result before treating the update as production-ready. Unknown schemas, invalid
weights, missing runtime dependencies and nonfinite outputs must fail in this
preflight, not be silently accepted. Frozen private player fits and parity checks
remain intentional safety requirements, not restrictions to remove.

Private engine revisions are captured when work is queued and carried through
the final receipt. Both bundles are staged completely, then swapped into place;
failed downloads retain the prior bundle and removed modules cannot linger.
All imported local Python dependencies, model data, schedules and declared
requirements participate in the public model fingerprint. A cached local marker
cannot override the live consumer's missing/different upload pointer.

Cloud scheduler date conversions are shared across fixed-time recovery scans.
Only lease acquisition holds the common Apps Script lock; long network work
does not hold the lock needed by Guardian. Thursday polling compares current
player scores with the processed digest throughout its window, even after a
successful correction receipt. A direct Google-to-MFL probe failure falls back
to the independent GitHub checker. `auditCloudSchedulerReadOnly` verifies live
score freshness and scans without dispatching jobs or writing league data.

Full audits include Guardian, cloud trigger executions, shared-lock behavior,
notification ownership and immutable official-snapshot protection. Report code
tests, live reads, deployed triggers, real write evidence and email delivery
separately. A read-only Guardian pass does not prove a live Taxi promotion or
SMTP delivery. Do not create real roster/lineup changes merely to test an audit.

## Thursday Correction Readiness

Thursday correction polling starts at 04:15 Eastern, not 03:45. This is an
eligibility boundary after the normal approximately-04:00 MFL processing window,
not proof that MFL has finished. Require reconciled standings/results/player
feeds and the same player-score revision observed at least five minutes apart.
Cache the observation between polling jobs; a changed revision resets the wait.
The half-hour-spaced GitHub backup slots must also be able to establish stability.
Waiting is successful polling, not an error or a late-correction warning.

Preserve each run's timestamped player-score input as a 90-day artifact and put
its capture time, post-build verification time and digest in the completion
receipt. Confirmation emails show the capture and verification times when
available. A difference from an earlier snapshot only proves that the two
observations differ; it does not establish when MFL applied a correction.
Do not describe ordinary Thursday reconciliation as a post-correction anomaly.

The October 29 investigation compared commits 978e60c7 (ADL) and 15a52233 (FAFL)
with the later verified publications. Their pre-04:00 player feeds contained
1,053 entries versus 1,058 later, with 12 changed existing scores. All 32 team
scores in each later publication matched MFL's own 04:15 ADL / 04:05 FAFL result
emails, while eight ADL and six FAFL early team totals differed. Those team
corrections were already present in the MFL emails; no later-change claim is
justified by this comparison. The emails do not establish every individual
bench player's correction time.

## FAFL Inactivity Watch

`fafl-inactivity-watch.yml` is an independent, standard-library Python job. It
does not install R or run any scoring/model publication. CloudPolling dispatches
it hourly at minute 7; GitHub supplies two independent backup checks daily.
The backup skips a fresh successful cloud check. Failure notifications remain
enabled. Full integration preflight includes the FAFL policy/parser tests.

Authenticated league exports supply exact last-access timestamps and current
contact details. Owner warnings go only to the affected owner. The digest goes
only to the uniquely matched Mike Filicicchia, Russ and Tim contacts in FAFL's
authenticated owner records; missing or ambiguous contacts fail closed. No
contact addresses or authentication data are written to the public ledger.

Seven elapsed days without a league visit creates one login incident. Missing
weekly lineup submission is evaluated only after the completed week's Monday
23:00 Eastern boundary (never before its last scheduled NFL kickoff). Inherited
lineups do not count as submissions, even if MFL displays a copied timestamp.
Current/upcoming incomplete lineups are not penalized. Monitoring starts with
Week 8 in 2026; the system does not invent prior-season or earlier-week strikes.

Auction monitoring uses all `AUCTION_INIT`/`AUCTION_BID` transactions, including
losing bids, not just auction winners. It activates only during the explicit
initial-auction start/end window in `data/fafl_inactivity/config_2026.json`.
Those boundaries are currently unset because the 2026 initial auction is over;
commissioners must configure the next initial auction rather than infer its
end from missing bids. Missing bid history is unknown, never proof of inactivity.

The state ledger tracks incidents and counts per franchise/owner/rule. Auction
and lineup repeat counts are separate. Rechecking one unresolved issue does not
create another strike. Owner replacements do not inherit the former owner's
counts. A grace deadline is recorded only after SMTP accepts the warning:
24 elapsed hours for bids, 120 elapsed hours for lineup/login. A second auction
or lineup infraction receives no new grace period and is sent for commissioner
review. Repeated login incidents still receive the normal warning period.

Owner delivery intent is checkpointed before sending; uncertain acknowledgements
are sent for delivery review instead of automatically duplicating the email or
starting an unverified deadline. New findings, rectifications, deadline expiry,
repeat infractions and source-coverage problems produce a deduplicated digest.
Unknown data cannot clear a watch or establish an overdue violation. No script
removes an owner, modifies a lineup/roster, or changes winnings.
