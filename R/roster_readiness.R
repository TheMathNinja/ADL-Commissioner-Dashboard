roster_readiness_type <- "Roster Readiness Warning"
lineup_issue_keys <- function(keys) as.character(jsonlite::toJSON(sort(unique(keys)), auto_unbox = FALSE))

verified_lineup_repairs <- function(lineups, rosters, current_designations, kickoffs, bye_weeks, week) {
  repairs <- list()
  for (franchise in unique(lineups$franchise)) {
    selected <- lineups |> filter(.data$franchise == .env$franchise)
    if (!nrow(selected) || anyDuplicated(selected$player_id) || anyNA(selected$player_pos)) next
    positions <- lineup_position_status(selected$franchise_id[[1]], lineups)
    filled <- positions$player_pos[positions$starter_count >= positions$min_starters &
      positions$starter_count <= positions$max_starters]
    keys <- if (length(filled)) paste0("position:", filled) else character()
    if (nrow(selected) == 21L) keys <- c(keys, "structure:total")
    if (!nrow(lineup_starter_count_alert_rows(selected$franchise_id[[1]], nrow(selected), lineups))) keys <- c(keys, "lineup:empty")
    groups <- adl_lineup_group_rules()
    for (i in seq_len(nrow(groups))) {
      group <- as.character(groups$lineup_group[[i]])
      if (sum(positions$starter_count[positions$lineup_group == group]) == groups$required_starters[[i]]) {
        keys <- c(keys, paste0("group:", group), paste0("excess:", group))
      }
    }
    if (!is.null(current_designations)) {
      healthy <- selected |> select(.data$player_id) |>
        inner_join(rosters |> filter(.data$franchise == .env$franchise), by = "player_id")
      if (nrow(healthy)) {
        bad_ids <- current_designations$player_id[inactive_designation(current_designations$player_status)]
        healthy <- healthy |> filter(!inactive_designation(.data$player_status), !.data$player_id %in% bad_ids,
          .data$roster_status %in% c("Active", "ROSTER"), .data$player_team %in% kickoffs$player_team,
          is.na(bye_weeks[.data$player_team]) | bye_weeks[.data$player_team] != .env$week)
        if (nrow(healthy)) keys <- c(keys, paste0("player:", healthy$player_id))
      }
    }
    repairs[[length(repairs) + 1L]] <- tibble(franchise = franchise, key = unique(keys))
  }
  if (length(repairs)) bind_rows(repairs) else tibble(franchise = character(), key = character())
}
readiness_team <- function(team) mfl_player_team(team, strict = TRUE)

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
  teams <- mfl_team_codes()
  health <- list()
  result <- bind_rows(lapply(teams, function(team) {
    tryCatch({
    url <- paste0("https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams/",
      tolower(mfl_team_to_provider(team, "espn")), "/depthcharts")
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

verified_role_submissions <- function(audit, checked_at) {
  if (!nrow(audit)) return(character())
  stamp <- as.POSIXct(sub(" [A-Z]+$", "", audit$submitted_at),
    format = "%Y-%m-%d %H:%M:%S", tz = "America/New_York")
  unique(audit$franchise[audit$submission_status %in% c("submitted", "commissioner_set") &
    !is.na(stamp) & as.numeric(stamp) <= as.numeric(checked_at)])
}

evaluate_roster_readiness <- function(rosters, lineups, roles, kickoffs, bye_weeks, week,
  checked_at = Sys.time(), submitted_franchises = character(), current_designations = NULL) {
  findings <- tibble()
  resolved <- tibble(franchise = character(), key = character())
  if (length(submitted_franchises) && !is.null(current_designations) && nrow(roles)) {
    # A backup promoted by a verified absence is the expected starter, not a warning.
    unavailable_ids <- union(
      rosters$player_id[inactive_designation(rosters$player_status)],
      current_designations$player_id[inactive_designation(current_designations$player_status)])
    roles$player_team <- mfl_player_team(roles$player_team)
    roles <- roles |> group_by(.data$player_team, .data$player_pos) |>
      mutate(
        available = !.data$player_id %in% unavailable_ids,
        expected = .data$available & .data$depth_rank ==
          if (any(.data$available)) min(.data$depth_rank[.data$available]) else Inf
      ) |> ungroup()
    rosters$player_team <- mfl_player_team(rosters$player_team)
    kickoffs$player_team <- mfl_player_team(kickoffs$player_team, strict = TRUE)
    names(bye_weeks) <- mfl_player_team(names(bye_weeks), strict = TRUE)
    selected <- lineups |>
      filter(.data$franchise %in% submitted_franchises, .data$player_pos %in% c("QB", "PK", "PN")) |>
      distinct(.data$franchise, .data$player_id, .data$player_pos) |>
      inner_join(rosters, by = c("franchise", "player_id", "player_pos")) |>
      inner_join(roles, by = c("player_id", "player_team", "player_pos")) |>
      inner_join(kickoffs, by = "player_team") |>
      filter(.data$roster_status %in% c("Active", "ROSTER"), .data$available,
        !is.na(.data$kickoff_at), .data$kickoff_at > checked_at,
        is.na(bye_weeks[.data$player_team]) | bye_weeks[.data$player_team] != .env$week)
    # Separate these warnings from missing-slot and injury episodes.
    good <- selected |> group_by(.data$franchise, .data$player_pos) |>
      filter(all(.data$expected)) |> ungroup()
    if (nrow(good)) resolved <- distinct(transmute(good, franchise = .data$franchise,
      key = paste0("starter-role:", .data$player_pos)))
    findings <- selected |> filter(!.data$expected) |>
      transmute(alert_type = roster_readiness_type, severity = "warning",
        conference = .data$conference, franchise = .data$franchise, franchise_name = .data$franchise_name,
        lineup_issue_keys = vapply(paste0("starter-role:", .data$player_pos), lineup_issue_keys, character(1)),
        rule = paste0("Submitted ", .data$player_pos, " must be an expected NFL starter (ADL V-A)"),
        observed = paste0("Your submitted ", .data$player_pos, ", ", .data$player_name,
          ", is not a projected NFL starter. Please remedy."),
        details = "")
  }
  attr(findings, "resolved") <- resolved
  attr(findings, "held") <- resolved[0, ]
  findings
}

send_coordinated_lineup_email <- function(alerts, season, week, checked_at, snapshot = NULL, directory = NULL) {
  failure <- function(reason) tibble(sent = FALSE, reason = reason, outbox_path = "", gm_emails_sent = 0L)
  if (nrow(alerts) && any(is.na(alerts$franchise) | !nzchar(alerts$franchise))) return(failure("offender_franchise_not_found"))
  if (is.null(directory)) directory <- tryCatch(fetch_mfl_franchise_recipients(season = season), error = identity)
  if (inherits(directory, "error")) return(failure("offender_recipient_lookup_failed"))
  snapshot_keys <- function(field, franchise) {
    rows <- snapshot[[field]]
    if (!is.null(rows) && nrow(rows)) unique(rows$key[rows$franchise == franchise]) else character()
  }
  resolved_teams <- if (!is.null(snapshot$resolved) && nrow(snapshot$resolved)) snapshot$resolved$franchise else character()
  held_teams <- if (!is.null(snapshot$held) && nrow(snapshot$held)) snapshot$held$franchise else character()
  teams <- unique(c(alerts$franchise, resolved_teams, held_teams))
  messages <- lapply(teams, function(franchise) {
    rows <- alerts |> filter(.data$franchise == .env$franchise)
    recipients <- directory |> filter(.data$franchise == .env$franchise)
    if (!nrow(recipients) || !any(nzchar(recipients$email))) return(list(error = "offender_email_not_found"))
    label <- if (nrow(rows)) rows$franchise_name[[1]] else franchise
    subject <- paste0("ADL Roster Needs Attention - ", label, " - Week ", week)
    entries <- lapply(seq_len(nrow(rows)), function(i) {
      row <- rows[i, ]
      encoded <- if ("lineup_issue_keys" %in% names(row)) row$lineup_issue_keys[[1]] else NA_character_
      keys <- if (!is.na(encoded) && nzchar(encoded)) jsonlite::fromJSON(encoded) else paste0("detail:",
        digest::digest(paste(row$rule, row$observed, sep = "|"), algo = "sha256", serialize = FALSE))
      list(keys = as.list(keys), body = paste0("Rule: ", row$rule, "\nObserved: ", row$observed))
    })
    url <- commissioner_submit_lineup_url(recipients, season)
    footer <- if (!is.null(url)) paste("Submit New Lineup:", url, sep = "\n") else ""
    legacy <- setNames(lapply(c("QB", "PK", "PN"), function(position) paste("roster-readiness", season, week, franchise,
      paste0("Roster readiness: expected starting ", position, " (ADL V-A)"),
      paste(sort(unique(recipients$email)), collapse = ","), sep = "|")), paste0("position:", c("QB", "PK", "PN")))
    payload <- list(lineup_season = season, lineup_week = week, lineup_franchise = franchise,
      lineup_checked_at = as.numeric(checked_at),
      lineup_entries = entries, lineup_header = subject, lineup_footer = footer,
      lineup_resolved = as.list(snapshot_keys("resolved", franchise)),
      lineup_held = as.list(snapshot_keys("held", franchise)), lineup_legacy = legacy)
    preview <- paste(c(subject, vapply(entries, `[[`, character(1), "body"), footer), collapse = "\n\n")
    list(subject = subject, body = preview, to = recipients$email, payload = payload, has_alerts = nrow(rows) > 0L)
  })
  errors <- vapply(messages, function(message) message$error %||% "", character(1))
  if (any(nzchar(errors))) return(failure(paste(unique(errors[nzchar(errors)]), collapse = ",")))
  statuses <- lapply(messages, function(message) send_alert_mail(message$subject, message$body,
    to = message$to, cc = character(), lineup_payload = message$payload))
  ok <- all(vapply(statuses, function(status) isTRUE(status$sent), logical(1)))
  tibble(sent = ok, reason = if (ok) "sent_gm_only" else "gm_email_failed", outbox_path = "",
    gm_emails_sent = sum(vapply(messages, `[[`, logical(1), "has_alerts")))
}
