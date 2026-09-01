library(dplyr)
library(readr)
library(tibble)

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0 || (length(x) == 1 && is.na(x))) y else x
}

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

mfl_player_team <- function(team) {
  team <- toupper(trimws(as.character(team)))
  dplyr::recode(
    team,
    ARZ = "ARI",
    JAX = "JAC",
    KC = "KCC",
    GB = "GBP",
    NO = "NOS",
    NE = "NEP",
    SF = "SFO",
    TB = "TBB",
    LA = "LAR",
    STL = "LAR",
    OAK = "LVR",
    SD = "LAC",
    .default = team
  )
}

roster_source_safe_file_slug <- function(x) {
  x <- tolower(gsub("[^A-Za-z0-9]+", "_", x))
  gsub("^_+|_+$", "", x)
}

normalize_rosters <- function(rosters, franchises = NULL) {
  roster_tbl <- tibble::as_tibble(rosters)

  rosters <- roster_tbl |>
    mutate(
      franchise_id = as.character(coalesce_col(roster_tbl, c("franchise_id", "franchiseId"))),
      player_id = as.character(coalesce_col(roster_tbl, c("player_id", "playerId", "id"))),
      player_name = as.character(coalesce_col(roster_tbl, c("player_name", "player", "name"))),
      player_team = as.character(coalesce_col(roster_tbl, c("team", "player_team", "nfl_team", "pro_team"))),
      player_pos = as.character(coalesce_col(roster_tbl, c("pos", "position", "player_pos", "player_position"))),
      roster_status = as.character(coalesce_col(roster_tbl, c("roster_status", "status"), "ROSTER")),
      player_status = as.character(coalesce_col(roster_tbl, c("player_status", "injury_status", "injuryStatus", "injury_status_full", "injury", "inj", "status_code"), NA_character_)),
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

normalize_mfl_roster_injuries <- function(injuries) {
  if (is.null(injuries) || length(injuries) == 0) {
    return(tibble(player_id = character(), player_team = character(), player_status = character()))
  }

  injuries_tbl <- if (is.data.frame(injuries)) {
    tibble::as_tibble(injuries)
  } else if (is.list(injuries) && !is.null(names(injuries)) && all(c("id", "status") %in% names(injuries))) {
    tibble::as_tibble(injuries)
  } else if (is.list(injuries)) {
    bind_rows(lapply(injuries, tibble::as_tibble))
  } else {
    tibble()
  }

  id_cols <- intersect(c("id", "player_id", "player.id"), names(injuries_tbl))
  if (!length(id_cols) || !"status" %in% names(injuries_tbl)) {
    return(tibble(player_id = character(), player_team = character(), player_status = character()))
  }

  injuries_tbl |>
    transmute(
      player_id = as.character(coalesce_col(injuries_tbl, c("id", "player_id", "player.id"))),
      player_team = as.character(coalesce_col(injuries_tbl, c("team", "player_team", "player.team"), NA_character_)),
      player_status = as.character(.data$status)
    ) |>
    filter(
      !is.na(.data$player_id),
      nzchar(.data$player_id),
      !is.na(.data$player_status),
      nzchar(.data$player_status)
    ) |>
    mutate(player_team = mfl_player_team(.data$player_team)) |>
    distinct(.data$player_id, .data$player_team, .keep_all = TRUE)
}

fetch_live_roster_injuries <- function(conn, season = get_current_season(), week = NULL) {
  query <- list(
    TYPE = "injuries",
    L = as.integer(get_env_or_default("ADL_LEAGUE_ID", "60206")),
    JSON = 1
  )
  if (!is.null(week) && !is.na(week)) query$W <- as.integer(week)

  direct_payload <- NULL
  for (base_url in c("https://api.myfantasyleague.com", "http://football.myfantasyleague.com")) {
    direct_payload <- tryCatch({
      response <- httr::GET(
        url = paste0(base_url, "/", season, "/export"),
        query = query,
        httr::user_agent(get_env_or_default("MFL_USER_AGENT", "ADLCommissionerDashboard"))
      )
      response_text <- httr::content(response, "text", encoding = "UTF-8")
      response_json <- jsonlite::fromJSON(response_text, flatten = TRUE)
      if ("error" %in% names(response_json)) stop(response_json$error$`$t` %||% "MFL injuries error")
      response_json[["injuries"]][["injury"]]
    }, error = function(e) NULL)
    if (!is.null(direct_payload) && length(direct_payload)) break
  }

  ffscrapr_payload <- tryCatch({
    if (!is.null(week) && !is.na(week)) {
      ffscrapr::mfl_getendpoint(conn, endpoint = "injuries", W = as.integer(week))[["content"]][["injuries"]][["injury"]]
    } else {
      ffscrapr::mfl_getendpoint(conn, endpoint = "injuries")[["content"]][["injuries"]][["injury"]]
    }
  }, error = function(e) NULL)

  bind_rows(
    normalize_mfl_roster_injuries(direct_payload),
    normalize_mfl_roster_injuries(ffscrapr_payload)
  ) |>
    distinct(.data$player_id, .data$player_team, .keep_all = TRUE)
}

mfl_roster_report_urls <- function(conn, season = get_current_season()) {
  league_id <- as.integer(get_env_or_default("ADL_LEAGUE_ID", "60206"))
  league_url <- as.character(conn[["league_url"]] %||% conn[["url"]] %||% "")
  report_path <- paste0("/" , season, "/options?L=", league_id, "&O=07")
  urls <- c(
    if (nzchar(league_url)) sub(paste0("/", season, "/.*$"), report_path, league_url) else character(),
    paste0("https://www.myfantasyleague.com", report_path),
    paste0("http://football.myfantasyleague.com", report_path)
  )
  unique(urls[nzchar(urls)])
}

extract_mfl_player_id_from_row <- function(row) {
  hrefs <- rvest::html_attr(rvest::html_elements(row, "a"), "href")
  hrefs <- hrefs[!is.na(hrefs)]
  match <- regmatches(hrefs, regexpr("launch_player_modal\\('[0-9]+','[0-9]+'\\)|([?&](P|PLAYER|PLAYER_ID|PLAYERS)=|/player\\?P=)[0-9]+", hrefs, ignore.case = TRUE))
  match <- match[nzchar(match)]
  if (!length(match)) return(NA_character_)
  sub(".*'([0-9]+)'\\)$|.*=([0-9]+)$", "\\1\\2", match[[1]])
}

extract_mfl_player_ids_from_rows <- function(rows) {
  vapply(seq_along(rows), function(i) extract_mfl_player_id_from_row(rows[[i]]), character(1))
}

extract_mfl_visible_injury_statuses_from_rows <- function(rows) {
  bind_rows(lapply(rows, function(row) {
    player_id <- extract_mfl_player_id_from_row(row)
    if (is.na(player_id) || !nzchar(player_id)) {
      return(tibble(player_id = character(), player_status = character()))
    }

    status_nodes <- rvest::html_elements(row, ".injurystatus")
    status_values <- rvest::html_attr(status_nodes, "title")
    if (!length(status_values)) status_values <- rvest::html_text2(status_nodes)
    status_values <- normalize_visible_injury_status(status_values)
    status_values <- status_values[!is.na(status_values) & nzchar(status_values)]
    if (!length(status_values)) {
      return(tibble(player_id = character(), player_status = character()))
    }

    tibble(player_id = player_id, player_status = status_values[[1]])
  }))
}

normalize_visible_injury_status <- function(x) {
  x <- toupper(trimws(as.character(x)))
  x <- gsub("\\s+", " ", x)
  dplyr::case_when(
    x %in% c("S", "(S)", "SUSP", "SUSPENDED") ~ "Suspended",
    x %in% c("I", "(I)", "IR", "INJURED", "INJURED RESERVE", "INJURED_RESERVE", "IR-R", "IR-PUP", "IR-NFI", "PUP", "NFI") ~ x,
    x %in% c("H", "(H)", "HOLDOUT") ~ "Holdout",
    x %in% c("O", "(O)", "OUT") ~ "Out",
    x %in% c("Q", "(Q)", "QUESTIONABLE") ~ "Questionable",
    x %in% c("D", "(D)", "DOUBTFUL") ~ "Doubtful",
    TRUE ~ NA_character_
  )
}

fetch_mfl_roster_report_statuses <- function(conn, season = get_current_season()) {
  if (!requireNamespace("rvest", quietly = TRUE)) {
    return(tibble(player_id = character(), player_status = character()))
  }

  for (url in mfl_roster_report_urls(conn, season)) {
    statuses <- tryCatch({
      response <- httr::GET(
        url,
        httr::user_agent(get_env_or_default("MFL_USER_AGENT", "ADLCommissionerDashboard"))
      )
      html <- httr::content(response, "text", encoding = "UTF-8")
      doc <- rvest::read_html(html)
      tables <- rvest::html_elements(doc, "table")
      if (tolower(Sys.getenv("ADL_ALERT_DEBUG", unset = "false")) %in% c("1", "true", "yes")) {
        dir.create(file.path("data", "commissioner_alerts"), recursive = TRUE, showWarnings = FALSE)
        writeLines(html, file.path("data", "commissioner_alerts", paste0("debug_roster_report_", roster_source_safe_file_slug(url), ".html")))
        table_headers <- vapply(tables, function(table) paste(names(tryCatch(rvest::html_table(table, fill = TRUE), error = function(e) tibble())), collapse = " | "), character(1))
        readr::write_csv(tibble(url = url, table_index = seq_along(table_headers), headers = table_headers), file.path("data", "commissioner_alerts", paste0("debug_roster_report_tables_", roster_source_safe_file_slug(url), ".csv")), na = "")
      }

      bind_rows(lapply(tables, function(table) {
        rows <- rvest::html_elements(table, "tr")
        row_statuses <- extract_mfl_visible_injury_statuses_from_rows(rows)
        if (nrow(row_statuses)) return(row_statuses)

        parsed <- tryCatch(rvest::html_table(table, fill = TRUE), error = function(e) NULL)
        if (is.null(parsed) || !nrow(parsed)) return(tibble(player_id = character(), player_status = character()))

        status_cols <- grep("inj|status", names(parsed), ignore.case = TRUE, value = TRUE)
        if (!length(status_cols)) return(tibble(player_id = character(), player_status = character()))

        ids <- extract_mfl_player_ids_from_rows(rows)
        ids <- tail(ids[!is.na(ids) & nzchar(ids)], nrow(parsed))
        if (length(ids) != nrow(parsed)) return(tibble(player_id = character(), player_status = character()))

        tibble(
          player_id = as.character(ids),
          player_status = apply(parsed[, status_cols, drop = FALSE], 1, function(values) {
            normalized <- normalize_visible_injury_status(values)
            normalized <- normalized[!is.na(normalized) & nzchar(normalized)]
            if (length(normalized)) normalized[[1]] else NA_character_
          })
        ) |>
          filter(!is.na(.data$player_status), nzchar(.data$player_status))
      })) |>
        distinct(.data$player_id, .keep_all = TRUE)
    }, error = function(e) tibble(player_id = character(), player_status = character()))

    if (tolower(Sys.getenv("ADL_ALERT_DEBUG", unset = "false")) %in% c("1", "true", "yes")) {
      message("Visible MFL roster status fallback checked ", url, " and found ", nrow(statuses), " status row(s).")
    }
    if (nrow(statuses)) return(statuses)
  }

  tibble(player_id = character(), player_status = character())
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
  injuries <- fetch_live_roster_injuries(conn, season = season, week = week) |>
    rename(injury_player_status = .data$player_status)
  visible_statuses <- fetch_mfl_roster_report_statuses(conn, season = season) |>
    rename(visible_player_status = .data$player_status)

  rosters <- rosters |>
    mutate(
      player_id = as.character(.data$player_id),
      player_team = mfl_player_team(as.character(coalesce_col(tibble::as_tibble(rosters), c("team", "player_team", "nfl_team", "pro_team"), NA_character_)))
    ) |>
    left_join(players, by = "player_id") |>
    left_join(injuries, by = c("player_id", "player_team")) |>
    left_join(visible_statuses, by = "player_id") |>
    mutate(player_status = coalesce(na_if(.data$injury_player_status, ""), na_if(.data$visible_player_status, ""), na_if(.data$player_status, ""))) |>
    select(-injury_player_status, -visible_player_status)
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
