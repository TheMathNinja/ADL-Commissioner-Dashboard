# Salary-adjustment notifications

The scheduled 5:17 a.m. Eastern daily run always publishes its dated Curator CSV
and generation/check timestamps, even when no email is needed.

The new-adjustments digest compares new Curator entries against a fresh read of
Contract Admin. It emails only rows not already recorded there. Player identity,
franchise, and transaction date distinguish repeated drops; signed amount and
date also distinguish cash trades. Initialed names and suspected spelling
matches are treated as existing rows for review, not requests to add duplicates.
Incorrect recorded amounts and controls remain the entry checker's responsibility.
Reversed Curator rows are not new-entry requests. A failed Sheet read is an
explicit run failure, not evidence that every row needs entering or is correct.

The checker continues producing its complete CSV daily. Its email excludes
missing Contract Admin entries already handled by the digest. Actual entered-row
errors in Contract Admin or MFL remain eligible for daily, deduplicated emails.
Pending MFL entries with unchecked ENTD? fields are emailed only on Monday
morning (before noon Eastern), normally in the existing 5:17 a.m. daily package,
ahead of the late-Monday official cap snapshot. There is no new Sunday-night job.
One reminder per outstanding issue per Monday is allowed; subsequent runs that
Monday do not repeat it. A still-pending issue may be reminded the next Monday.

No notification decision writes Contract Admin or MFL. The existing processed-row
ledger advances only after successful email delivery or a verified no-mail result.
Archive publication and email eligibility are separate: a push can publish data
without consuming the next daily digest, and a failed email can retry even when
the CSV is unchanged.

Run `Rscript scripts/test_saladj_notification_policy.R`,
`Rscript scripts/test_saladj_email.R`, and
`Rscript scripts/check_saladj_reconciliation.R --self-test-name-matching` before
changing either notification path. The daily workflow runs these same checks
before live processing.
