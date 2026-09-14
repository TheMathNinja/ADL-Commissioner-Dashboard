library(dplyr)
library(readr)
library(tibble)

source("R/commissioner_alerts.R")

inseason_inactivity_dir <- function() {
  Sys.getenv("ADL_INSEASON_INACTIVITY_DIR", unset = file.path("data", "inseason_inactivity"))
}

inseason_inactivity_path <- function(name, season = get_current_season(), ext = "csv") {
  dir.create(inseason_inactivity_dir(), recursive = TRUE, showWarnings = FALSE)
  file.path(inseason_inactivity_dir(), paste0(name, "_", season, ".", ext))
}

empty_inseason_inactivity_rows <- function() {
  tibble(
    alert_type = character(),
    severity = character(),
    conference = character(),
    franchise = character(),
    franchise_name = character(),
    violation_category = character(),
    rule = character(),
    observed = character(),
    details = character(),
    violation_key = character(),
    season_phase = character()
  )
}

inseason_inactivity_category <- function(alerts) {
  if (!nrow(alerts)) return(alerts)
  existing <- if ("violation_category" %in% names(alerts)) alerts$violation_category else rep(NA_character_, nrow(alerts))
  violation_key <- if ("violation_key" %in% names(alerts)) alerts$violation_key else rep("", nrow(alerts))
  rule <- if ("rule" %in% names(alerts)) alerts$rule else rep("", nrow(alerts))
  alerts |>
    mutate(
      violation_category = coalesce(
        na_if(as.character(.env$existing), ""),
        case_when(
          grepl("^final_roster_cutdown", .env$violation_key) ~ "Illegal Roster at Cutdown",
          grepl("^illegal_waiver_claim", .env$violation_key) ~ "Illegal Waiver Claim",
          grepl("^illegal_lineup", .env$violation_key) ~ "Illegal Lineup",
          grepl("^repeated_roster_violation", .env$violation_key) ~ "Roster Snapshot Violation",
          grepl("Temporary Eligibility", .env$rule, ignore.case = TRUE) ~ "Temporary Eligibility Abuse",
          grepl("log.?in|login", .env$rule, ignore.case = TRUE) ~ "Login Inactivity",
          grepl("Drop.*Deadline", .env$rule, ignore.case = TRUE) ~ "Drop Deadline Violation",
          TRUE ~ NA_character_
        )
      )
    )
}

adl_franchise_id_lookup <- function() {
  tibble(
    franchise_id = sprintf("%04d", 1:32),
    franchise = c(
      "DAL", "NYG", "PHI", "WAS", "CHI", "DET", "GBP", "MIN",
      "ATL", "CAR", "NOS", "TBB", "ARI", "LAR", "SFO", "SEA",
      "BUF", "MIA", "NEP", "NYJ", "BAL", "CIN", "CLE", "PIT",
      "HOU", "IND", "JAC", "TEN", "DEN", "KCC", "LVR", "LAC"
    )
  )
}

franchise_lookup_table <- function(season = get_current_season(), force_live = TRUE) {
  load_current_rosters(force_live = force_live, source = "auto", season = season) |>
    distinct(.data$conference, .data$franchise, .data$franchise_name) |>
    arrange(.data$conference, .data$franchise)
}

next_adl_waiver_run_at <- function(x) {
  x_local <- lubridate::with_tz(x, "America/New_York")
  run_at <- as.POSIXct(
    paste0(format(as.Date(x_local), "%Y-%m-%d"), " 05:00:00"),
    tz = "America/New_York"
  )
  run_at <- dplyr::if_else(x_local <= run_at, run_at, run_at + lubridate::days(1))
  lubridate::with_tz(run_at, "UTC")
}

adl_waiver_claim_run_at <- function(drop_time) {
  next_adl_waiver_run_at(drop_time + lubridate::hours(24))
}

parse_mfl_transaction_time <- function(x) {
  raw <- as.character(x %||% NA_character_)
  numeric_time <- suppressWarnings(as.numeric(raw))
  out <- suppressWarnings(as.POSIXct(numeric_time, origin = "1970-01-01", tz = "UTC"))
  fallback <- suppressWarnings(lubridate::ymd_hms(raw, quiet = TRUE, tz = "UTC"))
  out[is.na(out)] <- fallback[is.na(out)]
  out
}

