# check_saladj_reconciliation.R
# -----------------------------
# Compares MFL salary cap adjustments with the latest SalAdj Curator ledger.

library(dplyr)
library(readr)
library(tibble)

source("R/config_helpers.R")
source("R/commissioner_alerts.R")

arg_value <- function(name, default = NULL) {
  args <- commandArgs(trailingOnly = TRUE)
  prefix <- paste0("--", name, "=")
  matched <- args[startsWith(args, prefix)]
  if (!length(matched)) return(default)
  sub(prefix, "", matched[[1]], fixed = TRUE)
}

arg_flag <- function(name) {
  paste0("--", name) %in% commandArgs(trailingOnly = TRUE)
}

parse_amount <- function(x) {
  suppressWarnings(as.numeric(gsub("[$,]", "", as.character(x))))
}

saladj_expected_by_franchise <- function(path, season = get_current_season()) {
  if (!file.exists(path)) {
    stop("SalAdj Curator CSV not found: ", path, call. = FALSE)
  }

  current_pen_col <- paste0(season, " PEN")
  saladj <- readr::read_csv(path, col_types = readr::cols(.default = readr::col_character()), show_col_types = FALSE)

  if (!"FRAN" %in% names(saladj)) {
    stop("SalAdj Curator CSV is missing FRAN column: ", path, call. = FALSE)
  }
  if (!"SALARY" %in% names(saladj)) {
    stop("SalAdj Curator CSV is missing SALARY column: ", path, call. = FALSE)
  }

  saladj |>
    mutate(
      franchise = toupper(trimws(.data$FRAN)),
      salary_amount = parse_amount(.data$SALARY),
      current_penalty_amount = if (current_pen_col %in% names(saladj)) parse_amount(.data[[current_pen_col]]) else NA_real_,
      expected_amount = case_when(
        !is.na(.data$current_penalty_amount) ~ .data$current_penalty_amount,
        TRUE ~ .data$salary_amount
      )
    ) |>
    filter(nzchar(.data$franchise), !is.na(.data$expected_amount)) |>
    group_by(.data$franchise) |>
    summarize(
      saladj_expected = round(sum(.data$expected_amount, na.rm = TRUE), 2),
      saladj_row_count = n(),
      .groups = "drop"
    )
}

mfl_salary_adjustments_from_visible_page <- function(season = get_current_season()) {
  if (!requireNamespace("httr", quietly = TRUE)) {
    stop("Package httr is required to fetch the MFL salary adjustments page.", call. = FALSE)
  }
  if (!requireNamespace("rvest", quietly = TRUE) || !requireNamespace("xml2", quietly = TRUE)) {
    stop("Packages rvest and xml2 are required to parse the MFL salary adjustments page.", call. = FALSE)
  }

  conn <- connect_adl_mfl(season)
  league_id <- get_env_or_default("ADL_LEAGUE_ID", "60206")
  url <- paste0(
    "https://www46.myfantasyleague.com/", season,
    "/options?L=", league_id,
    "&O=142&SORT=FID&FRANCHISE_ID=0000&DAYS=999"
  )

  response <- httr::GET(
    url,
    httr::user_agent(get_env_or_default("MFL_USER_AGENT", "ADLCommissionerDashboard")),
    conn$auth_cookie,
    httr::timeout(as.numeric(get_env_or_default("ADL_MFL_SALADJ_TIMEOUT_SECONDS", "30")))
  )
  if (httr::http_error(response)) {
    stop("MFL salary adjustments page request failed with HTTP ", httr::status_code(response), ".", call. = FALSE)
  }

  html <- httr::content(response, as = "text", encoding = "UTF-8")
  doc <- xml2::read_html(html)
  tables <- rvest::html_table(doc, fill = TRUE)
  if (!length(tables)) {
    stop("MFL salary adjustments page did not contain parseable tables.", call. = FALSE)
  }

  rows <- dplyr::bind_rows(lapply(seq_along(tables), function(i) {
    tbl <- tibble::as_tibble(tables[[i]], .name_repair = "unique")
    if (!nrow(tbl)) return(tibble())
    names(tbl) <- make.names(names(tbl), unique = TRUE)
    tbl$.table_id <- i
    tbl
  }))

  if (!nrow(rows)) {
    stop("MFL salary adjustments page tables were empty.", call. = FALSE)
  }

  names_lower <- tolower(names(rows))
  franchise_col <- names(rows)[match(TRUE, grepl("franchise|team|owner", names_lower))]
  amount_col <- names(rows)[match(TRUE, grepl("amount|adjust", names_lower))]
  if (is.na(franchise_col) || is.na(amount_col)) {
    stop(
      "Could not identify franchise/amount columns on MFL salary adjustments page. Columns: ",
      paste(names(rows), collapse = ", "),
      call. = FALSE
    )
  }

  rows |>
    transmute(
      franchise_raw = as.character(.data[[franchise_col]]),
      amount = parse_amount(.data[[amount_col]])
    ) |>
    mutate(
      franchise = stringr::str_extract(.data$franchise_raw, "\\b[A-Z]{2,4}\\b"),
      franchise = toupper(trimws(.data$franchise))
    ) |>
    filter(nzchar(.data$franchise), !is.na(.data$amount)) |>
    group_by(.data$franchise) |>
    summarize(
      mfl_saladj = round(sum(.data$amount, na.rm = TRUE), 2),
      adjustment_count = n(),
      .groups = "drop"
    )
}

