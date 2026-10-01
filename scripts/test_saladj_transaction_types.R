source("R/saladj_engine.R")

stopifnot(isTRUE(is_salary_adjustment_drop("FREE_AGENT", "dropped")))
stopifnot(isTRUE(is_salary_adjustment_drop("WAIVER", "dropped")))
stopifnot(isTRUE(is_salary_adjustment_drop("BBID_WAIVER", "dropped")))
stopifnot(isTRUE(is_salary_adjustment_drop("ROSTER", "dropped")))
stopifnot(isTRUE(is_salary_adjustment_drop("LOAD_ROSTERS", "dropped")))

stopifnot(!isTRUE(is_salary_adjustment_drop("ROSTER", "added")))
stopifnot(!isTRUE(is_salary_adjustment_drop("TRADE", "dropped")))

unload_fields <- parse_load_roster_transaction_fields("|14105,")
stopifnot(unload_fields$added[[1]] == "")
stopifnot(unload_fields$dropped[[1]] == "14105,")

load_fields <- parse_load_roster_transaction_fields("14105,|")
stopifnot(load_fields$added[[1]] == "14105,")
stopifnot(load_fields$dropped[[1]] == "")

cat("SalAdj transaction-type checks passed.\n")
