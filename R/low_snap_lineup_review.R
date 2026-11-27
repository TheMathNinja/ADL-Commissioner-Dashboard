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

adl_snap_matches_total <- function(count, share, total) {
  is.finite(total) & total > 0 & is.finite(count) & count >= 0 & count <= total &
    count == floor(count) & is.finite(share) & share >= 0 & share <= 1 &
    abs(count / total - share) <= 0.005 + 1e-10
}

adl_snap_corroborates_total <- function(count, share, total) {
  usable <- is.finite(count) & is.finite(share)
  matches <- adl_snap_matches_total(count, share, total)
  sum(matches & count > 0, na.rm = TRUE) >= 3L &&
    sum(usable & !matches) <= 1L && !any(is.finite(count) & count > total)
}

prepare_adl_snap_evidence <- function(snaps, player_ids, season) {
  snaps$snap_pos <- snaps[["position"]] %||% rep(NA_character_, nrow(snaps))
  snaps$st_snaps <- snaps[["st_snaps"]] %||% rep(NA_real_, nrow(snaps))
  crosswalk <- player_ids |>
    transmute(mfl_id = as.character(.data$mfl_id), pfr_id = as.character(.data$pfr_id)) |>
    filter(!is.na(.data$mfl_id), grepl("^[0-9]+$", .data$mfl_id), !is.na(.data$pfr_id), nzchar(.data$pfr_id)) |>
    distinct() |>
    add_count(.data$mfl_id, name = "mfl_matches") |>
    add_count(.data$pfr_id, name = "pfr_matches") |>
    filter(.data$mfl_matches == 1L, .data$pfr_matches == 1L) |>
    select("mfl_id", "pfr_id")
  rows <- snaps |>
    filter(.data$season == .env$season, .data$game_type == "REG", !is.na(.data$game_id), nzchar(.data$game_id)) |>
    transmute(week = as.integer(.data$week), pfr_id = as.character(.data$pfr_player_id),
              nfl_team = mfl_player_team(.data$team), game_id = as.character(.data$game_id),
              opponent = mfl_player_team(.data$opponent),
              offense_snaps, defense_snaps, offense_pct, defense_pct, snap_pos, st_snaps)
  specialist_totals <- rows |>
    filter(.data$snap_pos %in% c("K", "P")) |>
    distinct(.data$game_id, .data$nfl_team, .data$snap_pos, .data$pfr_id, .data$st_snaps) |>
    group_by(.data$game_id, .data$nfl_team, .data$snap_pos) |>
    summarize(team_role = if (!anyDuplicated(.data$pfr_id) && all(is.finite(.data$st_snaps) &
      .data$st_snaps >= 0 & .data$st_snaps == floor(.data$st_snaps))) sum(.data$st_snaps) else NA_real_,
      .groups = "drop")
  totals <- rows |>
    group_by(.data$game_id, .data$nfl_team) |>
    summarize(opponent = if (n_distinct(.data$opponent) == 1L) first(.data$opponent) else NA_character_,
              team_offense = adl_snap_team_total(.data$offense_snaps, .data$offense_pct),
              team_defense = adl_snap_team_total(.data$defense_snaps, .data$defense_pct), .groups = "drop")
  counterparts <- totals |>
    filter(!is.na(.data$opponent), !is.na(.data$nfl_team), .data$nfl_team != .data$opponent) |>
    select(game_id, other_team = nfl_team, nfl_team = opponent,
           opposing_offense = team_offense, opposing_defense = team_defense) |>
    rename(opponent = other_team)
  totals <- left_join(totals, counterparts, by = c("game_id", "nfl_team", "opponent"),
                      relationship = "one-to-one", na_matches = "never") |>
    select(-"opponent")
  rows |>
    left_join(totals, by = c("game_id", "nfl_team"), relationship = "many-to-one") |>
    group_by(.data$game_id, .data$nfl_team) |>
    mutate(
      # The reciprocal opponent's verified unit can corroborate a total despite one bad row.
      use_opposing_defense = all(is.na(.data$team_offense)) && is.finite(first(.data$opposing_defense)) &&
        adl_snap_corroborates_total(.data$offense_snaps, .data$offense_pct, first(.data$opposing_defense)),
      use_opposing_offense = all(is.na(.data$team_defense)) && is.finite(first(.data$opposing_offense)) &&
        adl_snap_corroborates_total(.data$defense_snaps, .data$defense_pct, first(.data$opposing_offense)),
      team_offense = if_else(.data$use_opposing_defense, .data$opposing_defense, .data$team_offense),
      team_defense = if_else(.data$use_opposing_offense, .data$opposing_offense, .data$team_defense),
      offense_snaps = if_else(.data$use_opposing_defense &
        !adl_snap_matches_total(.data$offense_snaps, .data$offense_pct, .data$team_offense), NA_real_, .data$offense_snaps),
      defense_snaps = if_else(.data$use_opposing_offense &
        !adl_snap_matches_total(.data$defense_snaps, .data$defense_pct, .data$team_defense), NA_real_, .data$defense_snaps)
    ) |>
    ungroup() |>
    select(week, pfr_id, nfl_team, game_id, offense_snaps, defense_snaps, offense_pct, defense_pct,
           team_offense, team_defense, snap_pos, st_snaps) |>
    left_join(specialist_totals, by = c("game_id", "nfl_team", "snap_pos"), relationship = "many-to-one") |>
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

adl_legal_snap_swap <- function(positions, remove, add) {
  slot <- match(remove, positions)
  if (is.na(slot)) return(FALSE)
  positions[slot] <- add
  adl_legal_snap_positions(positions)
}

adl_legal_snap_positions <- function(positions) {
  rules <- adl_lineup_position_rules()
  if (length(positions) != 21L || !all(positions %in% rules$player_pos)) return(FALSE)
  counts <- tabulate(match(positions, rules$player_pos), nrow(rules))
  groups <- adl_lineup_group_rules()
  all(counts >= rules$min_starters & counts <= rules$max_starters) &&
    all(vapply(groups$lineup_group, function(unit) sum(counts[rules$lineup_group == unit]), integer(1)) ==
      groups$required_starters)
}

adl_assign_snap_replacements <- function(positions, slots, candidates, bench_ids, bench_pos) {
  active <- which(lengths(candidates) > 0L)
  best <- rep(NA_integer_, length(slots))
  best_count <- 0L
  # Try the lowest-workload starters and their strongest alternatives first,
  # but backtrack if that would prevent a larger legal set of distinct swaps.
  search <- function(index, selected, used, assigned, remaining_positions) {
    if (index > length(active)) {
      if (assigned > best_count && adl_legal_snap_positions(remaining_positions)) {
        best <<- selected
        best_count <<- assigned
      }
      return(invisible(NULL))
    }
    remaining <- active[seq.int(index, length(active))]
    unused <- setdiff(unique(bench_ids[unlist(candidates[remaining])]), used)
    if (assigned + min(length(remaining), length(unused)) <= best_count) return(invisible(NULL))
    i <- active[index]
    for (j in candidates[[i]][!bench_ids[candidates[[i]]] %in% used]) {
      selected[i] <- j
      next_positions <- remaining_positions
      next_positions[slots[i]] <- bench_pos[j]
      search(index + 1L, selected, c(used, bench_ids[j]), assigned + 1L, next_positions)
    }
    selected[i] <- NA_integer_
    search(index + 1L, selected, used, assigned, remaining_positions)
  }
  search(1L, best, character(), 0L, positions)
  best
}

adl_snap_workload <- function(rows, positions) {
  off <- positions %in% c("QB", "RB", "WR", "TE")
  specialist <- positions %in% c("PK", "PN")
  role_matches <- rows$snap_pos %in% c("K", "P") &
    rows$snap_pos == ifelse(positions == "PK", "K", "P")
  count <- ifelse(specialist, ifelse(role_matches, rows$st_snaps, NA_real_),
    rows$offense_snaps + rows$defense_snaps)
  total <- ifelse(specialist, rows$team_role, ifelse(off, rows$team_offense, rows$team_defense))
  list(count = count, share = ifelse(is.finite(count) & count >= 0 & is.finite(total) & total > 0,
    count / total, NA_real_))
}

adl_snap_unavailable <- function(x) {
  x <- toupper(trimws(coalesce(as.character(x), "")))
  inactive_designation(x) | x %in% c("DOUBTFUL", "D", "(D)", "BYE", "INACTIVE")
}

adl_snap_bid_details <- function(player, tx, evidence, week, deadline, kickoff) {
  if (!is.finite(as.numeric(deadline)) || !nrow(tx)) return("Free-agency effort could not be verified.")
  position <- c(QB = "QB", PK = "K", PN = "P")[[player$player_pos]]
  peers <- evidence[evidence$week == week & evidence$snap_pos %in% position &
    !evidence$mfl_id %in% player$player_id, , drop = FALSE]
  usage <- adl_snap_workload(peers, rep(player$player_pos, nrow(peers)))
  peer_kickoffs <- unname(kickoff[peers$nfl_team])
  ids <- peers$mfl_id[which(usage$share >= .30 & peer_kickoffs > deadline - 7 * 86400)]
  occurred <- suppressWarnings(as.numeric(tx$timestamp))
  parts <- strsplit(coalesce(tx$transaction, ""), "|", fixed = TRUE)
  target <- vapply(parts, function(p) if (length(p)) p[[1]] else "", "")
  proxy <- vapply(parts, function(p) length(p) == 3L &&
    trimws(p[[3]]) == paste(player$franchise_name, "forced bid increase"), logical(1))
  target_team <- peers$nfl_team[match(target, peers$mfl_id)]
  attempts <- tx$type %in% c("AUCTION_INIT", "AUCTION_BID", "AUCTION_WON", "FREE_AGENT", "WAIVER", "BBID_WAIVER") &
    (tx$franchise %in% player$franchise_id | proxy) & target %in% ids &
    occurred >= as.numeric(deadline) - 7 * 86400 & occurred < as.numeric(deadline) &
    occurred < as.numeric(kickoff[target_team])
  if (any(attempts, na.rm = TRUE)) {
    return(sprintf("Recorded MFL acquisition activity for %d higher-workload %s option(s) before kickoff.",
      length(unique(target[which(attempts)])), player$player_pos))
  }
  "No matching attempt found in the public MFL records checked; this does not establish that no bid was made or that an affordable option was available."
}

low_snap_review_rows <- function(lineups, evidence, week, history = tibble(), kickoffs = tibble(),
    final_designations = tibble(), fetch_transactions = function() tibble()) {
  if (!nrow(lineups) || !nrow(evidence) || !nrow(kickoffs)) return(tibble())
  threshold <- 0.30
  special_pos <- c("QB", "PK", "PN")
  current <- match(lineups$player_id, evidence$mfl_id[evidence$week == week])
  current <- evidence[evidence$week == week, , drop = FALSE][current, , drop = FALSE]
  workload <- adl_snap_workload(current, lineups$player_pos)
  special_idx <- which(lineups$player_pos %in% special_pos & workload$share < threshold)
  kickoff <- setNames(kickoffs$kickoff_at, mfl_player_team(kickoffs$player_team))
  bench <- attr(lineups, "mfl_bench")
  roster_history <- if ("roster_status" %in% names(history)) {
    history[!is.na(history$roster_status) & !is.na(history$snapshot_time), , drop = FALSE]
  } else tibble()
  injury_risk <- function(status) {
    toupper(trimws(coalesce(as.character(status), ""))) %in% c("Q", "(Q)", "QUESTIONABLE")
  }
  observed_roster <- function(player, deadline, team, specialist = FALSE) {
    if (!nrow(roster_history) || is.na(deadline)) return(FALSE)
    rows <- roster_history[which(roster_history$conference == player$conference &
      roster_history$franchise == player$franchise &
      roster_history$snapshot_time <= deadline & roster_history$snapshot_time > deadline - 8 * 3600), ]
    if (!nrow(rows)) return(FALSE)
    rows <- rows[which(rows$snapshot_time == max(rows$snapshot_time) & rows$player_id == player$player_id), ]
    if (!nrow(rows) || !all(mfl_player_team(rows$player_team) %in% team) ||
        !all(toupper(rows$player_pos) %in% player$player_pos) ||
        !all(toupper(rows$roster_status) %in% "ACTIVE")) return(FALSE)
    injury <- if (nrow(history)) history[which(history$conference == player$conference &
      history$player_id == player$player_id & history$snapshot_time >= max(rows$snapshot_time) &
      history$snapshot_time <= deadline), ] else tibble()
    !any(adl_snap_unavailable(injury$player_status)) &&
      !(specialist && any(injury_risk(injury$player_status)))
  }
  row <- function(player, observed, details) tibble(week = as.character(week),
    conference = player$conference, franchise = player$franchise, franchise_name = player$franchise_name,
    outcome = "Low snap share", observed = observed, details = details)
  flagged <- adl_low_snap_starters(lineups, evidence, week, threshold = threshold)
  if (nrow(flagged)) flagged <- flagged[!flagged$player_pos %in% special_pos, , drop = FALSE]
  replacement_rows <- if (nrow(flagged) && !is.null(bench) && nrow(bench) && nrow(roster_history)) {
    bench_current <- evidence[evidence$week == week, , drop = FALSE]
    bench_current <- bench_current[match(bench$player_id, bench_current$mfl_id), , drop = FALSE]
    bench_load <- adl_snap_workload(bench_current, bench$player_pos)
    raw <- current$offense_snaps + current$defense_snaps
    bind_rows(lapply(split(flagged, flagged$franchise_id), function(team_flags) {
      team_flags <- arrange(team_flags, .data$current_share, .data$previous_share, .data$player_id)
      team_rows <- which(lineups$franchise_id %in% team_flags$franchise_id[1])
      starters <- lineups[team_rows, ]
      if (anyNA(starters$player_id) || anyDuplicated(starters$player_id)) return(NULL)
      slots <- match(team_flags$player_id, starters$player_id)
      if (anyNA(slots)) return(NULL)
      candidates <- lapply(seq_len(nrow(team_flags)), function(i) {
        player <- team_flags[i, ]
        first <- unname(kickoff[player$nfl_team_at_game])
        if (is.na(first)) return(integer())
        possible <- which(bench$franchise_id %in% player$franchise_id & !is.na(bench$player_id) &
          !bench$player_id %in% starters$player_id & bench_load$count > raw[team_rows[slots[i]]] &
          bench_load$share > threshold)
        possible <- possible[order(-bench_load$share[possible], -bench_load$count[possible], bench$player_id[possible])]
        possible[vapply(possible, function(j) {
          alt <- bench[j, ]
          nfl_team <- bench_current$nfl_team[j]
          other <- unname(kickoff[nfl_team])
          !is.na(other) && adl_legal_snap_swap(starters$player_pos, player$player_pos, alt$player_pos) &&
            observed_roster(player, min(first, other), player$nfl_team_at_game) &&
            observed_roster(alt, min(first, other), nfl_team)
        }, logical(1))]
      })
      assigned <- adl_assign_snap_replacements(starters$player_pos, slots, candidates, bench$player_id, bench$player_pos)
      bind_rows(lapply(which(!is.na(assigned)), function(i) {
        j <- assigned[i]
        player <- team_flags[i, ]
        alt <- bench[j, ]
        return(row(player, sprintf("%s %s %s: %.1f%% of team %s snaps in Week %d; %.1f%% in Week %d.",
          player$player_name, player$nfl_team_at_game, player$player_pos, 100 * player$current_share,
          player$unit, week, 100 * player$previous_share, player$previous_week),
          sprintf("Verified legal bench swap: %s %s %s (%d snaps, %.1f%%, vs. %d snaps).",
            alt$player_name, bench_current$nfl_team[j], alt$player_pos, bench_load$count[j],
            100 * bench_load$share[j], raw[team_rows[slots[i]]])))
      }))
    }))
  } else tibble()
  injured <- function(player) {
    report <- final_designations[which(final_designations$player_id %in% player$player_id), , drop = FALSE]
    any(adl_snap_unavailable(report$player_status) | injury_risk(report$player_status))
  }
  tx <- NULL
  specialist_rows <- bind_rows(lapply(special_idx, function(i) {
    player <- lineups[i, ]
    team <- current$nfl_team[i]
    deadline <- unname(kickoff[team])
    if (is.na(deadline) || !nrow(final_designations) || injured(player) ||
        !observed_roster(player, deadline, team, specialist = TRUE)) return(NULL)
    if (is.null(tx)) tx <<- tryCatch(fetch_transactions(), error = function(e) tibble())
    unit <- if (player$player_pos == "QB") "team offense snaps" else paste0("team's ", player$player_pos, " snaps")
    row(player, sprintf("%s %s %s: %d snaps, %.1f%% of %s in Week %d.",
      player$player_name, team, player$player_pos, workload$count[i], 100 * workload$share[i], unit, week),
      paste("No inactive designation found at kickoff or in the weekly report; an in-game injury is not ruled out.",
        adl_snap_bid_details(player, tx, evidence, week, deadline, kickoff)))
  }))
  bind_rows(replacement_rows, specialist_rows)
}
