source("R/waiver_cap_corrections.R")
source("R/waiver_cap_sheet.R")

claim <- data.frame(
  player_id = "14789", player = "Tyler Huntley", drop_franchise_id = "0012",
  dropped_at_utc = "2026-09-13 15:06:30", claimed_at_utc = "2026-09-15 09:05:00"
)
ledger <- data.frame(
  season = 2026L, week = 1L, franchise_id = "0012", adjustment_id = "150",
  description = "T. Huntley - 1 yr at $1.10 mil dropped 9/13/26",
  amount = 1.1, captured_at_utc = "2026-09-15 03:15:00"
)
found <- match_waiver_cap_corrections(claim, ledger)
stopifnot(nrow(found) == 1L, found$corr_cell == "L14", found$amount == 1.1,
          found$key == "2026-1-150")
stopifnot(nrow(match_waiver_cap_corrections(claim, transform(ledger, captured_at_utc = "2026-09-15 10:00:00"))) == 0L)
stopifnot(nrow(match_waiver_cap_corrections(claim, transform(ledger, adjustment_id = "151", description = "T. Hill - 1 yr at $1.10 mil dropped 9/13/26"))) == 0L)
stopifnot(nrow(match_waiver_cap_corrections(claim, transform(ledger, adjustment_id = "151", franchise_id = "0011"))) == 0L)
stopifnot(waiver_cap_corr_cell(2L, "0012") == "X14")
stopifnot(inherits(try(match_waiver_cap_corrections(claim, rbind(ledger, ledger)), silent = TRUE), "try-error"))
formula <- waiver_cap_formula("", 1.1, found$key)
stopifnot(formula == '=SUM(0)-1.10+N("ADL-WAIVER-CORR:2026-1-150")')
stopifnot(waiver_cap_formula(formula, 1.1, found$key) == formula)
stopifnot(grepl('SUM(2.5)-1.10', waiver_cap_formula("2.5", 1.1, found$key), fixed = TRUE))
stopifnot(inherits(try(waiver_cap_formula("manual note", 1.1, found$key), silent = TRUE), "try-error"))
cat("Waiver cap correction matching checks passed.\n")
