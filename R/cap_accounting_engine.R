# cap_accounting_engine.R
# -----------------------
# Builds ADL salary cap accounting roster snapshots and weekly summaries.

library(dplyr)
library(ffscrapr)
library(httr)
library(jsonlite)
library(lubridate)
library(readr)
library(stringr)
library(tibble)

source("R/config_helpers.R")
source("R/mfl_helpers.R")

salary_thresholds <- tibble::tribble(
  ~season, ~adl_veteran_min,
  2020L, 0.8,
  2021L, 0.9,
  2022L, 0.9,
  2023L, 0.9,
  2024L, 1.0,
  2025L, 1.0,
  2026L, 1.1,
  2027L, 1.1,
  2028L, 1.2,
  2029L, 1.2,
  2030L, 1.3
)

cap_pos_order <- c("QB", "RB", "WR", "TE", "PK", "PN", "DT", "DE", "LB", "CB", "S")

waiver_correction_columns <- c(
  "SEASON", "WEEK", "WAIVER_WINDOW_START_ET", "WAIVER_WINDOW_END_ET", "DATE",
  "CONF", "FRAN", "FRANCHISE_ID", "PLAYER", "PLAYER_ID", "SALARY", "YEARS",
  "CONTRACT", "FG", "1.XX+", "RVSD?", "SALARY_SNAPSHOT_TIME_ET",
  "WAIVER_STATUS", "NOTES"
)

format_salary_dollars <- function(x) {
  dplyr::if_else(
    is.na(suppressWarnings(as.numeric(x))),
    NA_character_,
    paste0("$", sprintf("%.2f", suppressWarnings(as.numeric(x))))
  )
}

format_summary_dollars <- function(x) {
  dplyr::if_else(
    is.na(suppressWarnings(as.numeric(x))),
    NA_character_,
    sprintf("%.2f", suppressWarnings(as.numeric(x)))
  )
}

get_cap_veteran_min <- function(current_season) {
  vet_min <- salary_thresholds %>%
    dplyr::filter(.data$season == current_season) %>%
    dplyr::pull(.data$adl_veteran_min)

  if (length(vet_min) != 1 || is.na(vet_min)) {
    stop("No ADL veteran minimum configured for season ", current_season, ".")
  }

  vet_min
}

franchise_to_conf <- function(franchise_id_num) {
  dplyr::case_when(
    is.na(franchise_id_num) ~ NA_character_,
    franchise_id_num >= 1L & franchise_id_num <= 16L ~ "NFC",
    franchise_id_num >= 17L & franchise_id_num <= 32L ~ "AFC",
    TRUE ~ NA_character_
  )
}

add_conf_fields <- function(df, franchise_id_col = "franchise_id") {
  if (!franchise_id_col %in% names(df)) {
    df[[franchise_id_col]] <- NA_character_
  }

  df %>%
    dplyr::mutate(
      franchise_id_num = suppressWarnings(as.integer(as.character(.data[[franchise_id_col]]))),
      CONF = franchise_to_conf(.data$franchise_id_num)
    )
}

make_transaction_row_key <- function(df) {
  txn_id_col <- intersect(names(df), c("transaction_id", "trans_id", "id", "transactionId"))
  txn_id_val <- if (length(txn_id_col) == 1) as.character(df[[txn_id_col]]) else ""

  franchise_val <- if ("franchise_id" %in% names(df)) as.character(df[["franchise_id"]]) else ""
  player_val <- if ("player_id" %in% names(df)) as.character(df[["player_id"]]) else ""
  ts_val <- if ("timestamp" %in% names(df)) as.character(df[["timestamp"]]) else ""
  type_val <- if ("type" %in% names(df)) as.character(df[["type"]]) else ""
  desc_val <- if ("type_desc" %in% names(df)) as.character(df[["type_desc"]]) else ""
  comm_val <- if ("comments" %in% names(df)) as.character(df[["comments"]]) else ""

  paste0(
    "txn=", txn_id_val,
    "|fr=", franchise_val,
    "|pl=", player_val,
    "|ts=", ts_val,
    "|ty=", type_val,
    "|td=", desc_val,
    "|cm=", comm_val
  )
}

is_fg_contract <- function(contract_info) {
  x <- dplyr::coalesce(contract_info, "")
  stringr::str_detect(x, "(1\\.XX|2\\.XX|FT|TT|5YO)")
}

has_plus_contract <- function(contract_info) {
  x <- dplyr::coalesce(contract_info, "")
  stringr::str_detect(x, "\\+")
}

