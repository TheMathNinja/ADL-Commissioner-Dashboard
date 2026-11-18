source("R/inseason_inactivity_monitor.R")

commissioner_alert_status_week <- function(...) 9L
now <- as.POSIXct("2026-11-05 12:00:00", tz = "America/New_York")
kickoffs <- tibble(kickoff_at = as.POSIXct(c("2026-10-22 20:15:00", "2026-10-26 20:15:00"), tz = "America/New_York"))
stopifnot(lineup_alert_severity(lineup_week_last_kickoff(kickoffs), as.POSIXct("2026-10-24 05:25:00", tz = "America/New_York")) == "warning")
stopifnot(lineup_alert_severity(lineup_week_last_kickoff(kickoffs), now) == "violation")
stopifnot(is.na(lineup_week_last_kickoff(tibble(kickoff_at = as.POSIXct(NA)))))

positions <- c("QB", "RB", rep("WR", 4), "TE", "PK", "PN", rep("DT", 2), rep("DE", 3), rep("LB", 3), rep("CB", 2), rep("S", 2))
lineup <- tibble(franchise_id = "0002", franchise = "NYG", player_id = as.character(seq_along(positions)), player_pos = positions)
reports <- tibble(week = "6", conference = "NFC", franchise = "NYG", franchise_name = "New York Giants",
  alert_type = "Illegal Lineup", rule = "Starting lineups require 7 offensive starters", observed = "Missing RB", details = "Add RB")
check <- function(rows = lineup, history = reports, schedule = kickoffs) {
  evaluate_confirmed_illegal_lineup_inactivity(2026, now, history,
    fetch_lineups = function(...) rows, fetch_kickoffs = function(...) schedule)
}
# A stale pregame report must not become a penalty after a legal final lineup.
stopifnot(nrow(check()) == 0L)
bad <- lineup |> filter(player_pos != "RB")
stopifnot(nrow(check(bad)) == 1L)
stopifnot(grepl("final MFL lineup", check(bad)$observed))
# Warnings are candidates too, but only final evidence can confirm them.
reports$alert_type <- "Illegal Lineup Warning"
stopifnot(nrow(check(bad)) == 1L, nrow(check()) == 0L)
stopifnot(nrow(check(bad, bind_rows(reports, reports))) == 1L)
future <- reports; future$week <- "9"
stopifnot(nrow(check(bad, future)) == 0L)
stopifnot(nrow(check(bad, schedule = tibble(kickoff_at = now + 3600))) == 0L)
fails <- function(expr) inherits(tryCatch(force(expr), error = identity), "error")
stopifnot(fails(check(lineup[0, ])), fails(check(bind_rows(lineup, lineup[1, ]))))
unknown <- lineup; unknown$player_pos[1] <- NA_character_
stopifnot(fails(check(unknown)), fails(check(schedule = tibble())))

# Submission penalties must use a locked week even on Thursday/Sunday.
commissioner_alert_cutdown_datetime <- function(...) as.POSIXct("2026-09-01", tz = "UTC")
read_nfl_team_kickoffs <- function(season, week) tibble(kickoff_at = now + if (week == 9L) 3600 else -3600)
requested_week <- NA_integer_
lineup_submission_audit <- function(season, week, force_live) {
  requested_week <<- week
  tibble(week = week, conference = "NFC", franchise = "NYG", franchise_name = "New York Giants", submission_status = "not_submitted")
}
write_lineup_submission_audit <- function(...) stopifnot(TRUE)
submission <- evaluate_lineup_submission_inactivity(2026, TRUE, now)
stopifnot(requested_week == 8L, submission$week == "8", nrow(submission) == 1L)
read_nfl_team_kickoffs <- function(...) tibble()
stopifnot(fails(evaluate_lineup_submission_inactivity(2026, TRUE, now)))
cat("Final lineup confirmation regressions passed.\n")

# ADL V-A: a reviewed missed acquisition opportunity, not zero points, establishes this rule.
commissioner_alert_status_week <- function(...) 11L
now <- as.POSIXct("2026-11-17 12:00:00", tz = "UTC")
opportunity <- read_backup_lineup_opportunities(2026)
opportunity <- opportunity |> filter(franchise == "MIN", week == "10")
stopifnot(nrow(opportunity) == 1L)
auctions <- tibble(
  type = c("AUCTION_INIT", "AUCTION_BID", "AUCTION_WON"),
  franchise = "0011",
  timestamp = c("1794345430", "1794359977", "1794433293"),
  transaction = c("17038|1.10|", "17038|2|Tampa Bay Buccaneers forced bid increase", "17038|2|")
)
final_min <- tibble(franchise = "MIN", player_id = "16152")
backup_check <- function(history = auctions, final = final_min, evidence = opportunity,
  schedule = tibble(kickoff_at = now - 3600)) {
  evaluate_backup_lineup_inactivity(2026, now, evidence,
    fetch_transactions = function(...) history, fetch_lineups = function(...) final,
    fetch_kickoffs = function(...) schedule)
}
stopifnot(nrow(backup_check()) == 1L,
  backup_check()$violation_key == "illegal_lineup|2026|MIN|10")
# Any documented attempt is conservatively exempt, including a losing proxy bid.
bid <- auctions[2, ]; bid$franchise <- "0008"
stopifnot(nrow(backup_check(bind_rows(auctions, bid))) == 0L)
proxy <- auctions; proxy$transaction[2] <- "17038|2|Minnesota Vikings forced bid increase"
stopifnot(nrow(backup_check(proxy)) == 0L)
proxy$transaction[2] <- "17038|2|Minnesota Vikings bid (unrecognized annotation)"
stopifnot(nrow(backup_check(proxy)) == 0L)
# Repair, wrong week and unknown role evidence must not create hindsight penalties.
stopifnot(nrow(backup_check(final = mutate(final_min, player_id = "17038"))) == 0L)
future <- opportunity; future$week <- "11"
stopifnot(nrow(backup_check(evidence = future)) == 0L)
stopifnot(nrow(backup_check(evidence = opportunity[0, ])) == 0L)
stopifnot(nrow(backup_check(schedule = tibble(kickoff_at = now + 3600))) == 0L)
stopifnot(fails(backup_check(auctions[-1, ])), fails(backup_check(auctions[-3, ])),
  fails(backup_check(final = final_min[0, ])), fails(backup_check(schedule = tibble())))
cross <- opportunity; cross$auction_franchise_id <- "0024"
stopifnot(fails(backup_check(evidence = cross)))
invalid <- auctions; invalid$timestamp[2] <- "not-a-date"
stopifnot(fails(backup_check(invalid)))
# Same weekly key as structural/submission checks: one incident, not one per player or alternative.
both <- bind_rows(backup_check(), backup_check())
stopifnot(nrow(collapse_inseason_inactivity_candidates(both)) == 1L)
cat("Backup acquisition-attempt regressions passed.\n")
