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

parse_saladj_date <- function(x, season) {
  x <- as.character(x)
  parsed <- suppressWarnings(as.POSIXct(x, format = "%m/%d/%Y %H:%M:%S", tz = "America/Toronto"))
  missing <- is.na(parsed)
  if (any(missing)) {
    parsed[missing] <- suppressWarnings(as.POSIXct(x[missing], format = "%m/%d/%Y", tz = "America/Toronto"))
  }
  parsed
}

is_marked <- function(x) {
  x <- toupper(trimws(as.character(x)))
  !is.na(x) & nzchar(x) & x %in% c("X", "TRUE", "YES", "1")
}

derive_saladj_penalty_amount <- function(salary, years, is_pre_july_1, is_trade_or_ib, is_fg,
                                         is_suspended, is_jt, is_accelerated, plus_amount) {
  fg_rate <- c(
    "1" = 1,
    "2" = 2.1,
    "3" = 3.31,
    "4" = 4.641,
    "5" = 6.1051,
    "6" = 7.71561
  )

  if (is.na(salary) || is.na(years)) return(NA_real_)
  years_key <- as.character(as.integer(years))
  if (abs(years - as.integer(years)) > 0.001) return(NA_real_)

  accelerated_future_penalty <- function() {
    if (is_fg) {
      if (!years_key %in% names(fg_rate) || is.na(plus_amount)) return(NA_real_)
      salary * fg_rate[[years_key]] - salary + plus_amount
    } else if (is_trade_or_ib) {
      0
    } else {
      0.3 * salary * (years - 1)
    }
  }

  base_current_year <- if (is_pre_july_1 && is_fg && !is_jt) {
    if (!years_key %in% names(fg_rate) || is.na(plus_amount)) return(NA_real_)
    salary * fg_rate[[years_key]] + plus_amount
  } else if (is_fg || is_trade_or_ib) {
    salary
  } else if (is_pre_july_1 && !is_jt) {
    0.6 * salary + 0.3 * salary * (years - 1)
  } else {
    0.6 * salary
  }

  base <- base_current_year + if (is_accelerated && !(is_pre_july_1 && !is_jt)) {
    accelerated_future_penalty()
  } else {
    0
  }

  round(if (is_suspended) 0.5 * base else base, 2)
}

normalize_label <- function(x) {
  x |>
    as.character() |>
    toupper() |>
    gsub("[^A-Z0-9]+", " ", x = _) |>
    trimws()
}

franchise_reference <- function(conn) {
  franchise_tbl <- tibble::as_tibble(ffscrapr::ff_franchises(conn))
  franchise_tbl |>
    transmute(
      franchise = toupper(trimws(as.character(coalesce_col(franchise_tbl, c("franchise", "franchise_abbrev", "abbrev"), NA_character_)))),
      franchise_name = as.character(coalesce_col(franchise_tbl, c("franchise_name", "name"), NA_character_)),
      label_abbrev = normalize_label(.data$franchise),
      label_name = normalize_label(.data$franchise_name)
    ) |>
    filter(nzchar(.data$franchise)) |>
    distinct(.data$franchise, .keep_all = TRUE)
}