normalize_inseason_transactions <- function(tx, franchises) {
  if (is.null(tx) || !nrow(tx)) {
    return(tibble(
      franchise_id = character(),
      conference = character(),
      franchise = character(),
      franchise_name = character(),
      player_id = character(),
      player_name = character(),
      occurred_at = as.POSIXct(character()),
      type = character(),
      type_desc = character(),
      comments = character()
    ))
  }

  if (!"comments" %in% names(tx)) tx$comments <- NA_character_
  if (!"player_name" %in% names(tx)) tx$player_name <- NA_character_
  if (!"player_id" %in% names(tx)) tx$player_id <- NA_character_
  if (!"franchise_id" %in% names(tx)) tx$franchise_id <- NA_character_
  if (!"type" %in% names(tx)) tx$type <- NA_character_
  if (!"type_desc" %in% names(tx)) tx$type_desc <- NA_character_
  if (!"timestamp" %in% names(tx)) tx$timestamp <- NA_character_

  id_lookup <- adl_franchise_id_lookup()

  tibble::as_tibble(tx) |>
    transmute(
      franchise_id = as.character(.data$franchise_id),
      player_id = as.character(.data$player_id),
      player_name = as.character(.data$player_name),
      occurred_at = parse_mfl_transaction_time(.data$timestamp),
      type = toupper(as.character(.data$type)),
      type_desc = tolower(as.character(.data$type_desc)),
      comments = as.character(.data$comments)
    ) |>
    mutate(
      franchise_id_padded = if_else(grepl("^[0-9]+$", .data$franchise_id), sprintf("%04d", suppressWarnings(as.integer(.data$franchise_id))), NA_character_)
    ) |>
    left_join(id_lookup, by = c("franchise_id_padded" = "franchise_id")) |>
    mutate(franchise = coalesce(.data$franchise, toupper(.data$franchise_id))) |>
    left_join(franchises, by = "franchise") |>
    select(.data$franchise_id, .data$conference, .data$franchise, .data$franchise_name, .data$player_id, .data$player_name, .data$occurred_at, .data$type, .data$type_desc, .data$comments)
}

fetch_inseason_transactions <- function(season = get_current_season()) {
  if (!requireNamespace("ffscrapr", quietly = TRUE)) {
    stop("Package ffscrapr is required for in-season transaction checks.", call. = FALSE)
  }
  ffscrapr::ff_transactions(connect_adl_mfl(season))
}

evaluate_illegal_waiver_claims <- function(season = get_current_season(), force_live = TRUE, run_time = Sys.time()) {
  if (!isTRUE(force_live)) return(empty_inseason_inactivity_rows())

  franchises <- franchise_lookup_table(season = season, force_live = force_live)
  tx <- tryCatch(fetch_inseason_transactions(season), error = function(e) {
    warning("Unable to fetch MFL transactions for illegal waiver claim check: ", conditionMessage(e), call. = FALSE)
    NULL
  })

  normalized <- normalize_inseason_transactions(tx, franchises)
  if (!nrow(normalized)) return(empty_inseason_inactivity_rows())

  window_start <- lubridate::with_tz(run_time, "UTC") - lubridate::hours(24)
  waiver_adds <- normalized |>
    filter(
      !is.na(.data$occurred_at),
      .data$occurred_at >= window_start,
      .data$occurred_at <= lubridate::with_tz(run_time, "UTC"),
      .data$type_desc %in% c("added", "claimed") | grepl("waiver", paste(.data$type, .data$type_desc, .data$comments), ignore.case = TRUE)
    )

  if (!nrow(waiver_adds)) return(empty_inseason_inactivity_rows())

  drops <- normalized |>
    filter(.data$type_desc == "dropped", !is.na(.data$occurred_at), !is.na(.data$player_id), nzchar(.data$player_id)) |>
    transmute(
      player_id,
      drop_time = .data$occurred_at,
      legal_claim_run_at = adl_waiver_claim_run_at(.data$occurred_at)
    )

  waiver_adds |>
    left_join(drops, by = "player_id") |>
    group_by(.data$conference, .data$franchise, .data$franchise_name, .data$player_id, .data$player_name, .data$occurred_at) |>
    summarize(
      has_legal_drop = any(.data$legal_claim_run_at == next_adl_waiver_run_at(.data$occurred_at), na.rm = TRUE),
      latest_drop_time = if (all(is.na(.data$drop_time))) as.POSIXct(NA) else max(.data$drop_time, na.rm = TRUE),
      expected_run_at = if (all(is.na(.data$legal_claim_run_at))) as.POSIXct(NA) else max(.data$legal_claim_run_at, na.rm = TRUE),
      .groups = "drop"
    ) |>
    filter(!.data$has_legal_drop) |>
    transmute(
      alert_type = "In-Season Inactivity Violation",
      severity = "violation",
      conference,
      franchise,
      franchise_name,
      rule = "Illegal waiver claim",
      observed = paste0(.data$player_name, " was added without a matching legal waiver window in the prior 24-hour scan."),
      details = if_else(
        is.na(.data$latest_drop_time),
        "No prior drop was found for this player in league transaction history.",
        paste0(
          "Latest drop: ", format(lubridate::with_tz(.data$latest_drop_time, "America/New_York"), "%Y-%m-%d %H:%M %Z"),
          "; expected legal waiver run: ", format(lubridate::with_tz(.data$expected_run_at, "America/New_York"), "%Y-%m-%d %H:%M %Z")
        )
      ),
      violation_key = paste("illegal_waiver_claim", season, .data$franchise, .data$player_id, format(as.Date(.data$occurred_at), "%Y-%m-%d"), sep = "|"),
      season_phase = "inseason"
    )
}

read_all_commissioner_alert_reports <- function(season = get_current_season()) {
  files <- list.files(
    commissioner_alert_report_dir(),
    pattern = paste0("^commissioner_alert_report_.*_", season, "[.]csv$"),
    full.names = TRUE
  )
  if (!length(files)) return(tibble())

  bind_rows(lapply(files, function(path) {
    report <- tryCatch(
      read_csv(path, col_types = cols(.default = col_character()), show_col_types = FALSE),
      error = function(e) tibble()
    )
    if (!nrow(report)) return(tibble())
    report |>
      mutate(report_file = basename(path), .before = 1)
  }))
}

