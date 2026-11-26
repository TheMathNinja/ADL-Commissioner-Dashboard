adl_snap_team_total <- function(count, share) {
  observed <- is.finite(count) & count >= 0 & count == floor(count) &
    is.finite(share) & share >= 0 & share <= 1
  count <- count[observed]
  share <- share[observed]
  if (!any(share > 0) || any(count == 0 & share > 0)) return(NA_real_)

  # PFR reports whole percentages; require a unique team total consistent with all rows.
  half_point <- 0.005 + 1e-10
  lower <- max(1, count, ceiling(count / (share + half_point)))
  positive <- share > 0
  upper <- min(floor(count[positive] / (share[positive] - half_point)))
  if (lower == upper) lower else NA_real_
}

prepare_adl_snap_evidence <- function(snaps, player_ids, season) {
  crosswalk <- player_ids |>
    transmute(mfl_id = as.character(.data$mfl_id), pfr_id = as.character(.data$pfr_id)) |>
    filter(!is.na(.data$mfl_id), grepl("^[0-9]+$", .data$mfl_id), !is.na(.data$pfr_id), nzchar(.data$pfr_id)) |>
    distinct() |>
    add_count(.data$mfl_id, name = "mfl_matches") |>
    add_count(.data$pfr_id, name = "pfr_matches") |>
    filter(.data$mfl_matches == 1L, .data$pfr_matches == 1L) |>
    select("mfl_id", "pfr_id")
  snaps |>
    filter(.data$season == .env$season, .data$game_type == "REG", !is.na(.data$game_id), nzchar(.data$game_id)) |>
    transmute(week = as.integer(.data$week), pfr_id = as.character(.data$pfr_player_id),
              nfl_team = mfl_player_team(.data$team), game_id = as.character(.data$game_id),
              offense_snaps, defense_snaps, offense_pct, defense_pct) |>
    group_by(.data$game_id, .data$nfl_team) |>
    mutate(team_offense = adl_snap_team_total(.data$offense_snaps, .data$offense_pct),
           team_defense = adl_snap_team_total(.data$defense_snaps, .data$defense_pct)) |>
    ungroup() |>
    inner_join(crosswalk, by = "pfr_id", relationship = "many-to-one") |>
    distinct() |>
    group_by(.data$mfl_id, .data$week) |>
    filter(n() == 1L) |>
    ungroup()
}

adl_low_snap_starters <- function(lineups, evidence, week, threshold = 0.30) {
  if (week < 2L || !nrow(lineups) || !nrow(evidence)) return(tibble())
  starters <- lineups |>
    mutate(unit = case_when(
      toupper(.data$player_pos) %in% c("QB", "RB", "WR", "TE") ~ "offense",
      toupper(.data$player_pos) %in% c("DT", "DE", "LB", "CB", "S") ~ "defense",
      TRUE ~ NA_character_
    )) |>
    filter(!is.na(.data$unit))
  evidence_key <- paste(evidence$mfl_id, evidence$week)
  current <- match(paste(starters$player_id, week), evidence_key)
  previous <- match(paste(starters$player_id, week - 1L), evidence_key)
  pick_share <- function(indices) {
    offense <- evidence$offense_snaps[indices]
    defense <- evidence$defense_snaps[indices]
    denominator <- ifelse(starters$unit == "offense", evidence$team_offense[indices], evidence$team_defense[indices])
    valid <- is.finite(offense) & offense >= 0 & offense == floor(offense) &
      is.finite(defense) & defense >= 0 & defense == floor(defense)
    ifelse(valid, (offense + defense) / denominator, NA_real_)
  }
  starters |>
    mutate(week = .env$week, previous_week = .env$week - 1L,
           current_share = .env$pick_share(current), previous_share = .env$pick_share(previous),
           nfl_team_at_game = evidence$nfl_team[current]) |>
    filter(!is.na(.data$nfl_team_at_game), .data$nfl_team_at_game != "FA",
           !is.na(evidence$nfl_team[previous]), evidence$nfl_team[previous] != "FA",
           is.finite(.data$current_share), is.finite(.data$previous_share),
           .data$current_share >= 0, .data$current_share < .env$threshold,
           .data$previous_share >= 0, .data$previous_share < .env$threshold) |>
    distinct(.data$franchise, .data$player_id, .keep_all = TRUE)
}

load_adl_snap_evidence <- function(season) {
  prepare_adl_snap_evidence(nflreadr::load_snap_counts(season), nflreadr::load_ff_playerids(), season)
}

low_snap_review_rows <- function(lineups, evidence, week) {
  flagged <- adl_low_snap_starters(lineups, evidence, week)
  if (!nrow(flagged)) return(tibble())
  flagged |>
    transmute(week = as.character(.data$week), conference, franchise, franchise_name,
      outcome = "Low snap share",
      observed = sprintf("%s %s %s: %.1f%% of team %s snaps in Week %s; %.1f%% in Week %d.",
                         .data$player_name, .data$nfl_team_at_game, .data$player_pos, 100 * .data$current_share,
                         .data$unit, .data$week, 100 * .data$previous_share, .data$previous_week),
      details = "")
}
