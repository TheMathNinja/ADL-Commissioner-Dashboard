source("R/commissioner_alerts.R")
now <- as.POSIXct("2026-11-11 10:25:00", tz = "UTC")
rosters <- tibble(conference = "NFC", franchise = "MIN", franchise_name = "Minnesota Vikings",
  player_id = c("16152", "15694", "k", "p"), player_name = c("Anthony Richardson", "Malik Willis", "Kicker", "Punter"),
  player_team = c("IND", "MIA", "IND", "IND"), player_pos = c("QB", "QB", "PK", "PN"),
  roster_status = "Active", player_status = c("", "IR", "", ""))
roles <- tibble(player_id = c("16152", "15694", "17038", "k", "p", "QB1"),
  player_team = c("IND", "MIA", "MIA", "IND", "IND", "IND"), player_pos = c("QB","QB","QB","PK","PN","QB"),
  depth_rank = c(2L, 1L, 2L, 1L, 1L, 1L), source = "verified chart")
lineups <- rosters |> filter(player_id != "15694")
kickoffs <- tibble(player_team = c("IND", "MIA"), kickoff_at = now + 4 * 86400)
no_designations <- tibble(player_id = character(), player_status = character())
check <- function(roster = rosters, selected = lineups, depth = roles, schedule = kickoffs,
  byes = c(IND = 7, MIA = 8), when = now, submitted = "MIN", statuses = no_designations) {
  evaluate_roster_readiness(roster, selected, depth, schedule, byes, 10, when,
    submitted_franchises = submitted, current_designations = statuses)
}
warning <- check()
stopifnot(nrow(warning) == 1L, warning$severity == "warning",
  grepl("Your submitted QB, Anthony Richardson, is not a projected NFL starter. Please remedy.", warning$observed, fixed = TRUE),
  identical(warning$details, ""), nrow(commissioner_digest_alerts(warning)) == 0L,
  nrow(filter_lineup_email_days(warning, now)) == 1L)
stopifnot(nrow(check(submitted = character())) == 0L,
  nrow(check(statuses = NULL)) == 0L,
  nrow(check(depth = filter(roles, player_id != "16152"))) == 0L,
  nrow(check(schedule = filter(kickoffs, player_team != "IND"))) == 0L,
  nrow(check(schedule = mutate(kickoffs, kickoff_at = now - 1))) == 0L,
  nrow(check(byes = c(IND = 10L))) == 0L,
  nrow(check(statuses = tibble(player_id = "16152", player_status = "OUT"))) == 0L)
# Empty slots and unsubmitted carryovers are not projected-role findings.
stopifnot(nrow(check(selected = filter(lineups, player_pos != "QB"))) == 0L)
for (pos in c("PK", "PN")) {
  id <- rosters$player_id[rosters$player_pos == pos]
  depth <- mutate(roles, depth_rank = if_else(player_id == id, 2L, depth_rank))
  depth <- bind_rows(depth, tibble(player_id = paste0(pos, "1"), player_team = "IND",
    player_pos = pos, depth_rank = 1L, source = "verified chart"))
  result <- check(depth = depth)
  stopifnot(any(grepl(paste0("Your submitted ", pos), result$observed, fixed = TRUE)))
}
promoted <- filter(roles, player_id != "QB1")
stopifnot(nrow(check(depth = promoted)) == 0L)
audit <- tibble(franchise = c("MIN", "NYJ", "DAL", "PIT", "CLE"),
  submission_status = c("submitted", "not_submitted", "unknown", "submitted", "submitted"),
  submitted_at = c(rep("2026-11-11 04:00:00 EST", 3), NA, "2026-11-11 07:00:00 EST"))
stopifnot(identical(verified_role_submissions(audit, now), "MIN"))
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
send_alert_mail <- function(subject, body, to, cc, lineup_payload) {
  sent[[length(sent) + 1L]] <<- list(key = lineup_payload$lineup_legacy[["position:QB"]], body = body, cc = cc, to = to,
    payload = lineup_payload)
  list(sent = TRUE)
}
send_coordinated_lineup_email(warning, 2026, 10, now)
send_coordinated_lineup_email(warning, 2026, 10, now + 86400)
stopifnot(identical(sent[[1]]$key, sent[[2]]$key), length(sent[[1]]$cc) == 0L,
  grepl("F=0008", sent[[1]]$body, fixed = TRUE))
