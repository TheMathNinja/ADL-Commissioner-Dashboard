library(dplyr)
library(readr)
library(tibble)

get_env_or_default <- function(name, default = "") {
  value <- Sys.getenv(name, unset = default)
  if (is.na(value) || !nzchar(value)) default else value
}

get_current_season <- function(default = 2026L) {
  season <- suppressWarnings(as.integer(get_env_or_default("CURRENT_SEASON", as.character(default))))
  if (is.na(season)) default else season
}

franchise_code_from_name <- function(x) {
  dplyr::case_when(
    x == "Arizona Cardinals" ~ "ARI",
    x == "Atlanta Falcons" ~ "ATL",
    x == "Baltimore Ravens" ~ "BAL",
    x == "Buffalo Bills" ~ "BUF",
    x == "Carolina Panthers" ~ "CAR",
    x == "Chicago Bears" ~ "CHI",
    x == "Cincinnati Bengals" ~ "CIN",
    x == "Cleveland Browns" ~ "CLE",
    x == "Dallas Cowboys" ~ "DAL",
    x == "Denver Broncos" ~ "DEN",
    x == "Detroit Lions" ~ "DET",
    x == "Green Bay Packers" ~ "GBP",
    x == "Houston Texans" ~ "HOU",
    x == "Indianapolis Colts" ~ "IND",
    x == "Jacksonville Jaguars" ~ "JAX",
    x == "Kansas City Chiefs" ~ "KCC",
    x == "Los Angeles Chargers" ~ "LAC",
    x == "Los Angeles Rams" ~ "LAR",
    x == "Las Vegas Raiders" ~ "LVR",
    x == "Miami Dolphins" ~ "MIA",
    x == "Minnesota Vikings" ~ "MIN",
    x == "New England Patriots" ~ "NEP",
    x == "New Orleans Saints" ~ "NOS",
    x == "New York Giants" ~ "NYG",
    x == "New York Jets" ~ "NYJ",
    x == "Philadelphia Eagles" ~ "PHI",
    x == "Pittsburgh Steelers" ~ "PIT",
    x == "Seattle Seahawks" ~ "SEA",
    x == "San Francisco 49ers" ~ "SFO",
    x == "Tampa Bay Buccaneers" ~ "TBB",
    x == "Tennessee Titans" ~ "TEN",
    x == "Washington Commanders" ~ "WAS",
    TRUE ~ NA_character_
  )
}

connect_adl_mfl <- function(season = get_current_season()) {
  if (!requireNamespace("ffscrapr", quietly = TRUE)) {
    stop("Package ffscrapr is required for live roster refresh.")
  }

  league_id <- as.integer(get_env_or_default("ADL_LEAGUE_ID", "60206"))
  if (is.na(league_id)) stop("ADL_LEAGUE_ID must be numeric when provided.")

  args <- list(
    season = season,
    league_id = league_id,
    user_agent = get_env_or_default("MFL_USER_AGENT", "ADLCommissionerDashboard"),
    rate_limit_number = 3,
    rate_limit_seconds = 6
  )

  user_name <- get_env_or_default("MFL_USERNAME")
  password <- get_env_or_default("MFL_PASSWORD")
  if (nzchar(user_name)) args$user_name <- user_name
  if (nzchar(password)) args$password <- password

  do.call(ffscrapr::mfl_connect, args)
}

coalesce_col <- function(df, names, default = NA_character_) {
  found <- names[names %in% colnames(df)]
  if (length(found) == 0) return(rep(default, nrow(df)))
  df[[found[1]]]
}

normalize_rosters <- function(rosters, franchises = NULL) {
  roster_tbl <- tibble::as_tibble(rosters)

  rosters <- roster_tbl |>
    mutate(
      franchise_id = as.character(coalesce_col(roster_tbl, c("franchise_id", "franchiseId"))),
      player_id = as.character(coalesce_col(roster_tbl, c("player_id", "playerId", "id"))),
      player_name = as.character(coalesce_col(roster_tbl, c("player_name", "player", "name"))),
      player_team = as.character(coalesce_col(roster_tbl, c("team", "player_team"))),
      player_pos = as.character(coalesce_col(roster_tbl, c("pos", "position", "player_pos"))),
      roster_status = as.character(coalesce_col(roster_tbl, c("roster_status", "status"), "ROSTER")),
      player_status = as.character(coalesce_col(roster_tbl, c("player_status", "injury_status", "injury", "inj"), NA_character_)),
      prev_salary = suppressWarnings(as.numeric(coalesce_col(roster_tbl, c("prev_salary", "salary", "roster_salary")))),
      prev_years = suppressWarnings(as.numeric(coalesce_col(roster_tbl, c("prev_years", "contract_years", "roster_years", "years")))),
      contract = as.character(coalesce_col(roster_tbl, c("contract", "contractInfo", "roster_contractInfo")))
    )

  if (!is.null(franchises)) {
    franchise_tbl <- tibble::as_tibble(franchises)
    fr <- franchise_tbl |>
      transmute(
        franchise_id = as.character(.data$franchise_id),
        franchise_name = as.character(coalesce_col(franchise_tbl, c("franchise_name", "name"))),
        franchise = as.character(coalesce_col(franchise_tbl, c("franchise", "franchise_abbrev", "abbrev"), NA_character_)),
        franchise_salary_cap = suppressWarnings(as.numeric(coalesce_col(franchise_tbl, c("salaryCapAmount", "salary_cap_amount", "salary_cap"), NA_character_)))
      )
  } else if ("franchise_name" %in% names(rosters)) {
    roster_cap <- suppressWarnings(as.numeric(coalesce_col(rosters, c("franchise_salary_cap", "salaryCapAmount", "salary_cap_amount", "salary_cap"), NA_character_)))
    fr <- rosters |>
      mutate(franchise_salary_cap = roster_cap) |>
      distinct(franchise_id, franchise_name, franchise_salary_cap) |>
      mutate(
        franchise = franchise_code_from_name(.data$franchise_name)
      )
  } else {
    fr <- tibble(franchise_id = character(), franchise_name = character(), franchise = character(), franchise_salary_cap = numeric())
  }

  rosters |>
    left_join(fr, by = "franchise_id", suffix = c("", "_lookup")) |>
    mutate(
      franchise_name = coalesce(.data$franchise_name, .data$franchise_name_lookup),
      franchise = coalesce(.data$franchise, franchise_code_from_name(.data$franchise_name)),
      franchise_salary_cap = suppressWarnings(as.numeric(.data$franchise_salary_cap)),
      conference = case_when(
        suppressWarnings(as.integer(.data$franchise_id)) <= 16L ~ "NFC",
        suppressWarnings(as.integer(.data$franchise_id)) >= 17L ~ "AFC",
        TRUE ~ NA_character_
      ),
      roster_status = recode(.data$roster_status, ROSTER = "Active", ACTIVE_ROSTER = "Active", TAXI_SQUAD = "Taxi", .default = .data$roster_status),
      player = trimws(paste(.data$player_name, .data$player_team, .data$player_pos)),
      ext_marker = NA_character_,
      roster_last = tolower(sub(",.*$", "", .data$player_name))
    ) |>
    filter(!is.na(.data$franchise), !is.na(.data$player), !is.na(.data$prev_salary), !is.na(.data$prev_years)) |>
    select(
      conference, franchise, franchise_name, player_id, player, player_name,
      player_team, player_pos, roster_status, player_status, prev_salary, prev_years, franchise_salary_cap,
      contract, ext_marker, roster_last
    )
}

