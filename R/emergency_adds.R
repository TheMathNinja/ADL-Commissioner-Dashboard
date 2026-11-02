# Emergency acquisition permission and commissioner contract entry are separate checks.
emergency_add_key <- function(franchise, player_id, occurred_at) {
  paste(franchise, player_id, as.numeric(occurred_at), sep = "|")
}

parse_emergency_add_posts <- function(doc, franchises, url) {
  nodes <- rvest::html_elements(doc, ".frm.pst")
  if (!length(nodes)) stop("Cannot verify emergency adds: no message-board posts were parsed.", call. = FALSE)
  bind_rows(lapply(nodes, function(node) {
    poster <- rvest::html_text2(rvest::html_element(node, ".poster a"))
    cells <- rvest::html_elements(node, "td.message")
    stamp <- if (length(cells)) rvest::html_text2(cells[[1]]) else ""
    body <- if (length(cells) > 1) rvest::html_text2(cells[[length(cells)]]) else ""
    team <- franchises$franchise[match(trimws(poster), trimws(franchises$franchise_name))]
    if (is.na(team)) team <- franchises$franchise[match(toupper(trimws(poster)), franchises$franchise)]
    tibble(franchise = team, declared_at = extract_lineup_submitted_at(stamp), body = body, source_url = url)
  })) |>
    filter(!is.na(.data$franchise), grepl("emergen", .data$body, ignore.case = TRUE)) |>
    distinct()
}

fetch_emergency_add_posts <- function(season, franchises) {
  url <- Sys.getenv(paste0("ADL_EMERGENCY_ADD_THREAD_URL_", season), unset = "")
  if (!nzchar(url) && season == 2026L) url <- "https://www46.myfantasyleague.com/2026/mb/topic_show.pl?bid=202660206&tid=6682235"
  if (!nzchar(url)) stop("No emergency-add message-board thread configured for ", season, call. = FALSE)
  response <- httr::RETRY("GET", url, httr::timeout(25), times = 3, quiet = TRUE)
  httr::stop_for_status(response)
  parse_emergency_add_posts(xml2::read_html(httr::content(response, as = "text", encoding = "UTF-8")), franchises, url)
}

emergency_add_player_match <- function(body, player, pool) {
  words <- function(x) trimws(gsub("[^a-z0-9]+", " ", tolower(x)))
  contains <- function(x) nzchar(x) && grepl(paste0("\\b", x, "\\b"), words(body))
  parts <- trimws(strsplit(player$player_name, ",", fixed = TRUE)[[1]])
  names <- if (length(parts) == 2L) c(parts[[1]], strsplit(parts[[2]], "\\s+")[[1]][[1]]) else parts
  if (length(names) == 2L && (contains(words(paste(rev(names), collapse = " "))) || contains(words(paste(names, collapse = " "))))) return(TRUE)
  for (name in names) {
    token <- words(name)
    matching <- vapply(pool$player_name, function(p) grepl(paste0("\\b", token, "\\b"), words(p)), logical(1))
    if (contains(token) && sum(matching) == 1L) return(TRUE)
  }
  # Descriptions such as "the PIT punter" are valid only for a unique player.
  positions <- list(QB = "quarterback", RB = "running back", WR = "wide receiver", TE = "tight end", PK = "kicker", PN = "punter", DT = "defensive tackle", DE = "defensive end", LB = "linebacker", CB = "cornerback", S = "safety")
  pos <- player$player_pos[[1]]; team <- player$player_team[[1]]
  same <- pool$player_team == team & pool$player_pos == pos
  isTRUE(sum(same, na.rm = TRUE) == 1L) && contains(words(team)) &&
    (contains(words(pos)) || contains(positions[[pos]] %||% ""))
}