stopifnot(identical(unlist(sent[[1]]$payload$lineup_entries[[1]]$keys), "starter-role:QB"))
# The email and its durable delivery payload contain facts, not lineup advice.
needed <- warning
violation <- warning
violation$rule <- "Starting lineups require 7 offensive starters, including minimum 1 QB"
violation$observed <- "6 offensive starters (0 QB, 6 RB/WR/TE)"
violation$details <- "Must start 1 additional QB"
send_coordinated_lineup_email(bind_rows(violation, needed), 2026, 10, now)
preview <- sent[[3]]$body
entries <- sent[[3]]$payload$lineup_entries
stopifnot(
  grepl(violation$rule, preview, fixed = TRUE),
  grepl(violation$observed, preview, fixed = TRUE),
  grepl(needed$observed, preview, fixed = TRUE),
  grepl("Submit New Lineup:", preview, fixed = TRUE),
  !grepl("Kyle McCord|Must start|Roster evidence:", preview),
  identical(vapply(entries, `[[`, character(1), "body"),
    paste0("Rule: ", c(violation$rule, needed$rule), "\nObserved: ", c(violation$observed, needed$observed)))
)
healthy <- check(depth = promoted)
stopifnot("starter-role:QB" %in% attr(healthy, "resolved")$key)
unknown <- check(depth = promoted, submitted = character())
stopifnot(!"starter-role:QB" %in% attr(unknown, "resolved")$key)
# Preserve existing message hashes when no explicit issue key is supplied.
transport <- new.env(parent = globalenv())
transport$shQuote <- function(path) {
  transport$payload_path <- path
  base::shQuote(path, type = transport$quote_type)
}
transport$system2 <- function(command, args) {
  stopifnot(identical(args[[3]], base::shQuote(transport$payload_path, type = transport$quote_type)))
  transport$payload <- jsonlite::fromJSON(transport$payload_path)
  0L
}
sys.source("R/alert_transport.R", envir = transport)
for (quote_type in c("sh", "cmd")) {
  transport$quote_type <- quote_type
  transport$deliver_alert("test", "body", "min@example.test")
  stopifnot(!"delivery_key" %in% names(transport$payload))
  transport$deliver_alert("test", "body", "min@example.test", delivery_key = sent[[1]]$key)
  stopifnot(identical(transport$payload$delivery_key, sent[[1]]$key))
}
cat("Roster readiness, early-week routing, identity, unknown evidence and stable delivery-key regressions passed.\n")

# Ordinary missing-slot episodes still have their own independent keys.
positions <- c("QB", "RB", rep("WR", 4), "TE", "PK", rep("DT", 2), rep("DE", 3), rep("LB", 3), rep("CB", 2), rep("S", 2))
short_lineup <- tibble(franchise_id = "0008", player_id = as.character(seq_along(positions)), player_pos = positions)
structural <- lineup_starter_count_alert_rows("0008", nrow(short_lineup), short_lineup)
stopifnot(any(vapply(structural$lineup_issue_keys, function(key) "position:PN" %in% jsonlite::fromJSON(key), logical(1))))
short_lineup$franchise <- "MIN"
snapshot_rosters <- short_lineup |> mutate(player_status = "", roster_status = "Active", player_team = "IND")
repairs <- verified_lineup_repairs(short_lineup, snapshot_rosters, tibble(player_id = character(), player_status = character()), kickoffs, c(IND = 7), 10)
stopifnot(!"structure:total" %in% repairs$key, !"lineup:empty" %in% repairs$key,
  "position:WR" %in% repairs$key, "player:3" %in% repairs$key)
new_bad <- tibble(player_id = "3", player_status = "Out")
repairs <- verified_lineup_repairs(short_lineup, snapshot_rosters, new_bad, kickoffs, c(IND = 7), 10)
stopifnot(!"player:3" %in% repairs$key)
full_lineup <- bind_rows(short_lineup, tibble(franchise_id = "0008", franchise = "MIN", player_id = "punter", player_pos = "PN"))
repairs <- verified_lineup_repairs(full_lineup, snapshot_rosters, NULL, kickoffs, c(IND = 7), 10)
stopifnot(all(c("lineup:empty", "structure:total") %in% repairs$key), !"player:3" %in% repairs$key)
