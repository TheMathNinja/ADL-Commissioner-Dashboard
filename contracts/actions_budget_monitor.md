# Budget telemetry

The existing public failure reporter reviews billing daily; unsuccessful billing
reads retry after 30 minutes. No separate scheduled job or private runner is added.
`ACTIONS_BILLING_TOKEN` requires only the account Plan read permission. It is
passed only to the reporting step, never to tests or Guardian dispatch.

Billing API usage, account plan, and repository visibility establish the baseline.
Standard private compute draws from the included pool; public compute and storage
must not be subtracted from that pool. Net Actions charges are recorded separately.
The Linux-equivalent unit converts standard compute dollars at the published
standard Linux rate. API reporting may lag. Unknown plans, repositories, malformed
responses, and access failures are not interpreted as zero usage.

Current-software samples use Git tree metadata, not private source downloads.
Each allocated job is rounded before averaging. Skips, cancelled runs, old software,
and Guardian cache-only probes are excluded. At most 100 recent runs per workflow
and 12 eligible candidates are inspected; the latest five matching observations
form each mean. Missing samples retain explicit planning allowances, not a claim
of fully verified forecast coverage. Extra requests, retries, cold tests and
upgrades can exceed the reserves; these are forecasts, not spending controls.

All financial values and observation details are stored in private Guardian
`data/actions_budget.json`. Public output contains status only. A failed read
retains its last verified record as historical evidence, never as a current
balance. Six hours of unsuccessful billing reads generate one central incident
notice; verified access clears the episode. Budget-pace mail retains the existing
one-notice-per-month delivery key to avoid resending historical warnings.

No budget operation changes Guardian cadence, write permissions, backup dispatch,
missed-check deadlines, safety-net email settings, or spending limits. Required
local publication audits are never replaced by runtime-sample caches.
