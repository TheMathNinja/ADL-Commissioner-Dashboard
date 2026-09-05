library(dplyr)
library(readr)
library(tibble)

source("R/commissioner_alerts.R")

offseason_inactivity_dir <- function() Sys.getenv("ADL_INACTIVITY_DIR", unset = file.path("data", "offseason_inactivity"))

offseason_inactivity_path <- function(name, season = get_current_season(), ext = "csv") {
  dir.create(offseason_inactivity_dir(), recursive = TRUE, showWarnings = FALSE)
  file.path(offseason_inactivity_dir(), paste0(name, "_", season, ".", ext))
}

read_offseason_inactivity_issued <- function(season = get_current_season()) {
  path <- offseason_inactivity_path("issued_violations", season)
  if (!file.exists(path)) {
    return(tibble(
      violation_key = character(),
      issued_at = character(),
      season = integer(),
      conference = character(),
      franchise = character(),
      franchise_name = character(),
      rule = character(),
      season_phase = character()
    ))
  }
  read_csv(path, show_col_types = FALSE) |>
    mutate(violation_key = as.character(.data$violation_key))
}

write_offseason_inactivity_issued <- function(issued, season = get_current_season()) {
  issued |>
    distinct(.data$violation_key, .keep_all = TRUE) |>
    arrange(.data$issued_at, .data$conference, .data$franchise, .data$rule) |>
    write_csv(offseason_inactivity_path("issued_violations", season), na = "")
}

mark_offseason_inactivity_issued <- function(alerts, season = get_current_season(), run_time = Sys.time()) {
  new_issued <- alerts |>
    filter(.data$severity == "violation", !is.na(.data$violation_key), nzchar(.data$violation_key)) |>
    transmute(
      violation_key = .data$violation_key,
      issued_at = format(.env$run_time, "%Y-%m-%d %H:%M:%S %Z"),
      season = .env$season,
      conference = .data$conference,
      franchise = .data$franchise,
      franchise_name = .data$franchise_name,
      rule = .data$rule,
      season_phase = .data$season_phase
    )
  if (!nrow(new_issued)) return(read_offseason_inactivity_issued(season))
  issued <- bind_rows(read_offseason_inactivity_issued(season), new_issued)
  write_offseason_inactivity_issued(issued, season = season)
  read_offseason_inactivity_issued(season)
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
    event_type = c("rookie_draft", rep("pre_ufa_auction", 5), "ufa_auction", "roster_deadline", "roster_deadline"),
    event_name = c("Rookie Draft", "R/F", "FT", "RFA", "B/R", "UDFA", "UFA Auction", "UFA signing deadline", "Rookie signing deadline"),
    start_at = c(NA_character_, rep(NA_character_, 5), NA_character_, NA_character_, NA_character_),
    end_at = c(NA_character_, rep(NA_character_, 5), NA_character_, NA_character_, NA_character_),
    deadline_at = c(NA_character_, rep(NA_character_, 6), NA_character_, paste0(season, "-07-01 00:00:00"))
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
  ufa <- config |> filter(.data$event_type == "ufa_auction")
  deadlines <- config |> filter(.data$event_type == "roster_deadline")
  messages <- character()
  missing_pre_ufa <- setdiff(needed_pre_ufa, pre_ufa$event_name)
  if (length(missing_pre_ufa)) messages <- c(messages, paste0("Missing pre-UFA auction windows: ", paste(missing_pre_ufa, collapse = ", ")))
  if (nrow(pre_ufa) < 5L || any(is.na(parse_et_datetime(pre_ufa$start_at))) || any(is.na(parse_et_datetime(pre_ufa$end_at)))) messages <- c(messages, "One or more pre-UFA auction windows are missing start_at/end_at.")
  if (!nrow(ufa) || is.na(parse_et_datetime(ufa$start_at[[1]]))) messages <- c(messages, "Missing UFA auction start_at.")
  if (!nrow(deadlines) || any(is.na(parse_et_datetime(deadlines$deadline_at)))) messages <- c(messages, "One or more roster deadline rows are missing deadline_at.")
  messages
}

config_warning_rows <- function(messages, season = get_current_season()) {
  if (!length(messages)) return(empty_inactivity_rows())
  tibble(alert_type = "Offseason Inactivity Monitor", severity = "info", conference = NA_character_, franchise = NA_character_, franchise_name = "League", rule = "Offseason inactivity monitor configuration", observed = paste(messages, collapse = "; "), details = paste0("Add dates to ", offseason_inactivity_config_path(season), " before running retroactive auction-window and deadline checks."))
}

