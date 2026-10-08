# check_saladj_reconciliation.R
# -----------------------------
# Compares MFL salary cap adjustments with the latest SalAdj Curator ledger.

library(dplyr)
library(readr)
library(tibble)

source("R/config_helpers.R")
source("R/commissioner_alerts.R")

get_google_service_account_path <- function() {
  credentials_path <- Sys.getenv("GOOGLE_APPLICATION_CREDENTIALS", unset = "")
  if (nzchar(credentials_path)) return(credentials_path)

  credentials_json <- Sys.getenv("GOOGLE_SERVICE_ACCOUNT_JSON", unset = "")
  if (!nzchar(credentials_json)) return("")

  path <- tempfile(fileext = ".json")
  writeLines(credentials_json, path, useBytes = TRUE)
  path
}

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
  raw <- trimws(as.character(x))
  raw <- gsub("[\u2212\u2012\u2013\u2014]", "-", raw, perl = TRUE)
  is_negative <- grepl("^\\s*-", raw) | grepl("^\\(.*\\)$", raw)
  match_at <- regexpr("[+-]?[0-9][0-9,]*(\\.[0-9]+)?", raw, perl = TRUE)
  cleaned <- rep(NA_character_, length(raw))
  found <- !is.na(match_at) & match_at > 0
  if (any(found)) {
    found_match_at <- regexpr("[+-]?[0-9][0-9,]*(\\.[0-9]+)?", raw[found], perl = TRUE)
    cleaned[found] <- regmatches(raw[found], found_match_at)
  }
  cleaned <- gsub(",", "", cleaned, fixed = TRUE)
  parsed <- suppressWarnings(as.numeric(cleaned))
  parsed[is_negative & !is.na(parsed)] <- -abs(parsed[is_negative & !is.na(parsed)])
  parsed
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
  br_col <- get_col("B/R")
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
      player_pos = as.character(.env$get_col("PLAYER_POS")),
      contract_type = as.character(.env$get_col("CONTRACT")),
      salary_amount = parse_amount(.data$SALARY),
      years_amount = parse_amount(.data$YEARS),
      row_date = parse_saladj_date(.env$date_col, .env$season),
      is_pre_july_1 = !is.na(.data$row_date) &
        as.Date(.data$row_date, tz = "America/Toronto") < as.Date(paste0(.env$season, "-07-01")),
      is_br = is_marked(.env$br_col),
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
        player_pos,
        contract_type,
        amount = round(.data$expected_amount_known, 2),
        salary_amount,
        years_amount,
        row_date,
        is_cash_trade,
        is_br,
        is_trade_or_ib,
        is_fg,
        is_suspended,
        is_jt,
        is_accelerated,
        plus_raw,
        plus_amount
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
    (!nzchar(first) || grepl(paste0("\\b", first, "[A-Z]*\\b"), description, perl = TRUE))
}

description_suspected_name_match <- function(description, player, is_cash_trade) {
  if (isTRUE(is_cash_trade) || description_matches_expected(description, player, FALSE)) return(FALSE)
  description <- normalize_player_token(description)
  last <- normalize_player_token(player_last_name(player))
  first <- normalize_player_token(player_first_initial(player))
  if (!nzchar(last) || !nzchar(description) ||
      (nzchar(first) && !grepl(paste0("\\b", first, "[A-Z]*\\b"), description, perl = TRUE))) {
    return(FALSE)
  }
  description_words <- strsplit(description, "\\s+")[[1]]
  last_word_count <- length(strsplit(last, "\\s+")[[1]])
  if (length(description_words) < last_word_count) return(FALSE)
  candidates <- vapply(seq_len(length(description_words) - last_word_count + 1L), function(i) {
    paste(description_words[i:(i + last_word_count - 1L)], collapse = " ")
  }, character(1))
  min(utils::adist(last, candidates)) <= 1L
}

format_audit_datetime <- function(x) {
  if (!length(x) || is.na(x) || !nzchar(trimws(as.character(x)))) return("")
  render <- function(value) {
    paste0(
      format(value, "%b", tz = "America/Toronto"), " ",
      as.integer(format(value, "%d", tz = "America/Toronto")), ", ",
      format(value, "%Y", tz = "America/Toronto"), " at ",
      as.integer(format(value, "%I", tz = "America/Toronto")),
      format(value, ":%M:%S %p ET", tz = "America/Toronto")
    )
  }
  if (inherits(x, "POSIXt")) {
    return(render(x))
  }
  raw <- trimws(as.character(x))
  normalized <- gsub("a\\.m\\.", "AM", raw, ignore.case = TRUE)
  normalized <- gsub("p\\.m\\.", "PM", normalized, ignore.case = TRUE)
  parsed <- suppressWarnings(as.POSIXct(normalized, format = "%a %b %d %I:%M:%S %p ET %Y", tz = "America/Toronto"))
  if (is.na(parsed)) raw else render(parsed)
}

missing_entry_affected_official_snapshot <- function(drop_time, latest_snapshot_time) {
  drop_time <- suppressWarnings(as.POSIXct(drop_time, tz = "UTC"))
  latest_snapshot_time <- suppressWarnings(as.POSIXct(latest_snapshot_time, tz = "UTC"))
  !is.na(drop_time) && !is.na(latest_snapshot_time) && latest_snapshot_time >= drop_time
}

