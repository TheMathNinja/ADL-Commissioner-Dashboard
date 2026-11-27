final_lineup_time <- function(value) {
  if (inherits(value, "POSIXt")) return(as.POSIXct(value))
  value <- as.character(value)
  explicit_zone <- grepl(" (EST|EDT)$", value)
  time <- as.POSIXct(value, format = "%Y-%m-%d %H:%M:%S", tz = "America/New_York")
  if (any(explicit_zone)) {
    zoned <- sub(" EST$", " -0500", sub(" EDT$", " -0400", value[explicit_zone]))
    time[explicit_zone] <- as.POSIXct(zoned, format = "%Y-%m-%d %H:%M:%S %z", tz = "UTC")
  }
  time
}

review_inactive_starter <- function(history, kickoff, submitted, submission_status, grace_hours) {
  if (!nrow(history)) return(NULL)
  if (is.na(kickoff)) {
    if (any(inactive_designation(history$player_status))) {
      return(list(outcome = "Needs review", reason = "Kickoff could not be verified.", evidence = ""))
    }
    return(NULL)
  }
  # These are observation timestamps, not the NFL announcement timestamps.
  history <- history |>
    filter(!is.na(.data$snapshot_time), !is.na(.data$player_status), nzchar(.data$player_status),
           .data$snapshot_time <= .env$kickoff) |>
    arrange(.data$snapshot_time)
  if (!nrow(history) || !inactive_designation(tail(history$player_status, 1))) return(NULL)

  available <- which(!inactive_designation(history$player_status))
  last_available_row <- if (length(available)) tail(available, 1) else 0L
  last_available <- if (last_available_row) history$snapshot_time[last_available_row] else as.POSIXct(NA)
  first_out <- history$snapshot_time[last_available_row + 1L]
  prior_status <- if (last_available_row) history$player_status[last_available_row] else "unverified"
  deadline <- kickoff - grace_hours * 3600
  gm_stamp <- identical(submission_status, "submitted") && !is.na(submitted)
  # The report's submission stamp has minute precision. Require an entire
  # minute on either side when ordering it against a snapshot.
  post_notice <- gm_stamp && submitted > first_out && submitted + 60 <= kickoff
  left_in_place <- gm_stamp && !is.na(last_available) && submitted + 60 <= last_available
  outcome <- if (first_out < deadline || post_notice) {
    "Violation"
  } else if (!is.na(last_available) && last_available >= deadline && left_in_place) {
    "Excused"
  } else {
    "Needs review"
  }
  stamp <- function(time) if (is.na(time)) "unverified" else format(time, "%b %d %H:%M:%S %Z", tz = "America/New_York")
  reason <- if (post_notice) {
    "GM submitted after the player was confirmed inactive and before kickoff."
  } else if (first_out < deadline) {
    paste0("Player was already inactive more than ", grace_hours, " hours before kickoff.")
  } else if (outcome == "Excused") {
    paste0("Became inactive within ", grace_hours, " hours of kickoff and the GM left the lineup in place.")
  } else if (!is.na(last_available) && last_available < deadline) {
    paste0("The designation changed between snapshots that bracket the ", grace_hours,
           "-hour cutoff (", stamp(deadline), "). The snapshots do not show which side of the cutoff it changed on.")
  } else if (!gm_stamp || submitted >= kickoff) {
    "A GM submission before kickoff could not be verified."
  } else if (is.na(last_available)) {
    "No earlier available designation was archived to establish when inactivity began."
  } else {
    "The GM submission falls within or too close to the observed designation-change window to order the events."
  }
  list(outcome = outcome, post_notice = post_notice, reason = reason, evidence = paste0(
    "Prior designation: ", prior_status, " (", stamp(last_available), "). Inactive observed: ", stamp(first_out),
    ". Last GM submission: ", if (gm_stamp) stamp(submitted) else "unverified",
    ". Kickoff: ", stamp(kickoff), "."))
}

