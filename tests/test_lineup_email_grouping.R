source("R/commissioner_alerts.R")
alerts <- tibble::tibble(
  alert_type = c(rep("Illegal Lineup Warning", 4), "Illegal Lineup"),
  severity = c(rep("warning", 4), "violation"),
  franchise = c(rep("NYJ", 4), "KCC"),
  franchise_name = c(rep("New York Jets", 4), "Kansas City Chiefs"),
  conference = "AFC",
  rule = c(rep("No starters on bye", 4), "Starting lineups require minimum 1 PK and 1 PN"),
  observed = c("Kittle on Bye", "Reese on Bye", "Brown on Bye", "Bullock on Bye", "0 PK, 0 PN"),
  details = c(rep("", 4), "Must start 1 additional PK and 1 additional PN")
)
count <- function(text, pattern) sum(gregexpr(pattern, text, fixed = TRUE)[[1]] > 0)
digest <- render_commissioner_alert_email(alerts, 2026, 8, as.Date("2026-11-01"))
stopifnot(count(digest, "**Illegal Lineup**") == 1L,
          count(digest, "New York Jets") == 1L,
          count(digest, "Rule: No starters on bye") == 1L,
          !grepl("Illegal Lineup Warning", digest, fixed = TRUE))
for (player in c("Kittle", "Reese", "Brown", "Bullock")) stopifnot(grepl(player, digest, fixed = TRUE))
gm <- render_commissioner_gm_alert_email(alerts[1:4, ], 2026, 8)
stopifnot(count(gm, "Rule: No starters on bye") == 1L)
stopifnot(identical(alerts$alert_type[[1]], "Illegal Lineup Warning"))
cat("Lineup email grouping tests passed.\n")
