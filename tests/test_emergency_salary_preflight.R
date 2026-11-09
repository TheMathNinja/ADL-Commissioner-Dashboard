source("R/inseason_inactivity_monitor.R")
source("R/emergency_salary_preflight.R")
rosters <- tibble(franchise_id = c("0001", "0017"), franchise = c("DAL", "BUF"),
  player_id = c("123", "123"), player_name = "Example", prev_salary = c(0, 7),
  prev_years = c(1, 3), contract = c("2026 UFA", "2024 UFA"))
at <- as.POSIXct("2026-11-08 12:00:00", tz = "UTC")
tx <- tibble(franchise = "DAL", player_id = "123", occurred_at = at, type_desc = "added")
context <- list(transactions = tx, accepted = emergency_add_key("DAL", "123", at))
plan <- emergency_salary_plan(rosters, context, 2026)
stopifnot(nrow(plan) == 1L, plan$matched, plan$new_salary == 2.10)
league <- list(franchises = list(franchise = list(list(id = "0001", division = "00"), list(id = "0017", division = "04"))),
  divisions = list(division = list(list(id = "00", conference = "00"), list(id = "04", conference = "01"))))
unit <- emergency_salary_unit(league, "0001")
payload <- emergency_salary_payload(plan, unit, "60206")
stopifnot(unit == "CONFERENCE00", payload$APPEND == "1", !grepl('unit="LEAGUE"', payload$DATA),
          !grepl("contract", payload$DATA), grepl('salary="2.10"', payload$DATA))
stopifnot(emergency_salary_unit(league, "0017") == "CONFERENCE01")
stopifnot(inherits(tryCatch(emergency_salary_payload(plan, "LEAGUE", "60206"), error = identity), "error"))
nonzero <- plan; nonzero$prev_salary <- 1
stopifnot(inherits(tryCatch(emergency_salary_payload(nonzero, unit, "60206"), error = identity), "error"))
after <- rosters; after$prev_salary[[1]] <- 2.10
stopifnot(verify_emergency_salary(rosters, after, plan))
changed_contract <- after; changed_contract$prev_years[[1]] <- 2
stopifnot(inherits(tryCatch(verify_emergency_salary(rosters, changed_contract, plan), error = identity), "error"))
after$prev_salary[[2]] <- 2.10
stopifnot(inherits(tryCatch(verify_emergency_salary(rosters, after, plan), error = identity), "error"))
context$accepted <- emergency_add_key("BUF", "123", at)
stopifnot(!emergency_salary_plan(rosters, context, 2026)$matched)
context$accepted <- emergency_add_key("DAL", "123", at)
context$transactions <- bind_rows(tx, mutate(tx, occurred_at = at + 100, type_desc = "added"))
stopifnot(!emergency_salary_plan(rosters, context, 2026)$matched)
cat("Emergency salary scope, zero-only, acquisition identity and read-back tests passed.\n")