fetch_live_rosters <- function(season = get_current_season(), week = NULL) {
  conn <- connect_adl_mfl(season)
  rosters <- ffscrapr::ff_rosters(conn, week = week)
  players_tbl <- ffscrapr::mfl_players(conn) |>
    tibble::as_tibble()
  players <- players_tbl |>
    tibble::as_tibble() |>
    transmute(
      player_id = as.character(.data$player_id),
      player_status = as.character(coalesce_col(players_tbl, c("status"), NA_character_))
    ) |>
    distinct(.data$player_id, .keep_all = TRUE)
  rosters <- rosters |>
    mutate(player_id = as.character(.data$player_id)) |>
    left_join(players, by = "player_id")
  franchises <- ffscrapr::ff_franchises(conn)
  normalize_rosters(rosters, franchises)
}

latest_commissioner_roster_snapshot <- function(season = get_current_season()) {
  configured <- Sys.getenv("ADL_GM_ROSTER_SNAPSHOT", unset = "")
  if (nzchar(configured)) return(configured)

  default_snapshot <- file.path(
    "data/roster_snapshots",
    paste0("saladj_roster_snapshot_", season, "_latest.csv")
  )

  if (file.exists(default_snapshot)) return(default_snapshot)
  stop("No roster snapshot found. Set ADL_GM_ROSTER_SNAPSHOT or run a live roster refresh.")
}

read_snapshot_rosters <- function(season = get_current_season()) {
  read_csv(
    latest_commissioner_roster_snapshot(season),
    col_types = cols(.default = col_character()),
    show_col_types = FALSE
  ) |>
    normalize_rosters()
}

cache_is_fresh <- function(path, max_age_minutes) {
  file.exists(path) &&
    difftime(Sys.time(), file.info(path)$mtime, units = "mins") <= max_age_minutes
}

write_roster_cache <- function(rosters, cache_path, source_label, season) {
  write_csv(rosters, cache_path, na = "")
  write_csv(
    tibble(
      refreshed_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
      source = source_label,
      season = season,
      rows = nrow(rosters)
    ),
    file.path(dirname(cache_path), "roster_metadata.csv"),
    na = ""
  )
}

load_current_rosters <- function(
  source = get_env_or_default("ADL_GM_ROSTER_SOURCE", "auto"),
  force_live = FALSE,
  cache_minutes = as.numeric(get_env_or_default("ADL_GM_ROSTER_CACHE_MINUTES", "10")),
  cache_path = file.path("data", "current_rosters.csv"),
  season = get_current_season(),
  week = NULL
) {
  dir.create(dirname(cache_path), recursive = TRUE, showWarnings = FALSE)
  source <- match.arg(source, c("auto", "live", "cache", "snapshot"))

  if (!force_live && source %in% c("auto", "cache") && cache_is_fresh(cache_path, cache_minutes)) {
    return(read_csv(cache_path, show_col_types = FALSE))
  }

  if (source %in% c("auto", "live")) {
    live <- tryCatch(fetch_live_rosters(season = season, week = week), error = identity)
    if (!inherits(live, "error")) {
      write_roster_cache(live, cache_path, "ffscrapr::ff_rosters()", season)
      return(live)
    }
    if (source == "live") stop(live)
    message("Live roster refresh failed; falling back to snapshot/cache: ", conditionMessage(live))
  }

  if (source == "cache" && file.exists(cache_path)) {
    return(read_csv(cache_path, show_col_types = FALSE))
  }

  snapshot <- read_snapshot_rosters(season)
  write_roster_cache(snapshot, cache_path, "commissioner snapshot fallback", season)
  snapshot
}