alert_report_date <- function(report_rows) {
  checked <- suppressWarnings(as.Date(report_rows$checked_at))
  fallback <- suppressWarnings(as.Date(sub("^commissioner_alert_report_([0-9-]+).*", "\\1", report_rows$report_file)))
  checked[is.na(checked)] <- fallback[is.na(checked)]
  checked
}

read_confirmed_inseason_inactivity <- function(season = get_current_season()) {
  path <- Sys.getenv(
    "ADL_CONFIRMED_INSEASON_INACTIVITY",
    unset = file.path("data", "source", paste0("confirmed_inseason_inactivity_", season, ".csv"))
  )
  if (!file.exists(path)) {
    return(tibble(
      season = character(),
      violation_key = character(),
      conference = character(),
      franchise = character(),
      franchise_name = character(),
      violation_category = character(),
      rule = character(),
      observed = character(),
      details = character()
    ))
  }
  read_csv(path, col_types = cols(.default = col_character()), show_col_types = FALSE) |>
    filter(.data$season == as.character(.env$season))
}

evaluate_repeated_roster_violations <- function(season = get_current_season(), run_time = Sys.time()) {
  run_time <- as.POSIXct(run_time, tz = "America/New_York")
  final_cutdown_at <- commissioner_alert_cutdown_datetime(season, "final_roster_cutdown")
  if (run_time < final_cutdown_at) return(empty_inseason_inactivity_rows())

  reports <- read_all_commissioner_alert_reports(season)
  if (!nrow(reports)) return(empty_inseason_inactivity_rows())

  roster_types <- c("Roster Cap Violation", "Contract Years Violation", "Salary Cap Warning", "Salary Cap Violation")
  today <- as.Date(lubridate::with_tz(run_time, "America/New_York"))
  final_cutdown_date <- as.Date(lubridate::with_tz(final_cutdown_at, "America/New_York"))
  daily <- reports |>
    mutate(report_date = alert_report_date(dplyr::pick(dplyr::everything()))) |>
    filter(
      .data$alert_type %in% roster_types,
      !is.na(.data$franchise),
      nzchar(.data$franchise),
      !is.na(.data$report_date),
      .data$report_date >= .env$final_cutdown_date
    ) |>
    group_by(.data$conference, .data$franchise, .data$franchise_name, .data$report_date) |>
    summarize(types = paste(sort(unique(.data$alert_type)), collapse = ", "), .groups = "drop") |>
    arrange(.data$franchise, .data$report_date)

  if (!nrow(daily)) return(empty_inseason_inactivity_rows())

  bind_rows(lapply(split(daily, daily$franchise), function(rows) {
    rows <- rows |> arrange(.data$report_date)
    if (nrow(rows) < 2L) return(empty_inseason_inactivity_rows())
    breaks <- c(TRUE, diff(as.integer(rows$report_date)) != 1L)
    rows$streak_id <- cumsum(breaks)
    rows |>
      group_by(.data$conference, .data$franchise, .data$franchise_name, .data$streak_id) |>
      summarize(
        first_date = min(.data$report_date),
        last_date = max(.data$report_date),
        days = n_distinct(.data$report_date),
        types = paste(sort(unique(unlist(strsplit(.data$types, ", ", fixed = TRUE)))), collapse = ", "),
        .groups = "drop"
      ) |>
      filter(.data$days == 2L, .data$last_date == .env$today) |>
      transmute(
        alert_type = "In-Season Inactivity Violation",
        severity = "violation",
        conference,
        franchise,
        franchise_name,
        rule = "Repeated illegal roster violation for two consecutive days at the early morning snapshot",
        observed = paste0("Roster violations appeared from ", .data$first_date, " through ", .data$last_date, "."),
        details = paste0("Violation types: ", .data$types),
        violation_key = paste("repeated_roster_violation", season, .data$franchise, .data$first_date, sep = "|"),
        season_phase = "inseason"
      )
  }))
}

evaluate_final_roster_cutdown_inactivity <- function(season = get_current_season(), run_time = Sys.time()) {
  run_time <- as.POSIXct(run_time, tz = "America/New_York")
  final_cutdown_at <- commissioner_alert_cutdown_datetime(season, "final_roster_cutdown")
  if (run_time < final_cutdown_at) return(empty_inseason_inactivity_rows())

  confirmed <- read_confirmed_inseason_inactivity(season) |>
    filter(
      .data$violation_key == paste("final_roster_cutdown", .env$season, .data$franchise, sep = "|"),
      !is.na(.data$franchise),
      nzchar(.data$franchise)
    )

  if (!nrow(confirmed)) return(empty_inseason_inactivity_rows())

  confirmed |>
    transmute(
      alert_type = "In-Season Inactivity Violation",
      severity = "violation",
      conference,
      franchise,
      franchise_name,
      violation_category = coalesce(.data$violation_category, "Illegal Roster at Cutdown"),
      rule = coalesce(.data$rule, "Illegal roster at the Final Roster Cutdown Deadline"),
      observed = .data$observed,
      details = .data$details,
      violation_key = .data$violation_key,
      season_phase = "inseason"
    )
}

lineup_submission_report_options <- function() {
  raw <- Sys.getenv("ADL_MFL_STARTING_LINEUPS_OPTIONS", unset = "06")
  options <- trimws(unlist(strsplit(raw, ",", fixed = TRUE)))
  options[nzchar(options)]
}