latest_official_cap_snapshot_time <- function(season, base_dir = file.path("data", "cap_accounting")) {
  season_dir <- file.path(base_dir, as.character(season))
  metadata_files <- list.files(
    season_dir,
    pattern = paste0("^", season, "w[0-9]+_ADLsalarycapmetadata[.]csv$"),
    full.names = TRUE
  )
  metadata_times <- unlist(lapply(metadata_files, function(path) {
    rows <- suppressWarnings(readr::read_csv(path, show_col_types = FALSE))
    if (!"snapshot_taken_at_utc" %in% names(rows)) return(as.POSIXct(character()))
    suppressWarnings(as.POSIXct(rows$snapshot_taken_at_utc, tz = "UTC"))
  }))
  metadata_times <- as.POSIXct(metadata_times, origin = "1970-01-01", tz = "UTC")
  metadata_times <- metadata_times[!is.na(metadata_times)]
  if (length(metadata_times)) return(max(metadata_times))

  adjustment_files <- list.files(
    file.path(season_dir, "adjustment_snapshots"),
    pattern = paste0("^", season, "w[0-9]+_ADLsalaryadjustments[.]csv$"),
    full.names = TRUE
  )
  adjustment_times <- unlist(lapply(adjustment_files, function(path) {
    rows <- suppressWarnings(readr::read_csv(path, show_col_types = FALSE))
    if (!"captured_at_utc" %in% names(rows)) return(as.POSIXct(character()))
    suppressWarnings(as.POSIXct(rows$captured_at_utc, tz = "UTC"))
  }))
  adjustment_times <- as.POSIXct(adjustment_times, origin = "1970-01-01", tz = "UTC")
  adjustment_times <- adjustment_times[!is.na(adjustment_times)]
  if (length(adjustment_times)) max(adjustment_times) else as.POSIXct(NA, tz = "UTC")
}

build_commissioner_error_report <- function(
  expected_entries,
  actual_entries,
  tolerance = 0.01,
  latest_snapshot_time = as.POSIXct(NA, tz = "UTC")
) {
  used_actual <- integer()
  findings <- vector("list", nrow(expected_entries))

  for (i in seq_len(nrow(expected_entries))) {
    expected <- expected_entries[i, ]
    if (is.na(expected$amount)) {
      findings[[i]] <- tibble(
        issue = "INCOMPLETE_FORMULA", expected_franchise = expected$franchise,
        actual_franchise = NA_character_, player = expected$player,
        expected_amount = NA_real_, actual_amount = NA_real_, mfl_description = "",
        transaction_date = format_audit_datetime(expected$row_date), mfl_entered_at = "",
        action = "Complete the penalty formula before reconciling this entry."
      )
      next
    }

    description_match <- vapply(
      actual_entries$description, description_matches_expected, logical(1),
      player = expected$player, is_cash_trade = expected$is_cash_trade
    )
    identity_candidates <- which(description_match & !(actual_entries$actual_id %in% used_actual))
    candidate_amounts <- actual_entries$amount[identity_candidates]
    amount_candidates <- identity_candidates[
      !is.na(candidate_amounts) &
        abs(candidate_amounts - expected$amount) <= tolerance
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
      if (!missing_entry_affected_official_snapshot(expected$row_date, latest_snapshot_time)) next
      findings[[i]] <- tibble(
        issue = "MISSING_ENTRY", expected_franchise = expected$franchise,
        actual_franchise = NA_character_, player = expected$player,
        expected_amount = expected$amount, actual_amount = NA_real_, mfl_description = "",
        transaction_date = format_audit_datetime(expected$row_date), mfl_entered_at = "",
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
        transaction_date = format_audit_datetime(expected$row_date),
        mfl_entered_at = format_audit_datetime(actual_entries$entered_at[[chosen]]),
        action = paste0("Move this MFL adjustment from ", actual_entries$franchise[[chosen]],
                        " to ", expected$franchise, ".")
      )
      next
    }

    if (length(identity_same_franchise)) {
      numeric_identity_candidates <- identity_same_franchise[!is.na(actual_entries$amount[identity_same_franchise])]
      chosen <- if (length(numeric_identity_candidates)) {
        numeric_identity_candidates[[which.min(abs(actual_entries$amount[numeric_identity_candidates] - expected$amount))]]
      } else {
        identity_same_franchise[[1]]
      }
      used_actual <- c(used_actual, actual_entries$actual_id[[chosen]])
      findings[[i]] <- tibble(
        issue = "WRONG_AMOUNT", expected_franchise = expected$franchise,
        actual_franchise = actual_entries$franchise[[chosen]], player = expected$player,
        expected_amount = expected$amount, actual_amount = actual_entries$amount[[chosen]],
        mfl_description = actual_entries$description[[chosen]],
        transaction_date = format_audit_datetime(expected$row_date),
        mfl_entered_at = format_audit_datetime(actual_entries$entered_at[[chosen]]),
        action = paste0("Change the MFL adjustment to $", sprintf("%.2f", expected$amount), ".")
      )
      next
    }


    suspected_match <- vapply(
      actual_entries$description, description_suspected_name_match, logical(1),
      player = expected$player, is_cash_trade = expected$is_cash_trade
    )
    suspected_candidates <- which(
      suspected_match & !(actual_entries$actual_id %in% used_actual) &
        actual_entries$franchise == expected$franchise &
        !is.na(actual_entries$amount) &
        abs(actual_entries$amount - expected$amount) <= tolerance
    )
    if (length(suspected_candidates)) {
      chosen <- suspected_candidates[[1]]
      used_actual <- c(used_actual, actual_entries$actual_id[[chosen]])
      findings[[i]] <- tibble(
        issue = "SUSPECTED_NAME_MATCH", expected_franchise = expected$franchise,
        actual_franchise = actual_entries$franchise[[chosen]], player = expected$player,
        expected_amount = expected$amount, actual_amount = actual_entries$amount[[chosen]],
        mfl_description = actual_entries$description[[chosen]],
        transaction_date = format_audit_datetime(expected$row_date),
        mfl_entered_at = format_audit_datetime(actual_entries$entered_at[[chosen]]),
        action = paste0(
          "Verify whether Contract Admin '", expected$player, "' and MFL '",
          actual_entries$description[[chosen]],
          "' refer to the same player; correct the Contract Admin spelling if so."
        )
      )
      next
    }

    if (!missing_entry_affected_official_snapshot(expected$row_date, latest_snapshot_time)) next
    findings[[i]] <- tibble(
      issue = "MISSING_ENTRY", expected_franchise = expected$franchise,
      actual_franchise = NA_character_, player = expected$player,
      expected_amount = expected$amount, actual_amount = NA_real_, mfl_description = "",
      transaction_date = format_audit_datetime(expected$row_date), mfl_entered_at = "",
      action = paste0("Add the missing $", sprintf("%.2f", expected$amount),
                      " MFL adjustment to ", expected$franchise, ".")
    )
  }

  result <- bind_rows(findings)
  if (!nrow(result)) {
    return(tibble(
      issue = character(), expected_franchise = character(), actual_franchise = character(),
      player = character(), expected_amount = double(), actual_amount = double(),
      mfl_description = character(), transaction_date = character(),
      mfl_entered_at = character(), action = character()
    ))
  }

  result |>
    arrange(factor(.data$issue, c("WRONG_FRANCHISE", "WRONG_AMOUNT", "SUSPECTED_NAME_MATCH", "MISSING_ENTRY",
                                  "INCOMPLETE_FORMULA")),
            .data$expected_franchise, .data$actual_franchise, .data$player)
}

