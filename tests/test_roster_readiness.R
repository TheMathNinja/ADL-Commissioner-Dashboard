source("R/commissioner_alerts.R")
now <- as.POSIXct("2026-11-11 10:25:00", tz = "UTC")
rosters <- tibble(conference = "NFC", franchise = "MIN", franchise_name = "Minnesota Vikings",
  player_id = c("16152", "15694", "k", "p"), player_name = c("Anthony Richardson", "Malik Willis", "Kicker", "Punter"),
  player_team = c("IND", "MIA", "IND", "IND"), player_pos = c("QB", "QB", "PK", "PN"),
  roster_status = "Active", player_status = c("", "IR", "", ""))
roles <- tibble(player_id = c("16152", "15694", "17038", "k", "p"),
  depth_rank = c(2L, 1L, 1L, 1L, 1L), source = "https://www.espn.com")
lineups <- rosters |> filter(player_id != "15694")
kickoffs <- tibble(player_team = c("IND", "MIA"), kickoff_at = now + 4 * 86400)
check <- function(roster = rosters, selected = lineups, depth = roles, schedule = kickoffs, byes = c(IND = 7, MIA = 8), when = now) {
  evaluate_roster_readiness(roster, selected, depth, schedule, byes, 10, when)
}
warning <- check()
stopifnot(nrow(warning) == 1L, warning$severity == "warning",
  grepl("starting QB", warning$observed), grepl("acquire", warning$details),
  grepl("Anthony Richardson", warning$details), grepl("Malik Willis", warning$details),
  nrow(commissioner_digest_alerts(warning)) == 0L,
  nrow(filter_lineup_email_days(warning, now)) == 1L)
# Not every backup is inactive; a starter injury may change the expected role.
promoted <- roles; promoted$depth_rank[1] <- 1L
stopifnot(nrow(check(depth = promoted)) == 0L)
uncertain <- roles |> filter(player_id != "16152")
stopifnot(nrow(check(depth = uncertain)) == 0L)
stopifnot(nrow(check(schedule = mutate(kickoffs, kickoff_at = now - 1))) == 0L)
replacement <- rosters[2, ]; replacement$player_id <- "17038"; replacement$player_status <- ""
replacement$player_name <- "Kyle McCord"
with_starter <- bind_rows(rosters, replacement)
stopifnot(nrow(check(roster = with_starter)) == 0L)
needed <- check(roster = with_starter, when = now + 86400)
stopifnot(nrow(needed) == 1L, grepl("starting Kyle McCord", needed$details))
stopifnot(nrow(check(with_starter, bind_rows(lineups |> filter(player_pos != "QB"), replacement))) == 0L)
stopifnot(nrow(check(roster = rosters |> filter(player_pos != "PN"))) == 2L)
stopifnot(identical(readiness_team(c("LV", "WSH", "JAX")), c("LVR", "WAS", "JAC")))

# Structured charts use stable IDs, require current season/freshness and mapped starters.
chart <- list(status = "success", season = list(year = 2026), timestamp = "2026-11-11T10:00:00Z",
  team = list(abbreviation = "IND"), depthchart = list(list(positions = list(
    qb = list(athletes = list(list(id = "q"), list(id = "backup"))),
    pk = list(athletes = list(list(id = "k"))), p = list(athletes = list(list(id = "p")))))))
ids <- tibble(player_team = "IND", espn_id = c("q", "backup", "k", "p"),
  player_id = c("QB1", "16152", "k", "p"), player_pos = c("QB", "QB", "PK", "PN"))
mapped <- parse_readiness_depth_chart(chart, ids, 2026, "IND", now)
stopifnot(mapped$depth_rank[mapped$player_id == "16152"] == 2L)
injured_primary <- rosters[1, ]; injured_primary$franchise <- "NOS"
injured_primary$player_id <- "QB1"; injured_primary$player_status <- "Out"
effective_roles <- bind_rows(mapped |> mutate(source = "https://www.espn.com"),
  tibble(player_id = "15694", player_pos = "QB", player_team = "MIA", depth_rank = 1L, source = "https://www.espn.com"))
stopifnot(nrow(check(roster = bind_rows(rosters, injured_primary), depth = effective_roles) |> filter(franchise == "MIN")) == 0L)
fails <- function(expr) inherits(tryCatch(force(expr), error = identity), "error")
stale <- chart; stale$timestamp <- "2026-11-08T10:00:00Z"
stopifnot(fails(parse_readiness_depth_chart(stale, ids, 2026, "IND", now)),
  fails(parse_readiness_depth_chart(chart, ids, 2025, "IND", now)),
  fails(parse_readiness_depth_chart(chart, ids |> filter(espn_id != "q"), 2026, "IND", now)))

# Use the existing durable receipt bridge; no new mailer or commissioner CC.
fetch_mfl_franchise_recipients <- function(...) tibble(franchise = "MIN", franchise_id = "0008", email = "min@example.test")
sent <- list()
send_alert_mail <- function(subject, body, to, cc, delivery_key) {
  sent[[length(sent) + 1L]] <<- list(key = delivery_key, body = body, cc = cc, to = to)
  list(sent = TRUE)
}
send_roster_readiness_email(warning, 2026, 10, now)
send_roster_readiness_email(warning, 2026, 10, now + 86400)
stopifnot(identical(sent[[1]]$key, sent[[2]]$key), length(sent[[1]]$cc) == 0L,
  grepl("F=0008", sent[[1]]$body, fixed = TRUE))
# Preserve existing message hashes when no explicit issue key is supplied.
transport <- new.env(parent = globalenv())
transport$system2 <- function(command, args) {
  path <- gsub('^"|"$', "", args[[3]])
  transport$payload <- jsonlite::fromJSON(path)
  0L
}
sys.source("R/alert_transport.R", envir = transport)
transport$deliver_alert("test", "body", "min@example.test")
stopifnot(!"delivery_key" %in% names(transport$payload))
transport$deliver_alert("test", "body", "min@example.test", delivery_key = sent[[1]]$key)
stopifnot(identical(transport$payload$delivery_key, sent[[1]]$key))
cat("Roster readiness, early-week routing, identity, unknown evidence and stable delivery-key regressions passed.\n")
