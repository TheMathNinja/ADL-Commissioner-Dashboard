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

normalize_player_token <- function(x) {
  x |>
    as.character() |>
    toupper() |>
    gsub("[^A-Z0-9]+", " ", x = _) |>
    trimws()
}

player_last_name <- function(x) {
  x <- as.character(x)
  if (grepl(",", x, fixed = TRUE)) {
    return(trimws(strsplit(x, ",", fixed = TRUE)[[1]][[1]]))
  }
  parts <- strsplit(trimws(x), "\\s+")[[1]]
  if (!length(parts)) return("")
  parts[[length(parts)]]
}

player_first_initial <- function(x) {
  x <- trimws(as.character(x))
  if (!nzchar(x)) return("")
  if (grepl(",", x, fixed = TRUE)) {
    parts <- strsplit(x, ",", fixed = TRUE)[[1]]
    after_comma <- if (length(parts) >= 2) trimws(parts[[2]]) else ""
    return(substr(after_comma, 1, 1))
  }
  substr(x, 1, 1)
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

salary_year_pattern <- function(years, salary) {
  if (is.na(years) || is.na(salary)) return(NA_character_)
  salary_value <- gsub("[^0-9]+", " ", sprintf("%.2f", salary))
  paste0("\\b", as.integer(years), "\\s*(YR|YRS|YEAR|YEARS|/|-)[A-Z ]*\\b", salary_value, "\\b")
}

acceleration_matches_player <- function(player, salary, years, body) {
  body_norm <- normalize_player_token(body)
  if (!nzchar(body_norm)) return(FALSE)

  last <- normalize_player_token(player_last_name(player))
  first_initial <- normalize_player_token(player_first_initial(player))
  if (!nzchar(last) || !grepl(paste0("\\b", last, "\\b"), body_norm)) return(FALSE)

  contract_pattern <- salary_year_pattern(years, salary)
  has_contract <- !is.na(contract_pattern) &&
    grepl(contract_pattern, body_norm, ignore.case = TRUE, perl = TRUE)
  has_first_initial <- nzchar(first_initial) &&
    grepl(paste0("\\b", first_initial, "[A-Z]*\\b"), body_norm, perl = TRUE)

  has_contract || has_first_initial || nchar(last) >= 7
}

fetch_saladj_accelerations <- function(season = get_current_season(), franchises = NULL) {
  if (!requireNamespace("httr", quietly = TRUE) ||
      !requireNamespace("rvest", quietly = TRUE) ||
      !requireNamespace("xml2", quietly = TRUE)) {
    warning("Packages httr, rvest, and xml2 are required to fetch SalAdj acceleration declarations.", call. = FALSE)
    return(tibble(franchise = character(), declared_at = character(), body = character()))
  }

  league_id <- get_env_or_default("ADL_LEAGUE_ID", "60206")
  url <- Sys.getenv("ADL_SALADJ_ACCELERATION_THREAD_URL", unset = "")
  if (!nzchar(url) && season == 2026L) {
    url <- "https://www46.myfantasyleague.com/2026/mb/topic_show.pl?bid=202660206&tid=6728505"
  }
  if (!nzchar(url)) {
    return(tibble(franchise = character(), declared_at = character(), body = character()))
  }

  conn <- connect_adl_mfl(season)
  if (is.null(franchises)) franchises <- franchise_reference(conn)

  response <- httr::GET(
    url,
    httr::user_agent(get_env_or_default("MFL_USER_AGENT", "ADLCommissionerDashboard")),
    conn$auth_cookie,
    httr::timeout(as.numeric(get_env_or_default("ADL_MFL_SALADJ_ACCELERATION_TIMEOUT_SECONDS", "30")))
  )
  if (httr::http_error(response)) {
    warning("MFL SalAdj acceleration thread request failed with HTTP ", httr::status_code(response), ".", call. = FALSE)
    return(tibble(franchise = character(), declared_at = character(), body = character()))
  }

  doc <- xml2::read_html(httr::content(response, as = "text", encoding = "UTF-8"))
  post_nodes <- rvest::html_elements(doc, ".frm.pst")
  if (!length(post_nodes)) {
    return(tibble(franchise = character(), declared_at = character(), body = character()))
  }

  posts <- lapply(post_nodes, function(node) {
    poster <- rvest::html_text2(rvest::html_element(node, ".poster a"))
    message_cells <- rvest::html_elements(node, "td.message")
    declared_at <- if (length(message_cells) >= 1) rvest::html_text2(message_cells[[1]]) else ""
    body <- if (length(message_cells) >= 2) rvest::html_text2(message_cells[[length(message_cells)]]) else ""
    tibble(
      franchise = franchise_from_visible_label(poster, franchises),
      declared_at = declared_at,
      body = body
    )
  })

  dplyr::bind_rows(posts) |>
    filter(nzchar(.data$franchise), nzchar(trimws(.data$body))) |>
    distinct()
}

row_has_acceleration_declaration <- function(franchise, player, salary, years, accelerations) {
  if (is.null(accelerations) || !nrow(accelerations)) return(FALSE)
  candidates <- accelerations |> filter(.data$franchise == .env$franchise)
  if (!nrow(candidates)) return(FALSE)
  any(vapply(
    candidates$body,
    acceleration_matches_player,
    logical(1),
    player = player,
    salary = salary,
    years = years
  ))
}

saladj_expected_by_franchise <- function(path, season = get_current_season(), accelerations = NULL,
                                         return_entries = FALSE) {
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

  if (is.null(accelerations)) {
    accelerations <- fetch_saladj_accelerations(season)
  }

  prepared <- saladj |>
    mutate(
      franchise = toupper(trimws(.data$FRAN)),
      player = as.character(.env$player_col),
      player_team = as.character(.env$get_col("PLAYER_TEAM")),
      salary_amount = parse_amount(.data$SALARY),
      years_amount = parse_amount(.data$YEARS),
      row_date = parse_saladj_date(.env$date_col, .env$season),
      is_pre_july_1 = !is.na(.data$row_date) &
        as.Date(.data$row_date, tz = "America/Toronto") < as.Date(paste0(.env$season, "-07-01")),
      is_trade_or_ib = is_marked(.env$tr_ib_col),
      is_fg = is_marked(.env$fg_col),
      is_suspended = is_marked(.env$suspended_col),
      is_jt = is_marked(.env$jt_col),
      is_accelerated_csv = is_marked(.env$acc_col),
      is_accelerated_declared = mapply(
        row_has_acceleration_declaration,
        franchise = .data$franchise,
        player = .data$player,
        salary = .data$salary_amount,
        years = .data$years_amount,
        MoreArgs = list(accelerations = .env$accelerations)
      ),
      is_accelerated = .data$is_accelerated_csv | .data$is_accelerated_declared,
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
    filter(nzchar(.data$franchise), !.data$is_reversed)

  if (isTRUE(return_entries)) {
    return(prepared |>
      transmute(
        expected_id = row_number(),
        franchise,
        player,
        player_team,
        amount = round(.data$expected_amount_known, 2),
        row_date,
        is_cash_trade
      ))
  }

  prepared |>
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
      accelerated_rows = sum(.data$is_accelerated, na.rm = TRUE),
      acceleration_declaration_players = paste(
        head(.data$player[.data$is_accelerated_declared], 12),
        collapse = "; "
      ),
      .groups = "drop"
    )
}

mfl_salary_adjustments_from_visible_page <- function(season = get_current_season(), return_entries = FALSE) {
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

  remaining_cols <- setdiff(names(rows), c(franchise_col, amount_col, ".table_id"))
  description_col <- remaining_cols[match(TRUE, grepl("description|explanation|comment|reason|details", tolower(remaining_cols)))]
  if (is.na(description_col) && length(remaining_cols)) description_col <- remaining_cols[[1]]
  date_candidates <- setdiff(remaining_cols, description_col)
  entered_col <- date_candidates[match(TRUE, grepl("date|time|entered|added", tolower(date_candidates)))]
  if (is.na(entered_col) && length(date_candidates)) entered_col <- date_candidates[[1]]
  description_values <- if (!is.na(description_col)) as.character(rows[[description_col]]) else rep("", nrow(rows))
  entered_values <- if (!is.na(entered_col)) as.character(rows[[entered_col]]) else rep("", nrow(rows))

  entries <- rows |>
    transmute(
      franchise_raw = as.character(.data[[franchise_col]]),
      amount = parse_amount(.data[[amount_col]]),
      description = .env$description_values,
      entered_at = .env$entered_values
    ) |>
    mutate(
      franchise = vapply(.data$franchise_raw, franchise_from_visible_label, character(1), franchises = franchises)
    ) |>
    filter(nzchar(.data$franchise), !is.na(.data$amount)) |>
    mutate(actual_id = row_number())

  if (isTRUE(return_entries)) return(entries)

  entries |>
    group_by(.data$franchise) |>
    summarize(
      mfl_saladj = round(sum(.data$amount, na.rm = TRUE), 2),
      adjustment_count = n(),
      .groups = "drop"
    )
}

description_matches_expected <- function(description, player, is_cash_trade) {
  description <- normalize_player_token(description)
  if (isTRUE(is_cash_trade)) return(TRUE)
  last <- normalize_player_token(player_last_name(player))
  first <- normalize_player_token(player_first_initial(player))
  nzchar(last) && grepl(paste0("\\b", last, "\\b"), description, perl = TRUE) &&
    (!nzchar(first) || grepl(paste0("\\b", first, "\\b"), description, perl = TRUE))
}

build_commissioner_error_report <- function(expected_entries, actual_entries, tolerance = 0.01) {
  used_actual <- integer()
  findings <- vector("list", nrow(expected_entries))

  for (i in seq_len(nrow(expected_entries))) {
    expected <- expected_entries[i, ]
    if (is.na(expected$amount)) {
      findings[[i]] <- tibble(
        issue = "INCOMPLETE_FORMULA", expected_franchise = expected$franchise,
        actual_franchise = NA_character_, player = expected$player,
        expected_amount = NA_real_, actual_amount = NA_real_, mfl_description = "",
        action = "Complete the penalty formula before reconciling this entry."
      )
      next
    }

    description_match <- vapply(
      actual_entries$description, description_matches_expected, logical(1),
      player = expected$player, is_cash_trade = expected$is_cash_trade
    )
    identity_candidates <- which(description_match & !(actual_entries$actual_id %in% used_actual))
    amount_candidates <- identity_candidates[
      abs(actual_entries$amount[identity_candidates] - expected$amount) <= tolerance
    ]
    identity_same_franchise <- identity_candidates[
      actual_entries$franchise[identity_candidates] == expected$franchise
    ]
    same_franchise <- amount_candidates[
      actual_entries$franchise[amount_candidates] == expected$franchise
    ]

    if (length(same_franchise)) {
      chosen <- same_franchise[[1]]
      used_actual <- c(used_actual, actual_entries$actual_id[[chosen]])
      next
    }

    if (isTRUE(expected$is_cash_trade)) {
      findings[[i]] <- tibble(
        issue = "MISSING_ENTRY", expected_franchise = expected$franchise,
        actual_franchise = NA_character_, player = expected$player,
        expected_amount = expected$amount, actual_amount = NA_real_, mfl_description = "",
        action = paste0("Add or verify the missing $", sprintf("%.2f", expected$amount),
                        " cash-trade adjustment for ", expected$franchise, ".")
      )
      next
    }

    if (length(amount_candidates)) {
      chosen <- amount_candidates[[1]]
      used_actual <- c(used_actual, actual_entries$actual_id[[chosen]])
      findings[[i]] <- tibble(
        issue = "WRONG_FRANCHISE", expected_franchise = expected$franchise,
        actual_franchise = actual_entries$franchise[[chosen]], player = expected$player,
        expected_amount = expected$amount, actual_amount = actual_entries$amount[[chosen]],
        mfl_description = actual_entries$description[[chosen]],
        action = paste0("Move this MFL adjustment from ", actual_entries$franchise[[chosen]],
                        " to ", expected$franchise, ".")
      )
      next
    }

    if (length(identity_same_franchise)) {
      chosen <- identity_same_franchise[[which.min(abs(actual_entries$amount[identity_same_franchise] - expected$amount))]]
      used_actual <- c(used_actual, actual_entries$actual_id[[chosen]])
      findings[[i]] <- tibble(
        issue = "WRONG_AMOUNT", expected_franchise = expected$franchise,
        actual_franchise = actual_entries$franchise[[chosen]], player = expected$player,
        expected_amount = expected$amount, actual_amount = actual_entries$amount[[chosen]],
        mfl_description = actual_entries$description[[chosen]],
        action = paste0("Change the MFL adjustment to $", sprintf("%.2f", expected$amount), ".")
      )
      next
    }

    findings[[i]] <- tibble(
      issue = "MISSING_ENTRY", expected_franchise = expected$franchise,
      actual_franchise = NA_character_, player = expected$player,
      expected_amount = expected$amount, actual_amount = NA_real_, mfl_description = "",
      action = paste0("Add the missing $", sprintf("%.2f", expected$amount),
                      " MFL adjustment to ", expected$franchise, ".")
    )
  }

  bind_rows(findings) |>
    arrange(factor(.data$issue, c("WRONG_FRANCHISE", "WRONG_AMOUNT", "MISSING_ENTRY",
                                  "INCOMPLETE_FORMULA")),
            .data$expected_franchise, .data$actual_franchise, .data$player)
}

season <- suppressWarnings(as.integer(arg_value("season", Sys.getenv("CURRENT_SEASON", unset = get_current_season()))))
saladj_csv <- arg_value("saladj-csv", file.path("data", "SalAdjCurator_latest.csv"))
output_csv <- arg_value("output", file.path("data", "saladj_reconciliation.csv"))
error_output_csv <- arg_value("error-output", file.path("data", "commissioner_error_checker.csv"))
tolerance <- suppressWarnings(as.numeric(arg_value("tolerance", "0.01")))
fail_on_mismatch <- arg_flag("fail-on-mismatch") ||
  tolower(Sys.getenv("ADL_SALADJ_RECONCILE_FAIL_ON_MISMATCH", unset = "false")) %in% c("1", "true", "yes")
send_email <- arg_flag("send-email")
issued_csv <- arg_value("issued-ledger", file.path("data", "commissioner_error_checker_issued.csv"))

if (is.na(season)) stop("Provide a valid --season or CURRENT_SEASON.", call. = FALSE)
if (is.na(tolerance) || tolerance < 0) tolerance <- 0.01

expected <- saladj_expected_by_franchise(saladj_csv, season = season)
mfl <- mfl_salary_adjustments_from_visible_page(season = season)
expected_entries <- saladj_expected_by_franchise(saladj_csv, season = season, return_entries = TRUE)
mfl_entries <- mfl_salary_adjustments_from_visible_page(season = season, return_entries = TRUE)
error_report <- build_commissioner_error_report(expected_entries, mfl_entries, tolerance = tolerance)
error_report <- error_report |>
  mutate(issue_key = paste(.data$issue, .data$expected_franchise, .data$actual_franchise,
                           .data$player, sprintf("%.2f", .data$expected_amount),
                           sprintf("%.2f", .data$actual_amount), sep = "|"))

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
    accelerated_rows = coalesce(.data$accelerated_rows, 0L),
    acceleration_declaration_players = coalesce(.data$acceleration_declaration_players, ""),
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
    "missing_penalty_players",
    "accelerated_rows",
    "acceleration_declaration_players"
  )