contract_admin_saladj_entries <- function(season) {
  if (!requireNamespace("googlesheets4", quietly = TRUE)) {
    stop("Package googlesheets4 is required for the Contract Admin audit.", call. = FALSE)
  }
  credentials <- get_google_service_account_path()
  if (!nzchar(credentials)) {
    stop("GOOGLE_SERVICE_ACCOUNT_JSON or GOOGLE_APPLICATION_CREDENTIALS is required for the Contract Admin audit.", call. = FALSE)
  }

  googlesheets4::gs4_auth(path = credentials)
  sheet_id <- Sys.getenv(
    "CONTRACT_ADMIN_SHEET_ID",
    unset = "1Pyw8qVfiBlXNuX0lW0LdjRnBiijfbo2BXHfZMWwLLaw"
  )
  penalty_col <- paste0(season, " PEN")

  bind_rows(lapply(c("NFC Sal Adj", "AFC Sal Adj"), function(tab) {
    rows <- googlesheets4::read_sheet(
      ss = sheet_id,
      sheet = tab,
      range = "A1:X",
      col_names = FALSE,
      col_types = "c",
      .name_repair = "minimal"
    )
    rows <- as.data.frame(rows, stringsAsFactors = FALSE)
    headers <- trimws(as.character(unlist(rows[1, ], use.names = FALSE)))
    required <- c(
      "DATE", "FRAN", "PLAYER", "SALARY", "B/R", "TR/IB", "FG", "(S)",
      "JT", "ACC", "1.XX+", penalty_col, "RVSD?"
    )
    missing <- setdiff(required, headers)
    if (length(missing)) {
      stop(tab, " is missing columns: ", paste(missing, collapse = ", "), call. = FALSE)
    }
    column_index <- vapply(required, function(name) which(headers == name)[[1]], integer(1))
    values <- rows[-1, , drop = FALSE]

    tibble(
      franchise = toupper(trimws(as.character(values[[column_index[["FRAN"]]]]))),
      player = trimws(as.character(values[[column_index[["PLAYER"]]]])),
      input_salary = parse_amount(values[[column_index[["SALARY"]]]]),
      penalty_amount = parse_amount(values[[column_index[[penalty_col]]]]),
      entered_at = as.character(values[[column_index[["DATE"]]]]),
      description = trimws(as.character(values[[column_index[["PLAYER"]]]])),
      is_br = is_marked(values[[column_index[["B/R"]]]]),
      is_trade_or_ib = is_marked(values[[column_index[["TR/IB"]]]]),
      is_fg = is_marked(values[[column_index[["FG"]]]]),
      is_suspended = is_marked(values[[column_index[["(S)"]]]]),
      is_jt = is_marked(values[[column_index[["JT"]]]]),
      is_accelerated = is_marked(values[[column_index[["ACC"]]]]),
      plus_raw = trimws(as.character(values[[column_index[["1.XX+"]]]])),
      plus_amount = case_when(
        is.na(.data$plus_raw) | !nzchar(.data$plus_raw) ~ 0,
        TRUE ~ parse_amount(.data$plus_raw)
      ),
      is_reversed = is_marked(values[[column_index[["RVSD?"]]]]),
      sheet_tab = tab
    ) |>
      filter(nzchar(.data$franchise), nzchar(.data$player), !.data$is_reversed)
  })) |>
    mutate(actual_id = row_number())
}

