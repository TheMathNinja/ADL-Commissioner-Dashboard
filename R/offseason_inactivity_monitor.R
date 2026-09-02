library(dplyr)
library(readr)
library(tibble)

source("R/commissioner_alerts.R")

offseason_inactivity_dir <- function() Sys.getenv("ADL_INACTIVITY_DIR", unset = file.path("data", "offseason_inactivity"))

offseason_inactivity_path <- function(name, season = get_current_season(), ext = "csv") {
  dir.create(offseason_inactivity_dir(), recursive = TRUE, showWarnings = FALSE)
  file.path(offseason_inactivity_dir(), paste0(name, "_", season, ".", ext))
}

offseason_inactivity_config_path <- function(season = get_current_season()) {
  Sys.getenv("ADL_INACTIVITY_CONFIG", unset = file.path("data", "source", paste0("offseason_inactivity_windows_", season, ".csv")))
}

empty_inactivity_rows <- function() {
  tibble(
    alert_type = character(),
    severity = character(),
    conference = character(),
    franchise = character(),
    franchise_name = character(),
    rule = character(),
    observed = character(),
    details = character(),
    violation_key = character(),
    season_phase = character()
  )
}

offseason_inactivity_config_template <- function(season = get_current_season()) {
  tibble(
    event_type = c(rep("pre_ufa_auction", 5), "ufa_auction_first_three_days", "roster_deadline", "roster_deadline"),
    event_name = c("R/F", "FT", "RFA", "B/R", "UDFA", "UFA", "UFA signing deadline", "Rookie signing deadline"),
    start_at = c(rep(NA_character_, 5), NA_character_, NA_character_, NA_character_),
    end_at = c(rep(NA_character_, 5), NA_character_, NA_character_, NA_character_),
    deadline_at = c(rep(NA_character_, 6), NA_character_, NA_character_)
  )
}

ensure_offseason_inactivity_config <- function(season = get_current_season()) {
  path <- offseason_inactivity_config_path(season)
  if (!file.exists(path)) {
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    write_csv(offseason_inactivity_config_template(season), path, na = "")
  }
  path
}

read_offseason_inactivity_config <- function(season = get_current_season()) {
  path <- ensure_offseason_inactivity_config(season)
  config <- read_csv(path, show_col_types = FALSE)
  required <- c("event_type", "event_name", "start_at", "end_at", "deadline_at")
  missing <- setdiff(required, names(config))
  if (length(missing)) stop("Offseason inactivity config is missing column(s): ", paste(missing, collapse = ", "), call. = FALSE)
  config |>
    mutate(across(all_of(required), ~ trimws(as.character(.x))))
}

parse_et_datetime <- function(x) {
  x <- trimws(as.character(x %||% ""))
  x[!nzchar(x)] <- NA_character_
  as.POSIXct(x, tz = "America/New_York")
}

parse_mfl_activity_time <- function(x) {
  raw <- trimws(as.character(x %||% NA_character_))
  raw[!nzchar(raw)] <- NA_character_
  numeric_time <- suppressWarnings(as.numeric(raw))
  out <- suppressWarnings(as.POSIXct(numeric_time, origin = "1970-01-01", tz = "UTC"))
  fallback <- suppressWarnings(lubridate::ymd_hms(raw, quiet = TRUE, tz = "America/New_York"))
  fallback_date <- suppressWarnings(lubridate::ymd(raw, quiet = TRUE, tz = "America/New_York"))
  out[is.na(out)] <- fallback[is.na(out)]
  out[is.na(out)] <- fallback_date[is.na(out)]
  out
}

offseason_config_messages <- function(config) {
  needed_pre_ufa <- c("R/F", "FT", "RFA", "B/R", "UDFA")
  pre_ufa <- config |> filter(.data$event_type == "pre_ufa_auction")
  ufa <- config |> filter(.data$event_type == "ufa_auction_first_three_days")
  deadlines <- config |> filter(.data$event_type == "roster_deadline")
  messages <- character()
  missing_pre_ufa <- setdiff(needed_pre_ufa, pre_ufa$event_name)
  if (length(missing_pre_ufa)) messages <- c(messages, paste0("Missing pre-UFA auction windows: ", paste(missing_pre_ufa, collapse = ", ")))
  if (nrow(pre_ufa) < 5L || any(is.na(parse_et_datetime(pre_ufa$start_at))) || any(is.na(parse_et_datetime(pre_ufa$end_at)))) messages <- c(messages, "One or more pre-UFA auction windows are missing start_at/end_at.")
  if (!nrow(ufa) || is.na(parse_et_datetime(ufa$start_at[[1]])) || is.na(parse_et_datetime(ufa$end_at[[1]]))) messages <- c(messages, "Missing UFA first-three-days start_at/end_at.")
  if (!nrow(deadlines) || any(is.na(parse_et_datetime(deadlines$deadline_at)))) messages <- c(messages, "One or more roster deadline rows are missing deadline_at.")
  messages
}

