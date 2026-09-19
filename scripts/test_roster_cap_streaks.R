source("R/inseason_inactivity_monitor.R")

report_dir <- tempfile("roster-cap-streak-")
dir.create(report_dir)
Sys.setenv(ADL_ALERT_REPORT_DIR = report_dir)

rule <- "Maximum 45 non-suspended/non-holdout players on Active Roster + Taxi Squad"
row <- tibble::tibble(
  alert_type = "Roster Cap Violation", severity = "violation", conference = "NFC",
  franchise = "DET", franchise_name = "Detroit Lions", rule = rule,
  observed = "46 non-suspended/non-holdout Active + Taxi players",
  details = "1 above maximum (45 Active + 1 Taxi)"
)
report <- function(date, week, rows) {
  rows$checked_at <- paste0(date, " 10:00:00 UTC")
  readr::write_csv(rows, file.path(report_dir, paste0("commissioner_alert_report_", date, "_2026_week", week, ".csv")))
}

day1 <- as.POSIXct("2026-09-11 06:15:00", tz = "America/New_York")
day2 <- as.POSIXct("2026-09-12 06:15:00", tz = "America/New_York")
day3 <- as.POSIXct("2026-09-13 06:15:00", tz = "America/New_York")
stopifnot(identical(roster_cap_consecutive_days(row, 2026, day1), 1L))
report("2026-09-11", "01", row)
stopifnot(identical(roster_cap_consecutive_days(row, 2026, day2), 2L))
report("2026-09-12", "01", row)
report("2026-09-12", "02", row)
stopifnot(identical(roster_cap_consecutive_days(row, 2026, day2), 2L))
stopifnot(identical(roster_cap_consecutive_days(row, 2026, day3), 3L))

different_rule <- row
different_rule$rule <- "At least 40 players on Active Roster"
stopifnot(identical(roster_cap_consecutive_days(different_rule, 2026, day3), 1L))
stopifnot(identical(roster_cap_consecutive_days(row, 2026, day3 + 2 * 86400), 1L))

confirmed <- evaluate_repeated_roster_violations(2026, run_time = day2)
stopifnot(nrow(confirmed) == 1L, confirmed$franchise[[1]] == "DET")
stopifnot(grepl("Roster Cap Violation", confirmed$details[[1]], fixed = TRUE))
covered <- row
covered$consecutive_days <- 2L
stopifnot(!nrow(omit_inactivity_rows_covered_by_roster_cap(confirmed, covered)))
covered$consecutive_days <- 1L
stopifnot(nrow(omit_inactivity_rows_covered_by_roster_cap(confirmed, covered)) == 1L)
report("2026-09-13", "02", row)
stopifnot(!nrow(evaluate_repeated_roster_violations(2026, run_time = day3)))

first <- row
first$consecutive_days <- 1L
second <- row
second$consecutive_days <- 2L
first$season <- second$season <- "2026"
first$checked_date <- second$checked_date <- as.character(as.Date(day2))
digest <- render_commissioner_alert_email(dplyr::bind_rows(first, second), checked_date = as.Date(day2))
stopifnot(grepl("Roster Cap Violation (1st Consecutive)", digest, fixed = TRUE))
stopifnot(grepl("Roster Cap Violation (Inactivity Violation)", digest, fixed = TRUE))
stopifnot(grepl(paste0(rule, " (2nd Consecutive)"), digest, fixed = TRUE))
gm <- render_commissioner_gm_alert_email(second, checked_date = as.Date(day2))
stopifnot(grepl("Roster Cap Violation (Inactivity Violation)", gm, fixed = TRUE))
stopifnot(grepl(paste0(rule, " (2nd Consecutive)"), gm, fixed = TRUE))
cat("Roster-cap streak and email checks passed.\n")