season <- suppressWarnings(as.integer(arg_value("season", Sys.getenv("CURRENT_SEASON", unset = get_current_season()))))
saladj_csv <- arg_value("saladj-csv", file.path("data", "SalAdjCurator_latest.csv"))
output_csv <- arg_value("output", file.path("data", "saladj_reconciliation.csv"))
tolerance <- suppressWarnings(as.numeric(arg_value("tolerance", "0.01")))
fail_on_mismatch <- arg_flag("fail-on-mismatch") ||
  tolower(Sys.getenv("ADL_SALADJ_RECONCILE_FAIL_ON_MISMATCH", unset = "false")) %in% c("1", "true", "yes")

if (is.na(season)) stop("Provide a valid --season or CURRENT_SEASON.", call. = FALSE)
if (is.na(tolerance) || tolerance < 0) tolerance <- 0.01

expected <- saladj_expected_by_franchise(saladj_csv, season = season)
mfl <- mfl_salary_adjustments_from_visible_page(season = season)

report <- mfl |>
  full_join(expected, by = "franchise") |>
  mutate(
    mfl_saladj = coalesce(.data$mfl_saladj, 0),
    adjustment_count = coalesce(.data$adjustment_count, 0L),
    saladj_expected = coalesce(.data$saladj_expected, 0),
    saladj_row_count = coalesce(.data$saladj_row_count, 0L),
    difference = round(.data$mfl_saladj - .data$saladj_expected, 2),
    status = if_else(abs(.data$difference) <= .env$tolerance, "MATCH", "MISMATCH")
  ) |>
  arrange(.data$status != "MISMATCH", .data$franchise) |>
  select(
    .data$franchise,
    .data$mfl_saladj,
    .data$saladj_expected,
    .data$difference,
    .data$status,
    .data$adjustment_count,
    .data$saladj_row_count
  )

dir.create(dirname(output_csv), recursive = TRUE, showWarnings = FALSE)
write_csv(report, output_csv, na = "")

mismatches <- report |> filter(.data$status == "MISMATCH")
message("Wrote SalAdj reconciliation report: ", output_csv)
message(nrow(mismatches), " franchise mismatch(es).")
if (nrow(mismatches)) print(mismatches)

if (fail_on_mismatch && nrow(mismatches)) {
  stop("MFL salary adjustments do not match SalAdj Curator expected totals.", call. = FALSE)
}