is_rvsd_contract <- function(contract_info) {
  x <- dplyr::coalesce(contract_info, "")
  m <- stringr::str_match(x, "^([0-9]+)\\.XX\\^$")
  n <- suppressWarnings(as.integer(m[, 2]))
  !is.na(n) & n >= 3L
}

format_et <- function(x, fmt = "%m/%d/%Y %I:%M %p %Z") {
  ifelse(is.na(x), "", format(lubridate::with_tz(x, "America/Toronto"), fmt))
}

empty_waiver_corrections <- function() {
  out <- tibble::as_tibble(stats::setNames(rep(list(character()), length(waiver_correction_columns)), waiver_correction_columns))
  out
}

get_waiver_correction_window <- function(run_time = Sys.time()) {
  end_env <- Sys.getenv("WAIVER_CORRECTION_WINDOW_END", unset = "")
  start_env <- Sys.getenv("WAIVER_CORRECTION_WINDOW_START", unset = "")

  window_end <- if (nzchar(end_env)) {
    lubridate::parse_date_time(
      end_env,
      orders = c("Ymd HMS", "Ymd HM", "Ymd", "mdY HMS", "mdY HM", "mdY"),
      tz = "America/Toronto"
    )
  } else {
    lubridate::with_tz(run_time, "America/Toronto")
  }

  if (is.na(window_end)) {
    stop("WAIVER_CORRECTION_WINDOW_END could not be parsed.")
  }

  custom_start <- nzchar(start_env)
  custom_end <- nzchar(end_env)

  window_start <- if (custom_start) {
    lubridate::parse_date_time(
      start_env,
      orders = c("Ymd HMS", "Ymd HM", "Ymd", "mdY HMS", "mdY HM", "mdY"),
      tz = "America/Toronto"
    )
  } else {
    days_since_sunday <- as.integer(format(window_end, "%w"))
    sunday_date <- as.Date(window_end, tz = "America/Toronto") - days_since_sunday
    candidate <- as.POSIXct(paste0(format(sunday_date, "%Y-%m-%d"), " 05:00:00"), tz = "America/Toronto")
    if (candidate > window_end) candidate <- candidate - lubridate::days(7)
    candidate
  }

  if (is.na(window_start)) {
    stop("WAIVER_CORRECTION_WINDOW_START could not be parsed.")
  }

  if (!custom_end) {
    cap_end <- as.POSIXct(
      paste0(format(as.Date(window_start, tz = "America/Toronto") + 2L, "%Y-%m-%d"), " 03:30:00"),
      tz = "America/Toronto"
    )
    if (window_end > cap_end) {
      window_end <- cap_end
    }
  }

  list(
    start = lubridate::with_tz(window_start, "UTC"),
    end = lubridate::with_tz(window_end, "UTC")
  )
}

load_roster_snapshot_history <- function(snapshot_dir, season) {
  if (!dir.exists(snapshot_dir)) return(tibble::tibble())

  snapshot_files <- list.files(
    snapshot_dir,
    pattern = paste0("^saladj_roster_snapshot_", season, "_[0-9]{8}_[0-9]{6}\\.csv$"),
    full.names = TRUE
  )

  if (length(snapshot_files) == 0) return(tibble::tibble())

  dplyr::bind_rows(lapply(snapshot_files, function(snapshot_file) {
    readr::read_csv(
      snapshot_file,
      col_types = readr::cols(
        season = readr::col_integer(),
        snapshot_time = readr::col_datetime(),
        franchise_id = readr::col_character(),
        CONF = readr::col_character(),
        player_id = readr::col_character(),
        roster_salary = readr::col_double(),
        roster_years = readr::col_double(),
        roster_contractInfo = readr::col_character(),
        .default = readr::col_character()
      ),
      show_col_types = FALSE
    )
  }))
}

clean_cap_player_names <- function(x) {
  if (requireNamespace("nflreadr", quietly = TRUE)) {
    return(nflreadr::clean_player_names(dplyr::coalesce(x, "")))
  }

  stringr::str_squish(dplyr::coalesce(x, ""))
}