assess_emergency_adds <- function(adds, posts, pool, rosters, kickoffs, season, transactions) {
  accepted <- character(); contracts <- list()
  if (!nrow(adds)) return(list(accepted = accepted, contracts = tibble()))
  salary <- round_up_to_tenth(adl_sd_minimum(season))
  for (i in seq_len(nrow(adds))) {
    add <- adds[i, ]; player <- pool[pool$player_id == add$player_id, ]
    if (nrow(player) != 1L) next
    game <- kickoffs[kickoffs$player_team == player$player_team & kickoffs$kickoff_at > add$occurred_at &
                       kickoffs$kickoff_at <= add$occurred_at + lubridate::hours(24), ]
    if (nrow(game) != 1L) next
    relevant <- posts[!is.na(posts$declared_at) & posts$franchise == add$franchise &
                        posts$declared_at >= add$occurred_at - lubridate::hours(24) &
                        posts$declared_at <= game$kickoff_at[[1]], ]
    relevant <- relevant[vapply(relevant$body, function(body) {
      grepl("\\bemergency\\s+(add|added|adding|pickup|acquisition)\\b|\\b(add|added|adding)\\b.{0,30}\\bemergency\\b", body, ignore.case = TRUE) &&
        !grepl("\\b(not|no)\\s+(an?\\s+)?emergency\\b", body, ignore.case = TRUE) &&
        grepl("\\b(out|injured|injury|inactive|bye|need|unable|cannot|can't|no)\\b", tolower(body)) &&
        emergency_add_player_match(body, player, pool)
    }, logical(1)), ]
    if (!nrow(relevant)) next
    auction <- transactions[transactions$conference == add$conference & transactions$player_id == add$player_id & transactions$occurred_at <= add$occurred_at &
                              transactions$type %in% c("AUCTION_INIT", "AUCTION_WON"), ]
    auction <- auction[order(auction$occurred_at, decreasing = TRUE), ]
    if (nrow(auction) && auction$type[[1]] == "AUCTION_INIT") next
    accepted <- c(accepted, emergency_add_key(add$franchise, add$player_id, add$occurred_at))
    current <- rosters[rosters$franchise == add$franchise & rosters$player_id == add$player_id, ]
    if (nrow(current) != 1L) next # A later trade/drop is not evidence of a bad original contract.
    correct <- isTRUE(abs(current$prev_salary[[1]] - salary) < 0.0001) &&
      isTRUE(current$prev_years[[1]] == 1) && identical(toupper(trimws(current$contract[[1]])), paste(season, "UFA"))
    if (correct) next
    contracts[[length(contracts) + 1L]] <- tibble(
      alert_type = "Emergency Add Contract", severity = "warning", commissioner_only = TRUE,
      conference = add$conference, franchise = add$franchise, franchise_name = add$franchise_name,
      rule = "Verify emergency-add contract in MFL",
      observed = paste0(add$player_name, " | MFL contract: $", sprintf("%.2f", current$prev_salary[[1]]),
                        " / ", current$prev_years[[1]], " year / ", current$contract[[1]]),
      details = paste0("Emergency add declared ", format(relevant$declared_at[[1]], "%b %d, %Y %I:%M %p %Z"),
                       ". Required: Set the MFL contract to $", sprintf("%.2f", salary), " / 1 year / ", season,
                       " UFA. Declaration: ", relevant$source_url[[1]], ". This is a commissioner contract-entry check, not an owner inactivity violation.")
    )
  }
  list(accepted = unique(accepted), contracts = bind_rows(contracts))
}

.emergency_add_cache <- new.env(parent = emptyenv())

reconcile_emergency_add_violations <- function(issued, accepted, season, checked_at) {
  if (!nrow(issued) || !length(accepted)) return(issued)
  keys <- vapply(strsplit(accepted, "|", fixed = TRUE), function(parts) {
    date <- as.Date(as.POSIXct(as.numeric(parts[[3]]), origin = "1970-01-01", tz = "UTC"))
    paste("illegal_waiver_claim", season, parts[[1]], parts[[2]], date, sep = "|")
  }, character(1))
  if (!"rescinded_at" %in% names(issued)) issued$rescinded_at <- NA_character_
  if (!"rescission_reason" %in% names(issued)) issued$rescission_reason <- NA_character_
  corrected <- issued$violation_key %in% keys & (is.na(issued$rescinded_at) | !nzchar(issued$rescinded_at))
  issued$rescinded_at[corrected] <- format(checked_at, "%Y-%m-%d %H:%M:%S %Z")
  issued$rescission_reason[corrected] <- "Emergency-add declaration and acquisition window verified; any contract-entry issue is tracked separately for commissioners."
  issued
}

emergency_add_context <- function(season, run_time, rosters = NULL) {
  key <- paste(season, as.numeric(run_time))
  if (exists(key, .emergency_add_cache, inherits = FALSE)) return(get(key, .emergency_add_cache))
  if (is.null(rosters)) rosters <- load_current_rosters(force_live = TRUE, source = "live", season = season)
  franchises <- distinct(rosters, .data$conference, .data$franchise, .data$franchise_name)
  raw <- fetch_inseason_transactions(season)
  tx <- normalize_inseason_transactions(raw, franchises)
  adds <- tx |> filter(.data$type_desc %in% c("added", "claimed"), .data$occurred_at <= run_time,
                      .data$occurred_at >= run_time - lubridate::days(7))
  result <- list(accepted = character(), contracts = tibble())
  if (nrow(adds)) {
    pool <- bind_rows(
      rosters |> select(player_id, player_name, player_team, player_pos),
      raw |> transmute(player_id = as.character(.data$player_id), player_name = .data$player_name,
                       player_team = .data$team, player_pos = .data$pos)
    ) |> distinct()
    games <- nflreadr::load_schedules(seasons = season)
    game_type <- nfl_schedule_type_col(games)
    if (is.na(game_type)) stop("Cannot verify emergency-add kickoff windows: NFL schedule has no season type.", call. = FALSE)
    games <- games |> filter(.data[[game_type]] == "REG", .data$week %in% 1:18) |>
      mutate(kickoff_at = nfl_game_kickoff_at(dplyr::pick(dplyr::everything())))
    kickoffs <- bind_rows(
      games |> transmute(player_team = mfl_player_team(.data$home_team), kickoff_at),
      games |> transmute(player_team = mfl_player_team(.data$away_team), kickoff_at)
    ) |> filter(!is.na(.data$kickoff_at)) |> distinct()
    result <- assess_emergency_adds(adds, fetch_emergency_add_posts(season, franchises), pool, rosters, kickoffs, season, tx)
  }
  assign(key, result, .emergency_add_cache)
  result
}