audit_contract_admin_control_fields <- function(expected_entries, sheet_entries, tolerance = 0.01) {
  controls <- tibble::tribble(
    ~field, ~label,
    "is_br", "B/R",
    "is_trade_or_ib", "TR/IB",
    "is_fg", "FG",
    "is_suspended", "(S)",
    "is_jt", "JT",
    "is_accelerated", "ACC"
  )
  findings <- list()
  finding_index <- 0L

  for (i in seq_len(nrow(expected_entries))) {
    expected <- expected_entries[i, ]
    candidates <- which(
      sheet_entries$franchise == expected$franchise &
        vapply(
          sheet_entries$description,
          description_matches_expected,
          logical(1),
          player = expected$player,
          is_cash_trade = expected$is_cash_trade
        ) &
        !is.na(sheet_entries$input_salary) &
        abs(sheet_entries$input_salary - expected$salary_amount) <= tolerance
    )
    if (!length(candidates)) next
    actual <- sheet_entries[candidates[[1]], ]

    for (j in seq_len(nrow(controls))) {
      field <- controls$field[[j]]
      if (identical(isTRUE(expected[[field]]), isTRUE(actual[[field]]))) next
      label <- controls$label[[j]]
      direction <- if (isTRUE(expected[[field]])) "missing" else "unexpected"
      finding_index <- finding_index + 1L
      findings[[finding_index]] <- tibble(
        issue = "WRONG_CONTROL_FLAG",
        expected_franchise = expected$franchise,
        actual_franchise = actual$franchise,
        player = paste0(expected$player, " (", label, ")"),
        expected_amount = expected$amount,
        actual_amount = actual$penalty_amount,
        mfl_description = paste0(
          "Contract Admin ", label, " flag is ", direction,
          "; this caused the sheet formula to calculate $",
          sprintf("%.2f", actual$penalty_amount), " instead of $",
          sprintf("%.2f", expected$amount), "."
        ),
        transaction_date = format_audit_datetime(expected$row_date),
        mfl_entered_at = format_audit_datetime(actual$entered_at),
        action = if (isTRUE(expected[[field]])) {
          paste0("Mark ", label, " with x in Contract Admin and let its penalty formula recalculate.")
        } else {
          paste0("Remove the unexpected ", label, " mark in Contract Admin and let its penalty formula recalculate.")
        },
        stage = "SalAdj Curator controls -> Contract Admin formula",
        actual_system = "Contract Admin"
      )
    }

    expected_plus <- dplyr::coalesce(expected$plus_amount, 0)
    actual_plus <- dplyr::coalesce(actual$plus_amount, 0)
    if (abs(expected_plus - actual_plus) > tolerance) {
      finding_index <- finding_index + 1L
      findings[[finding_index]] <- tibble(
        issue = "WRONG_CONTROL_VALUE",
        expected_franchise = expected$franchise,
        actual_franchise = actual$franchise,
        player = paste0(expected$player, " (1.XX+)"),
        expected_amount = expected$amount,
        actual_amount = actual$penalty_amount,
        mfl_description = paste0(
          "Contract Admin 1.XX+ is '", actual$plus_raw, "' but Curator has '",
          expected$plus_raw, "'; the formula produced $", sprintf("%.2f", actual$penalty_amount),
          " instead of $", sprintf("%.2f", expected$amount), "."
        ),
        transaction_date = format_audit_datetime(expected$row_date),
        mfl_entered_at = format_audit_datetime(actual$entered_at),
        action = "Copy the Curator 1.XX+ value into Contract Admin and let its penalty formula recalculate.",
        stage = "SalAdj Curator controls -> Contract Admin formula",
        actual_system = "Contract Admin"
      )
    }
  }

  bind_rows(findings)
}

build_historical_mfl_expectations <- function(sheet_entries, curator_entries, season, tolerance = 0.01) {
  expected <- sheet_entries |>
    filter(!is.na(.data$penalty_amount)) |>
    transmute(
      expected_id = row_number(),
      source_sheet_id = .data$actual_id,
      franchise,
      player,
      player_team = "",
      amount = .data$penalty_amount,
      input_salary,
      row_date = parse_saladj_date(.data$entered_at, season),
      is_cash_trade = toupper(trimws(.data$player)) == "CASH TRADE"
    )
  used_sheet_ids <- integer()

  for (i in seq_len(nrow(curator_entries))) {
    curator <- curator_entries[i, ]
    candidates <- which(
      expected$franchise == curator$franchise &
        !(expected$source_sheet_id %in% used_sheet_ids) &
        vapply(
          expected$player,
          description_matches_expected,
          logical(1),
          player = curator$player,
          is_cash_trade = curator$is_cash_trade
        ) &
        !is.na(expected$input_salary) &
        abs(expected$input_salary - curator$salary_amount) <= tolerance
    )
    if (!length(candidates)) next
    chosen <- candidates[[1]]
    expected$amount[[chosen]] <- curator$amount
    expected$player[[chosen]] <- curator$player
    expected$player_team[[chosen]] <- curator$player_team
    expected$row_date[[chosen]] <- curator$row_date
    expected$is_cash_trade[[chosen]] <- curator$is_cash_trade
    used_sheet_ids <- c(used_sheet_ids, expected$source_sheet_id[[chosen]])
  }

  expected |>
    select(-.data$source_sheet_id, -.data$input_salary)
}