rookie_draft_check_is_active <- function(config, now = Sys.time()) {
  window <- config |>
    filter(.data$event_type == "rookie_draft") |>
    mutate(end_at = parse_et_datetime(.data$end_at)) |>
    filter(!is.na(.data$end_at)) |>
    slice_head(n = 1)
  if (!nrow(window)) return(TRUE)
  now <= window$end_at[[1]]
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
  franchise_ids <- adl_franchise_id_lookup()$franchise_id
  list(
    conn = conn,
    transactions = collect_named_records(safe_mfl_endpoint(conn, "transactions"), c("franchise_id", "franchise", "timestamp", "type", "comments", "description")),
    draft_results = collect_named_records(safe_mfl_endpoint(conn, "draftResults"), c("franchise_id", "franchise", "round", "pick", "comments", "timestamp")),
    auction_results = collect_named_records(safe_mfl_endpoint(conn, "auctionResults"), c("franchise_id", "franchise", "timestamp", "amount", "bid", "player_id", "auction")),
    polls = safe_mfl_endpoint(conn, "polls"),
    polls_by_franchise = setNames(lapply(franchise_ids, function(franchise_id) {
      safe_mfl_endpoint(conn, "polls", FRANCHISE_ID = franchise_id)
    }), franchise_ids)
  )
}

fetch_mfl_poll_page_html <- function(conn, season = get_current_season(), option = "69") {
  if (!requireNamespace("httr", quietly = TRUE)) stop("Package httr is required to fetch the MFL poll page.", call. = FALSE)
  league_id <- get_env_or_default("ADL_LEAGUE_ID", "60206")
  if (!nzchar(league_id)) league_id <- "60206"
  url <- sprintf("https://www46.myfantasyleague.com/%s/options?L=%s&O=%s", season, league_id, option)
  response <- httr::GET(
    url,
    httr::user_agent(get_env_or_default("MFL_USER_AGENT", "ADLCommissionerDashboard")),
    conn$auth_cookie,
    httr::timeout(30)
  )
  if (httr::http_error(response)) stop("MFL poll page request failed with HTTP ", httr::status_code(response), ".", call. = FALSE)
  httr::content(response, "text", encoding = "UTF-8")
}

parse_mfl_poll_footer_date <- function(footer) {
  footer <- trimws(as.character(footer %||% ""))
  if (!nzchar(footer)) return(as.Date(NA))
  matched <- regexec("Closed\\s+\\w+\\s+([A-Za-z]+\\s+\\d{1,2}).*\\s+(\\d{4})", footer, ignore.case = TRUE)
  parts <- regmatches(footer, matched)[[1]]
  if (length(parts) < 3) return(as.Date(NA))
  suppressWarnings(as.Date(lubridate::mdy(paste(parts[[2]], parts[[3]]))))
}

split_mfl_title_voters <- function(x) {
  x <- trimws(as.character(x %||% ""))
  if (!nzchar(x)) return(character())
  voters <- trimws(unlist(strsplit(x, ",", fixed = TRUE)))
  voters[nzchar(voters)]
}

