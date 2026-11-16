# Shared Display Changes

`live_display.json` is the reviewed specification for probability labels and tie
visibility in both leagues. Its examples are independent expected outputs, not
values copied from whatever the implementation currently returns.

For a requested presentation change:

1. Change the policy, increment `policyVersion`, and review boundary examples in
   this one contract. Keep display rules separate from lineup and scoring rules.
2. From the Commissioner checkout run:

   ```powershell
   python scripts/sync_live_display_contract.py PATH_TO_ADL PATH_TO_FAFL --write
   ```

   This updates both generated renderer settings and both downstream test
   fixtures. It does not rewrite assertions to accept arbitrary implementation
   output, change scoring, or change Guardian's lineup/acquisition rules.
3. Run the complete private Guardian `league-audit.yml` contracts recipe against
   all four local candidates. The existing test runner now checks contract drift
   before executing both leagues' tests. Do not push if any required check fails.
4. Publish compatible consumers (ADL and FAFL) first, then the Commissioner
   contract/checker. Consumer fixtures are self-contained, so consumers remain
   testable during this rollout. Never introduce a checker dependency before
   its files are deployed. Rebase and repeat the gate if inputs change.
5. Verify the complete production audit after publication. Keep a record of
   audited revisions, results, and any live verification limits.

Default sync mode is check-only. No scheduled workflow writes or auto-approves
contract changes. A drift failure must be resolved before publishing, not by
weakening or deleting the test.

For other shared behavior changes, add an explicit versioned contract with
reviewed examples and register its validation in the same release gate. Do not
automatically translate presentation changes into business-rule changes.