build_waiver_corrections <- function(
  conn,
  current_season,
  snapshot_week,
  vet_min,
  franchise_lookup,
  output_dir = "data",
  run_time = Sys.time()
) {
  window <- get_waiver_correction_window(run_time)
  snapshot_history <- load_roster_snapshot_history(file.path(output_dir, "roster_snapshots"), current_season)

  if (nrow(snapshot_history) == 0) {
    return(empty_waiver_corrections())
  }

  tx <- ffscrapr::ff_transactions(conn)
  if (!"comments" %in% names(tx)) tx$comments <- NA_character_
  if (!"player_name" %in% names(tx)) tx$player_name <- NA_character_
  if (!"player_id" %in% names(tx)) tx$player_id <- NA_character_

  tx <- tx %>%
    dplyr::mutate(
      player_id = as.character(.data$player_id),
      row_key = make_transaction_row_key(dplyr::pick(dplyr::everything())),
      DATE_raw = lubridate::ymd_hms(.data$timestamp, quiet = TRUE, tz = "UTC")
    )

  if (all(is.na(tx$DATE_raw))) {
    tx <- tx %>%
      dplyr::mutate(DATE_raw = as.POSIXct(.data$timestamp, tz = "UTC"))
  }

  tx_window <- tx %>%
    dplyr::mutate(
      franchise_id = stringr::str_pad(as.character(.data$franchise_id), width = 4, side = "left", pad = "0")
    ) %>%
    add_conf_fields("franchise_id") %>%
    dplyr::filter(
      .data$type == "FREE_AGENT",
      .data$type_desc == "dropped",
      !is.na(.data$DATE_raw),
      .data$DATE_raw >= window$start,
      .data$DATE_raw < window$end
    ) %>%
    dplyr::distinct(.data$row_key, .keep_all = TRUE)

  if (nrow(tx_window) == 0) {
    return(empty_waiver_corrections())
  }

  rosters_now <- ffscrapr::ff_rosters(conn)
  salary_col <- intersect(names(rosters_now), c("salary", "player_salary", "contract_salary"))
  years_col <- intersect(names(rosters_now), c("contract_years", "years", "contractYears"))
  info_col <- intersect(names(rosters_now), c("contractInfo", "contract_info", "contractinfo"))

  if (length(salary_col) == 0) rosters_now$salary <- NA_real_ else rosters_now <- rosters_now %>% dplyr::rename(salary = dplyr::all_of(salary_col[1]))
  if (length(years_col) == 0) rosters_now$contract_years <- NA_real_ else rosters_now <- rosters_now %>% dplyr::rename(contract_years = dplyr::all_of(years_col[1]))
  if (length(info_col) == 0) rosters_now$contractInfo <- NA_character_ else rosters_now <- rosters_now %>% dplyr::rename(contractInfo = dplyr::all_of(info_col[1]))
  if (!"franchise_id" %in% names(rosters_now)) rosters_now$franchise_id <- NA_character_
  if (!"player_id" %in% names(rosters_now)) rosters_now$player_id <- NA_character_

  current_same_conf_player <- rosters_now %>%
    dplyr::mutate(
      franchise_id = stringr::str_pad(as.character(.data$franchise_id), width = 4, side = "left", pad = "0"),
      player_id = as.character(.data$player_id)
    ) %>%
    add_conf_fields("franchise_id") %>%
    dplyr::left_join(
      franchise_lookup %>%
        dplyr::transmute(
          current_player_franchise_id = as.character(.data$franchise_id),
          current_player_abbrev = .data$FRANCHISE
        ),
      by = c("franchise_id" = "current_player_franchise_id")
    ) %>%
    dplyr::group_by(.data$player_id, .data$CONF) %>%
    dplyr::arrange(
      dplyr::desc(suppressWarnings(as.numeric(.data$salary))),
      dplyr::desc(suppressWarnings(as.numeric(.data$contract_years))),
      .by_group = TRUE
    ) %>%
    dplyr::slice(1) %>%
    dplyr::ungroup() %>%
    dplyr::transmute(
      player_id = .data$player_id,
      CONF = .data$CONF,
      current_player_salary = suppressWarnings(as.numeric(.data$salary)),
      current_player_contractInfo = as.character(.data$contractInfo),
      current_player_franchise_id = .data$franchise_id,
      current_player_abbrev = .data$current_player_abbrev
    )

  historical_roster_matches <- tx_window %>%
    dplyr::select(dplyr::all_of(c("row_key", "player_id", "franchise_id", "DATE_raw"))) %>%
    dplyr::left_join(
      snapshot_history %>%
        dplyr::mutate(
          franchise_id = stringr::str_pad(as.character(.data$franchise_id), width = 4, side = "left", pad = "0"),
          player_id = as.character(.data$player_id)
        ),
      by = c("player_id", "franchise_id"),
      relationship = "many-to-many"
    ) %>%
    dplyr::filter(!is.na(.data$snapshot_time), .data$snapshot_time <= .data$DATE_raw) %>%
    dplyr::group_by(.data$row_key) %>%
    dplyr::arrange(dplyr::desc(.data$snapshot_time), .by_group = TRUE) %>%
    dplyr::slice(1) %>%
    dplyr::ungroup() %>%
    dplyr::transmute(
      row_key = .data$row_key,
      salary_snap = .data$roster_salary,
      years_snap = .data$roster_years,
      info_snap = .data$roster_contractInfo,
      salary_snapshot_time = .data$snapshot_time
    )

  tx_window %>%
    dplyr::left_join(franchise_lookup, by = "franchise_id") %>%
    dplyr::left_join(historical_roster_matches, by = "row_key") %>%
    dplyr::left_join(current_same_conf_player, by = c("player_id", "CONF")) %>%
    dplyr::mutate(
      missing_salary_snapshot = is.na(.data$salary_snap) & is.na(.data$info_snap),
      current_same_conf_elsewhere = !is.na(.data$current_player_franchise_id) &
        .data$current_player_franchise_id != .data$franchise_id,
      waiver_claimed = .data$current_same_conf_elsewhere &
        !.data$missing_salary_snapshot &
        !is.na(.data$current_player_salary) &
        !is.na(.data$salary_snap) &
        abs(.data$current_player_salary - .data$salary_snap) < 0.001 &
        dplyr::coalesce(.data$current_player_contractInfo, "") == dplyr::coalesce(.data$info_snap, ""),
      salary_or_contract_qualifies = (dplyr::coalesce(.data$salary_snap, -Inf) >= vet_min) |
        is_fg_contract(.data$info_snap),
      qualifies = .data$salary_or_contract_qualifies | .data$missing_salary_snapshot
    ) %>%
    dplyr::filter(.data$qualifies, !.data$waiver_claimed) %>%
    dplyr::transmute(
      SEASON = as.character(current_season),
      WEEK = as.character(snapshot_week),
      WAIVER_WINDOW_START_ET = format_et(window$start),
      WAIVER_WINDOW_END_ET = format_et(window$end),
      DATE = format_et(.data$DATE_raw, "%m/%d/%Y %H:%M:%S"),
      CONF = dplyr::coalesce(.data$CONF, ""),
      FRAN = dplyr::coalesce(.data$FRANCHISE, ""),
      FRANCHISE_ID = .data$franchise_id,
      PLAYER = clean_cap_player_names(.data$player_name),
      PLAYER_ID = .data$player_id,
      SALARY = dplyr::if_else(.data$missing_salary_snapshot, "CHECK", as.character(.data$salary_snap)),
      YEARS = dplyr::if_else(.data$missing_salary_snapshot, "CHECK", as.character(.data$years_snap)),
      CONTRACT = dplyr::if_else(.data$missing_salary_snapshot, "", dplyr::coalesce(as.character(.data$info_snap), "")),
      FG = dplyr::if_else(!.data$missing_salary_snapshot & is_fg_contract(.data$info_snap), "x", ""),
      `1.XX+` = dplyr::if_else(!.data$missing_salary_snapshot & has_plus_contract(.data$info_snap), "fill", ""),
      `RVSD?` = dplyr::if_else(!.data$missing_salary_snapshot & is_rvsd_contract(.data$info_snap), "x", ""),
      SALARY_SNAPSHOT_TIME_ET = format_et(.data$salary_snapshot_time),
      WAIVER_STATUS = dplyr::case_when(
        .data$missing_salary_snapshot ~ "Needs salary snapshot review",
        .data$current_same_conf_elsewhere ~ paste0("Currently rostered by ", dplyr::coalesce(.data$current_player_abbrev, .data$current_player_franchise_id)),
        TRUE ~ "Not rostered in same conference at cap run"
      ),
      NOTES = dplyr::case_when(
        .data$missing_salary_snapshot ~ paste0("Dropped in waiver-correction window; no prior ", .data$CONF, " roster snapshot found."),
        TRUE ~ "Dropped in waiver-correction window; verify whether prior-week cap correction is needed."
      )
    ) %>%
    dplyr::arrange(.data$CONF, .data$FRAN, .data$DATE, .data$PLAYER) %>%
    dplyr::select(dplyr::all_of(waiver_correction_columns))
}

