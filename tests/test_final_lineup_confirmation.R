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

# XV-B: only a GM submission after a confirmed inactive observation and before
# kickoff defeats the late-scratch exemption. Show excused and uncertain rows.
game <- as.POSIXct("2026-11-22 13:00:00", tz = "America/New_York")
late_out <- tibble(snapshot_time = game - c(7200, 5400), player_status = c("Q", "O"))
review <- function(submission, status = "submitted", history = late_out) {
  review_inactive_starter(history, game, submission, status, 48)
}
stopifnot(
  as.numeric(difftime(final_lineup_time("2026-11-01 01:30:00 EST"),
                      final_lineup_time("2026-11-01 01:30:00 EDT"), units = "hours")) == 1,
  review(game - 4800)$outcome == "Violation",
  review(game - 9000)$outcome == "Excused",
  grepl("Prior designation: Q", review(game - 9000)$evidence, fixed = TRUE),
  review(game - 6000)$outcome == "Needs review",
  review(game - 5400)$outcome == "Needs review",
  review(game + 3600)$outcome == "Needs review",
  review(game - 4800, "commissioner_set")$outcome == "Needs review",
  review(game - 9000, history = mutate(late_out, snapshot_time = game - c(50, 49) * 3600))$outcome == "Violation",
  is.null(review(game - 4800, history = mutate(late_out, player_status = c("O", "Q"))))
)
cutoff_gap <- review(game - 60 * 3600, history = mutate(late_out, snapshot_time = game - c(53, 47) * 3600))
stopifnot(cutoff_gap$outcome == "Needs review",
          grepl("bracket the 48-hour cutoff", cutoff_gap$reason, fixed = TRUE),
          grepl("Nov 20 13:00:00 EST", cutoff_gap$reason, fixed = TRUE))
final <- lineup |> mutate(conference = "NFC", franchise_name = "New York Giants",
                          player_team = "NYG", player_name = paste("Player", player_id))
history <- late_out |> mutate(conference = "NFC", player_id = "1", player_team = "NYG")
schedule <- tibble(player_team = "NYG", kickoff_at = game)
stamps <- tibble(conference = "NFC", franchise = "NYG", submission_status = "submitted",
                 submitted_at = format(game - 9000, "%Y-%m-%d %H:%M:%S %Z"))
weekly_out <- tibble(player_id = "1", player_team = NA_character_, player_status = "O")
result <- build_final_lineup_review(final, schedule, history, stamps, integer(), 11L, weekly_out)
stopifnot(nrow(result) == 1L, result$outcome == "Excused", nrow(final_lineup_review_violations(result, 2026)) == 0L)
stopifnot(all(is_commissioner_only_alert(final_lineup_review_digest(result))))

hindsight <- bind_rows(weekly_out, tibble(player_id = "2", player_team = NA_character_, player_status = "O"))
result <- build_final_lineup_review(final[-3, ], schedule, history,
  mutate(stamps, submitted_at = format(game - 4800, "%Y-%m-%d %H:%M:%S %Z")), integer(), 11L, hindsight)
stopifnot(nrow(result) == 3L, sum(result$outcome == "Violation") == 2L,
          sum(result$outcome == "Needs review") == 1L,
          nrow(collapse_inseason_inactivity_candidates(final_lineup_review_violations(result, 2026))) == 1L)
late_submit <- mutate(stamps, submitted_at = format(game - 4800, "%Y-%m-%d %H:%M:%S %Z"))
scored <- mutate(final, player_score = if_else(player_id == "1", -0.8, 0))
stopifnot(nrow(build_final_lineup_review(scored, schedule, history, late_submit, integer(), 11L, weekly_out)) == 0L)
unconfirmed <- build_final_lineup_review(final, schedule, history, late_submit, integer(), 11L)
stopifnot(nrow(unconfirmed) == 1L, unconfirmed$outcome == "Needs review")
stopifnot(nrow(evaluate_final_lineup_review(2026, 11L, game + 1, late_submit,
  fetch_kickoffs = function(...) mutate(schedule, game_complete = FALSE),
  fetch_lineups = function(...) stop("Still in progress"))) == 0L)
cat("Final lineup designation and submission regressions passed.\n")

