# Run once to freeze historical data. Refresh only with --refresh.
library(dplyr)
source("R/nfl_realism.R")
source("R/nfl_realism_ids.R")
out <- "data/nfl_realism"
dir.create(out, recursive = TRUE, showWarnings = FALSE)
if (!file.exists(file.path(out, "manifest.json")) || "--refresh" %in% commandArgs(TRUE)) {
  # Local inputs permit reproducible, offline testing with previously fetched source files.
  roster_path <- Sys.getenv("NFL_REALISM_ROSTERS_RDS")
  schedule_path <- Sys.getenv("NFL_REALISM_SCHEDULES_RDS")
  rosters <- if (nzchar(roster_path)) readRDS(roster_path) else nflreadr::load_rosters_weekly(2021:2025)
  schedules <- if (nzchar(schedule_path)) readRDS(schedule_path) else nflreadr::load_schedules(2021:2025)
  id_path <- Sys.getenv("NFL_REALISM_IDS_RDS")
  mfl_dir <- Sys.getenv("NFL_REALISM_MFL_DIR", unset = file.path(out, "mfl"))
  dir.create(mfl_dir, recursive = TRUE, showWarnings = FALSE)
  ids <- if (nzchar(id_path)) readRDS(id_path) else nflreadr::load_ff_playerids()
  league_id <- Sys.getenv("ADL_LEAGUE_ID", unset = "60206")
  mfl <- dplyr::bind_rows(lapply(2021:2025, function(year) {
    path <- file.path(mfl_dir, paste0("players_", year, ".json"))
    if (!file.exists(path) || "--refresh" %in% commandArgs(TRUE)) {
      curl::curl_download(sprintf("https://api.myfantasyleague.com/%d/export?TYPE=players&L=%s&DETAILS=1&JSON=1", year, league_id), path)
      Sys.sleep(2)
    }
    data <- jsonlite::fromJSON(path)$players$player
    if (!is.data.frame(data) || !nrow(data)) stop("Missing ADL player database: ", year)
    dplyr::mutate(data, season = year)
  }))
  resolved <- resolve_nfl_realism_positions(rosters, ids, mfl)
  report <- summarize_nfl_realism(resolved$rosters, schedules)
  saveRDS(ids, file.path(out, "source_id_crosswalk.rds"), compress = "xz")
  readr::write_csv(mfl, file.path(out, "source_mfl_players.csv"))
  readr::write_csv(resolved$schema, file.path(out, "fallback_schema.csv"))
  readr::write_csv(report$players |> dplyr::filter(status %in% c("ACT", "INA")) |>
    dplyr::count(season, position_method, name = "player_games"), file.path(out, "position_coverage.csv"))
  saveRDS(rosters, file.path(out, "source_weekly_rosters_2021_2025.rds"), compress = "xz")
  saveRDS(schedules, file.path(out, "source_schedules_2021_2025.rds"), compress = "xz")
  for (name in c("weekly", "team_year", "league_year", "composite", "summary", "totals", "audit", "status_codes")) {
    readr::write_csv(report[[name]], file.path(out, paste0(name, ".csv")))
  }
  player_columns <- c("season", "team", "week", "gsis_id", "full_name", "position", "depth_chart_position", "mfl_id", "mfl_name", "mfl_position", "id_match_fields", "adl_position", "position_method", "estimate_reason", "estimated_position", "confidence", "total_support", "status", "status_description_abbr")
  readr::write_csv(report$players[, player_columns], file.path(out, "player_snapshots.csv.gz"))
  jsonlite::write_json(list(
    seasons = 2021:2025,
    captured_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    nflreadr_version = as.character(packageVersion("nflreadr")),
    source = "nflreadr::load_rosters_weekly(2021:2025)",
    adl_league_id = league_id,
    position_source = "Season-specific ADL MFL players exports, joined via nflreadr fantasy IDs and direct ESPN/Rotowire IDs",
    mfl_source_urls = sprintf("https://api.myfantasyleague.com/%d/export?TYPE=players&L=%s&DETAILS=1&JSON=1", 2021:2025, league_id),
    id_crosswalk_scope = "Current identity crosswalk frozen at retrieval; positions always come from historical ADL exports",
    team_games = nrow(report$audit),
    source_rows = nrow(rosters),
    source_md5 = unname(tools::md5sum(file.path(out, "source_weekly_rosters_2021_2025.rds"))),
    scope = "Completed regular-season games; excludes byes, postseason and canceled games",
    weighting = "Equal games within team-season, equal teams within season, equal seasons in composite",
    exact_53_available = FALSE
  ), file.path(out, "manifest.json"), auto_unbox = TRUE, pretty = TRUE)
}
publish_nfl_realism(out)
message("NFL Realism Report built from frozen 2021–2025 snapshot.")
