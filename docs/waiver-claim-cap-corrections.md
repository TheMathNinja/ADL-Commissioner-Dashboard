# Waiver claim cap corrections

The official weekly cap run saves the MFL salary adjustment entries that make up each team's `Adj` total. The daily SalAdj Curator records explicit waiver claim transactions. At 12:45 UTC each day, Waiver Claim Cap Corrections compares claims with the adjustment entries saved at each earlier official snapshot.

A correction requires one unambiguous MFL adjustment for the dropping franchise, player and drop date, present in the official snapshot before the claim. The correction offsets that penalty in the corresponding `Cap Rollover` `CORR` cell. A claim that never had a penalty in an official snapshot produces no correction. If multiple weeks counted the same penalty, each affected week is corrected. The email tells commissioners which MFL adjustment ID to remove; the workflow does not alter MFL.

The sheet write uses `GOOGLE_SERVICE_ACCOUNT_JSON`, shared on the existing Contract Admin spreadsheet. It checks the franchise row and `Corr` header, preserves existing cell content, writes a formula with a unique correction marker, and reads the cell back. Repeated runs recognize the marker. If credentials are unavailable or the cell is unsafe to edit, commissioners get the correction email with the sheet status so they can enter it manually.

The sheet's week blocks are 12 columns wide: Week 1 `CORR` is L, Week 2 is X. Weekly summary writeback targets only each week's first ten columns, leaving `CORR` and `Final` intact.

For a new season, update the `CURRENT_SEASON` value in `.github/workflows/waiver-cap-corrections.yml` and verify the Contract Admin sheet ID. The first official salary snapshot will create the new season's entry ledger. The 2026 Week 1 ledger was reconstructed from the live MFL entries after matching every franchise total against the official saved summary.

Run `Rscript scripts/test_waiver_cap_corrections.R` for matching tests. Use the workflow's manual dispatch with both switches off for a no-email, no-write production-data check.