archive_dir <- tempfile("mfl-pregame-")
archive_week <- file.path(archive_dir, "mfl_pregame_designations", "2026", "week11")
dir.create(archive_week, recursive = TRUE)
old_alert_dir <- Sys.getenv("ADL_ALERT_DIR", unset = NA_character_)
Sys.setenv(ADL_ALERT_DIR = archive_dir)
jsonlite::write_json(list(source = "mfl-injuries", season = 2026, week = 11,
  slot = "2026-11-22T17:30:00+00:00", observedAt = "2026-11-22T17:38:11.032+00:00",
  injuries = tibble(player_id = c("1", "2"), player_status = c("Out", "Questionable"))),
  file.path(archive_week, "mfl_20261122T173000Z.json"), auto_unbox = TRUE)
more_history <- read_mfl_pregame_designations(2026, 11, history)
stopifnot(nrow(more_history) == 1L, more_history$player_id == "1", more_history$player_team == "NYG",
  more_history$conference == "NFC", more_history$player_status == "Out",
  format(more_history$snapshot_time, "%H:%M:%S", tz = "UTC") == "17:38:11")
conflict <- bind_rows(history, mutate(history, player_team = "BUF"))
stopifnot(nrow(read_mfl_pregame_designations(2026, 11, conflict)) == 0L)
if (is.na(old_alert_dir)) Sys.unsetenv("ADL_ALERT_DIR") else Sys.setenv(ADL_ALERT_DIR = old_alert_dir)
cat("Cloud MFL-only pregame designation evidence regressions passed.\n")

players <- tibble(mfl_id = as.character(1:9), pfr_id = letters[1:9])
one_game <- tibble(season = 2026, game_type = "REG", game_id = "first",
  week = 10L, pfr_player_id = c(letters[1:6], "h", "i", "anchor"), team = "NYG", opponent = "BUF",
  offense_snaps = c(15, 2, 0, 25, NA, 25, 5, 25, 100),
  defense_snaps = c(0, 9, 0, 0, 0, 0, 12, 5, 50))
snaps <- bind_rows(one_game, mutate(one_game, game_id = "next", week = 11L,
  offense_snaps = c(25, 2, 0, 30, 29, 25, 0, 10, 100),
  defense_snaps = c(0, 10, 0, 0, 0, 0, 12, 5, 50))) |>
  mutate(offense_pct = offense_snaps / 100, defense_pct = defense_snaps / 50)
snaps <- bind_rows(snaps, filter(snaps, pfr_player_id == "f", week == 10) |>
  mutate(offense_snaps = 80, offense_pct = 0.8))
evidence <- prepare_adl_snap_evidence(snaps, players, 2026)
starters <- tibble(conference="NFC", franchise="NYG", franchise_name="New York Giants",
  player_id = as.character(1:9), player_name = paste("Player", 1:9),
  player_pos = c("QB", "S", "PK", "RB", "WR", "QB", "TE", "CB", "WR"))
low <- adl_low_snap_starters(starters, evidence, 11)
stopifnot(identical(low$player_id, c("1", "2")), identical(low$unit, c("offense", "defense")),
  identical(low$current_share, c(.25, .24)), identical(low$previous_share, c(.15, .22)),
  is.na(adl_snap_team_total(1, .01)), is.na(adl_snap_team_total(c(50, 49), c(1, .80))),
  adl_snap_team_total(c(25, 45), c(.52, .94)) == 48)
ambiguous <- bind_rows(players, tibble(mfl_id = "9", pfr_id = "a"))
stopifnot(!"1" %in% prepare_adl_snap_evidence(snaps, ambiguous, 2026)$mfl_id)
workload_team <- tibble(conference = "NFC", franchise = "NYG", franchise_id = "0002",
  franchise_name = "New York Giants", player_name = paste("Player", 1:21),
  player_pos = c("QB", "S", "PK", "RB", rep("WR", 4), "TE", "PN", rep("DT", 2),
    rep("DE", 2), rep("LB", 2), rep("CB", 2), rep("S", 2), "CB"),
  player_id = c("1", "2", "3", as.character(104:121)))
bench <- mutate(workload_team[1, ], player_id = "8", player_pos = "LB", player_name = "Bench LB")
attr(workload_team, "mfl_bench") <- bench
start <- as.POSIXct("2026-11-22 18:00:00", tz = "UTC")
schedule <- tibble(player_team = "NYG", kickoff_at = start)
archive <- bind_rows(workload_team[1:3, ], bench) |>
  mutate(player_team = "NYG", roster_status = "Active", snapshot_time = start - 300, player_status = NA_character_)
