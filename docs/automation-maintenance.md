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

The SalAdj reconciliation writes `data/saladj_reconciliation.csv`. A mismatch means the salary-adjustment totals visible on MFL's full-league salary adjustments page do not equal the totals implied by `data/SalAdjCurator_latest.csv`.

If `.git` remains blocked, the durable fix is to repair the Windows ACL on this checkout or create a fresh clone in a Codex-owned workspace. Until then, API-based commits are safer than fighting the local index lock.