label_stage_findings <- function(findings, stage, actual_system) {
  if (!nrow(findings)) return(findings)
  findings |>
    mutate(
      stage = stage,
      actual_system = actual_system,
      action = gsub("MFL adjustment", paste0(actual_system, " entry"), .data$action, fixed = TRUE)
    )
}

checker_list_label <- function(row) {
  if (identical(as.character(row$actual_system), "MFL")) return("MFL salary adjustments")
  if (grepl("Cap Rollover", as.character(row$stage), fixed = TRUE)) {
    return("Contract Admin Cap Rollover")
  }
  if (identical(as.character(row$actual_system), "Contract Admin")) {
    nfc <- c("DAL", "NYG", "PHI", "WAS", "CHI", "DET", "GBP", "MIN",
             "ATL", "CAR", "NOS", "TBB", "ARI", "LAR", "SFO", "SEA")
    conference <- if (as.character(row$expected_franchise) %in% nfc) "NFC" else "AFC"
    return(paste(conference, "Sal Adj tab (Contract Admin Sheet)"))
  }
  as.character(row$actual_system)
}

checker_error_label <- function(issue, list_label) {
  label <- switch(
    as.character(issue),
    MISSING_ENTRY = "Missing entry in",
    SUSPECTED_NAME_MATCH = "Suspected typo match in",
    WRONG_FRANCHISE = "Incorrect franchise in",
    WRONG_AMOUNT = "Incorrect amount in",
    INCOMPLETE_FORMULA = "Incomplete formula in",
    WRONG_CONTROL_FLAG = "Incorrect control flag in",
    WRONG_CONTROL_VALUE = "Incorrect control value in",
    CAP_ROLLOVER_MISMATCH = "Incorrect value in",
    "Discrepancy in"
  )
  paste(label, list_label)
}

checker_expected_label <- function(list_label) {
  if (identical(list_label, "MFL salary adjustments")) return("Expected MFL salary-adjustment entry")
  if (grepl(" Sal Adj tab ", list_label, fixed = TRUE)) return("Expected Sal Adj tab entry")
  paste0("Expected ", list_label, " entry")
}

checker_row_value <- function(row, name, default = "") {
  if (!name %in% names(row) || !length(row[[name]]) || is.na(row[[name]][[1]])) return(default)
  as.character(row[[name]][[1]])
}

format_checker_finding <- function(row) {
  list_label <- checker_list_label(row)
  is_control_issue <- as.character(row$issue) %in% c("WRONG_CONTROL_FLAG", "WRONG_CONTROL_VALUE")
  amount_prefix <- if (is_control_issue) {
    "Calculated penalty"
  } else if (grepl(" Sal Adj tab ", list_label, fixed = TRUE)) {
    "Contract"
  } else if (identical(list_label, "MFL salary adjustments")) {
    "Penalty/adjustment"
  } else {
    "Value"
  }
  expected_amount <- if (is.na(row$expected_amount)) {
    "Amount/formula pending"
  } else {
    paste0(amount_prefix, ": $", sprintf("%.2f", row$expected_amount))
  }
  player_team <- checker_row_value(row, "expected_player_team")
  player_pos <- checker_row_value(row, "expected_player_pos")
  player_identity <- if (grepl(" Sal Adj tab ", list_label, fixed = TRUE)) {
    as.character(row$player)
  } else {
    paste(c(row$player, player_team, player_pos)[nzchar(c(row$player, player_team, player_pos))], collapse = " ")
  }
  years <- suppressWarnings(as.numeric(checker_row_value(row, "expected_years", NA_character_)))
  contract <- checker_row_value(row, "expected_contract")
  contract_details <- if (grepl(" Sal Adj tab ", list_label, fixed = TRUE)) {
    c(if (!is.na(years)) paste0(format(years, trim = TRUE, scientific = FALSE), " yr"), contract)
  } else character()
  expected_financial <- paste(c(expected_amount, contract_details)[nzchar(c(expected_amount, contract_details))], collapse = " / ")
  expected_parts <- c(row$expected_franchise, player_identity, expected_financial)
  expected_parts <- expected_parts[!is.na(expected_parts) & nzchar(expected_parts)]
  actual_franchise <- checker_row_value(row, "actual_franchise")
  actual_amount <- suppressWarnings(as.numeric(checker_row_value(row, "actual_amount", NA_character_)))
  actual_description <- checker_row_value(row, "mfl_description")
  actual_identity <- if (identical(list_label, "MFL salary adjustments") && nzchar(actual_description)) {
    actual_description
  } else {
    player_identity
  }
  actual_financial <- paste(c(
    if (!is.na(actual_amount)) paste0(amount_prefix, ": $", sprintf("%.2f", actual_amount)),
    contract_details
  )[nzchar(c(
    if (!is.na(actual_amount)) paste0(amount_prefix, ": $", sprintf("%.2f", actual_amount)),
    contract_details
  ))], collapse = " / ")
  actual_parts <- c(
    actual_franchise,
    actual_identity,
    actual_financial
  )
  actual_parts <- actual_parts[!is.na(actual_parts) & nzchar(actual_parts)]
  actual_label <- if (as.character(row$issue) == "SUSPECTED_NAME_MATCH") {
    paste0("Possible matching ", list_label, " entry")
  } else if (grepl(" Sal Adj tab ", list_label, fixed = TRUE)) {
    "Erroneous Sal Adj tab entry"
  } else {
    paste0("Erroneous ", list_label, " entry")
  }
  required_action <- if (as.character(row$issue) == "MISSING_ENTRY" &&
                         grepl(" Sal Adj tab ", list_label, fixed = TRUE)) {
    conference <- sub(" Sal Adj tab.*$", "", list_label)
    missing_contract <- paste(c(
      if (!is.na(row$expected_amount)) paste0("$", sprintf("%.2f", row$expected_amount)),
      contract_details
    )[nzchar(c(
      if (!is.na(row$expected_amount)) paste0("$", sprintf("%.2f", row$expected_amount)),
      contract_details
    ))], collapse = " / ")
    paste0(
      "Add ", row$expected_franchise, "'s ", row$player, " drop (", missing_contract,
      ") to the ", conference, " Sal Adj tab."
    )
  } else {
    as.character(row$action)
  }
  c(
    paste0("Error Type: ", checker_error_label(row$issue, list_label)),
    if (nzchar(actual_franchise) && !is.na(actual_amount)) {
      paste0(actual_label, ": ", paste(actual_parts, collapse = " | "))
    } else NULL,
    paste0(checker_expected_label(list_label), ": ", paste(expected_parts, collapse = " | ")),
    if (!is.na(row$transaction_date) && nzchar(row$transaction_date)) paste0("Original transaction/drop: ", row$transaction_date) else NULL,
    if (identical(list_label, "MFL salary adjustments") &&
        !is.na(row$mfl_entered_at) && nzchar(row$mfl_entered_at)) {
      paste0("MFL salary-adjustment entry date: ", row$mfl_entered_at)
    } else NULL,
    paste0("Required: ", required_action),
    ""
  )
}