build_final_lineup_review <- function(lineups, kickoffs, history, submissions, byes, week,
    final_designations = tibble(), grace_hours = lineup_designation_grace_hours()) {
  if (!nrow(lineups)) return(tibble())
  if (is.null(history)) history <- tibble()
  if (nrow(history)) history$player_team <- mfl_player_team(history$player_team)
  if (nrow(history)) history <- split(history, paste(history$conference, history$player_id))
  by_team <- setNames(kickoffs$kickoff_at, mfl_player_team(kickoffs$player_team))
  final_inactives <- if (nrow(final_designations)) {
    final_designations |> filter(inactive_designation(.data$player_status))
  } else tibble()

  bind_rows(lapply(split(lineups, lineups$franchise_id), function(team) {
    club <- team[1, ]
    if (is.na(club$franchise[[1]]) || is.na(club$conference[[1]])) return(tibble())
    stamp <- if (nrow(submissions)) {
      submissions[submissions$franchise %in% club$franchise &
                    submissions$conference %in% club$conference, , drop = FALSE]
    } else tibble()
    submitted <- if (nrow(stamp) == 1L) final_lineup_time(stamp$submitted_at[[1]]) else as.POSIXct(NA)
    submission_status <- if (nrow(stamp) == 1L) stamp$submission_status[[1]] else "unknown"
    record <- function(outcome, observed, details = "") {
      tibble(week = as.character(week), conference = club$conference, franchise = club$franchise,
             franchise_name = club$franchise_name, outcome = outcome, observed = observed, details = details)
    }
    structural <- if (anyNA(team$player_pos) || any(!nzchar(team$player_pos)) || anyDuplicated(team$player_id)) {
      record("Needs review", "Final starter positions or player identities could not be verified.")
    } else {
      issues <- lineup_starter_count_alert_rows(club$franchise_id[[1]], nrow(team), team, 21L)
      if (nrow(issues)) record("Violation", issues$observed, issues$details) else tibble()
    }
    players <- bind_rows(lapply(seq_len(nrow(team)), function(i) {
      player <- team[i, ]
      score <- player[["player_score"]]
      if (length(score) && is.finite(score) && score != 0) return(tibble())
      archived <- history[[paste(player$conference, player$player_id)]]
      nfl_team <- mfl_player_team(player$player_team)[[1]]
      if (!is.null(archived)) {
        # Weekly roster archives can establish NFL team identity for a player
        # who changed NFL teams after the week being audited.
        archived_teams <- unique(archived$player_team[!is.na(archived$player_team) & archived$player_team != "FA"])
        if (length(archived_teams) == 1L) nfl_team <- archived_teams[[1]]
      }
      label <- paste(player$player_name, nfl_team, player$player_pos)
      reported_inactive <- nrow(final_inactives) && any(final_inactives$player_id %in% player$player_id &
        (is.na(final_inactives$player_team) | final_inactives$player_team %in% nfl_team))
      if (isTRUE(unname(byes[nfl_team]) == week)) {
        return(record("Needs review", paste(label, "started on bye."),
                      "Verify whether a healthy, active replacement was available before kickoff."))
      }
      if (!is.null(archived) && (length(archived_teams) > 1L || is.na(nfl_team) || nfl_team == "FA")) {
        if (any(inactive_designation(archived$player_status))) {
          return(record("Needs review", paste(label, "had an inactive designation."),
                        "NFL team identity could not be verified for this week."))
        }
        return(tibble())
      }
      if (!is.null(archived)) {
        archived <- archived |> filter(.data$player_team == .env$nfl_team)
        result <- review_inactive_starter(archived, unname(by_team[nfl_team]), submitted, submission_status, grace_hours)
        if (!is.null(result)) {
          if (result$outcome != "Needs review" && !reported_inactive) {
            return(record("Needs review", paste(label, "was marked inactive in an archived snapshot."),
              paste("The final weekly injury report did not confirm inactivity.", result$evidence)))
          }
          return(record(result$outcome, paste(label, "started while inactive."), paste(result$reason, result$evidence)))
        }
      }
      # The weekly MFL injury export can identify a player without a team field.
      if (reported_inactive) {
        prior <- if (is.null(archived) || !nrow(archived)) NA_character_ else {
          tail(archived |> filter(.data$snapshot_time <= unname(by_team[nfl_team])) |>
                 arrange(.data$snapshot_time) |> pull(.data$player_status), 1L)
        }
        return(record("Needs review", paste(label, "started and was listed inactive in the MFL weekly report."),
                      paste0("Last pre-kickoff designation: ", if (length(prior) && !is.na(prior)) prior else "unverified",
                             ". The final weekly report lists the player as inactive, but no inactive observation was archived before kickoff.")))
      }
      tibble()
    }))
    bind_rows(structural, players)
  }))
}

