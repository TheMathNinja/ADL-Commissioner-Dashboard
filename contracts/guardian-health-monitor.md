# Private Health Receipt Handoff

The Guardian repository remains private. Its existing worker publication exports
`data/guardian_health.json` with schema version, generation time, league identifiers,
week, check mode and verified check timestamps only. The private exporter reuses
the worker's snapshot validation: a new timestamp alone is not proof of coverage.
No player, roster, projection, model, formula, strategy or credential is exported.

The existing public failure reporter never checks out Guardian source. Its new
deadline assessor fetches only the health ledger and private coverage state. MFL
supplies current weeks and kickoff times independently of Guardian execution. An
old ledger is not success; missing checks still open incidents after ten minutes.
Historical missed windows survive rollover. Incidents retain their existing keys
and use the existing single email-delivery owner and durable claims.

Assessment results and daily Actions estimates are written only to the private
repository. They must not be printed, uploaded as public artifacts or committed to
the public reporter repository. Budget estimates sample rounded job timings;
GitHub billing remains authoritative. Budget reviews run once daily inside the
existing reporter, use no new private job and notify at most once per month.

## Activation Gate

1. Run the full four-repository local gate, including health exporter allowlist,
   private/public deadline parity, never-started, recovery, rollover and delivery tests.
2. Publish the private exporter and baseline ledger, then the public consumer.
3. Read-only compare against current private evidence. Exercise absence/recovery
   in memory, with no roster writes or test emails.
4. Set `GUARDIAN_COVERAGE_RUNNER=public-reporter-v1` on the public reporter first.
   Confirm a fresh persisted private assessment, then set the same variable on
   Guardian to skip periodic paid coverage jobs. Manual diagnostics remain usable.
5. Verify automatic reporter ticks and skipped private runner allocation.

Do not mute native GitHub/Google failure emails during this cost handoff. It does
not guarantee native cron punctuality or remove the shared-clock outage risk.
Rollback clears the Guardian variable first, then the reporter variable.

This change does not make already-public GM models private. Public visibility of
existing model sources requires a separate owner decision, not a billing workaround.