build_checker_email_body <- function(error_report) {
  lines <- unlist(lapply(seq_len(nrow(error_report)), function(i) {
    format_checker_finding(error_report[i, ])
  }))
  paste(c(
    "The Commissioner Error Checker found salary-adjustment discrepancies.",
    "",
    lines,
    "This checker is read-only. No Contract Admin or MFL entries were changed automatically."
  ), collapse = "\n")
}

audit_cap_rollover_sheet <- function(season, tolerance = 0.01) {
  credentials <- get_google_service_account_path()
  if (!nzchar(credentials) || !requireNamespace("googlesheets4", quietly = TRUE)) {
    return(tibble())
  }

  sheet_id <- Sys.getenv(
    "CONTRACT_ADMIN_SHEET_ID",
    unset = "1Pyw8qVfiBlXNuX0lW0LdjRnBiijfbo2BXHfZMWwLLaw"
  )
  summary_dir <- file.path("data", "cap_accounting", as.character(season), "summaries")
  files <- list.files(summary_dir, pattern = paste0("^", season, "w[0-9]+_ADLsalarycapsummary\\.csv$"), full.names = TRUE)
  if (!length(files)) return(tibble())

  googlesheets4::gs4_auth(path = credentials)
  sheet <- googlesheets4::read_sheet(
    ss = sheet_id, sheet = "Cap Rollover", range = "A1:HC34",
    col_names = FALSE, col_types = "c", .name_repair = "minimal"
  )
  sheet <- as.data.frame(sheet, stringsAsFactors = FALSE)
  teams <- trimws(as.character(sheet[3:34, 1]))
  findings <- list()

  for (file in files) {
    week <- suppressWarnings(as.integer(sub(paste0("^.*", season, "w([0-9]+)_.*$"), "\\1", file)))
    if (is.na(week)) next
    summary <- readr::read_csv(file, show_col_types = FALSE)
    prefix <- paste0("W", week, "_")
    cols <- paste0(prefix, c("A", "IR", "S", "TE", "Yrs", "Ill?", "Paid", "Vac$", "RostSal", "Adj"))
    if (!all(c("FRANCHISE", cols) %in% names(summary))) next
    start_col <- 2L + (week - 1L) * 12L
    end_col <- start_col + 9L
    if (end_col > ncol(sheet)) next

    for (i in seq_len(nrow(summary))) {
      sheet_row <- match(trimws(summary$FRANCHISE[[i]]), teams) + 2L
      if (is.na(sheet_row)) next
      expected_values <- as.character(unlist(summary[i, cols], use.names = FALSE))
      actual_values <- as.character(unlist(sheet[sheet_row, start_col:end_col], use.names = FALSE))
      numeric_positions <- setdiff(seq_along(cols), 6L)
      numeric_bad <- vapply(numeric_positions, function(j) {
        expected <- parse_amount(expected_values[[j]])
        actual <- parse_amount(actual_values[[j]])
        (is.na(expected) != is.na(actual)) || (!is.na(expected) && abs(expected - actual) > tolerance)
      }, logical(1))
      text_bad <- !identical(trimws(expected_values[[6]]), trimws(actual_values[[6]]))
      bad <- c(numeric_positions[numeric_bad], if (text_bad) 6L else integer())
      for (j in bad) {
        findings[[length(findings) + 1L]] <- tibble(
          issue = "CAP_ROLLOVER_MISMATCH",
          expected_franchise = trimws(summary$FRANCHISE[[i]]),
          actual_franchise = trimws(summary$FRANCHISE[[i]]),
          player = paste0("Week ", week, " ", sub(prefix, "", cols[[j]], fixed = TRUE)),
          expected_amount = parse_amount(expected_values[[j]]),
          actual_amount = parse_amount(actual_values[[j]]),
          mfl_description = paste0("Sheet value: ", actual_values[[j]]),
          transaction_date = "",
          mfl_entered_at = "",
          action = paste0("Restore Cap Rollover from ", basename(file), "."),
          stage = "Official snapshot CSV -> Contract Admin Cap Rollover",
          actual_system = "Contract Admin"
        )
      }
    }
  }
  bind_rows(findings)
}

