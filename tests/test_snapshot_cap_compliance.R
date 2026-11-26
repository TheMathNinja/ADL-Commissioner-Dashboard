source("R/inseason_inactivity_monitor.R")

Sys.setenv(ADL_WEEK_ONE_START = "2026-09-10")
at <- function(week) salary_cap_snapshot_datetime(2026L, week)
ledger <- tibble(franchise = "CHI", franchise_salary_cap = 250)
ledger[paste0("week_", 1:17)] <- as.list(c(240, 261, 249, rep(200, 14)))
attr(ledger, "league_cap") <- 244
franchises <- tibble(franchise = "CHI", conference = "NFC", franchise_name = "Chicago Bears")
rosters <- tibble(franchise = "CHI", conference = "NFC", franchise_name = "Chicago Bears",
  roster_status = "ROSTER", prev_salary = rep(261 / 45, 45), player_status = "",
  franchise_salary_cap = 250)

check <- function(time, data = ledger) evaluate_snapshot_cap_violations(2026L, time, ledger = data, franchises = franchises)
forecast <- function(time, data = ledger) evaluate_salary_cap_average_warnings(rosters, 2026L, ledger = data, checked_at = time)

stopifnot(nrow(forecast(at(1) - 1)) == 1L, grepl("spending limit: \\$250.00m", forecast(at(1) - 1)$details))
warning <- forecast(at(2) - 1)
stopifnot(nrow(warning) == 1L, grepl("Week 2.*1.00m", warning$observed), grepl("260.00m", warning$details))
stopifnot(nrow(check(at(2) - 1)) == 0L)
confirmed <- check(at(2))
stopifnot(confirmed$violation_key == "weekly_cap_overage|2026|CHI|2",
  grepl("250.50m", confirmed$observed), grepl("1.00m", confirmed$details), nrow(check(at(3))) == 0L)
stopifnot(nrow(forecast(at(17))) == 0L)

missing <- ledger
missing$week_1 <- NA_real_
stopifnot(nrow(check(at(2), missing)) == 0L, nrow(forecast(at(2) - 1, missing)) == 0L)
pending <- ledger
pending$week_2 <- NA_real_
stopifnot(nrow(check(at(2), pending)) == 0L, nrow(forecast(at(2), pending)) == 0L)

over <- ledger
over[paste0("week_", 3:17)] <- as.list(rep(251, 15))
stopifnot(nrow(check(at(3), over)) == 0L)
stopifnot(check(at(17), over)$violation_key == "season_cap_overage|2026|CHI|17")

minimum <- ledger
minimum[paste0("week_", 1:17)] <- as.list(rep(201.20, 17))
stopifnot(nrow(check(at(16), minimum)) == 0L,
  check(at(17), minimum)$violation_key == "season_cap_minimum_spending|2026|CHI|17")

inactivity_dir <- tempfile("cap-inactivity-")
Sys.setenv(ADL_INSEASON_INACTIVITY_DIR = inactivity_dir)
issued <- bind_rows(confirmed, check(at(17), over)) |>
  select(violation_key, franchise, franchise_name) |>
  mutate(issued_at = "2026-12-29 06:00:00 EST")
write_issued_inseason_inactivity(issued, 2026L)
stopifnot(inseason_inactivity_cumulative_summary(2026L)$inseason_violations == 3L)

cat("Snapshot cap compliance tests passed.\n")
