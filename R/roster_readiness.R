roster_readiness_type <- "Roster Readiness Warning"
readiness_team <- function(team) mfl_player_team(dplyr::recode(toupper(team), LV = "LVR", WSH = "WAS"))

parse_readiness_depth_chart <- function(chart, players, season, team, checked_at) {
  stamp <- suppressWarnings(as.POSIXct(chart$timestamp, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
  if (!identical(chart$status, "success") || as.integer(chart$season$year) != season ||
      is.na(stamp) || stamp > checked_at + 300 || stamp < checked_at - 86400 ||
      readiness_team(chart$team$abbreviation) != team) stop("Invalid or stale readiness depth chart: ", team)
  result <- bind_rows(lapply(chart$depthchart, function(group) {
    bind_rows(lapply(c(qb = "QB", pk = "PK", p = "PN"), function(position) {
      key <- c(QB = "qb", PK = "pk", PN = "p")[[position]]
      athletes <- group$positions[[key]]$athletes
      if (!length(athletes)) return(tibble())
      tibble(espn_id = vapply(athletes, record_field, character(1), name = "id"),
        player_pos = position, depth_rank = seq_along(athletes))
    }))
  }))
  keys <- unique(unlist(lapply(chart$depthchart, function(group) names(group$positions))))
  if (!nrow(result) || !"QB" %in% result$player_pos || !"qb" %in% keys) stop("Incomplete readiness depth chart: ", team)
  mapping <- players |> filter(.data$player_team == .env$team) |>
    distinct(.data$espn_id, .data$player_id, .data$player_pos) |>
    group_by(.data$espn_id) |> filter(n_distinct(.data$player_id) == 1L) |> ungroup()
  mapped <- result |> inner_join(mapping, by = c("espn_id", "player_pos")) |>
    mutate(player_team = .env$team, source = paste0("https://www.espn.com/nfl/team/depth/_/name/", tolower(chart$team$abbreviation)))
  if (!all(unique(result$player_pos) %in% mapped$player_pos[mapped$depth_rank == 1L])) {
    stop("Unmapped starting-player identities in readiness depth chart: ", team)
  }
  mapped
}

fetch_readiness_depth_charts <- function(season, checked_at = Sys.time()) {
  raw <- ffscrapr::mfl_getendpoint(connect_adl_mfl(season), "players", DETAILS = 1)[["content"]][["players"]][["player"]]
  records <- list_records(raw, c("id", "espn_id", "position", "team"))
  players <- tibble(
    player_id = vapply(records, record_field, character(1), name = "id"),
    espn_id = vapply(records, record_field, character(1), name = "espn_id"),
    player_pos = vapply(records, record_field, character(1), name = "position"),
    player_team = mfl_player_team(vapply(records, record_field, character(1), name = "team"))
  ) |> filter(.data$player_pos %in% c("QB", "PK", "PN"))
  crosswalk <- tryCatch(nflreadr::load_ff_playerids(), error = function(e) tibble(mfl_id = character(), espn_id = character())) |>
    transmute(player_id = as.character(.data$mfl_id), espn_id = as.character(.data$espn_id)) |>
    inner_join(players |> select(-espn_id), by = "player_id")
  players <- bind_rows(players, crosswalk) |>
    filter(!is.na(.data$espn_id), nzchar(.data$espn_id), .data$espn_id != "0") |> distinct()
  teams <- c("ARI", "ATL", "BAL", "BUF", "CAR", "CHI", "CIN", "CLE", "DAL", "DEN", "DET", "GB",
    "HOU", "IND", "JAX", "KC", "LAC", "LAR", "LV", "MIA", "MIN", "NE", "NO", "NYG", "NYJ", "PHI", "PIT", "SEA", "SF", "TB", "TEN", "WSH")
  health <- list()
  result <- bind_rows(lapply(teams, function(team) {
    tryCatch({
    url <- paste0("https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams/", tolower(team), "/depthcharts")
    response <- httr::GET(url, httr::timeout(8), httr::user_agent("ADLCommissionerDashboard"))
    httr::stop_for_status(response)
    chart <- jsonlite::fromJSON(httr::content(response, "text", encoding = "UTF-8"), simplifyVector = FALSE)
    rows <- parse_readiness_depth_chart(chart, players, season, readiness_team(team), checked_at)
    vacant <- setdiff(c("QB", "PK", "PN"), unique(rows$player_pos))
    health[[length(health) + 1L]] <<- tibble(team = team, status = "verified",
      detail = if (length(vacant)) paste("Chart has no listed", paste(vacant, collapse = "/")) else "")
    rows
    }, error = function(e) {
      health[[length(health) + 1L]] <<- tibble(team = team, status = "unverified", detail = conditionMessage(e))
      tibble()
    })
  }))
  if (!nrow(result)) result <- tibble(player_id = character(), player_pos = character(),
    depth_rank = integer(), player_team = character(), source = character())
  attr(result, "source_health") <- bind_rows(health)
  result
}

pending_readiness_auctions <- function(transactions, franchises, checked_at) {
  required <- c("type", "timestamp", "franchise", "transaction")
  if (!all(required %in% names(transactions))) stop("Unverified readiness auction history.")
  tx <- transactions[grepl("^AUCTION_", transactions$type), required]
  empty <- tibble(franchise = character(), player_id = character(), closes_at = as.POSIXct(character(), tz = "UTC"))
  if (!nrow(tx)) return(empty)
  tx$time <- as.POSIXct(suppressWarnings(as.numeric(tx$timestamp)), origin = "1970-01-01", tz = "UTC")
  if (anyNA(tx$time) || anyNA(tx$franchise) || anyNA(tx$transaction)) stop("Invalid readiness auction history.")
  tx <- tx[tx$time <= checked_at, ]
  tx$player_id <- vapply(strsplit(tx$transaction, "|", fixed = TRUE), `[[`, character(1), 1L)
  tx <- tx |> left_join(franchises |> select(.data$franchise_id, .data$conference), by = c("franchise" = "franchise_id"))
  if (anyNA(tx$conference)) stop("Unknown auction franchise/conference.")
  result <- list()
  for (key in unique(paste(tx$conference, tx$player_id, sep = "|"))) {
    history <- tx[paste(tx$conference, tx$player_id, sep = "|") == key, ]
    history <- history[order(history$time), ]
    starts <- which(history$type == "AUCTION_INIT")
    if (!length(starts)) next
    history <- history[seq.int(tail(starts, 1L), nrow(history)), ]
    if (any(!history$type %in% c("AUCTION_INIT", "AUCTION_BID"))) next
    leader <- history$franchise[[1]]
    clock <- history$time[[1]]
    participants <- character()
    for (i in seq_len(nrow(history))) {
      event <- history[i, ]
      if (event$franchise != leader) { leader <- event$franchise; clock <- event$time[[1]] }
      participants <- c(participants, event$franchise)
      parts <- strsplit(event$transaction, "|", fixed = TRUE)[[1]]
      if (length(parts) >= 3L) {
        annotation <- trimws(paste(parts[-c(1L, 2L)], collapse = "|"))
        proxy <- franchises$franchise_id[franchises$conference == event$conference &
          paste(franchises$franchise_name, "forced bid increase") == annotation]
        participants <- c(participants, proxy)
      }
    }
    closes_at <- clock + 86400
    if (closes_at <= checked_at) next
    for (id in unique(participants)) {
      franchise <- franchises$franchise[franchises$franchise_id == id]
      result[[length(result) + 1L]] <- tibble(franchise = franchise, conference = history$conference[[1]],
        player_id = history$player_id[[1]], closes_at = closes_at)
    }
  }
  if (length(result)) bind_rows(result) else empty
}

fetch_readiness_pending_auctions <- function(season, rosters, checked_at) {
  conn <- connect_adl_mfl(season)
  raw <- ffscrapr::mfl_getendpoint(conn, "transactions")[["content"]]
  if (is.null(raw$transactions) || !is.null(raw$error)) stop("Readiness auction feed unavailable.")
  records <- list_records(raw$transactions$transaction, c("type", "timestamp", "franchise", "transaction"))
  tx <- as_tibble(setNames(lapply(c("type", "timestamp", "franchise", "transaction"), function(field) {
    vapply(records, record_field, character(1), name = field)
  }), c("type", "timestamp", "franchise", "transaction")))
  league <- ffscrapr::mfl_getendpoint(conn, "league")[["content"]][["league"]]
  identities <- list_records(league$franchises$franchise, c("id", "name"))
  franchises <- tibble(franchise_id = vapply(identities, record_field, character(1), name = "id"),
    franchise_name = vapply(identities, record_field, character(1), name = "name")) |>
    left_join(rosters |> distinct(.data$franchise, .data$franchise_name, .data$conference), by = "franchise_name")
  if (nrow(franchises) != 32L || anyDuplicated(franchises$franchise_id) || anyNA(franchises$conference)) {
    stop("Readiness auction franchise identities unavailable.")
  }
  pending <- pending_readiness_auctions(tx, franchises, checked_at)
  if (nrow(pending)) pending <- pending |> anti_join(rosters |> distinct(.data$conference, .data$player_id),
    by = c("conference", "player_id"))
  pending
}

evaluate_roster_readiness <- function(rosters, lineups, roles, kickoffs, bye_weeks, week, checked_at = Sys.time(),
  pending_auctions = tibble(), pending_verified = TRUE, current_designations = NULL) {
  findings <- list()
  unavailable_roles <- rosters |> group_by(.data$player_id) |>
    summarize(role_unavailable = all(inactive_designation(.data$player_status)), .groups = "drop")
  roles <- roles |> left_join(unavailable_roles, by = "player_id") |>
    mutate(role_unavailable = coalesce(.data$role_unavailable, FALSE))
  # A known injured first-string player must not make his healthy replacement look unfit.
  if (all(c("player_team", "player_pos") %in% names(roles))) {
    roles <- roles |> group_by(.data$player_team, .data$player_pos) |>
      mutate(expected = !.data$role_unavailable & .data$depth_rank ==
        if (any(!.data$role_unavailable)) min(.data$depth_rank[!.data$role_unavailable]) else Inf) |> ungroup()
  } else roles$expected <- roles$depth_rank == 1L & !roles$role_unavailable
  pending <- tibble()
  if (nrow(pending_auctions) && !is.null(current_designations)) {
    injuries <- current_designations |> group_by(.data$player_id) |>
      summarize(pending_unavailable = any(inactive_designation(.data$player_status)), .groups = "drop")
    pending <- pending_auctions |> inner_join(roles, by = "player_id") |>
      left_join(injuries, by = "player_id") |> left_join(kickoffs, by = "player_team") |>
      filter(.data$expected, !coalesce(.data$pending_unavailable, FALSE),
        !is.na(.data$kickoff_at), .data$closes_at > .env$checked_at, .data$closes_at < .data$kickoff_at,
        is.na(bye_weeks[.data$player_team]) | bye_weeks[.data$player_team] != .env$week)
  }
  roster <- rosters |> filter(.data$player_pos %in% c("QB", "PK", "PN")) |>
    mutate(player_id = as.character(.data$player_id))
  for (franchise in unique(rosters$franchise)) {
    team <- rosters |> filter(.data$franchise == .env$franchise) |> slice_head(n = 1L)
    for (position in c("QB", "PK", "PN")) {
      owned <- roster |> filter(.data$franchise == .env$franchise, .data$player_pos == .env$position) |>
        left_join(roles |> select(.data$player_id, .data$depth_rank, .data$expected, .data$source), by = "player_id") |>
        left_join(kickoffs, by = "player_team")
      # After the position's available NFL games lock, do not request impossible changes.
      unlocked <- kickoffs$kickoff_at > checked_at
      if (!any(unlocked, na.rm = TRUE)) next
      active <- owned$roster_status %in% c("Active", "ROSTER")
      unavailable <- inactive_designation(owned$player_status) | owned$player_team %in% c("FA", "---", "") |
        (!is.na(bye_weeks[owned$player_team]) & bye_weeks[owned$player_team] == week)
      fit <- owned[active & !unavailable & !is.na(owned$depth_rank) & coalesce(owned$expected, FALSE) &
        !is.na(owned$kickoff_at) & owned$kickoff_at > checked_at, ]
      selected <- lineups |> filter(.data$franchise == .env$franchise, .data$player_pos == .env$position)
      # A legal locked starter has already filled this week's slot.
      if (any(selected$player_id %in% owned$player_id[!unavailable & !is.na(owned$kickoff_at) & owned$kickoff_at <= checked_at])) next
      if (nrow(fit) && any(selected$player_id %in% fit$player_id)) next
      # Early-week mail is for acquiring missing personnel, not ordinary lineup editing.
      if (nrow(fit) && as.POSIXlt(checked_at, tz = "America/New_York")$wday %in% c(2L, 3L)) next
      if (!nrow(fit) && !isTRUE(pending_verified)) next
      if (!nrow(fit) && nrow(pending) && any(pending$franchise == franchise & pending$player_pos == position)) next
      # Unknown role data must never be converted into an accusation of having no starter.
      if (any(active & !unavailable & is.na(owned$depth_rank))) next
      replacement <- if (nrow(fit)) paste(fit$player_name, collapse = " or ") else NULL
      observed <- if (nrow(fit)) paste0("Your ", position, " slot does not contain an expected available NFL starter.") else
        paste0("No expected available NFL starting ", position, " was identified on your Active roster for Week ", week, ".")
      details <- if (nrow(fit)) paste0("Submit a new lineup starting ", replacement, " at ", position,
        " before that player's kickoff; remove the current ", position, " selection.") else paste0(
        "Confirm whether your backup has been announced as the NFL starter. If not, acquire an available starting ", position, " through the league's auction/waiver process or trade, or activate an eligible starter you already own; then submit a new lineup before kickoff. ",
        "If no starter can be acquired or you are outbid, contact the commissioners and retain your bid evidence. A depth-chart listing is not proof of inactivity.")
      if (nrow(owned)) details <- paste0(details, " Roster evidence: ", paste(paste0(owned$player_name,
        " (", ifelse(unavailable, "unavailable/bye", ifelse(is.na(owned$depth_rank), "role unverified", paste0("depth ", owned$depth_rank))), ")"), collapse = "; "), ".")
      findings[[length(findings) + 1L]] <- tibble(alert_type = roster_readiness_type, severity = "warning",
        conference = team$conference, franchise = franchise, franchise_name = team$franchise_name,
        rule = paste0("Roster readiness: expected starting ", position, " (ADL V-A)"), observed = observed, details = details)
    }
  }
  bind_rows(findings)
}

send_roster_readiness_email <- function(alerts, season, week, checked_at) {
  directory <- fetch_mfl_franchise_recipients(season = season)
  for (i in seq_len(nrow(alerts))) {
    row <- alerts[i, ]
    recipients <- directory |> filter(.data$franchise == row$franchise[[1]])
    body <- render_commissioner_gm_alert_email(row, season, week, as.Date(checked_at, tz = "America/New_York"),
      title_prefix = "ADL Roster Needs Attention", lineup_url = commissioner_submit_lineup_url(recipients, season))
    lineup_url <- commissioner_submit_lineup_url(recipients, season)
    if (!is.null(lineup_url)) body <- paste(body, "", "Submit New Lineup:", lineup_url, sep = "\n")
    key <- paste("roster-readiness", season, week, row$franchise, row$rule,
      paste(sort(unique(recipients$email)), collapse = ","), sep = "|")
    status <- send_alert_mail(paste0("ADL Roster Needs Attention - ", row$franchise_name, " - Week ", week),
      body, to = recipients$email, cc = character(), delivery_key = key)
    if (!isTRUE(status$sent)) stop("Roster-readiness email delivery not confirmed: ", status$reason)
  }
  tibble(sent = TRUE, reason = "sent", outbox_path = "", gm_emails_sent = nrow(alerts))
}
