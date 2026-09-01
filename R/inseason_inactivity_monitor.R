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
    rule = character(),
    observed = character(),
    details = character(),
    violation_key = character(),
    season_phase = character()
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
    report <- tryCatch(read_csv(path, show_col_types = FALSE), error = function(e) tibble())
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

evaluate_repeated_roster_violations <- function(season = get_current_season(), run_date = Sys.Date()) {
  reports <- read_all_commissioner_alert_reports(season)
  if (!nrow(reports)) return(empty_inseason_inactivity_rows())

  roster_types <- c("Roster Cap Violation", "Contract Years Violation", "Salary Cap Warning", "Salary Cap Violation")
  daily <- reports |>
    mutate(report_date = alert_report_date(dplyr::pick(dplyr::everything()))) |>
    filter(.data$alert_type %in% roster_types, !is.na(.data$franchise), nzchar(.data$franchise), !is.na(.data$report_date)) |>
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
      mutate(qualifying_date = .data$first_date + 1L) |>
      filter(.data$days >= 2L, .data$qualifying_date == as.Date(.env$run_date)) |>
      transmute(
        alert_type = "In-Season Inactivity Violation",
        severity = "violation",
        conference,
        franchise,
        franchise_name,
        rule = "Repeated illegal roster violation for two consecutive days at the early morning snapshot",
        observed = paste0("Roster violations appeared on ", .data$first_date, " and ", .data$qualifying_date, "."),
        details = paste0("Violation types: ", .data$types),
        violation_key = paste("repeated_roster_violation", season, .data$franchise, .data$qualifying_date, sep = "|"),
        season_phase = "inseason"
      )
  }))
}

evaluate_final_roster_cutdown_inactivity <- function(season = get_current_season()) {
  reports <- read_all_commissioner_alert_reports(season)
  if (!nrow(reports)) return(empty_inseason_inactivity_rows())

  deadline_date <- as.Date(commissioner_alert_cutdown_datetime(season, "final_roster_cutdown"))
  reports |>
    mutate(report_date = alert_report_date(dplyr::pick(dplyr::everything()))) |>
    filter(
      .data$report_date == deadline_date,
      .data$alert_type == "Roster Cap Violation",
      !is.na(.data$franchise),
      nzchar(.data$franchise)
    ) |>
    transmute(
      alert_type = "In-Season Inactivity Violation",
      severity = "violation",
      conference,
      franchise,
      franchise_name,
      rule = "Illegal roster at the Final Roster Cutdown Deadline",
      observed = .data$observed,
      details = .data$details,
      violation_key = paste("final_roster_cutdown", season, .data$franchise, sep = "|"),
      season_phase = "inseason"
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
      rule = "Failed to set a full weekly lineup with 21 active/starting players",
      observed,
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

build_inseason_inactivity_alerts <- function(season = get_current_season(), force_live = TRUE, run_time = Sys.time(), persist = TRUE) {
  run_date <- as.Date(lubridate::with_tz(as.POSIXct(run_time, tz = 'UTC'), 'America/New_York'))
  candidates <- bind_rows(
    evaluate_final_roster_cutdown_inactivity(season),
    evaluate_repeated_roster_violations(season, run_date = run_date),
    evaluate_confirmed_illegal_lineup_inactivity(season),
    evaluate_illegal_waiver_claims(season = season, force_live = force_live, run_time = run_time)
  ) |>
    distinct(.data$violation_key, .keep_all = TRUE) |>
    mutate(season = .env$season, checked_at = format(run_time, "%Y-%m-%d %H:%M:%S %Z"), .before = 1)

  issued <- read_issued_inseason_inactivity(season)
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

render_inseason_inactivity_email <- function(alerts, season = get_current_season(), title = paste0("ADL In-Season Inactivity Violation Report - ", commissioner_alert_date_label())) {
  cumulative <- inseason_inactivity_cumulative_summary(season)
  if (!nrow(alerts)) {
    return(paste(c(title, "", "No new in-season inactivity violations were found."), collapse = "\n"))
  }

  lines <- c(title, "", commissioner_alert_count_label(nrow(alerts)), "")
  for (i in seq_len(nrow(alerts))) {
    row <- alerts[i, ]
    label <- row$franchise_name[[1]] %||% row$franchise[[1]]
    lines <- c(
      lines,
      paste0("In-Season Inactivity Violation - ", label),
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
      title = paste0("ADL In-Season Inactivity Violation - ", franchise_alerts$franchise_name[[1]], " - ", commissioner_alert_date_label())
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
