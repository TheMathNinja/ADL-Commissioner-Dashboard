# NFL Realism Report: immutable historical roster snapshots and explicit estimates.
nfl_realism_positions <- function() c("QB", "RB", "WR", "TE", "PK", "PN", "DT", "DE", "LB", "CB", "S", "OL", "LS", "UNMAPPED")

map_nfl_realism_position <- function(position, depth_chart_position) {
  p <- toupper(trimws(position))
  d <- toupper(trimws(depth_chart_position))
  dplyr::case_when(
    p == "OL" | d %in% c("C", "G", "T", "OT", "OG", "OL") ~ "OL",
    p == "LS" | d == "LS" ~ "LS",
    p == "K" | d %in% c("K", "PK") ~ "PK",
    p == "P" | d %in% c("P", "PN") ~ "PN",
    p %in% c("QB", "WR", "TE") ~ p,
    p %in% c("RB", "FB") | d %in% c("RB", "FB") ~ "RB",
    d %in% c("DT", "NT") ~ "DT",
    d == "DE" ~ "DE",
    p == "LB" | d %in% c("LB", "ILB", "MLB", "OLB") ~ "LB",
    d == "CB" ~ "CB",
    d %in% c("S", "FS", "SS") ~ "S",
    p %in% c("DT", "DE", "CB", "S") ~ p,
    TRUE ~ "UNMAPPED"
  )
}

summarize_nfl_realism <- function(rosters, schedules, seasons = 2021:2025) {
  required <- c("season", "team", "week", "game_type", "gsis_id", "full_name", "position", "depth_chart_position", "status", "status_description_abbr")
  stopifnot(all(required %in% names(rosters)))
  games <- schedules |>
    dplyr::filter(.data$season %in% seasons, .data$game_type == "REG", !is.na(.data$result))
  expected <- dplyr::bind_rows(
    dplyr::transmute(games, season, week, team = home_team),
    dplyr::transmute(games, season, week, team = away_team)
  ) |> dplyr::distinct()
  r <- rosters |>
    dplyr::filter(.data$season %in% seasons, .data$game_type == "REG") |>
    dplyr::semi_join(expected, by = c("season", "week", "team")) |>
    dplyr::mutate(
      player_key = dplyr::if_else(!is.na(.data$gsis_id) & nzchar(.data$gsis_id), .data$gsis_id,
        paste("name", .data$full_name, .data$birth_date, sep = ":")),
      adl_position = .data$adl_position
    )
  # Never collapse different players with missing IDs; refuse conflicting duplicate snapshots.
  duplicates <- r |> dplyr::count(season, team, week, player_key) |> dplyr::filter(.data$n > 1)
  if (nrow(duplicates)) stop("Duplicate player/team/week records require review.")
  observed <- r |> dplyr::distinct(season, team, week)
  missing <- dplyr::anti_join(expected, observed, by = c("season", "week", "team"))
  if (nrow(missing)) stop("Missing scheduled team-game roster snapshots: ", nrow(missing))
  included <- r |> dplyr::filter(.data$status %in% c("ACT", "INA"))
  # Complete every status/position cell on every observed game, including genuine zeros.
  grid <- merge(as.data.frame(expected), expand.grid(
    status = c("ACT", "INA"), adl_position = nfl_realism_positions(), stringsAsFactors = FALSE), by = NULL)
  weekly <- grid |>
    dplyr::left_join(dplyr::count(included, season, team, week, status, adl_position, name = "players"),
      by = c("season", "team", "week", "status", "adl_position")) |>
    dplyr::mutate(players = dplyr::coalesce(.data$players, 0L)) |>
    dplyr::arrange(season, team, week, status, match(adl_position, nfl_realism_positions()))
  team_year <- weekly |> dplyr::group_by(season, team, status, adl_position) |>
    dplyr::summarise(mean_players = mean(players), min_players = min(players), max_players = max(players),
      games = dplyr::n(), .groups = "drop")
  league_year <- team_year |> dplyr::group_by(season, status, adl_position) |>
    dplyr::summarise(mean_players = mean(mean_players), teams = dplyr::n(), .groups = "drop") |>
    dplyr::mutate(team = "NFL")
  composite <- league_year |> dplyr::group_by(status, adl_position) |>
    dplyr::summarise(mean_players = mean(mean_players), seasons = dplyr::n(), .groups = "drop") |>
    dplyr::mutate(season = "ALL", team = "NFL")
  summary <- dplyr::bind_rows(dplyr::mutate(team_year, season = as.character(season)),
    dplyr::mutate(league_year, season = as.character(season)), composite)
  totals <- summary |> dplyr::group_by(season, team) |>
    dplyr::summarise(
      act = sum(mean_players[status == "ACT"]), ina = sum(mean_players[status == "INA"]),
      observed_roster = sum(mean_players), ol = sum(mean_players[adl_position == "OL"]),
      ls = sum(mean_players[adl_position == "LS"]), unmapped = sum(mean_players[adl_position == "UNMAPPED"]),
      observed_adl = sum(mean_players[!adl_position %in% c("OL", "LS", "UNMAPPED")]),
      .groups = "drop") |>
    dplyr::mutate(observed_non_ol_ls = observed_roster - ol - ls)
  audit <- included |> dplyr::group_by(season, team, week) |>
    dplyr::summarise(act = sum(status == "ACT"), ina = sum(status == "INA"),
      observed_roster = dplyr::n(), unmapped = sum(adl_position == "UNMAPPED"), .groups = "drop") |>
    dplyr::mutate(review = act > 48 | observed_roster > 55 | observed_roster < 53 | unmapped > 0)
  list(players = r, weekly = weekly, team_year = team_year, league_year = league_year,
    composite = composite, summary = summary, totals = totals, audit = audit,
    status_codes = r |> dplyr::count(season, status, status_description_abbr, name = "player_games"))
}

