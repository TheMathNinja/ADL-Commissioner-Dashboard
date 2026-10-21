#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tibble)
})

source("R/commissioner_alerts.R")
source("R/inseason_inactivity_monitor.R")

reports <- tibble(
  alert_type = c("Illegal Lineup", "Illegal Lineup"),
  conference = c("NFC", "NFC"),
  franchise = c("NYG", "PHI"),
  franchise_name = c("New York Giants", "Philadelphia Eagles"),
  week = c("6", "7"),
  observed = c(
    "6 offensive starters (1 QB, 5 RB/WR/TE)",
    "6 offensive starters (1 QB, 5 RB/WR/TE)"
  ),
  details = c("Must start 1 additional RB", "Must start 1 additional RB")
)

alerts <- evaluate_confirmed_illegal_lineup_inactivity(
  season = 2026,
  run_time = as.POSIXct("2026-10-20 05:28:30", tz = "America/New_York"),
  reports = reports
)

stopifnot(nrow(alerts) == 1L)
stopifnot(identical(alerts$franchise, "NYG"))
stopifnot(identical(alerts$week, "6"))
stopifnot(identical(alerts$violation_key, "illegal_lineup|2026|NYG|6"))
stopifnot(grepl("Week 6 lineup", alerts$observed, fixed = TRUE))
stopifnot(!any(grepl("Week 7 lineup", alerts$observed, fixed = TRUE)))

cat("Illegal-lineup week rollover regression test passed.\n")
