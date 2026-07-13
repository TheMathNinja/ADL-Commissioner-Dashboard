# cap_accounting_engine.R
# -----------------------
# Builds ADL salary cap accounting roster snapshots and weekly summaries.

library(dplyr)
library(ffscrapr)
library(httr)
library(jsonlite)
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

  schedule <- nflreadr::load_schedules(seasons = current_season) %>%
    dplyr::filter(
      .data$season_type == "REG",
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
  dir.create(snapshot_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(summary_dir, recursive = TRUE, showWarnings = FALSE)

  snapshot_stub <- paste0(current_season, "w", snapshot_week, "_ADLsalarycapsnapshot")
  summary_stub <- paste0(current_season, "w", snapshot_week, "_ADLsalarycapsummary")

  output_snapshot_rds <- file.path(snapshot_dir, paste0(snapshot_stub, ".rds"))
  output_snapshot_csv <- file.path(snapshot_dir, paste0(snapshot_stub, ".csv"))
  output_summary_rds <- file.path(summary_dir, paste0(summary_stub, ".rds"))
  output_summary_csv <- file.path(summary_dir, paste0(summary_stub, ".csv"))
  output_warnings_csv <- file.path(base_dir, paste0(current_season, "w", snapshot_week, "_ADLsalarycapwarnings.csv"))

  injuries_df <- get_mfl_injuries(current_season, snapshot_week)
  sal_adj_summary <- get_mfl_salary_adjustments(conn) %>%
    summarise_salary_adjustments()

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

  franchise_lookup <- get_franchise_lookup(conn)
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

  tibble::tibble(
    current_season = current_season,
    snapshot_week = snapshot_week,
    snapshot_csv = output_snapshot_csv,
    snapshot_rds = output_snapshot_rds,
    summary_csv = output_summary_csv,
    summary_rds = output_summary_rds,
    warnings_csv = output_warnings_csv
  )
}