get_snapshot_week <- function(current_season = get_current_season(), fantasy_weeks = 17L) {
  snapshot_week_env <- Sys.getenv("SNAPSHOT_WEEK", unset = "")

  if (nzchar(snapshot_week_env)) {
    snapshot_week <- suppressWarnings(as.integer(snapshot_week_env))
    if (is.na(snapshot_week) || snapshot_week < 1) {
      stop("SNAPSHOT_WEEK must be a positive integer when provided.")
    }
    return(snapshot_week)
  }

  if (!requireNamespace("nflreadr", quietly = TRUE)) {
    stop("SNAPSHOT_WEEK is not set and nflreadr is not installed, so the snapshot week cannot be inferred.")
  }

  today_et <- as.Date(format(Sys.time(), tz = "America/New_York", usetz = FALSE))

  schedule <- nflreadr::load_schedules(seasons = current_season)
  schedule_type_col <- dplyr::case_when(
    "season_type" %in% names(schedule) ~ "season_type",
    "game_type" %in% names(schedule) ~ "game_type",
    TRUE ~ NA_character_
  )

  if (is.na(schedule_type_col)) {
    stop("Could not infer SNAPSHOT_WEEK because the NFL schedule data has no season_type or game_type column.")
  }

  schedule <- schedule %>%
    dplyr::filter(
      .data[[schedule_type_col]] == "REG",
      .data$week <= fantasy_weeks,
      !is.na(.data$gameday),
      as.Date(.data$gameday) < today_et
    )

  snapshot_week <- suppressWarnings(max(schedule$week, na.rm = TRUE))

  if (!is.finite(snapshot_week) || is.na(snapshot_week) || snapshot_week < 1) {
    stop(
      "Could not infer SNAPSHOT_WEEK for season ", current_season,
      ". Set SNAPSHOT_WEEK explicitly for offseason or preseason runs."
    )
  }

  as.integer(snapshot_week)
}

