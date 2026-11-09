# SalAdj contract and reconciliation audit

## Findings and changes

- Contract Admin ingestion omitted YEARS and CONTRACT. Comparisons now include
  both, preserve ^/+/*, normalize only case/whitespace, and show actual versus
  expected values even when current-year penalties are identical.
- Control matching required equal salary, hiding additional metadata errors
  when salary was also wrong. Matching now uses franchise, transaction date,
  player and B/R event class. Multiple matching rows produce a review finding
  instead of choosing the first row.
- Next-year penalty discrepancies now receive their own finding. Existing
  current-year amount, flag, plus-value, MFL total and Cap Rollover checks remain.
- The literal yearless N.XX^ matcher existed in both SalAdj and cap accounting's
  waiver output. Both now use the shared year-aware rookie classifier. Rounds
  3-6 remain NG regardless of salary or PPE; rounds 1-2 and changed contract
  types such as EXT are not excluded by this rule.
- Fresh, cached and final/manual-merged Curator output exclude NG rookie drops.
  B/R and TR/IB adjustments remain separate, preserved event types.
- Active NG rookie drop rows remaining in Contract Admin receive a reversal
  warning, and cannot become expected MFL penalties. Already-reversed rows
  remain excluded using the existing RVSD? mechanism.

## McDonald correction

PHI's 2023 3.18^ drop (2026-10-27) was the only row removed by the live
Curator rebuild. Added an idempotent -2.22 Week 8 correction under
week8-phi-ng-ppe-reversal-20261109. Original +2.22 ledger entry, historical
snapshots, prior archives and sent-email history remain available as evidence.
No Week 9 official snapshot existed at repair time. The latest summary carries
net zero PHI Week 8 CORR; no future Curator output will request this drop.

Read-only live checks confirmed the user restored ^ and marked RVSD? in
NFC Sal Adj row 136, and the McDonald entry was absent from the visible MFL
adjustment page. No Google Sheet or MFL writes or emails were performed.

## Verification scope

Reviewed SalAdj snapshot selection, historical cache merge, drop qualification,
cash/B/R separation, contract classifiers, waiver output, Contract Admin input
mapping and matching, historical MFL expectations and message rendering.
Focused regressions cover these changed paths plus existing waiver, event,
notification and cap snapshot tests. The required four-repository publication
gate is run separately on the exact candidate before push.

This does not reconstruct every contract's signing history or prove all
historical commissioner entries correct. In particular, non-rookie guarantee
classification still depends on the available source records and existing
salary/contract rules; this change does not infer a historical guarantee from
an unavailable original signing record. Archived snapshots are not rewritten.
