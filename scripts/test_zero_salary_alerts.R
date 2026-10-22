library(dplyr)
library(tibble)

source("R/commissioner_alerts.R")

raw_rosters <- tibble(
  franchise_id = c("0009", "0017", "0018"),
  franchise_name = c("Atlanta Falcons", "Buffalo Bills", "Miami Dolphins"),
  player_id = c("mcguire", "sanders", "valid"),
  player_name = c("McGuire, Isaiah", "Sanders, Shedeur", "Valid, Player"),
  team = c("CLE", "CLE", "MIA"),
  pos = c("DE", "QB", "RB"),
  roster_status = "ROSTER",
  salary = c(NA_character_, "0", "1.50"),
  contract_years = c("1", "1", "1"),
  contract = c("2026 UFA", "2026 UFA", "2026 UDFA")
)

rosters <- normalize_rosters(raw_rosters)
stopifnot(nrow(rosters) == 3L)

alerts <- evaluate_salary_adjustment_alerts(
  rosters,
  season = 2026,
  checked_at = as.POSIXct("2026-10-20 09:20:50", tz = "America/New_York")
)

salary_errors <- alerts |>
  filter(.data$alert_type == "MFL Salary Data Error") |>
  arrange(.data$franchise)

stopifnot(nrow(salary_errors) == 2L)
stopifnot(identical(salary_errors$franchise, c("ATL", "BUF")))
stopifnot(all(grepl("showing \\$0[.]00 in MFL$", salary_errors$observed)))
stopifnot(all(salary_errors$commissioner_only))
stopifnot(!any(alerts$alert_type == "Salary Adjustments" & grepl("McGuire|Sanders", alerts$observed)))

cat("Zero-salary MFL data alert checks passed.\n")