get_franchise_lookup <- function(conn) {
  fr <- ffscrapr::ff_franchises(conn)

  abbrev_col <- dplyr::case_when(
    "franchise_abbrev" %in% names(fr) ~ "franchise_abbrev",
    "abbrev" %in% names(fr) ~ "abbrev",
    TRUE ~ NA_character_
  )

  if (is.na(abbrev_col)) {
    fr %>%
      dplyr::transmute(
        franchise_id = as.character(.data$franchise_id),
        FRANCHISE = as.character(.data$franchise_name)
      )
  } else {
    fr %>%
      dplyr::transmute(
        franchise_id = as.character(.data$franchise_id),
        FRANCHISE = as.character(.data[[abbrev_col]])
      )
  } %>%
    dplyr::arrange(suppressWarnings(as.integer(.data$franchise_id)))
}

initialize_summary_shell <- function(franchise_lookup, fantasy_weeks) {
  out <- franchise_lookup %>%
    dplyr::arrange(suppressWarnings(as.integer(.data$franchise_id)))

  for (wk in seq_len(fantasy_weeks)) {
    out[[paste0("W", wk, "_A")]] <- NA_real_
    out[[paste0("W", wk, "_IR")]] <- NA_real_
    out[[paste0("W", wk, "_S")]] <- NA_real_
    out[[paste0("W", wk, "_TE")]] <- NA_real_
    out[[paste0("W", wk, "_Yrs")]] <- NA_real_
    out[[paste0("W", wk, "_Ill?")]] <- NA_character_
    out[[paste0("W", wk, "_Paid")]] <- NA_real_
    out[[paste0("W", wk, "_Vac$")]] <- NA_real_
    out[[paste0("W", wk, "_RostSal")]] <- NA_real_
    out[[paste0("W", wk, "_Adj")]] <- NA_real_
    out[[paste0("W", wk, "_Corr")]] <- NA_real_
    out[[paste0("W", wk, "_Final")]] <- NA_real_
  }

  out
}

normalize_cap_summary_suffixes <- function(summary_df) {
  names(summary_df) <- stringr::str_replace(names(summary_df), "^(W\\d+)_SalAdj$", "\\1_Adj")
  names(summary_df) <- stringr::str_replace(names(summary_df), "^(W\\d+)_Cor$", "\\1_Corr")
  summary_df
}

get_mfl_injuries <- function(current_season, snapshot_week) {
  inj_resp <- httr::GET(
    url = paste0("https://api.myfantasyleague.com/", current_season, "/export"),
    query = list(TYPE = "injuries", W = snapshot_week, JSON = 1),
    httr::user_agent("ADLCommissionerDashboard")
  )

  inj_text <- httr::content(inj_resp, "text", encoding = "UTF-8")
  inj_json <- jsonlite::fromJSON(inj_text, flatten = TRUE)

  if ("error" %in% names(inj_json)) {
    warning(inj_json$error$`$t`)
    return(tibble::tibble(player_id = character(), inj = character()))
  }

  if (!"injuries" %in% names(inj_json) || !"injury" %in% names(inj_json$injuries)) {
    return(tibble::tibble(player_id = character(), inj = character()))
  }

  inj_json$injuries$injury %>%
    tibble::as_tibble() %>%
    dplyr::transmute(
      player_id = as.character(.data$id),
      inj = as.character(.data$status)
    ) %>%
    dplyr::distinct(.data$player_id, .keep_all = TRUE)
}