config_warning_rows <- function(messages, season = get_current_season()) {
  if (!length(messages)) return(empty_inactivity_rows())
  tibble(alert_type = "Offseason Inactivity Monitor", severity = "info", conference = NA_character_, franchise = NA_character_, franchise_name = "League", rule = "Offseason inactivity monitor configuration", observed = paste(messages, collapse = "; "), details = paste0("Add dates to ", offseason_inactivity_config_path(season), " before running retroactive auction-window and deadline checks."))
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

collect_named_records <- function(x, names_any = character()) {
  out <- list()
  visit <- function(value) {
    if (is.null(value)) return(NULL)
    if (inherits(value, "data.frame")) { out[[length(out) + 1L]] <<- tibble::as_tibble(value); return(NULL) }
    if (!is.list(value)) return(NULL)
    value_names <- names(value) %||% character()
    if (length(value_names) && length(intersect(tolower(value_names), tolower(names_any)))) out[[length(out) + 1L]] <<- tibble::as_tibble(as.list(value))
    invisible(lapply(value, visit))
  }
  visit(x)
  if (!length(out)) return(tibble())
  bind_rows(out)
}

safe_mfl_endpoint <- function(conn, endpoint, ...) {
  tryCatch(ffscrapr::mfl_getendpoint(conn, endpoint, ...)[["content"]], error = function(e) { warning("Unable to fetch MFL endpoint ", endpoint, ": ", conditionMessage(e), call. = FALSE); NULL })
}

fetch_offseason_activity_records <- function(season = get_current_season()) {
  if (!requireNamespace("ffscrapr", quietly = TRUE)) stop("Package ffscrapr is required for the offseason inactivity monitor.", call. = FALSE)
  conn <- connect_adl_mfl(season)
  list(
    transactions = collect_named_records(safe_mfl_endpoint(conn, "transactions"), c("franchise_id", "franchise", "timestamp", "type", "comments", "description")),
    draft_results = collect_named_records(safe_mfl_endpoint(conn, "draftResults"), c("franchise_id", "franchise", "round", "pick", "comments", "timestamp")),
    auction_results = collect_named_records(safe_mfl_endpoint(conn, "auctionResults"), c("franchise_id", "franchise", "timestamp", "amount", "bid", "player_id", "auction")),
    polls = safe_mfl_endpoint(conn, "polls")
  )
}

record_text <- function(tbl) {
  if (!nrow(tbl)) return(character())
  apply(as.data.frame(tbl), 1, function(row) paste(row, collapse = " "))
}

coalesce_record_col <- function(tbl, candidates, default = NA_character_) {
  if (!nrow(tbl)) return(character())
  coalesce_col(tbl, candidates, default)
}

normalize_activity_records <- function(records, source, franchises) {
  tbl <- tibble::as_tibble(records)
  if (!nrow(tbl)) {
    return(tibble(
      source = character(),
      franchise_id = character(),
      conference = character(),
      franchise = character(),
      franchise_name = character(),
      player_id = character(),
      player_name = character(),
      occurred_at = as.POSIXct(character()),
      round = integer(),
      type = character(),
      type_desc = character(),
      event_text = character()
    ))
  }
  franchise_id <- as.character(coalesce_record_col(tbl, c("franchise_id", "franchiseId", "franchise"), NA_character_))
  occurred_at_raw <- as.character(coalesce_record_col(tbl, c("timestamp", "timestamp_formatted", "date", "created", "when"), NA_character_))
  occurred_at <- parse_mfl_activity_time(occurred_at_raw)
  id_lookup <- adl_franchise_id_lookup()
  normalized <- tibble(
    source = source,
    franchise_id = franchise_id,
    player_id = as.character(coalesce_record_col(tbl, c("player_id", "playerId", "player", "id"), NA_character_)),
    player_name = as.character(coalesce_record_col(tbl, c("player_name", "playerName", "name"), NA_character_)),
    round = suppressWarnings(as.integer(coalesce_record_col(tbl, c("round", "draft_round"), NA_character_))),
    occurred_at = occurred_at,
    type = toupper(as.character(coalesce_record_col(tbl, c("type", "transaction_type"), NA_character_))),
    type_desc = tolower(as.character(coalesce_record_col(tbl, c("type_desc", "typeDescription", "description"), NA_character_))),
    event_text = record_text(tbl)
  ) |>
    mutate(franchise_code = toupper(.data$franchise_id), franchise_id_padded = if_else(grepl("^[0-9]+$", .data$franchise_id), sprintf("%04d", suppressWarnings(as.integer(.data$franchise_id))), NA_character_)) |>
    left_join(id_lookup, by = c("franchise_id_padded" = "franchise_id")) |>
    mutate(franchise = coalesce(.data$franchise, .env$franchises$franchise[match(.data$franchise_code, toupper(.env$franchises$franchise))]))
  normalized |>
    left_join(franchises, by = "franchise") |>
    select(.data$source, .data$franchise_id, .data$conference, .data$franchise, .data$franchise_name, .data$player_id, .data$player_name, .data$occurred_at, .data$round, .data$type, .data$type_desc, .data$event_text)
}

evaluate_poll_endpoint_availability <- function(activity) {
  if (is.null(activity$polls)) {
    return(tibble(
      alert_type = "Offseason Inactivity Review Gap",
      severity = "info",
      conference = NA_character_,
      franchise = NA_character_,
      franchise_name = "League",
      rule = "Bylaw first-round voting check",
      observed = "MFL polls endpoint was not available to the monitor in this run.",
      details = "ffscrapr has no dedicated polls wrapper, but MFL export supports generic endpoint requests such as TYPE=polls. First-round bylaw voting can be automated after we confirm the poll payload includes voter/franchise participation.",
      violation_key = NA_character_,
      season_phase = "offseason"
    ))
  }

  poll_count <- length(collect_named_records(activity$polls, c("question", "poll", "id", "votes")))
  tibble(
    alert_type = "Offseason Inactivity Review",
    severity = "info",
    conference = NA_character_,
    franchise = NA_character_,
    franchise_name = "League",
    rule = "Bylaw first-round voting check",
    observed = paste0("MFL TYPE=polls endpoint responded with ", poll_count, " poll-like record(s)."),
    details = "This review does not yet issue bylaw-vote inactivity violations; next step is mapping poll votes to franchise IDs for the specific first-round amendment polls.",
    violation_key = NA_character_,
    season_phase = "offseason"
  )
}

evaluate_rookie_draft_clock_expirations <- function(activity, franchises) {
  events <- bind_rows(normalize_activity_records(activity$draft_results, "draftResults", franchises), normalize_activity_records(activity$transactions, "transactions", franchises)) |>
    filter(grepl("expire|expired|timer|clock", .data$event_text, ignore.case = TRUE), grepl("draft", .data$event_text, ignore.case = TRUE), !is.na(.data$franchise)) |>
    distinct(.data$franchise, .data$round, .data$event_text, .keep_all = TRUE)
  all_expirations <- events |>
    transmute(alert_type = "Rookie Draft Clock Expiration", severity = "info", conference, franchise, franchise_name, rule = "Report all rookie draft clock expirations", observed = paste0("Round ", coalesce(as.character(.data$round), "?"), " clock expiration"), details = .data$event_text)
  violations <- events |>
    group_by(.data$conference, .data$franchise, .data$franchise_name) |>
    summarize(early_round_expirations = sum(.data$round %in% 1:2, na.rm = TRUE), late_round_expirations = sum(.data$round %in% 3:5, na.rm = TRUE), total_expirations = n(), .groups = "drop") |>
    filter(.data$early_round_expirations >= 1L | .data$late_round_expirations >= 2L) |>
    transmute(alert_type = "Offseason Inactivity Violation", severity = "violation", conference, franchise, franchise_name, rule = "Rookie Draft clock may expire at most 0 times in Rounds 1-2 and at most once in Rounds 3-5", observed = paste0(.data$early_round_expirations, " Rounds 1-2 expiration(s); ", .data$late_round_expirations, " Rounds 3-5 expiration(s)"), details = paste0(.data$total_expirations, " total rookie draft clock expiration(s) found"), violation_key = paste("rookie_draft_clock", .data$franchise, sep = "|"), season_phase = "offseason")
  bind_rows(all_expirations, violations)
}

normalize_bid_events <- function(activity, franchises) {
  bind_rows(normalize_activity_records(activity$transactions, "transactions", franchises), normalize_activity_records(activity$auction_results, "auctionResults", franchises)) |>
    filter(!is.na(.data$franchise), grepl("bid|auction", .data$event_text, ignore.case = TRUE)) |>
    distinct(.data$franchise, .data$occurred_at, .data$event_text, .keep_all = TRUE)
}

evaluate_pre_ufa_auction_participation <- function(bids, config, franchises) {
  windows <- config |> filter(.data$event_type == "pre_ufa_auction") |> mutate(start_at = parse_et_datetime(.data$start_at), end_at = parse_et_datetime(.data$end_at)) |> filter(!is.na(.data$start_at), !is.na(.data$end_at))
  if (nrow(windows) < 5L) return(empty_inactivity_rows())
  participation <- bind_rows(lapply(seq_len(nrow(windows)), function(i) { window <- windows[i, ]; bids |> filter(.data$occurred_at >= window$start_at[[1]], .data$occurred_at <= window$end_at[[1]]) |> distinct(.data$franchise) |> transmute(franchise, event_name = window$event_name[[1]]) }))
  franchises |>
    left_join(participation |> group_by(.data$franchise) |> summarize(auction_bid_count = n_distinct(.data$event_name), auctions = paste(sort(unique(.data$event_name)), collapse = ", "), .groups = "drop"), by = "franchise") |>
    mutate(auction_bid_count = coalesce(.data$auction_bid_count, 0L), auctions = if_else(nzchar(coalesce(.data$auctions, "")), .data$auctions, "none")) |>
    filter(.data$auction_bid_count <= 1L) |>
    transmute(alert_type = "Offseason Inactivity Violation", severity = "violation", conference, franchise, franchise_name, rule = "Must place bids in at least 2 pre-UFA auctions: R/F, FT, RFA, B/R, and UDFA", observed = paste0(.data$auction_bid_count, " pre-UFA auction(s) with a bid"), details = paste0("Auctions with bids: ", .data$auctions), violation_key = paste("pre_ufa_participation", .data$franchise, sep = "|"), season_phase = "offseason")
}

evaluate_ufa_auction_bid_gaps <- function(bids, config, franchises) {
  window <- config |> filter(.data$event_type == "ufa_auction_first_three_days") |> mutate(start_at = parse_et_datetime(.data$start_at), end_at = parse_et_datetime(.data$end_at)) |> filter(!is.na(.data$start_at), !is.na(.data$end_at)) |> slice_head(n = 1)
  if (!nrow(window)) return(empty_inactivity_rows())
  bind_rows(lapply(seq_len(nrow(franchises)), function(i) {
    franchise_row <- franchises[i, ]
    franchise_code <- franchise_row$franchise[[1]]
    times <- bids |> filter(.data$franchise == .env$franchise_code, .data$occurred_at >= window$start_at[[1]], .data$occurred_at <= window$end_at[[1]]) |> pull(.data$occurred_at) |> sort()
    checkpoints <- sort(c(window$start_at[[1]], times, window$end_at[[1]]))
    gaps <- diff(as.numeric(checkpoints)) / 3600
    if (!length(gaps) || max(gaps, na.rm = TRUE) < 24) return(empty_inactivity_rows())
    gap_index <- which.max(gaps)
    tibble(alert_type = "Offseason Inactivity Violation", severity = "violation", conference = franchise_row$conference[[1]], franchise = franchise_row$franchise[[1]], franchise_name = franchise_row$franchise_name[[1]], rule = "Must not go 24 hours without submitting an auction bid during the first 3 days of UFA", observed = paste0(sprintf("%.1f", gaps[[gap_index]]), " hours between UFA bids/checkpoints"), details = paste0("Gap from ", format(checkpoints[[gap_index]], "%Y-%m-%d %H:%M %Z"), " to ", format(checkpoints[[gap_index + 1L]], "%Y-%m-%d %H:%M %Z")), violation_key = paste("ufa_bid_gap", franchise_row$franchise[[1]], format(checkpoints[[gap_index]], "%Y%m%d%H%M"), sep = "|"), season_phase = "offseason")
  }))
}

next_adl_waiver_run_at <- function(x) {
  if (inherits(x, "POSIXt")) {
    x <- suppressWarnings(as.POSIXct(as.numeric(x), origin = "1970-01-01", tz = "UTC"))
  } else {
    x <- parse_mfl_activity_time(x)
  }
  x_local <- lubridate::with_tz(x, "America/New_York")
  run_at <- as.POSIXct(paste0(format(as.Date(x_local), "%Y-%m-%d"), " 05:00:00"), tz = "America/New_York")
  run_at <- dplyr::if_else(x_local <= run_at, run_at, run_at + lubridate::days(1))
  lubridate::with_tz(run_at, "UTC")
}

adl_offseason_waiver_claim_run_at <- function(drop_time) {
  if (!inherits(drop_time, "POSIXt")) {
    drop_time <- parse_mfl_activity_time(drop_time)
  } else {
    drop_time <- suppressWarnings(as.POSIXct(as.numeric(drop_time), origin = "1970-01-01", tz = "UTC"))
  }
  next_adl_waiver_run_at(drop_time + lubridate::hours(48))
}

safe_offseason_waiver_claim_run_at <- function(drop_time) {
  tryCatch(adl_offseason_waiver_claim_run_at(drop_time), error = function(e) as.POSIXct(NA))
}

evaluate_offseason_illegal_waiver_claims <- function(activity, franchises, season = get_current_season()) {
  tx <- normalize_activity_records(activity$transactions, "transactions", franchises)
  if (!nrow(tx)) return(empty_inactivity_rows())

  waiver_adds <- tx |>
    filter(
      !is.na(.data$occurred_at),
      !is.na(.data$franchise),
      nzchar(.data$franchise),
      !is.na(.data$player_id),
      nzchar(.data$player_id),
      toupper(.data$player_id) != "NA",
      .data$type_desc %in% c("added", "claimed") | grepl("waiver", paste(.data$type, .data$type_desc, .data$event_text), ignore.case = TRUE)
    )
  if (!nrow(waiver_adds)) return(empty_inactivity_rows())

  drops <- tx |>
    filter(
      !is.na(.data$occurred_at),
      !is.na(.data$player_id),
      nzchar(.data$player_id),
      toupper(.data$player_id) != "NA",
      .data$type_desc == "dropped" | grepl("\\bdrop|dropped\\b", .data$event_text, ignore.case = TRUE)
    ) |>
    transmute(player_id, drop_time = .data$occurred_at) |>
    mutate(
      legal_claim_run_at = as.POSIXct(
        vapply(seq_along(.data$drop_time), function(i) as.numeric(safe_offseason_waiver_claim_run_at(.data$drop_time[[i]])), numeric(1)),
        origin = "1970-01-01",
        tz = "UTC"
      )
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
      alert_type = "Offseason Inactivity Violation",
      severity = "violation",
      conference,
      franchise,
      franchise_name,
      rule = "Illegal offseason waiver claim",
      observed = paste0(if_else(!is.na(.data$player_name) & nzchar(.data$player_name) & toupper(.data$player_name) != "NA", .data$player_name, .data$player_id), " was added without a matching legal offseason waiver window."),
      details = if_else(
        is.na(.data$latest_drop_time),
        "No prior drop was found for this player in league transaction history.",
        paste0(
          "Latest drop: ", format(lubridate::with_tz(.data$latest_drop_time, "America/New_York"), "%Y-%m-%d %H:%M %Z"),
          "; expected legal waiver run: ", format(lubridate::with_tz(.data$expected_run_at, "America/New_York"), "%Y-%m-%d %H:%M %Z")
        )
      ),
      violation_key = paste("offseason_illegal_waiver", season, .data$franchise, .data$player_id, format(as.Date(.data$occurred_at), "%Y-%m-%d"), sep = "|"),
      season_phase = "offseason"
    )
}

read_archived_commissioner_alert_reports <- function(season = get_current_season()) {
  files <- list.files(
    commissioner_alert_report_dir(),
    pattern = paste0("^commissioner_alert_report_.*_", season, "[.]csv$"),
    full.names = TRUE
  )
  if (!length(files)) return(tibble())

  bind_rows(lapply(files, function(path) {
    report <- tryCatch(read_csv(path, show_col_types = FALSE), error = function(e) tibble())
    if (!nrow(report)) return(tibble())
    report |> mutate(report_file = basename(path), .before = 1)
  }))
}

archived_report_date <- function(report_rows) {
  checked <- suppressWarnings(as.Date(report_rows$checked_at))
  fallback <- suppressWarnings(as.Date(sub("^commissioner_alert_report_([0-9-]+).*", "\\1", report_rows$report_file)))
  checked[is.na(checked)] <- fallback[is.na(checked)]
  checked
}

evaluate_repeated_offseason_roster_violations <- function(season = get_current_season()) {
  reports <- read_archived_commissioner_alert_reports(season)
  if (!nrow(reports)) return(empty_inactivity_rows())

  roster_types <- c("Roster Cap Violation", "Contract Years Violation", "Salary Cap Violation")
  daily <- reports |>
    mutate(report_date = archived_report_date(dplyr::pick(dplyr::everything()))) |>
    filter(.data$alert_type %in% roster_types, !is.na(.data$franchise), nzchar(.data$franchise), !is.na(.data$report_date)) |>
    group_by(.data$conference, .data$franchise, .data$franchise_name, .data$report_date) |>
    summarize(types = paste(sort(unique(.data$alert_type)), collapse = ", "), .groups = "drop") |>
    arrange(.data$franchise, .data$report_date)

  bind_rows(lapply(split(daily, daily$franchise), function(rows) {
    rows <- rows |> arrange(.data$report_date)
    if (nrow(rows) < 3L) return(empty_inactivity_rows())
    breaks <- c(TRUE, diff(as.integer(rows$report_date)) != 1L)
    rows$streak_id <- cumsum(breaks)
    rows |>
      group_by(.data$conference, .data$franchise, .data$franchise_name, .data$streak_id) |>
      summarize(
        first_date = min(.data$report_date),
        last_date = max(.data$report_date),
        days = n_distinct(.data$report_date),
        dates = list(sort(unique(.data$report_date))),
        types = paste(sort(unique(unlist(strsplit(.data$types, ", ", fixed = TRUE)))), collapse = ", "),
        .groups = "drop"
      ) |>
      filter(.data$days >= 3L) |>
      mutate(third_date = as.Date(vapply(.data$dates, function(x) as.character(x[[3]]), character(1)))) |>
      transmute(
        alert_type = "Offseason Inactivity Violation",
        severity = "violation",
        conference,
        franchise,
        franchise_name,
        rule = "Repeated illegal roster violation for three consecutive days at the early morning snapshot",
        observed = paste0("Roster violations appeared from ", .data$first_date, " through ", .data$last_date, "."),
        details = paste0("Violation types: ", .data$types, "; inactivity violation would be triggered on ", .data$third_date, "."),
        violation_key = paste("offseason_repeated_roster", season, .data$franchise, .data$first_date, sep = "|"),
        season_phase = "offseason"
      )
  }))
}

evaluate_ufa_signing_deadline_review <- function(config, season = get_current_season()) {
  deadline <- config |>
    filter(.data$event_type == "roster_deadline", grepl("UFA signing", .data$event_name, ignore.case = TRUE)) |>
    mutate(deadline_at = parse_et_datetime(.data$deadline_at)) |>
    slice_head(n = 1)
  if (!nrow(deadline) || is.na(deadline$deadline_at[[1]])) return(empty_inactivity_rows())

  reports <- read_archived_commissioner_alert_reports(season)
  report_dates <- if (nrow(reports)) unique(archived_report_date(reports)) else as.Date(character())
  deadline_date <- as.Date(lubridate::with_tz(deadline$deadline_at[[1]], "America/New_York"))

  if (!deadline_date %in% report_dates) {
    return(tibble(
      alert_type = "Offseason Inactivity Review Gap",
      severity = "info",
      conference = NA_character_,
      franchise = NA_character_,
      franchise_name = "League",
      rule = "Illegal roster at UFA signing deadline / failed UFA signing deadline review",
      observed = paste0("No archived commissioner alert report was found for ", deadline_date, "."),
      details = "The 2026 UFA signing deadline cannot be reconstructed reliably from the current archive. Future seasons should use a scheduled deadline scrape at the exact deadline.",
      violation_key = NA_character_,
      season_phase = "offseason"
    ))
  }

  empty_inactivity_rows()
}

evaluate_roster_deadline_inactivity <- function(season, config, force_live = TRUE) {
  deadlines <- config |> filter(.data$event_type == "roster_deadline") |> mutate(deadline_at = parse_et_datetime(.data$deadline_at)) |> filter(!is.na(.data$deadline_at), .data$deadline_at <= Sys.time())
  if (!nrow(deadlines)) return(empty_inactivity_rows())
  reports <- read_archived_commissioner_alert_reports(season)
  report_dates <- if (nrow(reports)) unique(archived_report_date(reports)) else as.Date(character())

  bind_rows(lapply(seq_len(nrow(deadlines)), function(i) {
    deadline <- deadlines[i, ]
    deadline_date <- as.Date(lubridate::with_tz(deadline$deadline_at[[1]], "America/New_York"))
    if (!deadline_date %in% report_dates) {
      return(tibble(
        alert_type = "Offseason Inactivity Review Gap",
        severity = "info",
        conference = NA_character_,
        franchise = NA_character_,
        franchise_name = "League",
        rule = paste0(deadline$event_name[[1]], ": illegal roster deadline check"),
        observed = paste0("No archived commissioner alert report was found for ", deadline_date, "."),
        details = "This deadline cannot be reconstructed reliably from live roster state after the fact. Future seasons should use a scheduled deadline scrape at the exact deadline.",
        violation_key = NA_character_,
        season_phase = "offseason"
      ))
    }

    reports |>
      mutate(report_date = archived_report_date(dplyr::pick(dplyr::everything()))) |>
      filter(
        .data$report_date == deadline_date,
        .data$alert_type %in% c("Roster Cap Violation", "Contract Years Violation", "Salary Cap Violation"),
        !is.na(.data$franchise),
        nzchar(.data$franchise)
      ) |>
      transmute(
        alert_type = "Offseason Inactivity Violation",
        severity = "violation",
        conference,
        franchise,
        franchise_name,
        rule = paste0(deadline$event_name[[1]], ": illegal roster at deadline"),
        observed = paste(.data$alert_type, .data$observed, sep = " - "),
        details = .data$details,
        violation_key = paste("offseason_roster_deadline", season, deadline$event_name[[1]], .data$franchise, sep = "|"),
        season_phase = "offseason"
      )
  }))
}

offseason_review_error_row <- function(component, error) {
  tibble(
    alert_type = "Offseason Inactivity Review Gap",
    severity = "info",
    conference = NA_character_,
    franchise = NA_character_,
    franchise_name = "League",
    rule = component,
    observed = "This review component could not be completed from the available data.",
    details = conditionMessage(error),
    violation_key = NA_character_,
    season_phase = "offseason"
  )
}

safe_offseason_review <- function(component, expr) {
  tryCatch(expr, error = function(e) offseason_review_error_row(component, e))
}

build_offseason_inactivity_alerts <- function(season = get_current_season(), force_live = TRUE) {
  config <- read_offseason_inactivity_config(season)
  franchises <- franchise_lookup_table(season = season, force_live = force_live)
  activity <- fetch_offseason_activity_records(season = season)
  bids <- normalize_bid_events(activity, franchises)
  alerts <- bind_rows(
    safe_offseason_review("Offseason inactivity monitor configuration", config_warning_rows(offseason_config_messages(config), season = season)),
    safe_offseason_review("Bylaw first-round voting check", evaluate_poll_endpoint_availability(activity)),
    safe_offseason_review("Rookie Draft clock expirations", evaluate_rookie_draft_clock_expirations(activity, franchises)),
    safe_offseason_review("Pre-UFA auction participation", evaluate_pre_ufa_auction_participation(bids, config, franchises)),
    safe_offseason_review("UFA first-three-days 24-hour bid gaps", evaluate_ufa_auction_bid_gaps(bids, config, franchises)),
    safe_offseason_review("Illegal offseason waiver claims", evaluate_offseason_illegal_waiver_claims(activity, franchises, season = season)),
    safe_offseason_review("Repeated offseason roster violations", evaluate_repeated_offseason_roster_violations(season)),
    safe_offseason_review("UFA signing deadline review", evaluate_ufa_signing_deadline_review(config, season = season)),
    safe_offseason_review("Roster deadline inactivity checks", evaluate_roster_deadline_inactivity(season, config, force_live = force_live))
  ) |>
    mutate(season = .env$season, checked_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"), .before = 1) |>
    distinct(.data$alert_type, .data$franchise, .data$rule, .data$observed, .keep_all = TRUE) |>
    arrange(desc(.data$severity == "violation"), .data$alert_type, .data$conference, .data$franchise)
  write_csv(alerts, offseason_inactivity_path("alerts", season), na = "")
  alerts
}

render_offseason_inactivity_email <- function(alerts, title = paste0("ADL Offseason Inactivity Monitor - ", commissioner_alert_date_label())) {
  if (!nrow(alerts)) return(paste(c(title, "", "No offseason inactivity issues were found."), collapse = "\n"))
  violation_count <- sum(alerts$severity == "violation", na.rm = TRUE)
  lines <- c(title, "", paste0(violation_count, " violation(s) found."), "")
  for (i in seq_len(nrow(alerts))) { row <- alerts[i, ]; label <- row$franchise_name[[1]] %||% "League"; lines <- c(lines, paste0(row$alert_type[[1]], " - ", label), paste0("Rule: ", row$rule[[1]]), paste0("Observed: ", row$observed[[1]])); if (nzchar(trimws(row$details[[1]] %||% ""))) lines <- c(lines, paste0("Details: ", row$details[[1]])); lines <- c(lines, "") }
  paste(lines, collapse = "\n")
}

send_offseason_inactivity_email <- function(alerts, season = get_current_season(), send_empty = TRUE) {
  if (!nrow(alerts) && !send_empty) { body <- render_offseason_inactivity_email(alerts); outbox_path <- write_commissioner_alert_outbox(body, season = season, name = "email_outbox_offseason_inactivity"); return(tibble(sent = FALSE, reason = "no_alerts", outbox_path = outbox_path)) }
  recipients <- resolve_commissioner_alert_recipients(season = season)
  body <- render_offseason_inactivity_email(alerts)
  outbox_path <- write_commissioner_alert_outbox(body, season = season, name = "email_outbox_offseason_inactivity")
  digest_status <- send_alert_mail(subject = paste0("ADL Offseason Inactivity Monitor - ", commissioner_alert_date_label()), body = body, to = recipients$email)
  violation_alerts <- alerts |> filter(.data$severity == "violation", !is.na(.data$franchise), nzchar(.data$franchise))
  if (!nrow(violation_alerts)) return(tibble(sent = isTRUE(digest_status$sent), reason = digest_status$reason, outbox_path = outbox_path, gm_emails_sent = 0L))
  offender_recipients <- tryCatch(fetch_mfl_franchise_recipients(season = season, franchises = unique(violation_alerts$franchise)), error = function(e) e)
  if (inherits(offender_recipients, "error")) return(tibble(sent = FALSE, reason = paste0("offender_recipient_lookup_failed: ", conditionMessage(offender_recipients)), outbox_path = outbox_path))
  gm_status <- bind_rows(lapply(unique(violation_alerts$franchise), function(franchise) {
    franchise_alerts <- violation_alerts |> filter(.data$franchise == .env$franchise)
    gm_to <- offender_recipients |> filter(toupper(.data$franchise) == toupper(.env$franchise)) |> pull(.data$email)
    gm_cc <- conference_cc_email(franchise_alerts$conference[[1]])
    gm_body <- render_offseason_inactivity_email(franchise_alerts, title = paste0("ADL Offseason Inactivity Violation - ", franchise_alerts$franchise_name[[1]], " - ", commissioner_alert_date_label()))
    gm_outbox <- write_commissioner_alert_outbox(gm_body, season = season, name = paste0("email_outbox_offseason_inactivity_gm_", safe_file_slug(franchise)))
    if (!length(gm_to)) return(tibble(franchise = franchise, sent = FALSE, reason = "offender_email_not_found", outbox_path = gm_outbox, recipients = "", cc = gm_cc))
    status <- send_alert_mail(subject = paste0("ADL Offseason Inactivity Violation ", commissioner_alert_date_label()), body = gm_body, to = gm_to, cc = gm_cc)
    tibble(franchise = franchise, sent = isTRUE(status$sent), reason = status$reason, outbox_path = gm_outbox, recipients = paste(gm_to, collapse = ", "), cc = gm_cc)
  }))
  write_csv(gm_status, offseason_inactivity_path("email_gm_status", season), na = "")
  if (!isTRUE(digest_status$sent)) return(tibble(sent = FALSE, reason = digest_status$reason, outbox_path = outbox_path, gm_emails_sent = sum(gm_status$sent)))
  if (any(!gm_status$sent)) return(tibble(sent = FALSE, reason = paste0("gm_email_failed: ", paste(unique(gm_status$reason[!gm_status$sent]), collapse = ", ")), outbox_path = outbox_path, gm_emails_sent = sum(gm_status$sent)))
  tibble(sent = TRUE, reason = "sent", outbox_path = outbox_path, gm_emails_sent = sum(gm_status$sent))
}