lineup_submission_report_url <- function(season = get_current_season(), option = "06", week = NULL) {
  league_id <- get_env_or_default("ADL_LEAGUE_ID", "60206")
  if (!nzchar(league_id)) league_id <- "60206"
  url <- paste0(
    "https://www46.myfantasyleague.com/", season,
    "/options?L=", league_id,
    "&O=", option
  )
  if (!is.null(week) && !is.na(week)) url <- paste0(url, "&W=", as.integer(week))
  url
}

fetch_lineup_submission_report_html <- function(season = get_current_season(), week) {
  if (!requireNamespace("httr", quietly = TRUE)) {
    stop("Package httr is required to fetch MFL lineup submission reports.", call. = FALSE)
  }
  if (!requireNamespace("xml2", quietly = TRUE) || !requireNamespace("rvest", quietly = TRUE)) {
    stop("Packages xml2 and rvest are required to parse MFL lineup submission reports.", call. = FALSE)
  }

  conn <- connect_adl_mfl(season)
  options <- lineup_submission_report_options()
  last_error <- NULL

  for (option in options) {
    url <- lineup_submission_report_url(season = season, option = option, week = week)
    response <- tryCatch(
      httr::GET(
        url,
        httr::user_agent(get_env_or_default("MFL_USER_AGENT", "ADLCommissionerDashboard")),
        conn$auth_cookie,
        httr::timeout(as.numeric(get_env_or_default("ADL_MFL_LINEUP_SUBMISSION_TIMEOUT_SECONDS", "30")))
      ),
      error = function(e) e
    )
    if (inherits(response, "error")) {
      last_error <- conditionMessage(response)
      next
    }
    if (httr::http_error(response)) {
      last_error <- paste0("HTTP ", httr::status_code(response), " for ", url)
      next
    }

    html <- httr::content(response, "text", encoding = "UTF-8")
    text <- tryCatch(rvest::html_text2(xml2::read_html(html)), error = function(e) "")
    if (grepl("Starting Lineups|Lineup Submitted|lineup.*submitted|No lineup submitted", text, ignore.case = TRUE)) {
      return(list(html = html, url = url, option = option))
    }
    last_error <- paste0("Option ", option, " did not look like a Starting Lineups report.")
  }

  stop("Unable to fetch a parseable MFL Starting Lineups report: ", last_error %||% "no report options configured", call. = FALSE)
}

extract_lineup_submitted_at <- function(text) {
  text <- gsub("\\s+", " ", as.character(text %||% ""))
  patterns <- c(
    "((Mon|Tue|Wed|Thu|Fri|Sat|Sun) [A-Z][a-z]{2,9}[.]? [0-9]{1,2} [0-9]{1,2}:[0-9]{2}:[0-9]{2} [ap][.]?m[.]? ET [0-9]{4})",
    "(?i)(lineup submitted|submitted|last updated|updated)[: ]+([A-Z][a-z]{2,9}[.]? [0-9]{1,2},? [0-9]{4}[, ]+[0-9]{1,2}:[0-9]{2} ?[AP]M)",
    "(?i)(lineup submitted|submitted|last updated|updated)[: ]+([0-9]{1,2}/[0-9]{1,2}/[0-9]{2,4}[, ]+[0-9]{1,2}:[0-9]{2} ?[AP]M)",
    "([A-Z][a-z]{2,9}[.]? [0-9]{1,2},? [0-9]{4}[, ]+[0-9]{1,2}:[0-9]{2} ?[AP]M)",
    "([0-9]{1,2}/[0-9]{1,2}/[0-9]{2,4}[, ]+[0-9]{1,2}:[0-9]{2} ?[AP]M)"
  )

  for (pattern in patterns) {
    match <- regexpr(pattern, text, perl = TRUE)
    if (match[[1]] > 0) {
      hit <- regmatches(text, match)[[1]]
      stamp <- sub("(?i)^(lineup submitted|submitted|last updated|updated)[: ]+", "", hit, perl = TRUE)
      stamp <- gsub("a[.]m[.]", "AM", stamp, ignore.case = TRUE)
      stamp <- gsub("p[.]m[.]", "PM", stamp, ignore.case = TRUE)
      stamp <- gsub("\\s+ET\\s+", " ", stamp, ignore.case = TRUE)
      parsed <- suppressWarnings(lubridate::mdy_hm(stamp, tz = "America/New_York", quiet = TRUE))
      if (is.na(parsed)) {
        parsed <- suppressWarnings(lubridate::parse_date_time(
          stamp,
          orders = c("a b d HMS p Y", "a B d HMS p Y", "B d Y I:M p", "b d Y I:M p", "mdY I:M p"),
          tz = "America/New_York",
          quiet = TRUE
        ))
      }
      if (!is.na(parsed)) return(parsed)
    }
  }

  as.POSIXct(NA)
}

