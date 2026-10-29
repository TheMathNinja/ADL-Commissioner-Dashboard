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