injury_sheet <- tibble(player_id = "unused", player_status = "Out")
evidence2 <- evidence |>
  mutate(defense_snaps = if_else(mfl_id == "8", 33, defense_snaps),
    snap_pos = case_when(mfl_id == "3" ~ "K", mfl_id %in% c("1", "4") ~ "QB", TRUE ~ snap_pos),
    team_role = if_else(mfl_id == "3", 12, team_role), st_snaps = if_else(mfl_id == "3", 1, st_snaps))
tx <- tibble(type = "AUCTION_BID", franchise = "0002", transaction = "4|8|",
  timestamp = as.character(as.numeric(start - 3600)))
evidence2 <- bind_rows(evidence2, evidence2 |> filter(week == 10L) |> mutate(week = 9L))
efficiency_scores <- tibble(week = rep(9:10, each = 2), mfl_id = rep(c("2", "8"), 2),
  points = c(1, 10, 1, 10))
score_history <- function(weeks) efficiency_scores
contaminated <- bind_rows(efficiency_scores, tibble(week = 11L, mfl_id = "2", points = 100))
eff <- adl_season_snap_efficiency(evidence2, contaminated, adl_prior_snap_weeks(11L))
stopifnot(eff$games[eff$mfl_id == "2"] == 2L,
  isTRUE(all.equal(eff$points_per_snap[eff$mfl_id == "2"], 2 / 22)))
low_review <- low_snap_review_rows(workload_team, evidence2, 11, archive, schedule, injury_sheet,
  function() tx, score_history)
stopifnot(nrow(low_review) == 3L, nrow(final_lineup_review_violations(low_review, 2026)) == 0L,
  any(grepl("Bench LB", low_review$details)), any(grepl("Recorded MFL acquisition activity", low_review$details)),
  any(grepl("team's PK snaps", low_review$observed)),
  any(grepl("66.0% of team defense snaps in Week 11; 76.0% in Week 10", low_review$details, fixed = TRUE)),
  any(grepl("ADL scoring through Week 10", low_review$details, fixed = TRUE)),
  any(grepl("9.34 vs. 1.05 estimated points (+8.30)", low_review$details, fixed = TRUE)),
  !any(grepl("33 snaps", low_review$details, fixed = TRUE)),
  all(is_commissioner_only_alert(final_lineup_review_digest(low_review))))
injured_qb <- bind_rows(injury_sheet, tibble(player_id = "1", player_status = "Q"))
unavailable_bench <- archive |> mutate(roster_status = if_else(player_id == "8", "IR", roster_status))
stopifnot(nrow(low_snap_review_rows(workload_team, evidence2, 11, unavailable_bench, schedule, injured_qb)) == 1L,
  nrow(low_snap_review_rows(workload_team, evidence2, 11, archive, schedule, injured_qb,
    fetch_scoring = score_history)) == 2L,
  nrow(low_snap_review_rows(workload_team, evidence2, 11, archive, schedule, injured_qb,
    fetch_scoring = function(weeks) mutate(efficiency_scores, points = if_else(mfl_id == "2", 20, 1)))) == 1L,
  !adl_legal_snap_swap(workload_team$player_pos, "DT", "LB"),
  !adl_legal_snap_swap(workload_team$player_pos, "S", "WR"),
  !adl_legal_snap_swap(workload_team$player_pos, "CB", "S"))
same_position <- workload_team
attr(same_position, "mfl_bench") <- mutate(bench, player_pos = "S")
same_archive <- archive |> mutate(player_pos = if_else(player_id == "8", "S", player_pos))
for (gain in c(2.99, 3, 3.01)) {
  threshold_scores <- efficiency_scores |> mutate(points = if_else(
    mfl_id == "2", 5 / 11.5 * 11, (5 + gain) / 35.5 * 38))
  revised <- low_snap_review_rows(same_position, evidence2, 11, same_archive, schedule, injury_sheet,
    fetch_scoring = function(weeks) threshold_scores)
  stopifnot(any(grepl("Available Player Suggestion:", revised$details, fixed = TRUE)) == (gain >= 3))
}
for (bench_snaps in c(44, 45, 46)) {
  boundary <- evidence2 |>
    mutate(defense_snaps = if_else(mfl_id == "8" & week == 11, bench_snaps, defense_snaps),
      team_defense = if_else(mfl_id == "8" & week == 11, 100, team_defense))
  revised <- low_snap_review_rows(workload_team, boundary, 11, archive, schedule, injury_sheet,
    fetch_scoring = score_history)
  stopifnot(any(grepl("Available Player Suggestion:", revised$details, fixed = TRUE)) == (bench_snaps >= 45))
}
for (bench_snaps in c(44, 45, NA_real_)) {
  prior <- evidence2 |>
    mutate(offense_snaps = if_else(mfl_id == "8" & week == 10, 0, offense_snaps),
      defense_snaps = if_else(mfl_id == "8" & week == 10, bench_snaps, defense_snaps),
      team_defense = if_else(mfl_id == "8" & week == 10, 100, team_defense))
  revised <- low_snap_review_rows(workload_team, prior, 11, archive, schedule, injury_sheet,
    fetch_scoring = score_history)
  stopifnot(any(grepl("Available Player Suggestion:", revised$details, fixed = TRUE)) == isTRUE(bench_snaps >= 45))
}
bye_evidence <- evidence2 |> filter(!(mfl_id %in% c("2", "8") & week == 10L))
bye_evidence <- bind_rows(bye_evidence, bye_evidence |> filter(week == 9L) |> mutate(week = 8L))
bye_scores <- bind_rows(efficiency_scores, efficiency_scores |> filter(week == 9L) |> mutate(week = 8L))
bye_replay <- function(data, byes) low_snap_review_rows(workload_team, data, 11, archive, schedule,
  injury_sheet, fetch_scoring = function(weeks) bye_scores, byes = byes)