lineup_submission_status_from_text <- function(text) {
  text <- as.character(text %||% "")
  lower <- tolower(text)
  not_submitted <- grepl("no lineup submitted|lineup not submitted|has not submitted|did not submit|without lineups|previous week's lineup|previous week.?s lineup", lower)
  commissioner_set <- grepl("commissioner.?set|commish.?set|set by commissioner|\\*[^\\n]{0,80}commissioner", lower, perl = TRUE)
  submitted_at <- extract_lineup_submitted_at(text)

  if (isTRUE(commissioner_set)) {
    return(list(status = "commissioner_set", submitted_at = submitted_at, note = "MFL indicates this lineup was set by a commissioner."))
  }
  if (isTRUE(not_submitted)) {
    return(list(status = "not_submitted", submitted_at = submitted_at, note = "MFL indicates no lineup was submitted for this week."))
  }
  if (!is.na(submitted_at) || grepl("lineup submitted|submitted", lower)) {
    return(list(status = "submitted", submitted_at = submitted_at, note = "MFL shows a submitted lineup stamp."))
  }
  list(status = "unknown", submitted_at = as.POSIXct(NA), note = "No parseable submission stamp or no-submission marker was found.")
}

parse_lineup_submission_report_html <- function(html, franchises, season = get_current_season(), week, source_url = NA_character_) {
  if (!requireNamespace("xml2", quietly = TRUE) || !requireNamespace("rvest", quietly = TRUE)) {
    stop("Packages xml2 and rvest are required to parse MFL lineup submission reports.", call. = FALSE)
  }

  doc <- xml2::read_html(html)
  lines <- unlist(strsplit(rvest::html_text2(doc), "\n", fixed = TRUE))
  lines <- trimws(lines[nzchar(trimws(lines))])
  report_tables <- rvest::html_elements(doc, "table.report")
  table_index <- tibble(
    caption = vapply(report_tables, function(node) rvest::html_text2(rvest::html_element(node, "caption")), character(1)),
    text = vapply(report_tables, rvest::html_text2, character(1))
  )

  franchise_rows <- franchises |>
    mutate(
      franchise = as.character(.data$franchise),
      franchise_name = as.character(.data$franchise_name)
    ) |>
    distinct(.data$conference, .data$franchise, .data$franchise_name)

  bind_rows(lapply(seq_len(nrow(franchise_rows)), function(i) {
    team <- franchise_rows[i, ]
    name_pattern <- paste0("\\b", gsub("([\\W])", "\\\\\\1", team$franchise_name[[1]], perl = TRUE), "\\b")
    code_pattern <- paste0("\\b", gsub("([\\W])", "\\\\\\1", team$franchise[[1]], perl = TRUE), "\\b")
    lineup_caption_pattern <- paste0(name_pattern, "\\s+Week\\s+", as.integer(week), "\\s+lineup")
    table_idx <- grep(lineup_caption_pattern, table_index$caption, ignore.case = TRUE, perl = TRUE)

    if (length(table_idx)) {
      excerpt <- table_index$text[[table_idx[[1]]]]
      status <- lineup_submission_status_from_text(excerpt)
    } else {
      line_idx <- grep(lineup_caption_pattern, lines, ignore.case = TRUE, perl = TRUE)
      if (!length(line_idx)) line_idx <- grep(name_pattern, lines, ignore.case = TRUE, perl = TRUE)
      if (!length(line_idx)) line_idx <- grep(code_pattern, lines, ignore.case = TRUE, perl = TRUE)
    }

    if (!length(table_idx) && !length(line_idx)) {
      status <- list(
        status = "unknown",
        submitted_at = as.POSIXct(NA),
        note = "Franchise was not found in the MFL Starting Lineups report text."
      )
      excerpt <- ""
    } else if (!length(table_idx)) {
      start <- line_idx[[1]]
      other_team_idx <- sort(unique(unlist(lapply(seq_len(nrow(franchise_rows)), function(j) {
        if (j == i) return(integer())
        other_name <- paste0("\\b", gsub("([\\W])", "\\\\\\1", franchise_rows$franchise_name[[j]], perl = TRUE), "\\s+Week\\s+", as.integer(week), "\\s+lineup\\b")
        grep(other_name, lines, ignore.case = TRUE, perl = TRUE)
      }))))
      next_team <- other_team_idx[other_team_idx > start]
      end <- if (length(next_team)) min(next_team[[1]] - 1L, start + 80L) else min(length(lines), start + 80L)
      excerpt <- paste(lines[start:end], collapse = "\n")
      status <- lineup_submission_status_from_text(excerpt)
    }

    tibble(
      season = as.character(season),
      week = as.character(week),
      conference = team$conference[[1]],
      franchise = team$franchise[[1]],
      franchise_name = team$franchise_name[[1]],
      submission_status = status$status,
      submitted_at = if (is.na(status$submitted_at)) NA_character_ else format(status$submitted_at, "%Y-%m-%d %H:%M:%S %Z"),
      source_url = source_url,
      source_note = status$note,
      source_excerpt = substr(excerpt, 1L, 500L)
    )
  }))
}

lineup_submission_audit <- function(season = get_current_season(), week, force_live = TRUE) {
  franchises <- franchise_lookup_table(season = season, force_live = force_live)
  fetched <- fetch_lineup_submission_report_html(season = season, week = week)
  parse_lineup_submission_report_html(
    html = fetched$html,
    franchises = franchises,
    season = season,
    week = week,
    source_url = fetched$url
  )
}

write_lineup_submission_audit <- function(audit, season = get_current_season()) {
  path <- inseason_inactivity_path("lineup_submission_audit", season)
  write_csv(audit, path, na = "")
  path
}