get_mfl_salary_adjustments <- function(conn) {
  salary_adj_raw <- ffscrapr::mfl_getendpoint(conn, endpoint = "salaryAdjustments")
  adj_list <- salary_adj_raw$content$salaryAdjustments$salaryAdjustment

  if (is.null(adj_list) || length(adj_list) == 0) {
    return(tibble::tibble(franchise_id = character(), amount = numeric()))
  }

  purrr::map_dfr(adj_list, function(x) {
    tibble::tibble(
      franchise_id = dplyr::coalesce(as.character(x$franchise_id), NA_character_),
      amount = suppressWarnings(as.numeric(dplyr::coalesce(as.character(x$amount), NA_character_)))
    )
  }) %>%
    dplyr::mutate(franchise_id = stringr::str_pad(.data$franchise_id, width = 4, side = "left", pad = "0"))
}

summarise_salary_adjustments <- function(sal_adj_df) {
  if (nrow(sal_adj_df) == 0) {
    return(tibble::tibble(franchise_id = character(), Adj = numeric()))
  }

  sal_adj_df %>%
    dplyr::group_by(.data$franchise_id) %>%
    dplyr::summarise(Adj = sum(.data$amount, na.rm = TRUE), .groups = "drop")
}

latest_prior_summary_rds <- function(summary_dir, current_season, snapshot_week) {
  if (!dir.exists(summary_dir)) return(NULL)

  rds_files <- list.files(
    summary_dir,
    pattern = paste0("^", current_season, "w\\d+_ADLsalarycapsummary\\.rds$"),
    full.names = TRUE
  )

  if (length(rds_files) == 0) return(NULL)

  week_nums <- stringr::str_match(
    basename(rds_files),
    paste0("^", current_season, "w(\\d+)_ADLsalarycapsummary\\.rds$")
  )[, 2] %>%
    as.integer()

  prior_idx <- which(week_nums < snapshot_week)
  if (length(prior_idx) == 0) return(NULL)

  rds_files[prior_idx][which.max(week_nums[prior_idx])]
}