parse_mfl_poll_page_votes <- function(html, franchises) {
  if (!requireNamespace("xml2", quietly = TRUE)) stop("Package xml2 is required to parse the MFL poll page.", call. = FALSE)
  if (!requireNamespace("rvest", quietly = TRUE)) stop("Package rvest is required to parse the MFL poll page.", call. = FALSE)
  doc <- xml2::read_html(html)
  poll_nodes <- rvest::html_elements(doc, xpath = "//*[starts-with(@id, 'poll_')]")
  if (!length(poll_nodes)) {
    return(tibble(
      poll_id = character(),
      poll_question = character(),
      poll_closed_date = as.Date(character()),
      answer = character(),
      votes = integer(),
      voter_name = character(),
      voter_franchise = character()
    ))
  }

  bind_rows(lapply(poll_nodes, function(node) {
    poll_id <- sub("^poll_", "", rvest::html_attr(node, "id") %||% NA_character_)
    question <- rvest::html_text2(rvest::html_element(node, ".poll-question"))
    footer <- rvest::html_text2(rvest::html_element(node, ".reportfooter"))
    closed_date <- parse_mfl_poll_footer_date(footer)
    rows <- rvest::html_elements(node, "tr")

    bind_rows(lapply(rows, function(row) {
      label <- rvest::html_text2(rvest::html_element(row, ".inputlabel"))
      label <- sub(":\\s*$", "", trimws(label))
      if (!nzchar(label) || identical(label, "Total Votes")) return(NULL)
      link <- rvest::html_element(row, "a[title]")
      voter_names <- split_mfl_title_voters(rvest::html_attr(link, "title"))
      if (!length(voter_names)) return(NULL)
      vote_count <- suppressWarnings(as.integer(rvest::html_text2(rvest::html_element(row, "td:nth-child(2)"))))
      tibble(
        poll_id = poll_id,
        poll_question = question,
        poll_closed_date = closed_date,
        answer = label,
        votes = vote_count,
        voter_name = voter_names
      )
    }))
  })) |>
    left_join(franchises |> distinct(.data$franchise, .data$franchise_name), by = c("voter_name" = "franchise_name")) |>
    mutate(voter_franchise = .data$franchise) |>
    select(.data$poll_id, .data$poll_question, .data$poll_closed_date, .data$answer, .data$votes, .data$voter_name, .data$voter_franchise)
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

evaluate_bylaw_first_wave_voting <- function(poll_page_votes, franchises, season = get_current_season(), run_time = Sys.time()) {
  if (!nrow(poll_page_votes)) {
    return(tibble(
      alert_type = "Offseason Inactivity Review Gap",
      severity = "info",
      conference = NA_character_,
      franchise = NA_character_,
      franchise_name = "League",
      rule = "First-round bylaw amendment poll voting",
      observed = "MFL poll page did not return parseable answer-level voter lists.",
      details = "The monitor expects voter names in the MFL League Polls page answer-count title attributes.",
      violation_key = NA_character_,
      season_phase = "offseason"
    ))
  }

  poll_summary <- poll_page_votes |>
    distinct(.data$poll_id, .data$poll_question, .data$poll_closed_date)
  v1 <- poll_summary |>
    filter(grepl("^V1(\\b|\\s*:)", trimws(.data$poll_question), ignore.case = TRUE), !is.na(.data$poll_closed_date)) |>
    arrange(.data$poll_closed_date, .data$poll_id) |>
    slice_head(n = 1)

  if (!nrow(v1)) {
    return(tibble(
      alert_type = "Offseason Inactivity Review Gap",
      severity = "info",
      conference = NA_character_,
      franchise = NA_character_,
      franchise_name = "League",
      rule = "First-round bylaw amendment poll voting",
      observed = "No parseable V1 poll with a closed date was found on the MFL League Polls page.",
      details = "The voting inactivity rule needs the V1 poll date to identify the first wave of amendment polls.",
      violation_key = NA_character_,
      season_phase = "offseason"
    ))
  }

  wave_date <- v1$poll_closed_date[[1]]
  trigger_date <- wave_date + 7L
  current_date <- as.Date(lubridate::with_tz(as.POSIXct(run_time), "America/New_York"))
  first_wave_polls <- poll_summary |>
    filter(.data$poll_closed_date == .env$wave_date)
  first_wave_votes <- poll_page_votes |>
    filter(.data$poll_id %in% first_wave_polls$poll_id, !is.na(.data$voter_franchise), nzchar(.data$voter_franchise)) |>
    distinct(.data$voter_franchise, .data$poll_id)
  participation <- franchises |>
    distinct(.data$conference, .data$franchise, .data$franchise_name) |>
    left_join(
      first_wave_votes |>
        count(.data$voter_franchise, name = "first_wave_polls_voted"),
      by = c("franchise" = "voter_franchise")
    ) |>
    mutate(first_wave_polls_voted = coalesce(.data$first_wave_polls_voted, 0L))

  violations <- if (current_date >= trigger_date) {
    participation |>
      filter(.data$first_wave_polls_voted == 0L) |>
      transmute(
        alert_type = "Offseason Inactivity Violation",
        severity = "violation",
        conference,
        franchise,
        franchise_name,
        rule = "Must vote in at least one first-round bylaw amendment poll",
        observed = paste0("0 votes recorded across ", nrow(first_wave_polls), " first-wave poll(s) closed on ", format(.env$wave_date, "%Y-%m-%d"), "."),
        details = paste0("First wave anchored by V1 poll: ", v1$poll_question[[1]], "; alert eligible on ", format(.env$trigger_date, "%Y-%m-%d"), "."),
        violation_key = paste("bylaw_first_wave_no_vote", season, format(.env$wave_date, "%Y-%m-%d"), .data$franchise, sep = "|"),
        season_phase = "offseason"
      )
  } else {
    empty_inactivity_rows()
  }

  info <- tibble(
    alert_type = "Offseason Inactivity Review",
    severity = "info",
    conference = NA_character_,
    franchise = NA_character_,
    franchise_name = "League",
    rule = "First-round bylaw amendment poll voting",
    observed = paste0(nrow(first_wave_polls), " first-wave poll(s) found using V1 close date ", format(wave_date, "%Y-%m-%d"), ". ", nrow(participation |> filter(.data$first_wave_polls_voted == 0L)), " franchise(s) voted in none of them."),
    details = paste0("Alert eligible on ", format(trigger_date, "%Y-%m-%d"), "; checked on ", format(current_date, "%Y-%m-%d"), ". Polls: ", paste(sort(first_wave_polls$poll_question), collapse = " | ")),
    violation_key = NA_character_,
    season_phase = "offseason"
  )

  bind_rows(info, violations)
}

poll_first_wave_participation_records <- function(poll_page_votes, franchises) {
  if (!nrow(poll_page_votes)) {
    return(tibble(
      wave_date = as.Date(character()),
      first_wave_poll_count = integer(),
      conference = character(),
      franchise = character(),
      franchise_name = character(),
      first_wave_polls_voted = integer(),
      voted_poll_ids = character(),
      voted_poll_questions = character()
    ))
  }

  poll_summary <- poll_page_votes |>
    distinct(.data$poll_id, .data$poll_question, .data$poll_closed_date)
  v1 <- poll_summary |>
    filter(grepl("^V1(\\b|\\s*:)", trimws(.data$poll_question), ignore.case = TRUE), !is.na(.data$poll_closed_date)) |>
    arrange(.data$poll_closed_date, .data$poll_id) |>
    slice_head(n = 1)
  if (!nrow(v1)) return(tibble())

  wave_date <- v1$poll_closed_date[[1]]
  first_wave_polls <- poll_summary |>
    filter(.data$poll_closed_date == .env$wave_date)
  first_wave_votes <- poll_page_votes |>
    filter(.data$poll_id %in% first_wave_polls$poll_id, !is.na(.data$voter_franchise), nzchar(.data$voter_franchise)) |>
    distinct(.data$voter_franchise, .data$poll_id, .data$poll_question)

  franchises |>
    distinct(.data$conference, .data$franchise, .data$franchise_name) |>
    left_join(
      first_wave_votes |>
        group_by(.data$voter_franchise) |>
        summarize(
          first_wave_polls_voted = n_distinct(.data$poll_id),
          voted_poll_ids = paste(sort(unique(.data$poll_id)), collapse = ", "),
          voted_poll_questions = paste(sort(unique(.data$poll_question)), collapse = " | "),
          .groups = "drop"
        ),
      by = c("franchise" = "voter_franchise")
    ) |>
    mutate(
      wave_date = .env$wave_date,
      first_wave_poll_count = nrow(first_wave_polls),
      first_wave_polls_voted = coalesce(.data$first_wave_polls_voted, 0L),
      voted_poll_ids = coalesce(.data$voted_poll_ids, ""),
      voted_poll_questions = coalesce(.data$voted_poll_questions, "")
    ) |>
    select(.data$wave_date, .data$first_wave_poll_count, .data$conference, .data$franchise, .data$franchise_name, .data$first_wave_polls_voted, .data$voted_poll_ids, .data$voted_poll_questions) |>
    arrange(.data$conference, .data$franchise)
}

poll_audit_records <- function(activity, franchises) {
  poll_records <- list()
  visit_poll_records <- function(value) {
    if (is.null(value) || !is.list(value)) return(invisible(NULL))
    value_names <- names(value) %||% character()
    if ("answer" %in% value_names && length(intersect(value_names, c("id", "question", "author", "hasVoted")))) {
      poll_records[[length(poll_records) + 1L]] <<- value
      return(invisible(NULL))
    }
    invisible(lapply(value, visit_poll_records))
  }
  visit_poll_records(activity$polls)

  if (!length(poll_records)) {
    return(tibble(
      poll_id = character(),
      question = character(),
      author = character(),
      has_voted = character(),
      expires = character(),
      multiple_choice = character(),
      answer_id = character(),
      answer_text = character(),
      answer_votes = character(),
      raw_poll_text = character()
    ))
  }

  bind_rows(lapply(poll_records, function(poll) {
    answers <- poll$answer %||% list()
    if (inherits(answers, "data.frame")) {
      answers <- lapply(seq_len(nrow(answers)), function(i) as.list(answers[i, , drop = FALSE]))
    } else if (is.list(answers) && length(answers) && !is.null(names(answers)) && length(intersect(names(answers), c("id", "text", "votes")))) {
      answers <- list(answers)
    }
    if (!length(answers)) answers <- list(list(id = NA_character_, text = NA_character_, votes = NA_character_))

    bind_rows(lapply(answers, function(answer) {
      answer <- as.list(answer)
      tibble(
        poll_id = as.character(poll$id %||% NA_character_),
        question = as.character(poll$question %||% NA_character_),
        author = as.character(poll$author %||% NA_character_),
        has_voted = as.character(poll$hasVoted %||% NA_character_),
        expires = as.character(poll$expires %||% NA_character_),
        multiple_choice = as.character(poll$multiple_choice %||% NA_character_),
        answer_id = as.character(answer$id %||% NA_character_),
        answer_text = as.character(answer$text %||% NA_character_),
        answer_votes = as.character(answer$votes %||% NA_character_),
        raw_poll_text = paste(capture.output(str(poll, max.level = 2)), collapse = " ")
      )
    }))
  })) |>
    distinct(.data$poll_id, .data$answer_id, .keep_all = TRUE)
}

poll_franchise_audit_records <- function(activity, franchises) {
  payloads <- c(list(`0000` = activity$polls), activity$polls_by_franchise %||% list())
  if (!length(payloads)) {
    return(tibble(
      request_franchise_id = character(),
      request_franchise = character(),
      request_franchise_name = character(),
      poll_id = character(),
      question = character(),
      author = character(),
      has_voted = character(),
      expires = character(),
      multiple_choice = character(),
      answer_id = character(),
      answer_text = character(),
      answer_votes = character(),
      raw_poll_text = character()
    ))
  }

  id_lookup <- adl_franchise_id_lookup()
  bind_rows(lapply(names(payloads), function(franchise_id) {
    franchise_code <- id_lookup$franchise[match(franchise_id, id_lookup$franchise_id)]
    if (!length(franchise_code) || is.na(franchise_code)) franchise_code <- NA_character_
    request_name <- franchises$franchise_name[match(franchise_code, franchises$franchise)]
    if (!length(request_name) || is.na(request_name)) {
      request_name <- if (identical(franchise_id, "0000")) "Commissioner" else NA_character_
    }
    poll_audit_records(list(polls = payloads[[franchise_id]]), franchises) |>
      mutate(
        request_franchise_id = .env$franchise_id,
        request_franchise = .env$franchise_code,
        request_franchise_name = .env$request_name,
        .before = 1
      )
  }))
}

evaluate_rookie_draft_clock_expirations <- function(activity, franchises, config = NULL) {
  if (!is.null(config) && !rookie_draft_check_is_active(config)) return(empty_inactivity_rows())
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
  parse_auction_token <- function(event_text, field) {
    text <- as.character(event_text %||% "")
    m <- regexec("\\b(AUCTION_INIT|AUCTION_BID|AUCTION_WON)\\s+([0-9]{4})(?:\\s+[^|\\s]+)*\\s+([^\\s|]+)\\|([0-9.]+)\\|", text, ignore.case = TRUE, perl = TRUE)
    parts <- regmatches(text, m)
    vapply(parts, function(x) {
      if (length(x) < 5L) return(NA_character_)
      switch(
        field,
        type = x[[2]],
        franchise_id = x[[3]],
        player_id = x[[4]],
        amount = x[[5]],
        NA_character_
      )
    }, character(1))
  }

  parse_forced_bid_franchise <- function(event_text) {
    text <- as.character(event_text %||% "")
    m <- regexec("\\|\\s*([^|]+?)\\s+forced bid increase\\b", text, ignore.case = TRUE)
    parts <- regmatches(text, m)
    vapply(parts, function(x) {
      if (length(x) < 2L) return(NA_character_)
      trimws(x[[2]])
    }, character(1))
  }

  franchise_name_lookup <- franchises |>
    transmute(franchise_name_key = toupper(trimws(.data$franchise_name)), forced_franchise = .data$franchise)

  bind_rows(normalize_activity_records(activity$transactions, "transactions", franchises), normalize_activity_records(activity$auction_results, "auctionResults", franchises)) |>
    filter(!is.na(.data$franchise), grepl("bid|auction", .data$event_text, ignore.case = TRUE)) |>
    mutate(
      auction_event_type = toupper(parse_auction_token(.data$event_text, "type")),
      auction_franchise_id = parse_auction_token(.data$event_text, "franchise_id"),
      auction_player_id = parse_auction_token(.data$event_text, "player_id"),
      auction_amount_raw = suppressWarnings(as.numeric(parse_auction_token(.data$event_text, "amount"))),
      auction_amount = if_else(.data$auction_amount_raw > 100, .data$auction_amount_raw / 1000, .data$auction_amount_raw),
      auction_forced_franchise_name = parse_forced_bid_franchise(.data$event_text),
      auction_forced_franchise_key = toupper(trimws(.data$auction_forced_franchise_name)),
      event_kind = case_when(
        grepl("nominat|AUCTION_INIT", .data$event_text, ignore.case = TRUE) ~ "nomination",
        grepl("AUCTION_BID|bid", .data$event_text, ignore.case = TRUE) ~ "bid",
        grepl("AUCTION_WON", .data$event_text, ignore.case = TRUE) ~ "win",
        TRUE ~ "auction"
      ),
      commissioner_initiated = grepl("\\(C\\)|commissioner", .data$event_text, ignore.case = TRUE)
    ) |>
    left_join(franchise_name_lookup, by = c("auction_forced_franchise_key" = "franchise_name_key")) |>
    mutate(
      auction_player_id = coalesce(.data$auction_player_id, .data$player_id),
      auction_high_bidder_franchise = coalesce(.data$forced_franchise, .data$franchise)
    ) |>
    select(-.data$auction_forced_franchise_key, -.data$forced_franchise) |>
    distinct(.data$franchise, .data$occurred_at, .data$event_text, .keep_all = TRUE)
}

late_ufa_ng_bid_prohibition_window <- function(config, season = get_current_season()) {
  start_at <- ufa_ng_bid_adjustment_start(season)
  end_at <- commissioner_alert_cutdown_datetime(season, "final_roster_cutdown")
  tibble(start_at = start_at, end_at = end_at)
}

late_ufa_ng_bid_sequence_events <- function(bids, config, season = get_current_season()) {
  window <- late_ufa_ng_bid_prohibition_window(config, season = season)
  if (!nrow(bids) || is.na(window$start_at[[1]]) || is.na(window$end_at[[1]])) {
    return(tibble())
  }

  bids |>
    filter(
      !is.na(.data$occurred_at),
      .data$occurred_at >= window$start_at[[1]],
      .data$occurred_at < window$end_at[[1]],
      .data$event_kind %in% c("bid", "nomination", "win")
    ) |>
    mutate(
      auction_high_bidder_franchise = coalesce(.data$auction_high_bidder_franchise, .data$franchise),
      auction_player_id = coalesce(.data$auction_player_id, .data$player_id)
    ) |>
    arrange(.data$auction_player_id, .data$occurred_at, .data$auction_amount_raw)
}

evaluate_offseason_illegal_ng_bid_sequences <- function(bids, config, franchises, season = get_current_season()) {
  events <- late_ufa_ng_bid_sequence_events(bids, config, season = season)
  if (!nrow(events)) return(empty_inactivity_rows())

  sd_min <- adl_sd_minimum(season)
  required_bid <- round_up_to_tenth(sd_min)
  franchise_lookup <- franchises |>
    distinct(.data$conference, .data$franchise, .data$franchise_name)

  bid_events <- events |>
    filter(
      .data$event_kind == "bid",
      !is.na(.data$auction_player_id),
      nzchar(.data$auction_player_id),
      !is.na(.data$auction_amount),
      !is.na(.data$auction_high_bidder_franchise),
      nzchar(.data$auction_high_bidder_franchise)
    ) |>
    group_by(.data$auction_player_id) |>
    arrange(.data$occurred_at, .data$auction_amount_raw, .by_group = TRUE) |>
    mutate(
      previous_high_bidder = dplyr::lag(.data$auction_high_bidder_franchise),
      high_bidder_changed = is.na(.data$previous_high_bidder) | .data$auction_high_bidder_franchise != .data$previous_high_bidder
    ) |>
    ungroup()

  if (!nrow(bid_events)) return(empty_inactivity_rows())

  violations <- bind_rows(lapply(split(bid_events, bid_events$auction_player_id), function(player_events) {
    player_events <- player_events |> arrange(.data$occurred_at, .data$auction_amount_raw)
    below_sd <- player_events |>
      filter(
        .data$auction_amount > 0,
        .data$auction_amount < .env$sd_min,
        .data$high_bidder_changed
      )
    if (!nrow(below_sd)) return(tibble())

    bind_rows(lapply(seq_len(nrow(below_sd)), function(i) {
      earlier <- below_sd[i, ]
      later <- player_events |>
        filter(
          .data$occurred_at > earlier$occurred_at[[1]],
          .data$auction_amount >= .env$sd_min,
          .data$auction_high_bidder_franchise != earlier$auction_high_bidder_franchise[[1]]
        ) |>
        slice_head(n = 1)
      if (!nrow(later)) return(tibble())
      tibble(
        offender_franchise = earlier$auction_high_bidder_franchise[[1]],
        auction_player_id = earlier$auction_player_id[[1]],
        player_name = earlier$player_name[[1]],
        below_sd_amount = earlier$auction_amount[[1]],
        below_sd_at = earlier$occurred_at[[1]],
        later_amount = later$auction_amount[[1]],
        later_high_bidder = later$auction_high_bidder_franchise[[1]],
        later_at = later$occurred_at[[1]]
      )
    }))
  }))

  if (!nrow(violations)) return(empty_inactivity_rows())

  violations |>
    left_join(franchise_lookup, by = c("offender_franchise" = "franchise")) |>
    left_join(
      franchise_lookup |>
        transmute(later_high_bidder = .data$franchise, later_high_bidder_name = .data$franchise_name),
      by = "later_high_bidder"
    ) |>
    mutate(
      player_label = if_else(
        !is.na(.data$player_name) & nzchar(.data$player_name) & toupper(.data$player_name) != "NA",
        .data$player_name,
        .data$auction_player_id
      )
    ) |>
    distinct(.data$offender_franchise, .data$auction_player_id, .keep_all = TRUE) |>
    transmute(
      alert_type = "Offseason Inactivity Violation",
      severity = "violation",
      conference,
      franchise = .data$offender_franchise,
      franchise_name,
      rule = "Must not place an NG bid below SD minimum during the late-offseason prohibition period",
      observed = paste0(
        .data$player_label,
        " was high bidder at ",
        format_millions(.data$below_sd_amount),
        " below SD minimum, then later bid to at least ",
        format_millions(.env$sd_min),
        " with a different high bidder."
      ),
      details = paste0(
        "Below-SD high bid: ",
        format(lubridate::with_tz(.data$below_sd_at, "America/New_York"), "%Y-%m-%d %H:%M %Z"),
        "; later high bidder: ",
        coalesce(.data$later_high_bidder_name, .data$later_high_bidder),
        " at ",
        format_millions(.data$later_amount),
        " on ",
        format(lubridate::with_tz(.data$later_at, "America/New_York"), "%Y-%m-%d %H:%M %Z"),
        "; legal minimum bid: ",
        format_millions(.env$required_bid),
        "."
      ),
      violation_key = paste("offseason_illegal_ng_bid", season, .data$offender_franchise, .data$auction_player_id, format(as.Date(.data$below_sd_at), "%Y-%m-%d"), sep = "|"),
      season_phase = "offseason"
    )
}

pre_ufa_auction_windows <- function(config) {
  windows <- config |> filter(.data$event_type == "pre_ufa_auction") |> mutate(start_at = parse_et_datetime(.data$start_at), end_at = parse_et_datetime(.data$end_at)) |> filter(!is.na(.data$start_at), !is.na(.data$end_at))
  windows
}

pre_ufa_auction_participation_events <- function(bids, config) {
  windows <- pre_ufa_auction_windows(config)
  if (!nrow(windows) || !nrow(bids)) {
    return(tibble(
      event_name = character(),
      franchise = character(),
      occurred_at = as.POSIXct(character()),
      event_kind = character(),
      commissioner_initiated = logical(),
      event_text = character()
    ))
  }

  bind_rows(lapply(seq_len(nrow(windows)), function(i) {
    window <- windows[i, ]
    bids |>
      filter(.data$occurred_at >= window$start_at[[1]], .data$occurred_at <= window$end_at[[1]]) |>
      transmute(
        event_name = window$event_name[[1]],
        franchise,
        occurred_at,
        event_kind = coalesce(.data$event_kind, "auction"),
        commissioner_initiated = coalesce(.data$commissioner_initiated, FALSE),
        event_text
      )
  })) |>
    distinct(.data$event_name, .data$franchise, .data$occurred_at, .data$event_text, .keep_all = TRUE)
}

pre_ufa_auction_participation_detail <- function(bids, config, franchises) {
  events <- pre_ufa_auction_participation_events(bids, config)
  participation_events <- events |>
    filter(
      .data$event_kind == "bid" |
        (.data$event_name %in% c("R/F", "UDFA") & .data$event_kind == "nomination")
    )
  franchise_order <- franchises |> transmute(franchise, franchise_sort_order = row_number())

  franchises |>
    left_join(
      participation_events |>
        group_by(.data$franchise) |>
        summarize(
          auction_bid_count = n_distinct(.data$event_name),
          qualifying_auction_event_count = n(),
          auctions = paste(sort(unique(.data$event_name)), collapse = ", "),
          event_kinds = paste(sort(unique(.data$event_kind)), collapse = ", "),
          .groups = "drop"
        ),
      by = "franchise"
    ) |>
    left_join(
      events |>
        group_by(.data$franchise) |>
        summarize(
          auction_event_count = n(),
          nomination_event_count = sum(.data$event_kind == "nomination", na.rm = TRUE),
          commissioner_initiated_event_count = sum(.data$commissioner_initiated, na.rm = TRUE),
          .groups = "drop"
        ),
      by = "franchise"
    ) |>
    left_join(franchise_order, by = "franchise") |>
    mutate(
      auction_bid_count = coalesce(.data$auction_bid_count, 0L),
      qualifying_auction_event_count = coalesce(.data$qualifying_auction_event_count, 0L),
      auction_event_count = coalesce(.data$auction_event_count, 0L),
      nomination_event_count = coalesce(.data$nomination_event_count, 0L),
      commissioner_initiated_event_count = coalesce(.data$commissioner_initiated_event_count, 0L),
      auctions = if_else(nzchar(coalesce(.data$auctions, "")), .data$auctions, "none"),
      event_kinds = if_else(nzchar(coalesce(.data$event_kinds, "")), .data$event_kinds, "none")
    ) |>
    arrange(.data$franchise_sort_order) |>
    select(-.data$franchise_sort_order)
}

evaluate_pre_ufa_auction_participation <- function(bids, config, franchises) {
  windows <- pre_ufa_auction_windows(config)
  if (nrow(windows) < 5L) return(empty_inactivity_rows())
  pre_ufa_auction_participation_detail(bids, config, franchises) |>
    filter(.data$auction_bid_count <= 1L) |>
    transmute(alert_type = "Offseason Inactivity Violation", severity = "violation", conference, franchise, franchise_name, rule = "Must place bids in at least 2 pre-UFA auctions: R/F, FT, RFA, B/R, and UDFA", observed = paste0(.data$auction_bid_count, " pre-UFA auction(s) with a bid"), details = paste0("Auctions with bids: ", .data$auctions), violation_key = paste("pre_ufa_participation", .data$franchise, sep = "|"), season_phase = "offseason")
}

evaluate_ufa_auction_bid_gaps <- function(bids, config, franchises) {
  window <- config |>
    filter(.data$event_type == "ufa_auction") |>
    mutate(start_at = parse_et_datetime(.data$start_at), end_at = .data$start_at + lubridate::hours(72)) |>
    filter(!is.na(.data$start_at), !is.na(.data$end_at)) |>
    slice_head(n = 1)
  if (!nrow(window)) {
    window <- config |>
      filter(.data$event_type == "ufa_auction_first_three_days") |>
      mutate(start_at = parse_et_datetime(.data$start_at), end_at = parse_et_datetime(.data$end_at)) |>
      filter(!is.na(.data$start_at), !is.na(.data$end_at)) |>
      slice_head(n = 1)
  }
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

build_offseason_inactivity_alerts <- function(season = get_current_season(), force_live = TRUE, include_info = FALSE, run_time = Sys.time()) {
  config <- read_offseason_inactivity_config(season)
  franchises <- franchise_lookup_table(season = season, force_live = force_live)
  activity <- fetch_offseason_activity_records(season = season)
  bids <- normalize_bid_events(activity, franchises)
  poll_audit <- safe_offseason_review("MFL poll audit", poll_audit_records(activity, franchises))
  poll_franchise_audit <- safe_offseason_review("MFL poll franchise audit", poll_franchise_audit_records(activity, franchises))
  poll_page_html <- safe_offseason_review("MFL poll page fetch", fetch_mfl_poll_page_html(activity$conn, season = season))
  poll_page_votes <- if (is.character(poll_page_html) && length(poll_page_html) == 1L) {
    safe_offseason_review("MFL poll page vote audit", parse_mfl_poll_page_votes(poll_page_html, franchises))
  } else {
    tibble()
  }
  poll_first_wave_participation <- safe_offseason_review("MFL first-wave poll participation", poll_first_wave_participation_records(poll_page_votes, franchises))
  pre_ufa_events <- safe_offseason_review("Pre-UFA auction participation events", pre_ufa_auction_participation_events(bids, config))
  pre_ufa_detail <- safe_offseason_review("Pre-UFA auction participation detail", pre_ufa_auction_participation_detail(bids, config, franchises))
  late_ufa_ng_events <- safe_offseason_review("Late-offseason NG bid sequence events", late_ufa_ng_bid_sequence_events(bids, config, season = season))
  late_ufa_ng_violations <- safe_offseason_review("Illegal late-offseason NG bid sequences", evaluate_offseason_illegal_ng_bid_sequences(bids, config, franchises, season = season))
  if ("poll_id" %in% names(poll_audit)) {
    write_csv(poll_audit, offseason_inactivity_path("poll_audit", season), na = "")
  }
  if ("request_franchise_id" %in% names(poll_franchise_audit)) {
    write_csv(poll_franchise_audit, offseason_inactivity_path("poll_franchise_audit", season), na = "")
  }
  if ("voter_franchise" %in% names(poll_page_votes)) {
    write_csv(poll_page_votes, offseason_inactivity_path("poll_page_votes", season), na = "")
  }
  if ("first_wave_polls_voted" %in% names(poll_first_wave_participation)) {
    write_csv(poll_first_wave_participation, offseason_inactivity_path("poll_first_wave_participation", season), na = "")
  }
  if ("event_name" %in% names(pre_ufa_events)) {
    write_csv(pre_ufa_events, offseason_inactivity_path("pre_ufa_auction_participation_events", season), na = "")
  }
  if ("auction_bid_count" %in% names(pre_ufa_detail)) {
    write_csv(pre_ufa_detail, offseason_inactivity_path("pre_ufa_auction_participation", season), na = "")
  }
  if ("auction_player_id" %in% names(late_ufa_ng_events)) {
    write_csv(late_ufa_ng_events, offseason_inactivity_path("late_ufa_ng_bid_sequence_events", season), na = "")
  }
  if ("violation_key" %in% names(late_ufa_ng_violations)) {
    write_csv(late_ufa_ng_violations, offseason_inactivity_path("late_ufa_ng_bid_sequence_violations", season), na = "")
  }
  candidates <- bind_rows(
    safe_offseason_review("Offseason inactivity monitor configuration", config_warning_rows(offseason_config_messages(config), season = season)),
    safe_offseason_review("Bylaw first-round voting check", evaluate_bylaw_first_wave_voting(poll_page_votes, franchises, season = season, run_time = run_time)),
    safe_offseason_review("Rookie Draft clock expirations", evaluate_rookie_draft_clock_expirations(activity, franchises, config = config)),
    safe_offseason_review("Pre-UFA auction participation", evaluate_pre_ufa_auction_participation(bids, config, franchises)),
    safe_offseason_review("UFA first-three-days 24-hour bid gaps", evaluate_ufa_auction_bid_gaps(bids, config, franchises)),
    late_ufa_ng_violations,
    safe_offseason_review("Illegal offseason waiver claims", evaluate_offseason_illegal_waiver_claims(activity, franchises, season = season)),
    safe_offseason_review("Repeated offseason roster violations", evaluate_repeated_offseason_roster_violations(season)),
    safe_offseason_review("UFA signing deadline review", evaluate_ufa_signing_deadline_review(config, season = season)),
    safe_offseason_review("Roster deadline inactivity checks", evaluate_roster_deadline_inactivity(season, config, force_live = force_live))
  ) |>
    mutate(season = .env$season, checked_at = format(.env$run_time, "%Y-%m-%d %H:%M:%S %Z"), .before = 1) |>
    distinct(.data$alert_type, .data$franchise, .data$rule, .data$observed, .keep_all = TRUE) |>
    arrange(desc(.data$severity == "violation"), .data$alert_type, .data$conference, .data$franchise)
  write_csv(candidates, offseason_inactivity_path("review", season), na = "")

  issued <- read_offseason_inactivity_issued(season) |>
    filter(!is.na(.data$violation_key), nzchar(.data$violation_key)) |>
    distinct(.data$violation_key)

  new_violations <- candidates |>
    filter(.data$severity == "violation", !is.na(.data$violation_key), nzchar(.data$violation_key)) |>
    anti_join(issued, by = "violation_key")

  alerts <- if (isTRUE(include_info)) {
    bind_rows(new_violations, candidates |> filter(.data$severity != "violation"))
  } else {
    new_violations
  }
  alerts <- alerts |>
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