evaluate_lineup_submission_inactivity <- function(season = get_current_season(), force_live = TRUE, run_time = Sys.time()) {
  if (!isTRUE(force_live)) return(empty_inseason_inactivity_rows())
  run_time <- as.POSIXct(run_time, tz = "America/New_York")
  if (run_time < commissioner_alert_cutdown_datetime(season, "final_roster_cutdown")) {
    return(empty_inseason_inactivity_rows())
  }

  week <- commissioner_alert_status_week(season = season, checked_at = run_time)
  if (is.na(week)) return(empty_inseason_inactivity_rows())

  kickoffs <- tryCatch(read_nfl_team_kickoffs(season = season, week = week), error = function(e) tibble())
  first_game_at <- if (nrow(kickoffs) && "kickoff_at" %in% names(kickoffs)) {
    kickoff_values <- as.POSIXct(kickoffs$kickoff_at, tz = "UTC")
    kickoff_values <- kickoff_values[!is.na(kickoff_values)]
    if (length(kickoff_values)) min(kickoff_values) else as.POSIXct(NA)
  } else {
    as.POSIXct(NA)
  }
  if (!is.na(first_game_at) && lubridate::with_tz(run_time, "UTC") < first_game_at) {
    return(empty_inseason_inactivity_rows())
  }

  audit <- tryCatch(
    lineup_submission_audit(season = season, week = week, force_live = force_live),
    error = function(e) {
      warning("Unable to audit MFL lineup submission stamps: ", conditionMessage(e), call. = FALSE)
      tibble()
    }
  )
  if (nrow(audit)) write_lineup_submission_audit(audit, season = season)
  if (!nrow(audit)) return(empty_inseason_inactivity_rows())

  audit |>
    filter(.data$submission_status %in% c("not_submitted", "commissioner_set")) |>
    transmute(
      alert_type = "In-Season Inactivity Violation",
      severity = "violation",
      conference,
      franchise,
      franchise_name,
      week = as.character(.data$week),
      violation_category = "Illegal Lineup",
      rule = "GM must submit a legal weekly lineup",
      observed = case_when(
        .data$submission_status == "commissioner_set" ~ paste0("Week ", .env$week, " lineup was set by a commissioner rather than submitted by the GM."),
        TRUE ~ paste0("No GM-submitted lineup was recorded for Week ", .env$week, ". MFL may be using an inherited lineup.")
      ),
      details = "",
      violation_key = paste("illegal_lineup", season, .data$franchise, .env$week, sep = "|"),
      season_phase = "inseason"
    )
}

is_sunday_lineup_submission_warning_day <- function(run_time = Sys.time()) {
  checked_local <- lubridate::with_tz(as.POSIXct(run_time, tz = "America/New_York"), "America/New_York")
  as.POSIXlt(checked_local)$wday == 0L
}

evaluate_lineup_submission_warnings <- function(season = get_current_season(), week, force_live = TRUE, run_time = Sys.time()) {
  empty <- tibble(
    alert_type = character(), severity = character(), conference = character(),
    franchise = character(), franchise_name = character(), rule = character(),
    observed = character(), details = character()
  )
  if (!isTRUE(force_live) || is.null(week) || is.na(week)) return(empty)
  if (!is_sunday_lineup_submission_warning_day(run_time)) return(empty)

  audit <- tryCatch(
    lineup_submission_audit(season = season, week = week, force_live = force_live),
    error = function(e) {
      warning("Unable to audit MFL lineup submission stamps for Sunday warning: ", conditionMessage(e), call. = FALSE)
      tibble()
    }
  )
  if (nrow(audit)) write_lineup_submission_audit(audit, season = season)
  if (!nrow(audit)) return(empty)

  audit |>
    filter(.data$submission_status %in% c("not_submitted", "commissioner_set")) |>
    transmute(
      alert_type = "Illegal Lineup Warning",
      severity = "warning",
      conference,
      franchise,
      franchise_name,
      rule = "GM must submit a legal weekly lineup",
      observed = case_when(
        .data$submission_status == "commissioner_set" ~ paste0("Week ", .env$week, " lineup appears to have been set by a commissioner rather than submitted by the GM."),
        TRUE ~ paste0("No GM-submitted lineup has been recorded for Week ", .env$week, ". MFL may be using an inherited lineup.")
      ),
      details = ""
    )
}
evaluate_confirmed_illegal_lineup_inactivity <- function(season = get_current_season()) {
  reports <- read_all_commissioner_alert_reports(season)
  if (!nrow(reports) || !"week" %in% names(reports)) return(empty_inseason_inactivity_rows())

  reports |>
    filter(
      .data$alert_type == "Illegal Lineup",
      !is.na(.data$franchise),
      nzchar(.data$franchise)
    ) |>
    group_by(.data$conference, .data$franchise, .data$franchise_name, .data$week) |>
    summarize(
      observed = paste(unique(.data$observed), collapse = "; "),
      details = paste(unique(.data$details[nzchar(coalesce(.data$details, ""))]), collapse = "; "),
      .groups = "drop"
    ) |>
    transmute(
      alert_type = "In-Season Inactivity Violation",
      severity = "violation",
      conference,
      franchise,
      franchise_name,
      week = as.character(.env$week),
      violation_category = "Illegal Lineup",
      rule = "GM must submit a legal weekly lineup",
      observed = paste0("Week ", .data$week, " lineup was submitted or played illegally: ", .data$observed),
      details,
      violation_key = paste("illegal_lineup", season, .data$franchise, .data$week, sep = "|"),
      season_phase = "inseason"
    )
}