with_bye <- bye_replay(bye_evidence, c(NYG = 10L))
stopifnot(any(grepl("22.0% in Week 9", with_bye$observed, fixed = TRUE)),
  any(grepl("76.0% in Week 9", with_bye$details, fixed = TRUE)),
  !any(grepl("Available Player Suggestion:", bye_replay(bye_evidence, integer())$details, fixed = TRUE)),
  !any(grepl("Available Player Suggestion:", bye_replay(
    mutate(bye_evidence, nfl_team = if_else(mfl_id == "8" & week == 9L, "BUF", nfl_team)),
    c(NYG = 10L))$details, fixed = TRUE)))
positions <- workload_team$player_pos
cb_slots <- head(which(positions == "CB"), 2L)
s_slots <- head(which(positions == "S"), 2L)
stopifnot(
  identical(adl_assign_snap_replacements(positions, cb_slots, list(1L, 1L), "one", "CB"),
    c(1L, NA_integer_)),
  identical(adl_assign_snap_replacements(positions, cb_slots, list(c(1L, 2L), 1L),
    c("one", "two"), c("CB", "CB")), c(2L, 1L)),
  identical(adl_assign_snap_replacements(positions, cb_slots, list(1L, 2L),
    c("one", "one"), c("CB", "CB")), c(1L, NA_integer_)),
  identical(adl_assign_snap_replacements(positions, s_slots, list(1L, 2L),
    c("one", "two"), c("LB", "LB")), c(1L, NA_integer_))
)
mail <- render_final_lineup_review_lines(final_lineup_review_digest(low_review))
stopifnot(sum(mail == "Low-snap starters to review (3)") == 1L,
  any(grepl("no strike", mail, fixed = TRUE)), any(grepl("24.0% of team defense snaps", mail, fixed = TRUE)))
cat("Consecutive low snap share, identity, position, and advisory-only regressions passed.\n")

bal_buf <- tibble(season = 2026, game_type = "REG", game_id = "2026_08_BAL_BUF", week = 8L,
  pfr_player_id = c("a", "b", "c", "d", "anchor"), team = c(rep("BAL", 4), "BUF"),
  opponent = c(rep("BUF", 4), "BAL"), offense_snaps = c(51, 42, 11, 3, 82),
  offense_pct = c(1, .82, .22, .40, 1), defense_snaps = c(82, 0, 0, 0, 51),
  defense_pct = c(1, 0, 0, 0, 1))
verified_bal <- prepare_adl_snap_evidence(bal_buf, players, 2026)
stopifnot(all(verified_bal$team_offense == 51), identical(verified_bal$offense_snaps, c(51, 42, 11, NA_real_)))
bad_reciprocal <- bal_buf |> mutate(opponent = if_else(team == "BUF", "NYG", opponent))
two_outliers <- bal_buf |> mutate(offense_pct = if_else(pfr_player_id == "c", .8, offense_pct))
stopifnot(all(is.na(prepare_adl_snap_evidence(bad_reciprocal, players, 2026)$team_offense)),
          all(is.na(prepare_adl_snap_evidence(two_outliers, players, 2026)$team_offense)))
cat("Reciprocal opponent snap totals and bad-row isolation regressions passed.\n")