evaluate_final_lineup_review <- function(season, week, run_time, submissions,
    fetch_lineups = function(season, week) fetch_live_lineups(season, week, include_bench = TRUE),
    fetch_kickoffs = read_nfl_team_kickoffs,
    fetch_history = read_designation_snapshot_history, fetch_byes = read_bye_weeks,
    fetch_injuries = fetch_mfl_injury_payload, fetch_snap_evidence = load_adl_snap_evidence,
    fetch_transactions = fetch_backup_lineup_transactions, fetch_scoring = fetch_adl_snap_scoring) {
  if (is.na(week)) return(tibble())
  kickoffs <- fetch_kickoffs(season = season, week = week)
  last_kickoff <- lineup_week_last_kickoff(kickoffs)
  if (is.na(last_kickoff) || run_time < last_kickoff) return(tibble())
  if (!"game_complete" %in% names(kickoffs) || !isTRUE(all(kickoffs$game_complete))) return(tibble())
  lineups <- fetch_lineups(season = season, week = week)
  if (!nrow(lineups)) stop("MFL returned no starters for completed Week ", week, ".")
  history <- fetch_history(season, week)
  injuries <- tryCatch(
    normalize_mfl_injury_designations(fetch_injuries(season = season, week = week)),
    error = function(e) {
      warning("Weekly MFL injury report unavailable: ", conditionMessage(e), call. = FALSE)
      tibble()
    }
  )
  byes <- fetch_byes(season)
  review <- build_final_lineup_review(lineups, kickoffs, history, submissions, byes, week, injuries)
  if (week >= 2L) {
    snap_review <- tryCatch({
      evidence <- fetch_snap_evidence(season)
      coverage <- unique(evidence$nfl_team[evidence$week == week])
      list(rows = low_snap_review_rows(lineups, evidence, week, history, kickoffs, injuries,
        function() fetch_transactions(season, DAYS = max(14L, as.integer(difftime(Sys.time(),
          min(kickoffs$kickoff_at), units = "days")) + 9L)),
        function(weeks) fetch_scoring(season, weeks), byes),
           complete = all(mfl_player_team(kickoffs$player_team) %in% coverage))
    }, error = function(e) {
      warning("NFL snap-share evidence unavailable; leaving low-snap cases unverified.", call. = FALSE)
      list(rows = tibble(), complete = FALSE)
    })
    review <- bind_rows(review, snap_review$rows)
    if (!snap_review$complete) {
      review <- bind_rows(review, tibble(week = as.character(week), conference = NA_character_,
        franchise = NA_character_, franchise_name = "Snap-share coverage", outcome = "Snap coverage",
        observed = "NFL snap-count coverage was incomplete for this week.",
        details = "Missing counts are not zero. The general bench-swap screen requires two verified weeks."))
    }
  }
  if (is.null(history) || !nrow(history)) {
    review <- bind_rows(review, tibble(
      week = as.character(week), conference = NA_character_, franchise = NA_character_,
      franchise_name = "Final lineup evidence", outcome = "Needs review",
      observed = "No archived designations were available.",
      details = "The results and weekly injury report may establish lineup issues, but the timing of inactive designations cannot be verified."
    ))
  }
  review
}

final_lineup_review_violations <- function(review, season) {
  if (!nrow(review)) return(empty_inseason_inactivity_rows())
  review |>
    filter(.data$outcome == "Violation") |>
    transmute(
      alert_type = "In-Season Inactivity Violation", severity = "violation",
      conference, franchise, franchise_name, week, violation_category = "Illegal Lineup",
      rule = "GM must submit a legal weekly lineup",
      observed = paste0("Week ", .data$week, " final lineup: ", .data$observed),
      details, violation_key = paste("illegal_lineup", season, .data$franchise, .data$week, sep = "|"),
      season_phase = "inseason"
    )
}

final_lineup_review_digest <- function(review) {
  if (!nrow(review)) return(tibble())
  review |>
    transmute(
      alert_type = "Final Lineup Review",
      severity = "info", commissioner_only = TRUE, conference, franchise, franchise_name, week, review_outcome = outcome,
      rule = paste0("Week ", .data$week, " - ", .data$outcome), observed, details
    )
}

render_final_lineup_review_lines <- function(rows) {
  headings <- c(Violation = "Confirmed violations", Excused = "Excused inactivity", `Needs review` = "Needs review",
                `Low snap share` = "Low-snap starters to review", `Snap coverage` = "Snap-share coverage notice")
  lines <- c(paste0("Week ", paste(unique(rows$week), collapse = ", "),
                    ": ", sum(rows$review_outcome %in% "Violation"), " confirmed violation(s), ",
                    sum(rows$review_outcome %in% "Excused"), " excused, ",
                    sum(rows$review_outcome %in% "Needs review"), " needing review."), "")
  for (outcome in names(headings)) {
    selected <- rows[rows$review_outcome %in% outcome, , drop = FALSE]
    if (!nrow(selected)) next
    lines <- c(lines, paste0(headings[[outcome]], " (", nrow(selected), ")"),
      if (outcome == "Low snap share") paste(
        "Screening only; no strike. Skill and defensive starters must be below 30% in the reviewed game",
        "and their previous scheduled game, with a verified legal bench replacement at 45% or higher",
        "in their own two games. An NFL bye is skipped, not counted as zero.",
        "Cross-position swaps must also imply more ADL points at the reviewed week's observed workloads,",
        "using season-to-date points per snap from before that week (at least two verified games per player).",
        "Each replacement is used at most once per franchise, and the swaps must leave a legal combined lineup.",
        "QB, PK and PN are checked separately for current-week usage and recorded acquisition efforts;",
        "no bench alternative is required. PK/PN share compares snaps among players at the same position on their NFL team."),
      unlist(lapply(seq_len(nrow(selected)), function(i) {
        row <- selected[i, ]
        team <- if (is.na(row$franchise) || !nzchar(row$franchise)) row$franchise_name else
          paste0(row$franchise, " (", row$conference, ")")
        c(paste0("- ", team, " - ", row$observed),
          if (!is.na(row$details) && nzchar(row$details)) paste0("  ", row$details))
      })), "")
  }
  lines
}
