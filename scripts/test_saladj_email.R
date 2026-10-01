source("R/config_helpers.R")
source("R/saladj_email.R")

rows <- data.frame(
  CONF = c("AFC", "NFC"),
  DATE = c("9/30/2026 19:48:53", "9/30/2026 14:03:42"),
  FRAN = c("JAC", "ATL"),
  PLAYER = c("Jerry Jeudy", "Joey Porter"),
  PLAYER_TEAM = c("CLE", "PIT"),
  PLAYER_POS = c("WR", "CB"),
  SALARY = c("5", "2.01"),
  YEARS = c("1", "1"),
  CONTRACT = c("2026 UFA", "2026 oEXT"),
  NOTES = c("ON WAIVERS CURRENTLY", "ON WAIVERS CURRENTLY"),
  `RVSD?` = c("", ""),
  check.names = FALSE,
  stringsAsFactors = FALSE
)

body <- render_saladj_email(
  rows,
  "2026_10_01_ADLSalAdjCurator.csv",
  "10/1/2026 12:34 p.m. EDT",
  list(
    scheduled_display = "10/1/2026 5:17 a.m. EDT",
    started_display = "10/1/2026 12:29 p.m. EDT",
    completed_display = "10/1/2026 12:34 p.m. EDT",
    duration_display = "5m 12s",
    trigger = "schedule"
  )
)

stopifnot(regexpr("NFC\\n---", body)[1] < regexpr("AFC\\n---", body)[1])
stopifnot(grepl("Dropped 9/30/2026 19:48:53 ET by JAC", body, fixed = TRUE))
stopifnot(grepl("Jerry Jeudy CLE WR: $5.00 / 1 yr / 2026 UFA | Notes: ON WAIVERS CURRENTLY", body, fixed = TRUE))
stopifnot(grepl("Joey Porter PIT CB: $2.01 / 1 yr / 2026 oEXT", body, fixed = TRUE))
stopifnot(grepl("Scheduled: 10/1/2026 5:17 a.m. EDT", body, fixed = TRUE))
stopifnot(grepl("Runtime to email: 5m 12s", body, fixed = TRUE))

cat("SalAdj email template checks passed.\n")