read_issued_inseason_inactivity <- function(season = get_current_season()) {
  path <- inseason_inactivity_path("issued_violations", season)
  if (!file.exists(path)) {
    return(tibble(violation_key = character(), issued_at = character()))
  }
  read_csv(path, show_col_types = FALSE)
}

write_issued_inseason_inactivity <- function(issued, season = get_current_season()) {
  write_csv(issued, inseason_inactivity_path("issued_violations", season), na = "")
}

normalize_inseason_inactivity_bind_types <- function(x) {
  if (is.null(x) || !nrow(x)) return(x)
  x |>
    mutate(
      across(
        any_of(c(
          "season", "week", "checked_at", "alert_type", "severity", "conference",
          "franchise", "franchise_name", "violation_category", "rule", "observed",
          "details", "violation_key", "season_phase"
        )),
        as.character
      )
    )
}

first_nonempty_value <- function(x) {
  x <- as.character(x)
  x <- x[!is.na(x) & nzchar(x)]
  if (length(x)) x[[1]] else NA_character_
}

collapse_inseason_inactivity_candidates <- function(candidates) {
  if (!nrow(candidates)) return(candidates)
  expected_cols <- c(
    "season", "week", "checked_at", "alert_type", "severity", "conference",
    "franchise", "franchise_name", "violation_category", "rule", "observed",
    "details", "violation_key", "season_phase"
  )
  for (col in setdiff(expected_cols, names(candidates))) {
    candidates[[col]] <- NA_character_
  }
  candidates |>
    group_by(.data$violation_key) |>
    summarize(
      season = first_nonempty_value(.data$season),
      week = first_nonempty_value(.data$week),
      checked_at = first_nonempty_value(.data$checked_at),
      alert_type = first_nonempty_value(.data$alert_type),
      severity = first_nonempty_value(.data$severity),
      conference = first_nonempty_value(.data$conference),
      franchise = first_nonempty_value(.data$franchise),
      franchise_name = first_nonempty_value(.data$franchise_name),
      violation_category = first_nonempty_value(.data$violation_category),
      rule = first_nonempty_value(.data$rule),
      observed = paste(unique(as.character(.data$observed[!is.na(.data$observed) & nzchar(.data$observed)])), collapse = "; "),
      details = paste(unique(as.character(.data$details[!is.na(.data$details) & nzchar(.data$details)])), collapse = "; "),
      season_phase = first_nonempty_value(.data$season_phase),
      .groups = "drop"
    )
}

build_inseason_inactivity_alerts <- function(season = get_current_season(), force_live = TRUE, run_time = Sys.time(), persist = TRUE) {
  run_time <- as.POSIXct(run_time, tz = "America/New_York")
  if (run_time < commissioner_alert_cutdown_datetime(season, "final_roster_cutdown")) {
    return(empty_inseason_inactivity_rows())
  }

  candidates <- bind_rows(
    lapply(
      list(
        evaluate_final_roster_cutdown_inactivity(season, run_time = run_time),
        evaluate_repeated_roster_violations(season, run_time = run_time),
        evaluate_confirmed_illegal_lineup_inactivity(season),
        evaluate_lineup_submission_inactivity(season = season, force_live = force_live, run_time = run_time),
        evaluate_illegal_waiver_claims(season = season, force_live = force_live, run_time = run_time)
      ),
      normalize_inseason_inactivity_bind_types
    )
  ) |>
    inseason_inactivity_category() |>
    collapse_inseason_inactivity_candidates() |>
    mutate(season = as.character(.env$season), checked_at = format(run_time, "%Y-%m-%d %H:%M:%S %Z"), .before = 1)

  issued <- read_issued_inseason_inactivity(season) |>
    normalize_inseason_inactivity_bind_types()
  new_alerts <- candidates |>
    anti_join(issued |> distinct(.data$violation_key), by = "violation_key") |>
    arrange(.data$conference, .data$franchise, .data$rule)

  if (isTRUE(persist)) {
    write_csv(new_alerts, inseason_inactivity_path("alerts", season), na = "")
  }

  if (isTRUE(persist) && nrow(new_alerts)) {
    updated_issued <- bind_rows(
      issued,
      new_alerts |>
        transmute(
          violation_key,
          season,
          conference,
          franchise,
          franchise_name,
          violation_category,
          rule,
          issued_at = format(run_time, "%Y-%m-%d %H:%M:%S %Z")
        )
    ) |>
      distinct(.data$violation_key, .keep_all = TRUE)
    write_issued_inseason_inactivity(updated_issued, season)
  }

  new_alerts
}

inseason_inactivity_cumulative_summary <- function(season = get_current_season()) {
  issued <- read_issued_inseason_inactivity(season)
  if (!nrow(issued) || !"franchise" %in% names(issued)) {
    return(tibble(franchise = character(), franchise_name = character(), inseason_violations = integer()))
  }
  issued |>
    filter(!is.na(.data$franchise), nzchar(.data$franchise)) |>
    group_by(.data$franchise, .data$franchise_name) |>
    summarize(inseason_violations = n_distinct(.data$violation_key), .groups = "drop") |>
    arrange(desc(.data$inseason_violations), .data$franchise)
}