season <- suppressWarnings(as.integer(arg_value("season", Sys.getenv("CURRENT_SEASON", unset = get_current_season()))))
saladj_csv <- arg_value("saladj-csv", file.path("data", "SalAdjCurator_latest.csv"))
output_csv <- arg_value("output", file.path("data", "saladj_reconciliation.csv"))
error_output_csv <- arg_value("error-output", file.path("data", "commissioner_error_checker.csv"))
tolerance <- suppressWarnings(as.numeric(arg_value("tolerance", "0.01")))
fail_on_mismatch <- arg_flag("fail-on-mismatch") ||
  tolower(Sys.getenv("ADL_SALADJ_RECONCILE_FAIL_ON_MISMATCH", unset = "false")) %in% c("1", "true", "yes")
send_email <- arg_flag("send-email")
email_to <- trimws(arg_value("to", ""))
issued_csv <- arg_value("issued-ledger", file.path("data", "commissioner_error_checker_issued.csv"))
render_error_csv <- arg_value("render-error-csv", "")
render_output <- arg_value(
  "render-output",
  file.path("data", "commissioner_alerts", "email_outbox_commissioner_error_checker.txt")
)

if (arg_flag("self-test-name-matching")) {
  stopifnot(
    description_matches_expected("J. Owusu-Koramoah - B/R - 4/24/25", "J. Owusu-Koramoah", FALSE),
    description_suspected_name_match("J. Owusu-Koramoah - B/R - 4/24/25", "J. Owusu-Koromoah", FALSE),
    !description_suspected_name_match("J. Owusu-Koramoah - B/R - 4/24/25", "J. Other-Player", FALSE),
    !missing_entry_affected_official_snapshot(
      as.POSIXct("2026-10-07 23:30:35", tz = "UTC"),
      as.POSIXct("2026-10-06 04:18:48", tz = "UTC")
    ),
    missing_entry_affected_official_snapshot(
      as.POSIXct("2026-10-07 23:30:35", tz = "UTC"),
      as.POSIXct("2026-10-13 03:15:00", tz = "UTC")
    )
  )
  expected_test <- tibble(
    franchise = "MIN", player = "J. Owusu-Koromoah", amount = 0.63,
    row_date = as.POSIXct(NA), is_cash_trade = FALSE
  )
  actual_test <- tibble(
    actual_id = 1L, franchise = "MIN", amount = 0.63,
    description = "J. Owusu-Koramoah - B/R - 4/24/25", entered_at = ""
  )
  finding_test <- build_commissioner_error_report(expected_test, actual_test)
  stopifnot(nrow(finding_test) == 1L, finding_test$issue[[1]] == "SUSPECTED_NAME_MATCH")
  rendered_test <- format_checker_finding(
    label_stage_findings(finding_test, "Contract Admin history / Curator-validated penalty logic -> MFL", "MFL")[1, ]
  )
  stopifnot(
    rendered_test[[1]] == "Error Type: Suspected typo match in MFL salary adjustments",
    rendered_test[[2]] == paste0(
      "Possible matching MFL salary adjustments entry: MIN | ",
      "J. Owusu-Koramoah - B/R - 4/24/25 | Penalty/adjustment: $0.63"
    ),
    rendered_test[[3]] == "Expected MFL salary-adjustment entry: MIN | J. Owusu-Koromoah | Penalty/adjustment: $0.63",
    !any(grepl("^Stage:|^MFL:", rendered_test))
  )
  afc_test <- finding_test[1, ] |>
    mutate(issue = "MISSING_ENTRY", expected_franchise = "DEN", player = "Tyrel Dodson",
           expected_amount = 2.3, stage = "SalAdj Curator -> Contract Admin Sal Adj",
           actual_system = "Contract Admin", action = "Add the missing entry.",
           actual_franchise = NA_character_, actual_amount = NA_real_,
           expected_player_team = "CAR", expected_player_pos = "LB",
           expected_years = 1, expected_contract = "2026 UFA")
  nfc_test <- afc_test |>
    mutate(issue = "WRONG_FRANCHISE", expected_franchise = "ATL", actual_franchise = "SFO",
           player = "Dre Greenlaw", expected_amount = 6.06, actual_amount = 6.06,
           expected_player_team = "SFO", expected_contract = "2025 UFA",
           mfl_entered_at = "9/30/2026")
  stopifnot(
    format_checker_finding(afc_test)[[1]] == "Error Type: Missing entry in AFC Sal Adj tab (Contract Admin Sheet)",
    format_checker_finding(afc_test)[[2]] ==
      "Expected Sal Adj tab entry: DEN | Tyrel Dodson | Contract: $2.30 / 1 yr / 2026 UFA",
    format_checker_finding(afc_test)[[3]] ==
      "Required: Add DEN's Tyrel Dodson drop ($2.30 / 1 yr / 2026 UFA) to the AFC Sal Adj tab.",
    format_checker_finding(nfc_test)[[1]] == "Error Type: Incorrect franchise in NFC Sal Adj tab (Contract Admin Sheet)",
    format_checker_finding(nfc_test)[[2]] == paste0(
      "Erroneous Sal Adj tab entry: SFO | Dre Greenlaw | ",
      "Contract: $6.06 / 1 yr / 2025 UFA"
    ),
    format_checker_finding(nfc_test)[[3]] == paste0(
      "Expected Sal Adj tab entry: ATL | Dre Greenlaw | ",
      "Contract: $6.06 / 1 yr / 2025 UFA"
    ),
    !any(grepl("entry date", format_checker_finding(nfc_test), ignore.case = TRUE))
  )
  message("Commissioner Error Checker suspected-name matching tests passed.")
  quit(save = "no", status = 0L)
}