publish_nfl_realism <- function(data_dir = "data/nfl_realism", docs_dir = "docs") {
  source("R/dashboard_helpers.R")
  source("R/nfl_realism_html.R")
  types <- readr::cols(season = readr::col_character())
  summary <- readr::read_csv(file.path(data_dir, "summary.csv"), col_types = types, guess_max = Inf, show_col_types = FALSE)
  totals <- readr::read_csv(file.path(data_dir, "totals.csv"), col_types = types, show_col_types = FALSE)
  manifest <- jsonlite::read_json(file.path(data_dir, "manifest.json"), simplifyVector = TRUE)
  adl_summary <- adl_team_year <- NULL
  if(file.exists(file.path(data_dir,"adl_summary.csv"))) {
    adl_summary <- readr::read_csv(file.path(data_dir,"adl_summary.csv"),col_types=types,show_col_types=FALSE)
    adl_team_year <- readr::read_csv(file.path(data_dir,"adl_team_year.csv"),show_col_types=FALSE)
    league <- readr::read_csv(file.path(data_dir,"nfl_adl_window_summary.csv"),col_types=types,show_col_types=FALSE) |> dplyr::mutate(team="NFL")
    teams <- readr::read_csv(file.path(data_dir,"nfl_adl_window_team_year.csv"),col_types=types,show_col_types=FALSE)
    summary <- dplyr::bind_rows(league,teams)
    totals <- summary |> dplyr::group_by(season,team) |> dplyr::summarise(
      act=sum(mean_players[status=="ACT"]),ina=sum(mean_players[status=="INA"]),observed_roster=sum(mean_players),
      ol=sum(mean_players[adl_position=="OL"]),ls=sum(mean_players[adl_position=="LS"]),
      unmapped=sum(mean_players[adl_position=="UNMAPPED"]),.groups="drop") |>
      dplyr::mutate(observed_non_ol_ls=observed_roster-ol-ls)
    manifest$comparison_scope <- "2021-2025, weeks 1-17; ADL per franchise-week, NFL per played team-game"
  }
  downloads <- file.path(docs_dir, "downloads/nfl-realism")
  dir.create(downloads, recursive = TRUE, showWarnings = FALSE)
  files <- list.files(data_dir, full.names = TRUE)
  files <- files[!file.info(files)$isdir & !grepl("^(adl_players|player_snapshots|source_)",basename(files))]
  file.copy(files, downloads, overwrite = TRUE)
  writeLines(build_nfl_realism_html(summary, totals, manifest, adl_summary, adl_team_year), file.path(docs_dir, "nfl-realism-report.html"), useBytes = TRUE)
}