build_cap_accounting_snapshot <- function(
  current_season = get_current_season(),
  snapshot_week = as.integer(Sys.getenv("SNAPSHOT_WEEK", unset = "1")),
  fantasy_weeks = 17L,
  output_dir = "data"
) {
  if (is.na(snapshot_week) || snapshot_week < 1) {
    stop("SNAPSHOT_WEEK must be a positive integer.")
  }

  conn <- connect_adl_mfl(current_season)
  vet_min <- get_cap_veteran_min(current_season)

  base_dir <- file.path(output_dir, "cap_accounting", as.character(current_season))
  snapshot_dir <- file.path(base_dir, "snapshots")
  summary_dir <- file.path(base_dir, "summaries")
  waiver_correction_dir <- file.path(base_dir, "waiver_corrections")
  dir.create(snapshot_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(summary_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(waiver_correction_dir, recursive = TRUE, showWarnings = FALSE)

  snapshot_stub <- paste0(current_season, "w", snapshot_week, "_ADLsalarycapsnapshot")
  summary_stub <- paste0(current_season, "w", snapshot_week, "_ADLsalarycapsummary")
  waiver_correction_stub <- paste0(current_season, "w", snapshot_week, "_ADLwaivercorrections")

  output_snapshot_rds <- file.path(snapshot_dir, paste0(snapshot_stub, ".rds"))
  output_snapshot_csv <- file.path(snapshot_dir, paste0(snapshot_stub, ".csv"))
  output_summary_rds <- file.path(summary_dir, paste0(summary_stub, ".rds"))
  output_summary_csv <- file.path(summary_dir, paste0(summary_stub, ".csv"))
  output_waiver_corrections_csv <- file.path(waiver_correction_dir, paste0(waiver_correction_stub, ".csv"))
  output_warnings_csv <- file.path(base_dir, paste0(current_season, "w", snapshot_week, "_ADLsalarycapwarnings.csv"))

  franchise_lookup <- get_franchise_lookup(conn)
  injuries_df <- get_mfl_injuries(current_season, snapshot_week)
  sal_adj_summary <- get_mfl_salary_adjustments(conn) %>%
    summarise_salary_adjustments()
  waiver_corrections <- build_waiver_corrections(
    conn = conn,
    current_season = current_season,
    snapshot_week = snapshot_week,
    vet_min = vet_min,
    franchise_lookup = franchise_lookup,
    output_dir = output_dir
  )

  snapshot_raw <- ffscrapr::ff_rosters(conn, week = snapshot_week) %>%
    dplyr::mutate(
      franchise_id = as.character(.data$franchise_id),
      player_id = as.character(.data$player_id)
    ) %>%
    dplyr::left_join(injuries_df, by = "player_id")

  snapshot_sorted <- snapshot_raw %>%
    dplyr::mutate(pos = factor(.data$pos, levels = cap_pos_order, ordered = TRUE)) %>%
    dplyr::arrange(
      suppressWarnings(as.integer(.data$franchise_id)),
      .data$roster_status,
      .data$pos,
      .data$player_name
    ) %>%
    dplyr::mutate(pos = as.character(.data$pos)) %>%
    dplyr::relocate("inj", .after = "player_name")

  warning_rows <- snapshot_sorted %>%
    dplyr::mutate(
      salary_num = suppressWarnings(as.numeric(.data$salary)),
      player_display = stringr::str_trim(paste(.data$player_name, .data$team, .data$pos)),
      conference = dplyr::case_when(
        suppressWarnings(as.integer(.data$franchise_id)) >= 1L & suppressWarnings(as.integer(.data$franchise_id)) <= 16L ~ "NFC",
        suppressWarnings(as.integer(.data$franchise_id)) >= 17L & suppressWarnings(as.integer(.data$franchise_id)) <= 32L ~ "AFC",
        TRUE ~ NA_character_
      )
    ) %>%
    dplyr::filter(!is.na(.data$salary_num), .data$salary_num == 0) %>%
    dplyr::transmute(
      season = current_season,
      week = snapshot_week,
      file_type = "summary",
      filename = basename(output_summary_csv),
      warning = paste0(.data$player_display, " in ", .data$conference, " has Salary = 0")
    )

  saveRDS(snapshot_sorted, output_snapshot_rds)

  snapshot_csv_out <- snapshot_sorted %>%
    dplyr::mutate(
      roster_status = dplyr::if_else(.data$roster_status == "ROSTER", "ACTIVE_ROSTER", .data$roster_status),
      player_name = stringr::str_trim(paste(.data$player_name, .data$team, .data$pos)),
      salary = format_salary_dollars(.data$salary)
    ) %>%
    dplyr::rename(
      FRANCHISE = "franchise_name",
      PLAYER = "player_name",
      INJ = "inj",
      SALARY = "salary",
      YEARS = "contract_years",
      CONTRACT = "contractInfo",
      ROSTER = "roster_status"
    ) %>%
    dplyr::select(
      "FRANCHISE",
      "PLAYER",
      "INJ",
      "SALARY",
      "YEARS",
      "CONTRACT",
      "ROSTER"
    )

  readr::write_csv(snapshot_csv_out, output_snapshot_csv, na = "")

  prior_summary_rds <- latest_prior_summary_rds(summary_dir, current_season, snapshot_week)

  if (is.null(prior_summary_rds)) {
    summary_out <- initialize_summary_shell(franchise_lookup, fantasy_weeks)
  } else {
    summary_out <- readRDS(prior_summary_rds) %>%
      normalize_cap_summary_suffixes()
    if (!"franchise_id" %in% names(summary_out)) {
      summary_out <- franchise_lookup %>% dplyr::left_join(summary_out, by = "FRANCHISE")
    }
  }

  summary_base <- snapshot_sorted %>%
    dplyr::left_join(franchise_lookup, by = "franchise_id") %>%
    dplyr::mutate(
      roster_status_calc = dplyr::if_else(.data$roster_status == "ROSTER", "ACTIVE_ROSTER", as.character(.data$roster_status)),
      inj = as.character(.data$inj),
      contract_years_num = suppressWarnings(as.numeric(.data$contract_years)),
      salary_num = suppressWarnings(as.numeric(.data$salary)),
      is_active = .data$roster_status_calc == "ACTIVE_ROSTER",
      is_ir = .data$roster_status_calc == "INJURED_RESERVE",
      is_suspended = .data$inj == "Suspended",
      is_taxi_non_suspended = .data$roster_status_calc == "TAXI_SQUAD" & dplyr::coalesce(.data$inj != "Suspended", TRUE),
      is_taxi_suspended = .data$roster_status_calc == "TAXI_SQUAD" & dplyr::coalesce(.data$inj == "Suspended", FALSE)
    )

  current_week_summary <- summary_base %>%
    dplyr::group_by(.data$franchise_id, .data$FRANCHISE) %>%
    dplyr::summarise(
      A = sum(.data$is_active, na.rm = TRUE),
      IR = sum(.data$is_ir, na.rm = TRUE),
      S = sum(.data$is_suspended, na.rm = TRUE),
      TE = sum(.data$is_taxi_non_suspended, na.rm = TRUE),
      Yrs = sum(.data$contract_years_num, na.rm = TRUE) -
        sum(dplyr::if_else(.data$is_ir, .data$contract_years_num, 0), na.rm = TRUE) -
        sum(dplyr::if_else(.data$is_taxi_suspended, .data$contract_years_num, 0), na.rm = TRUE),
      Paid = dplyr::n() - sum(.data$is_taxi_suspended, na.rm = TRUE),
      `Vac$` = pmax(0, vet_min * (45 - (dplyr::n() - sum(.data$is_taxi_suspended, na.rm = TRUE)))),
      RostSal = sum(.data$salary_num, na.rm = TRUE) -
        sum(dplyr::if_else(.data$is_taxi_suspended, .data$salary_num, 0), na.rm = TRUE),
      .groups = "drop"
    ) %>%
    dplyr::mutate(`Ill?` = dplyr::if_else(.data$A < 40 | .data$A + .data$TE > 45 | .data$Yrs > 120, "Y", "")) %>%
    dplyr::left_join(sal_adj_summary, by = "franchise_id") %>%
    dplyr::mutate(
      Adj = dplyr::coalesce(.data$Adj, 0),
      Corr = NA_real_,
      Final = NA_real_
    ) %>%
    dplyr::select(
      "franchise_id",
      "FRANCHISE",
      "A",
      "IR",
      "S",
      "TE",
      "Yrs",
      `Ill?`,
      "Paid",
      `Vac$`,
      "RostSal",
      "Adj",
      "Corr",
      "Final"
    )

  week_cols <- c("A", "IR", "S", "TE", "Yrs", "Ill?", "Paid", "Vac$", "RostSal", "Adj", "Corr", "Final")
  new_names <- paste0("W", snapshot_week, "_", week_cols)
  names(current_week_summary)[match(week_cols, names(current_week_summary))] <- new_names

  summary_out <- summary_out %>%
    dplyr::select(-dplyr::any_of(new_names)) %>%
    dplyr::left_join(current_week_summary, by = c("franchise_id", "FRANCHISE"))

  ordered_summary_cols <- c(
    "franchise_id",
    "FRANCHISE",
    unlist(lapply(seq_len(fantasy_weeks), function(wk) {
      paste0("W", wk, "_", week_cols)
    }))
  )

  summary_out <- summary_out %>%
    dplyr::select(dplyr::any_of(ordered_summary_cols)) %>%
    dplyr::arrange(suppressWarnings(as.integer(.data$franchise_id)))

  saveRDS(summary_out, output_summary_rds)

  summary_csv_out <- summary_out %>%
    dplyr::select(-"franchise_id")

  dollar_summary_cols <- names(summary_csv_out)[
    stringr::str_detect(names(summary_csv_out), "_Vac\\$|_RostSal|_Adj|_Corr|_Final")
  ]

  summary_csv_out <- summary_csv_out %>%
    dplyr::mutate(dplyr::across(dplyr::all_of(dollar_summary_cols), format_summary_dollars))

  readr::write_csv(summary_csv_out, output_summary_csv, na = "")
  readr::write_csv(warning_rows, output_warnings_csv, na = "")
  if (nrow(waiver_corrections) > 0) {
    readr::write_csv(waiver_corrections, output_waiver_corrections_csv, na = "")
  } else if (file.exists(output_waiver_corrections_csv)) {
    unlink(output_waiver_corrections_csv)
  }

  tibble::tibble(
    current_season = current_season,
    snapshot_week = snapshot_week,
    snapshot_csv = output_snapshot_csv,
    snapshot_rds = output_snapshot_rds,
    summary_csv = output_summary_csv,
    summary_rds = output_summary_rds,
    waiver_corrections_csv = if (nrow(waiver_corrections) > 0) output_waiver_corrections_csv else NA_character_,
    warnings_csv = output_warnings_csv
  )
}
