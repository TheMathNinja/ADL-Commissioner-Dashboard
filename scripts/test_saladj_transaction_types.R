source("R/saladj_engine.R")

stopifnot(isTRUE(is_salary_adjustment_drop("FREE_AGENT", "dropped")))
stopifnot(isTRUE(is_salary_adjustment_drop("WAIVER", "dropped")))
stopifnot(isTRUE(is_salary_adjustment_drop("BBID_WAIVER", "dropped")))
stopifnot(isTRUE(is_salary_adjustment_drop("ROSTER", "dropped")))
stopifnot(isTRUE(is_salary_adjustment_drop("LOAD_ROSTERS", "dropped")))

stopifnot(!isTRUE(is_salary_adjustment_drop("ROSTER", "added")))
stopifnot(!isTRUE(is_salary_adjustment_drop("TRADE", "dropped")))

raw_unload <- normalize_raw_mfl_transactions(list(
  timestamp = "1790874028",
  type = "LOAD_ROSTERS",
  franchise = "0030",
  transaction = "|14105,"
))
expanded_unload <- expand_mfl_player_list_transactions(raw_unload)
stopifnot(any(
  expanded_unload$type == "LOAD_ROSTERS" &
    expanded_unload$type_desc == "dropped" &
    expanded_unload$player_id == "14105"
))

raw_load <- normalize_raw_mfl_transactions(list(
  timestamp = "1790874028",
  type = "LOAD_ROSTERS",
  franchise = "0030",
  transaction = "14105,|"
))
expanded_load <- expand_mfl_player_list_transactions(raw_load)
stopifnot(any(
  expanded_load$type == "LOAD_ROSTERS" &
    expanded_load$type_desc == "added" &
    expanded_load$player_id == "14105"
))
stopifnot(!any(
  expanded_load$type == "LOAD_ROSTERS" &
    expanded_load$type_desc == "dropped" &
    expanded_load$player_id == "14105"
))

cat("SalAdj transaction-type checks passed.\n")
