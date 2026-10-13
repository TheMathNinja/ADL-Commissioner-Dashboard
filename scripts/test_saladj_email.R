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
stopifnot(grepl("Jerry Jeudy CLE WR: $5.00 / 1 yr / 2026 UFA\n  Notes: ON WAIVERS CURRENTLY", body, fixed = TRUE))
stopifnot(grepl("Joey Porter PIT CB: $2.01 / 1 yr / 2026 oEXT", body, fixed = TRUE))
stopifnot(!grepl("There are new salary adjustments to enter", body, fixed = TRUE))
stopifnot(!grepl("Run audit", body, fixed = TRUE))
stopifnot(grepl("SalAdj scraper scheduled: 10/1/2026 5:17 a.m. EDT", body, fixed = TRUE))
stopifnot(grepl("Run type: Scheduled daily refresh", body, fixed = TRUE))
stopifnot(grepl("Run started: 10/1/2026 12:29 p.m. EDT", body, fixed = TRUE))
stopifnot(grepl("Run completed / email prepared: 10/1/2026 12:34 p.m. EDT (runtime: 5m 12s)", body, fixed = TRUE))
stopifnot(grepl("Dashboard CSV here: https://", body, fixed = TRUE))
stopifnot(grepl(
  "SalAdj Curator published 2 new row(s) at 10/1/2026 12:34 p.m. EDT.\nDashboard CSV here:",
  body,
  fixed = TRUE
))
stopifnot(!grepl("EDT.\n\nDashboard CSV here:", body, fixed = TRUE))

cash_body <- render_saladj_email(
  rows[1, , drop = FALSE],
  "2026_10_01_ADLSalAdjCurator.csv",
  "10/1/2026 12:34 p.m. EDT",
  cash_limit_violations = tibble::tibble(
    franchise = "WAS", net_direction = "acquired", net_amount = 12.25,
    limit = 12.20, overage = 0.05, total_given = 0, total_acquired = 12.25
  )
)
stopifnot(grepl("Cash Trade Limit Violation", cash_body, fixed = TRUE))
stopifnot(grepl("WAS: Net cash acquired is $12.25m; maximum is $12.20m.", cash_body, fixed = TRUE))
stopifnot(grepl("Details: $0.05m above maximum ($0.00m given; $12.25m acquired).", cash_body, fixed = TRUE))

push_body <- render_saladj_email(
  rows[1, , drop = FALSE],
  "2026_10_01_ADLSalAdjCurator.csv",
  "10/1/2026 7:34 p.m. EDT",
  list(
    scheduled_display = "",
    started_display = "10/1/2026 7:33 p.m. EDT",
    completed_display = "10/1/2026 7:34 p.m. EDT",
    duration_display = "1m 1s",
    trigger = "push"
  )
)
stopifnot(grepl("Run type: Transaction-triggered refresh", push_body, fixed = TRUE))
stopifnot(grepl("Run started: 10/1/2026 7:33 p.m. EDT", push_body, fixed = TRUE))
stopifnot(!grepl("SalAdj scraper scheduled:", push_body, fixed = TRUE))

orchestrated_body <- render_saladj_email(
  rows[1, , drop = FALSE],
  "2026_10_10_ADLSalAdjCurator.csv",
  "10/10/2026 5:20 a.m. EDT",
  list(
    scheduled_display = "10/10/2026 5:17 a.m. EDT",
    started_display = "10/10/2026 5:19 a.m. EDT",
    completed_display = "10/10/2026 5:21 a.m. EDT",
    duration_display = "1m 19s",
    trigger = "daily_maintenance"
  )
)
stopifnot(grepl("Run type: Scheduled daily refresh", orchestrated_body, fixed = TRUE))
stopifnot(!grepl("Manually triggered refresh", orchestrated_body, fixed = TRUE))
stopifnot(grepl("SalAdj scraper scheduled: 10/10/2026 5:17 a.m. EDT", orchestrated_body, fixed = TRUE))

html_body <- render_saladj_email_html(body, "2026_10_01_ADLSalAdjCurator.csv")
stopifnot(grepl('<a href="https://themathninja.github.io/ADL-Commissioner-Dashboard/downloads/2026_10_01_ADLSalAdjCurator.csv">Dashboard CSV here</a>', html_body, fixed = TRUE))
stopifnot(!grepl("Dashboard CSV here: https://", html_body, fixed = TRUE))

parsed_start <- parse_saladj_workflow_time("2026-10-01T19:03:00Z")
stopifnot(format(parsed_start, "%Y-%m-%d %H:%M:%S", tz = "UTC") == "2026-10-01 19:03:00")
stopifnot(format(parsed_start, "%Y-%m-%d %H:%M:%S", tz = "America/New_York") == "2026-10-01 15:03:00")

cat("SalAdj email template checks passed.\n")
