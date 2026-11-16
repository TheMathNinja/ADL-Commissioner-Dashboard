# Salary-adjustment notifications

The scheduled 5:17 a.m. Eastern daily run always publishes its dated Curator CSV
and generation/check timestamps, even when no email is needed.

The daily workflow sends one combined salary-adjustment action report, replacing
the separate new-adjustments digest and checker email. Its categories are:

1. Items to Enter into Contract Admin and MFL
2. Items in Contract Admin to be Entered into MFL
3. Items that Need Correcting in Contract Admin or MFL

The first category compares Curator entries against a fresh read of
Contract Admin. It emails only rows not already recorded there. Player identity,
franchise, and transaction date distinguish repeated drops; signed amount and
date also distinguish cash trades. Initialed names and suspected spelling
matches are treated as existing rows for review, not requests to add duplicates.
Incorrect recorded amounts and controls remain the entry checker's responsibility.
Reversed Curator rows are not new-entry requests. A failed Sheet read is an
explicit run failure, not evidence that every row needs entering or is correct.

The checker continues producing its complete CSV daily. It is the sole automatic
email owner when ADL_SALADJ_COMBINED_ACTION_EMAIL=true; the Curator publishes data
but neither sends mail nor advances its email ledger. Actual entered-row
errors in Contract Admin or MFL remain eligible for daily, deduplicated emails.
Pending MFL entries with unchecked ENTD? fields are emailed only on Monday
morning (before noon Eastern), normally in the existing 5:17 a.m. daily package,
ahead of the late-Monday official cap snapshot. There is no new Sunday-night job.
All current outstanding items are included for context whenever a new item,
new correction, or Monday reminder warrants sending. Existing items alone do
not cause repeat mail. The old digest ledger is imported as prior delivery
evidence. Only confirmed delivery advances either ledger; a failed delivery is
retryable and remains a reportable workflow failure after recovery outputs save.
One reminder per outstanding issue per Monday is allowed; subsequent runs that
Monday do not repeat it. A still-pending issue may be reminded the next Monday.

An unchecked ENTD? row that fully explains the total difference is a warning,
not an entry error. A successfully read empty MFL adjustment list counts as $0;
unavailable entry evidence does not. Signed pending credits follow the same rule.
After a completed official cap snapshot at or after the row's transaction date,
an unentered adjustment becomes an overdue-entry error, eligible beyond the
Monday reminder window. Missing snapshot evidence never invents a missed cutoff.
Rows marked entered, incorrect amounts/franchises, and unexplained total/formula
differences remain errors. Do not change a correct summary total to match an MFL
total that simply lacks a pending entry. No entries or snapshots are auto-repaired.

No notification decision writes Contract Admin or MFL. The existing processed-row
ledger advances only after successful email delivery or a verified no-mail result.
Archive publication and email eligibility are separate: a push can publish data
without consuming the next daily digest, and a failed email can retry even when
the CSV is unchanged.

Manual SalAdj resends also recheck Contract Admin before mailing; an archive with
no remaining unrecorded new entries sends nothing. Explicit frozen checker
report copies remain historical reports, not fresh scheduled alerts.

Run `Rscript scripts/test_saladj_action_report.R`,
`Rscript scripts/test_saladj_notification_policy.R`,
`Rscript scripts/test_saladj_email.R`, and
`Rscript scripts/check_saladj_reconciliation.R --self-test-name-matching` before
changing either notification path. The daily workflow runs these same checks
before live processing.
