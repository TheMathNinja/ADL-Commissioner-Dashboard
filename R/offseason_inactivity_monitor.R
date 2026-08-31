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
  tibble(alert_type = character(), severity = character(), conference = character(), franchise = character(), franchise_name = character(), rule = character(), observed = character(), details = character())
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
    auction_results = collect_named_records(safe_mfl_endpoint(conn, "auctionResults"), c("franchise_id", "franchise", "timestamp", "amount", "bid", "player_id", "auction"))
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
  if (!nrow(tbl)) return(tibble(source = character(), franchise_id = character(), conference = character(), franchise = character(), franchise_name = character(), occurred_at = as.POSIXct(character()), round = integer(), event_text = character()))
  franchise_id <- as.character(coalesce_record_col(tbl, c("franchise_id", "franchiseId", "franchise"), NA_character_))
  occurred_at_raw <- as.character(coalesce_record_col(tbl, c("timestamp", "timestamp_formatted", "date", "created", "when"), NA_character_))
  occurred_at <- suppressWarnings(as.POSIXct(as.numeric(occurred_at_raw), origin = "1970-01-01", tz = "America/New_York"))
  fallback_time <- suppressWarnings(as.POSIXct(occurred_at_raw, tz = "America/New_York"))
  occurred_at[is.na(occurred_at)] <- fallback_time[is.na(occurred_at)]
  id_lookup <- adl_franchise_id_lookup()
  normalized <- tibble(source = source, franchise_id = franchise_id, round = suppressWarnings(as.integer(coalesce_record_col(tbl, c("round", "draft_round"), NA_character_))), occurred_at = occurred_at, event_text = record_text(tbl)) |>
    mutate(franchise_code = toupper(.data$franchise_id), franchise_id_padded = if_else(grepl("^[0-9]+$", .data$franchise_id), sprintf("%04d", suppressWarnings(as.integer(.data$franchise_id))), NA_character_)) |>
    left_join(id_lookup, by = c("franchise_id_padded" = "franchise_id")) |>
    mutate(franchise = coalesce(.data$franchise, .env$franchises$franchise[match(.data$franchise_code, toupper(.env$franchises$franchise))]))
  normalized |>
    left_join(franchises, by = "franchise") |>
    select(.data$source, .data$franchise_id, .data$conference, .data$franchise, .data$franchise_name, .data$occurred_at, .data$round, .data$event_text)
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
    transmute(alert_type = "Offseason Inactivity Violation", severity = "violation", conference, franchise, franchise_name, rule = "Rookie Draft clock may expire at most 0 times in Rounds 1-2 and at most once in Rounds 3-5", observed = paste0(.data$early_round_expirations, " Rounds 1-2 expiration(s); ", .data$late_round_expirations, " Rounds 3-5 expiration(s)"), details = paste0(.data$total_expirations, " total rookie draft clock expiration(s) found"))
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
    transmute(alert_type = "Offseason Inactivity Violation", severity = "violation", conference, franchise, franchise_name, rule = "Must place bids in at least 2 pre-UFA auctions: R/F, FT, RFA, B/R, and UDFA", observed = paste0(.data$auction_bid_count, " pre-UFA auction(s) with a bid"), details = paste0("Auctions with bids: ", .data$auctions))
}

evaluate_ufa_auction_bid_gaps <- function(bids, config, franchises) {
  window <- config |> filter(.data$event_type == "ufa_auction_first_three_days") |> mutate(start_at = parse_et_datetime(.data$start_at), end_at = parse_et_datetime(.data$end_at)) |> filter(!is.na(.data$start_at), !is.na(.data$end_at)) |> slice_head(n = 1)
  if (!nrow(window)) return(empty_inactivity_rows())
  bind_rows(lapply(seq_len(nrow(franchises)), function(i) {
    franchise <- franchises[i, ]
    times <- bids |> filter(.data$franchise == franchise$franchise[[1]], .data$occurred_at >= window$start_at[[1]], .data$occurred_at <= window$end_at[[1]]) |> pull(.data$occurred_at) |> sort()
    checkpoints <- sort(c(window$start_at[[1]], times, window$end_at[[1]]))
    gaps <- diff(as.numeric(checkpoints)) / 3600
    if (!length(gaps) || max(gaps, na.rm = TRUE) < 24) return(empty_inactivity_rows())
    gap_index <- which.max(gaps)
    tibble(alert_type = "Offseason Inactivity Violation", severity = "violation", conference = franchise$conference[[1]], franchise = franchise$franchise[[1]], franchise_name = franchise$franchise_name[[1]], rule = "Must not go 24 hours without submitting an auction bid during the first 3 days of UFA", observed = paste0(sprintf("%.1f", gaps[[gap_index]]), " hours between UFA bids/checkpoints"), details = paste0("Gap from ", format(checkpoints[[gap_index]], "%Y-%m-%d %H:%M %Z"), " to ", format(checkpoints[[gap_index + 1L]], "%Y-%m-%d %H:%M %Z")) )
  }))
}

evaluate_roster_deadline_inactivity <- function(season, config, force_live = TRUE) {
  deadlines <- config |> filter(.data$event_type == "roster_deadline") |> mutate(deadline_at = parse_et_datetime(.data$deadline_at)) |> filter(!is.na(.data$deadline_at), .data$deadline_at <= Sys.time())
  if (!nrow(deadlines)) return(empty_inactivity_rows())
  rosters <- load_current_rosters(force_live = force_live, source = "auto", season = season)
  bind_rows(lapply(seq_len(nrow(deadlines)), function(i) { deadline <- deadlines[i, ]; rule <- commissioner_alert_roster_cap_rule(season = season, checked_at = deadline$deadline_at[[1]]); evaluate_roster_cap_alerts(rosters, rule = rule, season = season, checked_at = deadline$deadline_at[[1]]) |> mutate(alert_type = "Offseason Inactivity Violation", rule = paste0(deadline$event_name[[1]], ": ", .data$rule)) }))
}

build_offseason_inactivity_alerts <- function(season = get_current_season(), force_live = TRUE) {
  config <- read_offseason_inactivity_config(season)
  franchises <- franchise_lookup_table(season = season, force_live = force_live)
  activity <- fetch_offseason_activity_records(season = season)
  bids <- normalize_bid_events(activity, franchises)
  alerts <- bind_rows(config_warning_rows(offseason_config_messages(config), season = season), evaluate_rookie_draft_clock_expirations(activity, franchises), evaluate_pre_ufa_auction_participation(bids, config, franchises), evaluate_ufa_auction_bid_gaps(bids, config, franchises), evaluate_roster_deadline_inactivity(season, config, force_live = force_live)) |>
    mutate(season = .env$season, checked_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"), .before = 1) |>
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
