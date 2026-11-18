# Role and availability evidence is reviewed, never inferred from a zero score.
read_backup_lineup_opportunities <- function(season) {
  path <- Sys.getenv("ADL_BACKUP_LINEUP_OPPORTUNITIES", unset = file.path(
    "data", "source", paste0("backup_lineup_opportunities_", season, ".csv")))
  if (!file.exists(path)) return(tibble())
  rows <- read_csv(path, col_types = cols(.default = col_character()), show_col_types = FALSE)
  required <- c("season", "week", "franchise", "franchise_id", "conference", "franchise_name",
    "backup_player_id", "backup_player_name", "alternative_player_id", "alternative_player_name",
    "auction_franchise_id", "opened_at", "closed_at", "role_source", "availability_source", "reviewed_by")
  if (!all(required %in% names(rows)) || anyNA(rows[required]) ||
      any(!nzchar(trimws(as.matrix(rows[required]))))) stop("Incomplete backup-lineup opportunity evidence.")
  rows |> filter(.data$season == as.character(.env$season))
}

fetch_backup_lineup_transactions <- function(season) {
  content <- ffscrapr::mfl_getendpoint(connect_adl_mfl(season), "transactions")[["content"]]
  raw <- content[["transactions"]][["transaction"]]
  records <- list_records(raw, record_names = c("type", "timestamp", "franchise", "transaction"))
  if (!length(records)) stop("Missing auction history for backup-lineup check.")
  tibble(
    type = vapply(records, record_field, character(1), name = "type"),
    timestamp = vapply(records, record_field, character(1), name = "timestamp"),
    franchise = vapply(records, record_field, character(1), name = "franchise"),
    transaction = vapply(records, record_field, character(1), name = "transaction")
  )
}

evaluate_backup_lineup_inactivity <- function(season = get_current_season(), run_time = Sys.time(),
  opportunities = read_backup_lineup_opportunities(season), fetch_transactions = fetch_backup_lineup_transactions,
  fetch_lineups = fetch_live_lineups, fetch_kickoffs = read_nfl_team_kickoffs) {
  if (!nrow(opportunities)) return(empty_inseason_inactivity_rows())
  current_week <- commissioner_alert_status_week(season = season, checked_at = run_time)
  candidates <- opportunities |>
    filter(as.integer(.data$week) < .env$current_week)
  if (!nrow(candidates)) return(empty_inseason_inactivity_rows())
  ids <- adl_franchise_id_lookup()
  for (i in seq_len(nrow(candidates))) {
    row <- candidates[i, ]
    team <- match(row$franchise_id, ids$franchise_id)
    winner <- match(row$auction_franchise_id, ids$franchise_id)
    conference <- if (!is.na(team) && team <= 16L) "NFC" else "AFC"
    if (is.na(team) || is.na(winner) || ids$franchise[team] != row$franchise ||
        row$conference != conference || (team <= 16L) != (winner <= 16L)) {
      stop("Acquisition opportunity must be in the franchise's own conference.")
    }
  }
  tx <- fetch_transactions(season)
  required <- c("type", "timestamp", "franchise", "transaction")
  if (!all(required %in% names(tx)) || !nrow(tx)) stop("Missing backup-lineup auction evidence.")
  tx$occurred_at <- as.POSIXct(suppressWarnings(as.numeric(tx$timestamp)), origin = "1970-01-01", tz = "UTC")
  auction <- tx$type %in% c("AUCTION_INIT", "AUCTION_BID", "AUCTION_WON")
  if (anyNA(tx$occurred_at[auction]) || anyNA(tx$transaction[auction]) || anyNA(tx$franchise[auction])) {
    stop("Invalid backup-lineup auction evidence.")
  }
  verified <- lapply(seq_len(nrow(candidates)), function(i) {
    row <- candidates[i, ]
    week <- as.integer(row$week)
    last_kickoff <- lineup_week_last_kickoff(fetch_kickoffs(season = season, week = week))
    if (is.na(last_kickoff)) stop("Missing kickoff evidence for backup-lineup check.")
    if (run_time < last_kickoff) return(tibble())
    lineups <- fetch_lineups(season = season, week = week)
    selected <- lineups |> filter(.data$franchise == row$franchise[[1]])
    if (!nrow(selected) || anyNA(selected$player_id) || anyDuplicated(selected$player_id)) {
      stop("Incomplete final lineup evidence for backup-lineup check.")
    }
    if (!row$backup_player_id %in% selected$player_id) return(tibble())
    opened <- as.POSIXct(row$opened_at, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    closed <- as.POSIXct(row$closed_at, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    if (is.na(opened) || is.na(closed) || opened >= closed || closed > last_kickoff) {
      stop("Invalid reviewed acquisition window.")
    }
    history <- tx[auction & !is.na(tx$occurred_at) & tx$occurred_at >= opened & tx$occurred_at <= closed &
      startsWith(coalesce(tx$transaction, ""), paste0(row$alternative_player_id, "|")), ]
    # Both boundaries must exist; a partial feed cannot establish no attempt.
    if (!any(history$type == "AUCTION_INIT" & history$franchise == row$auction_franchise_id & history$occurred_at == opened) ||
        !any(history$type == "AUCTION_WON" & history$franchise == row$auction_franchise_id & history$occurred_at == closed)) {
      stop("Reviewed auction boundaries not verified by MFL.")
    }
    direct <- history$franchise == row$franchise_id & history$type %in% c("AUCTION_INIT", "AUCTION_BID", "AUCTION_WON")
    # MFL sometimes records the leading bidder, naming the losing bidder only in the annotation.
    annotation <- vapply(strsplit(history$transaction, "|", fixed = TRUE), function(parts) {
      if (length(parts) < 3L) "" else paste(parts[-c(1L, 2L)], collapse = "|")
    }, character(1))
    proxy <- trimws(annotation) == paste(row$franchise_name, "forced bid increase")
    ambiguous_attempt <- grepl(row$franchise_name, annotation, fixed = TRUE)
    if (any(direct | proxy | ambiguous_attempt)) return(tibble())
    tibble(
      alert_type = "In-Season Inactivity Violation", severity = "violation",
      conference = row$conference, franchise = row$franchise, franchise_name = row$franchise_name,
      week = as.character(week), violation_category = "Illegal Lineup",
      rule = "Do not start a non-playing backup without pursuing an available active alternative (ADL V-A; XV-B)",
      observed = paste0("Week ", week, " final lineup started ", row$backup_player_name,
        "; no recorded acquisition attempt for ", row$alternative_player_name, " during the reviewed available auction."),
      details = paste0("Availability/role reviewed by ", row$reviewed_by, ". Auction: ", row$opened_at,
        " to ", row$closed_at, ". Sources: ", row$role_source, "; ", row$availability_source,
        ". Unsuccessful recorded bids are exempt. Commissioner review/correction required; no roster changes were made."),
      violation_key = paste("illegal_lineup", season, row$franchise, week, sep = "|"), season_phase = "inseason"
    )
  })
  result <- bind_rows(verified)
  if (!nrow(result)) empty_inseason_inactivity_rows() else result
}