render_inseason_inactivity_email <- function(alerts, season = get_current_season(), title = paste0("In-Season Inactivity Violations - ", commissioner_alert_date_label())) {
  cumulative <- inseason_inactivity_cumulative_summary(season)
  if (!nrow(alerts)) {
    return(paste(c(title, "", "No new in-season inactivity violations were found."), collapse = "\n"))
  }

  alerts <- inseason_inactivity_category(alerts)
  lines <- c(title, "", commissioner_alert_count_label(nrow(alerts)), "")
  for (i in seq_len(nrow(alerts))) {
    row <- alerts[i, ]
    label <- row$franchise_name[[1]] %||% row$franchise[[1]]
    category <- row$violation_category[[1]] %||% row$rule[[1]]
    lines <- c(
      lines,
      paste0(label, ": ", category),
      "",
      paste0("Rule: ", row$rule[[1]]),
      paste0("Observed: ", row$observed[[1]])
    )
    if (nzchar(trimws(row$details[[1]] %||% ""))) {
      lines <- c(lines, paste0("Details: ", row$details[[1]]))
    }
    lines <- c(lines, "")
  }

  if (nrow(cumulative)) {
    lines <- c(lines, "Cumulative In-Season Inactivity Violations", "")
    for (i in seq_len(nrow(cumulative))) {
      lines <- c(lines, paste0(cumulative$franchise_name[[i]] %||% cumulative$franchise[[i]], ": ", cumulative$inseason_violations[[i]]))
    }
  }

  paste(lines, collapse = "\n")
}

send_inseason_inactivity_email <- function(alerts, season = get_current_season(), send_empty = FALSE) {
  body <- render_inseason_inactivity_email(alerts, season = season)
  outbox_path <- write_commissioner_alert_outbox(body, season = season, name = "email_outbox_inseason_inactivity")

  if (!nrow(alerts) && !send_empty) {
    return(tibble(sent = FALSE, reason = "no_alerts", outbox_path = outbox_path, gm_emails_sent = 0L))
  }

  recipients <- resolve_commissioner_alert_recipients(season = season)
  digest_status <- send_alert_mail(
    subject = paste0("ADL In-Season Inactivity Violation Report - ", commissioner_alert_date_label()),
    body = body,
    to = recipients$email
  )

  violation_alerts <- alerts |> filter(.data$severity == "violation", !is.na(.data$franchise), nzchar(.data$franchise))
  if (!nrow(violation_alerts)) {
    return(tibble(sent = isTRUE(digest_status$sent), reason = digest_status$reason, outbox_path = outbox_path, gm_emails_sent = 0L))
  }

  offender_recipients <- tryCatch(
    fetch_mfl_franchise_recipients(season = season, franchises = unique(violation_alerts$franchise)),
    error = function(e) e
  )
  if (inherits(offender_recipients, "error")) {
    return(tibble(sent = FALSE, reason = paste0("offender_recipient_lookup_failed: ", conditionMessage(offender_recipients)), outbox_path = outbox_path, gm_emails_sent = 0L))
  }

  gm_status <- bind_rows(lapply(unique(violation_alerts$franchise), function(franchise) {
    franchise_alerts <- violation_alerts |> filter(.data$franchise == .env$franchise)
    gm_to <- offender_recipients |> filter(toupper(.data$franchise) == toupper(.env$franchise)) |> pull(.data$email)
    gm_cc <- conference_cc_email(franchise_alerts$conference[[1]])
    gm_body <- render_inseason_inactivity_email(
      franchise_alerts,
      season = season,
      title = paste0("In-Season Inactivity Violations - ", commissioner_alert_date_label())
    )
    gm_outbox <- write_commissioner_alert_outbox(gm_body, season = season, name = paste0("email_outbox_inseason_inactivity_gm_", safe_file_slug(franchise)))
    if (!length(gm_to)) {
      return(tibble(franchise = franchise, sent = FALSE, reason = "offender_email_not_found", outbox_path = gm_outbox, recipients = "", cc = gm_cc))
    }
    status <- send_alert_mail(
      subject = paste0("ADL In-Season Inactivity Violation ", commissioner_alert_date_label()),
      body = gm_body,
      to = gm_to,
      cc = gm_cc
    )
    tibble(franchise = franchise, sent = isTRUE(status$sent), reason = status$reason, outbox_path = gm_outbox, recipients = paste(gm_to, collapse = ", "), cc = gm_cc)
  }))

  write_csv(gm_status, inseason_inactivity_path("email_gm_status", season), na = "")

  if (!isTRUE(digest_status$sent)) {
    return(tibble(sent = FALSE, reason = digest_status$reason, outbox_path = outbox_path, gm_emails_sent = sum(gm_status$sent)))
  }
  if (any(!gm_status$sent)) {
    return(tibble(sent = FALSE, reason = paste0("gm_email_failed: ", paste(unique(gm_status$reason[!gm_status$sent]), collapse = ", ")), outbox_path = outbox_path, gm_emails_sent = sum(gm_status$sent)))
  }
  tibble(sent = TRUE, reason = "sent", outbox_path = outbox_path, gm_emails_sent = sum(gm_status$sent))
}
