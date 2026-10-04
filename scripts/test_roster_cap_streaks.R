source("R/inseason_inactivity_monitor.R")

report_dir <- tempfile("roster-cap-streak-")
dir.create(report_dir)
snapshot_dir <- tempfile("roster-cap-snapshots-")
dir.create(snapshot_dir)
Sys.setenv(ADL_ALERT_REPORT_DIR = report_dir)
Sys.setenv(ADL_ROSTER_SNAPSHOT_DIR = snapshot_dir)

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

# A missing alert report must not erase a real streak when the saved roster
# snapshot for that date proves the same violation.
snapshot_rows <- tibble::tibble(
  season = 2026,
  snapshot_time = "2026-09-14T09:17:00Z",
  franchise_id = "0006",
  franchise_name = "Detroit Lions",
  CONF = "NFC",
  player_id = as.character(seq_len(46L)),
  player_name = paste("Player", seq_len(46L)),
  player_team = "DET",
  player_pos = "LB",
  player_status = "",
  roster_status = c(rep("Active", 45L), "Taxi"),
  roster_salary = 1,
  roster_years = 1,
  roster_contractInfo = "2026 UFA"
)
readr::write_csv(
  snapshot_rows,
  file.path(snapshot_dir, "saladj_roster_snapshot_2026_20260914_091700.csv")
)
report("2026-09-13", "01", row)
day_after_outage <- as.POSIXct("2026-09-15 06:15:00", tz = "America/New_York")
stopifnot(identical(
  roster_cap_consecutive_days(row, 2026, day_after_outage, snapshot_dir = snapshot_dir),
  5L
))

# A genuinely missing day with neither a report nor a snapshot still breaks
# the streak rather than inventing evidence.
stopifnot(identical(
  roster_cap_consecutive_days(row, 2026, day_after_outage + 86400, snapshot_dir = snapshot_dir),
  1L
))

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
friday_digest <- render_commissioner_alert_email(first, week = 3L, checked_date = as.Date("2026-09-25"))
stopifnot(startsWith(friday_digest, "ADL Commissioner Alerts - Sep 25 (Week 3 Friday)"))
gm <- render_commissioner_gm_alert_email(second, checked_date = as.Date(day2))
stopifnot(grepl("Roster Cap Violation (Inactivity Violation)", gm, fixed = TRUE))
stopifnot(grepl(paste0(rule, " (2nd Consecutive)"), gm, fixed = TRUE))

clean_report <- tibble::tibble(
  alert_type = character(), severity = character(), conference = character(),
  franchise = character(), franchise_name = character(), rule = character(),
  observed = character(), details = character()
)
report("2026-09-26", "03", row)
for (date in c("2026-09-27", "2026-09-28", "2026-09-29")) {
  readr::write_csv(
    clean_report,
    file.path(report_dir, paste0("commissioner_alert_report_", date, "_2026_week03.csv"))
  )
}
clean_lines <- render_commissioner_clean_run_lines(2026, as.Date("2026-09-30"), report_dir)
stopifnot(grepl("Sep 27, Sep 28, Sep 29 (3 consecutive clean days)", paste(clean_lines, collapse = "\n"), fixed = TRUE))
clean_digest <- render_commissioner_alert_email(clean_report, season = 2026, checked_date = as.Date("2026-09-30"))
stopifnot(grepl("Verified Clean Daily Runs", clean_digest, fixed = TRUE))
stopifnot(grepl("Sep 27, Sep 28, Sep 29", clean_digest, fixed = TRUE))
unlink(file.path(report_dir, "commissioner_alert_report_2026-09-28_2026_week03.csv"))
gap_lines <- paste(render_commissioner_clean_run_lines(2026, as.Date("2026-09-30"), report_dir), collapse = "\n")
stopifnot(grepl("Sep 29 (1 consecutive clean day)", gap_lines, fixed = TRUE))

no_clean_lines <- render_commissioner_clean_run_lines(2026, as.Date("2026-09-27"), report_dir)
stopifnot(length(no_clean_lines) == 0L)
dirty_digest <- render_commissioner_alert_email(row, season = 2026, checked_date = as.Date("2026-09-27"))
stopifnot(!grepl("Clean Daily Runs", dirty_digest, fixed = TRUE))
cat("Roster-cap streak and email checks passed.\n")

# A pre-existing checked_at column must not mask the scalar run timestamp when
# inactivity rows are normalized for the daily alert report.
run_checked_at <- as.POSIXct("2026-09-22 06:15:00", tz = "America/New_York")
masked <- tibble::tibble(checked_at = c("old-1", "old-2"), season = c("2026", "2026")) |>
  dplyr::mutate(checked_at = format(as.POSIXct(.env$run_checked_at, tz = "UTC"), "%Y-%m-%d %H:%M:%S %Z"))
stopifnot(length(unique(masked$checked_at)) == 1L, grepl("2026-09-22", masked$checked_at[[1]], fixed = TRUE))
