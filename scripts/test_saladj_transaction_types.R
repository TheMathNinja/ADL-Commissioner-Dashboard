source("R/saladj_engine.R")

stopifnot(isTRUE(is_salary_adjustment_drop("FREE_AGENT", "dropped")))
stopifnot(isTRUE(is_salary_adjustment_drop("WAIVER", "dropped")))
stopifnot(isTRUE(is_salary_adjustment_drop("BBID_WAIVER", "dropped")))
stopifnot(isTRUE(is_salary_adjustment_drop("ROSTER", "dropped")))

stopifnot(!isTRUE(is_salary_adjustment_drop("ROSTER", "added")))
stopifnot(!isTRUE(is_salary_adjustment_drop("TRADE", "dropped")))

cat("SalAdj transaction-type checks passed.\n")