if (nzchar(render_error_csv)) {
  frozen_report <- readr::read_csv(
    render_error_csv,
    col_types = readr::cols(.default = readr::col_character()),
    show_col_types = FALSE
  ) |>
    mutate(
      expected_amount = suppressWarnings(as.numeric(.data$expected_amount)),
      actual_amount = suppressWarnings(as.numeric(.data$actual_amount))
    )
  dir.create(dirname(render_output), recursive = TRUE, showWarnings = FALSE)
  writeLines(build_checker_email_body(frozen_report), render_output)
  message("Rendered frozen Commissioner Error Checker report: ", render_output)
  quit(save = "no", status = 0L)
}

if (is.na(season)) stop("Provide a valid --season or CURRENT_SEASON.", call. = FALSE)
if (is.na(tolerance) || tolerance < 0) tolerance <- 0.01

expected <- saladj_expected_by_franchise(saladj_csv, season = season)
mfl <- mfl_salary_adjustments_from_visible_page(season = season)
expected_entries <- saladj_expected_by_franchise(saladj_csv, season = season, return_entries = TRUE)
mfl_entries <- mfl_salary_adjustments_from_visible_page(season = season, return_entries = TRUE)
sheet_entries <- contract_admin_saladj_entries(season)
sheet_expected_entries <- expected_entries |>
  mutate(amount = .data$salary_amount)
sheet_actual_entries <- sheet_entries |>
  transmute(
    actual_id = row_number(), franchise, amount = .data$input_salary,
    description, entered_at
  )
sheet_entry_details <- expected_entries |>
  transmute(
    expected_franchise = .data$franchise,
    player,
    expected_amount = .data$salary_amount,
    expected_player_team = .data$player_team,
    expected_player_pos = .data$player_pos,
    expected_years = .data$years_amount,
    expected_contract = .data$contract_type
  ) |>
  distinct()
latest_snapshot_time <- latest_official_cap_snapshot_time(season)
message(
  "Latest completed official cap snapshot used for missing-entry gating: ",
  if (is.na(latest_snapshot_time)) "none" else format(latest_snapshot_time, "%Y-%m-%d %H:%M:%S UTC", tz = "UTC")
)
sheet_error_report <- build_commissioner_error_report(
  sheet_expected_entries,
  sheet_actual_entries,
  tolerance = tolerance,
  latest_snapshot_time = latest_snapshot_time
) |>
  label_stage_findings("SalAdj Curator -> Contract Admin Sal Adj", "Contract Admin") |>
  left_join(sheet_entry_details, by = c("expected_franchise", "player", "expected_amount"))
control_field_error_report <- audit_contract_admin_control_fields(
  expected_entries, sheet_entries, tolerance = tolerance
)
historical_mfl_expected_entries <- build_historical_mfl_expectations(
  sheet_entries, expected_entries, season = season, tolerance = tolerance
)
mfl_error_report <- build_commissioner_error_report(
  historical_mfl_expected_entries,
  mfl_entries,
  tolerance = tolerance,
  latest_snapshot_time = latest_snapshot_time
) |>
  label_stage_findings("Contract Admin history / Curator-validated penalty logic -> MFL", "MFL")
cap_rollover_error_report <- audit_cap_rollover_sheet(season, tolerance = tolerance)
error_report <- bind_rows(
  tibble(
    issue = character(), expected_franchise = character(), actual_franchise = character(),
    player = character(), expected_amount = double(), actual_amount = double(),
    mfl_description = character(), transaction_date = character(),
    mfl_entered_at = character(), action = character(), stage = character(),
    actual_system = character(), expected_player_team = character(),
    expected_player_pos = character(), expected_years = double(),
    expected_contract = character()
  ),
  sheet_error_report,
  control_field_error_report,
  mfl_error_report,
  cap_rollover_error_report
)
error_report <- error_report |>
  mutate(
    legacy_issue_key = paste(.data$issue, .data$expected_franchise, .data$actual_franchise,
                             .data$player, sprintf("%.2f", .data$expected_amount),
                             sprintf("%.2f", .data$actual_amount), sep = "|"),
    issue_key = if_else(
      .data$actual_system == "MFL",
      .data$legacy_issue_key,
      paste(.data$stage, .data$legacy_issue_key, sep = "|")
    )
  ) |>
  select(-.data$legacy_issue_key)

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
    body <- build_checker_email_body(new_errors)
    dir.create(file.path("data", "commissioner_alerts"), recursive = TRUE, showWarnings = FALSE)
    writeLines(body, file.path("data", "commissioner_alerts", "email_outbox_commissioner_error_checker.txt"))
    recipients <- if (nzchar(email_to)) {
      tibble(email = email_to)
    } else {
      resolve_commissioner_alert_recipients(season = season)
    }
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