franchise_from_visible_label <- function(x, franchises) {
  label <- normalize_label(x)
  if (!nzchar(label)) return(NA_character_)

  abbrev_match <- franchises$franchise[match(label, franchises$label_abbrev)]
  if (!is.na(abbrev_match)) return(abbrev_match)

  name_match <- franchises$franchise[match(label, franchises$label_name)]
  if (!is.na(name_match)) return(name_match)

  contains_name <- which(vapply(franchises$label_name, function(name) {
    nzchar(name) && grepl(name, label, fixed = TRUE)
  }, logical(1)))
  if (length(contains_name) == 1L) return(franchises$franchise[[contains_name]])

  contains_abbrev <- which(vapply(franchises$label_abbrev, function(abbrev) {
    nzchar(abbrev) && grepl(paste0("\\b", abbrev, "\\b"), label)
  }, logical(1)))
  if (length(contains_abbrev) == 1L) return(franchises$franchise[[contains_abbrev]])

  NA_character_
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

  get_col <- function(name, default = "") {
    if (name %in% names(saladj)) saladj[[name]] else rep(default, nrow(saladj))
  }

  player_col <- get_col("PLAYER")
  date_col <- get_col("DATE")
  tr_ib_col <- get_col("TR/IB")
  fg_col <- get_col("FG")
  suspended_col <- get_col("(S)")
  jt_col <- get_col("JT")
  plus_col <- get_col("1.XX+")
  rvsd_col <- get_col("RVSD?")
  acc_col <- get_col("ACC")

  saladj |>
    mutate(
      franchise = toupper(trimws(.data$FRAN)),
      player = as.character(.env$player_col),
      salary_amount = parse_amount(.data$SALARY),
      years_amount = parse_amount(.data$YEARS),
      row_date = parse_saladj_date(.env$date_col, .env$season),
      is_pre_july_1 = !is.na(.data$row_date) &
        as.Date(.data$row_date, tz = "America/Toronto") < as.Date(paste0(.env$season, "-07-01")),
      is_trade_or_ib = is_marked(.env$tr_ib_col),
      is_fg = is_marked(.env$fg_col),
      is_suspended = is_marked(.env$suspended_col),
      is_jt = is_marked(.env$jt_col),
      is_accelerated = is_marked(.env$acc_col),
      plus_raw = trimws(as.character(.env$plus_col)),
      plus_amount = case_when(
        is.na(.data$plus_raw) | !nzchar(.data$plus_raw) ~ 0,
        TRUE ~ parse_amount(.data$plus_raw)
      ),
      is_reversed = is_marked(.env$rvsd_col),
      current_penalty_amount = if (current_pen_col %in% names(saladj)) parse_amount(.data[[current_pen_col]]) else NA_real_,
      is_cash_trade = toupper(trimws(.data$player)) == "CASH TRADE",
      expected_amount_known = case_when(
        !is.na(.data$current_penalty_amount) ~ .data$current_penalty_amount,
        .data$is_cash_trade ~ .data$salary_amount,
        TRUE ~ mapply(
          derive_saladj_penalty_amount,
          salary = .data$salary_amount,
          years = .data$years_amount,
          is_pre_july_1 = .data$is_pre_july_1,
          is_trade_or_ib = .data$is_trade_or_ib,
          is_fg = .data$is_fg,
          is_suspended = .data$is_suspended,
          is_jt = .data$is_jt,
          is_accelerated = .data$is_accelerated,
          plus_amount = .data$plus_amount
        )
      )
    ) |>
    filter(nzchar(.data$franchise), !.data$is_reversed) |>
    group_by(.data$franchise) |>
    summarize(
      saladj_expected_known = round(sum(.data$expected_amount_known, na.rm = TRUE), 2),
      saladj_row_count = n(),
      known_penalty_rows = sum(!is.na(.data$expected_amount_known)),
      missing_penalty_rows = sum(is.na(.data$expected_amount_known)),
      missing_penalty_players = paste(
        head(.data$player[is.na(.data$expected_amount_known)], 12),
        collapse = "; "
      ),
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
  franchises <- franchise_reference(conn)
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
      franchise = vapply(.data$franchise_raw, franchise_from_visible_label, character(1), franchises = franchises)
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
    saladj_expected_known = coalesce(.data$saladj_expected_known, 0),
    saladj_row_count = coalesce(.data$saladj_row_count, 0L),
    known_penalty_rows = coalesce(.data$known_penalty_rows, 0L),
    missing_penalty_rows = coalesce(.data$missing_penalty_rows, 0L),
    missing_penalty_players = coalesce(.data$missing_penalty_players, ""),
    saladj_expected = if_else(.data$missing_penalty_rows > 0L, NA_real_, .data$saladj_expected_known),
    difference = if_else(
      .data$missing_penalty_rows > 0L,
      NA_real_,
      round(.data$mfl_saladj - .data$saladj_expected, 2)
    ),
    status = case_when(
      .data$missing_penalty_rows > 0L ~ "INCOMPLETE_FORMULA",
      abs(.data$difference) <= .env$tolerance ~ "MATCH",
      TRUE ~ "MISMATCH"
    )
  ) |>
  arrange(match(.data$status, c("MISMATCH", "INCOMPLETE_FORMULA", "MATCH")), .data$franchise) |>
  select(
    "franchise",
    "mfl_saladj",
    "saladj_expected",
    "saladj_expected_known",
    "difference",
    "status",
    "adjustment_count",
    "saladj_row_count",
    "known_penalty_rows",
    "missing_penalty_rows",
    "missing_penalty_players"
  )

dir.create(dirname(output_csv), recursive = TRUE, showWarnings = FALSE)
write_csv(report, output_csv, na = "")

mismatches <- report |> filter(.data$status == "MISMATCH")
incomplete <- report |> filter(.data$status == "INCOMPLETE_FORMULA")
message("Wrote SalAdj reconciliation report: ", output_csv)
message(nrow(mismatches), " franchise mismatch(es).")
message(nrow(incomplete), " franchise(s) need Contract Admin penalty formula values.")
if (nrow(mismatches)) print(mismatches)
if (nrow(incomplete)) print(incomplete)

if (fail_on_mismatch && (nrow(mismatches) || nrow(incomplete))) {
  stop("MFL salary adjustments cannot be fully reconciled to SalAdj Curator expected totals.", call. = FALSE)
}