dir.create(dirname(output_csv), recursive = TRUE, showWarnings = FALSE)
write_csv(report, output_csv, na = "")
write_csv(error_report, error_output_csv, na = "")

mismatches <- report |> filter(.data$status == "MISMATCH")
incomplete <- report |> filter(.data$status == "INCOMPLETE_FORMULA")
message("Wrote SalAdj reconciliation report: ", output_csv)
message("Wrote commissioner error report: ", error_output_csv)
message(nrow(error_report), " item-level commissioner error(s).")

if (send_email && nrow(error_report)) {
  issued <- if (file.exists(issued_csv)) {
    readr::read_csv(issued_csv, col_types = readr::cols(.default = readr::col_character()), show_col_types = FALSE)
  } else {
    tibble(issue_key = character(), issued_at = character())
  }
  new_errors <- error_report |> filter(!.data$issue_key %in% issued$issue_key)

  if (nrow(new_errors)) {
    lines <- unlist(lapply(seq_len(nrow(new_errors)), function(i) {
      row <- new_errors[i, ]
      actual <- if (is.na(row$actual_franchise) || !nzchar(row$actual_franchise)) "not found" else row$actual_franchise
      c(
        paste0(row$issue, ": ", row$player),
        paste0("Expected: ", row$expected_franchise, " / $", sprintf("%.2f", row$expected_amount)),
        paste0("MFL: ", actual,
               if (!is.na(row$actual_amount)) paste0(" / $", sprintf("%.2f", row$actual_amount)) else ""),
        if (nzchar(row$mfl_description)) paste0("MFL entry: ", row$mfl_description) else NULL,
        paste0("Required: ", row$action),
        ""
      )
    }))
    body <- paste(c(
      "The Commissioner Error Checker found new salary-adjustment discrepancies.",
      "",
      lines,
      "This checker is read-only. No MFL entries were changed automatically."
    ), collapse = "\n")
    dir.create(file.path("data", "commissioner_alerts"), recursive = TRUE, showWarnings = FALSE)
    writeLines(body, file.path("data", "commissioner_alerts", "email_outbox_commissioner_error_checker.txt"))
    recipients <- resolve_commissioner_alert_recipients(season = season)
    status <- tryCatch(
      send_alert_mail(
        subject = "[ADL Commissioner Alerts] Commissioner cap-entry errors found",
        body = body,
        to = recipients$email
      ),
      error = function(e) list(sent = FALSE, reason = conditionMessage(e))
    )
    if (isTRUE(status$sent)) {
      issued <- bind_rows(
        issued,
        new_errors |> transmute(issue_key, issued_at = format(Sys.time(), tz = "America/Toronto", usetz = TRUE))
      ) |> distinct(.data$issue_key, .keep_all = TRUE)
      dir.create(dirname(issued_csv), recursive = TRUE, showWarnings = FALSE)
      write_csv(issued, issued_csv)
      message("Sent commissioner error email for ", nrow(new_errors), " new issue(s).")
    } else {
      warning("Commissioner error email was not sent: ", status$reason, call. = FALSE)
    }
  } else {
    message("No new commissioner errors to email; all current issues were previously reported.")
  }
}
message(nrow(mismatches), " franchise mismatch(es).")
message(nrow(incomplete), " franchise(s) need Contract Admin penalty formula values.")
if (nrow(mismatches)) print(mismatches)
if (nrow(incomplete)) print(incomplete)

if (fail_on_mismatch && (nrow(mismatches) || nrow(incomplete))) {
  stop("MFL salary adjustments cannot be fully reconciled to SalAdj Curator expected totals.", call. = FALSE)
}
