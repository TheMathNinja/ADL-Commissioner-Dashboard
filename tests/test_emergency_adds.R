source("R/inseason_inactivity_monitor.R")
valid_schedule <- data.frame(season = 2026, week = 9, game_type = "REG",
  home_team = "PIT", away_team = "BAL", gameday = "2026-11-08", gametime = "13:00")
reads <- 0L; clears <- 0L
recovered <- suppressWarnings(load_verified_nfl_schedule(2026, loader = function(...) {
  reads <<- reads + 1L
  if (reads == 1L) return(data.frame(roof = character()))
  if (reads == 2L) stop("temporary network failure")
  valid_schedule
}, clear = function() clears <<- clears + 1L, sleep = function(...) NULL))
stopifnot(identical(recovered, valid_schedule), reads == 3L, clears == 2L)
for (bad in list(data.frame(), transform(valid_schedule, season = 2025),
                 transform(valid_schedule, gametime = NA_character_))) {
  reads <- 0L
  failed <- tryCatch(suppressWarnings(load_verified_nfl_schedule(2026,
    loader = function(...) { reads <<- reads + 1L; bad },
    clear = function() NULL, sleep = function(...) NULL)), error = identity)
  stopifnot(inherits(failed, "error"), reads == 4L)
}
add_time <- as.POSIXct("2026-11-01 14:22:25", tz = "UTC")
adds <- tibble(conference = "AFC", franchise = "HOU", franchise_name = "Houston Texans",
               player_id = "13848", player_name = "Johnston, Cam", occurred_at = add_time)
pool <- tibble(player_id = "13848", player_name = "Johnston, Cam", player_team = "PIT", player_pos = "PN")
roster <- bind_cols(adds |> select(franchise, player_id), tibble(prev_salary = 2.10, prev_years = 1, contract = "2026 UFA"))
posts <- tibble(franchise = "HOU", declared_at = add_time + 103, body = "I emergency added the PIT punter since my Tommy is out today", source_url = "https://example.test/post")
kickoffs <- tibble(player_team = "PIT", kickoff_at = as.POSIXct("2026-11-01 18:00:00", tz = "UTC"))
tx <- tibble(conference = "AFC", player_id = "13848", occurred_at = add_time - 86400, type = "AUCTION_WON")
check <- function(p = posts, r = roster, a = adds, k = kickoffs, players = pool, history = tx) assess_emergency_adds(a, p, players, r, k, 2026, history)
stopifnot(length(check()$accepted) == 1L, nrow(check()$contracts) == 0L)
bad <- roster; bad$prev_salary <- 2.01
result <- check(r = bad)
stopifnot(length(result$accepted) == 1L, nrow(result$contracts) == 1L,
          result$contracts$commissioner_only, grepl("2.10 / 1 year / 2026 UFA", result$contracts$details, fixed = TRUE),
          is_commissioner_only_alert(result$contracts))
bad <- roster; bad$prev_years <- 2
stopifnot(nrow(check(r = bad)$contracts) == 1L)
bad <- roster; bad$contract <- "2026 SD"
stopifnot(nrow(check(r = bad)$contracts) == 1L)
wrong <- posts; wrong$franchise <- "CHI"
stopifnot(!length(check(p = wrong)$accepted))
wrong <- posts; wrong$body <- "I emergency added the PIT punter"
stopifnot(!length(check(p = wrong)$accepted))
wrong <- posts; wrong$body <- "This was not an emergency add of the PIT punter, he was out"
stopifnot(!length(check(p = wrong)$accepted))
wrong <- posts; wrong$declared_at <- kickoffs$kickoff_at + 1
stopifnot(!length(check(p = wrong)$accepted))
wrong <- kickoffs; wrong$kickoff_at <- add_time + 86401
stopifnot(!length(check(k = wrong)$accepted))
wrong <- kickoffs; wrong$kickoff_at <- add_time
stopifnot(!length(check(k = wrong)$accepted))
wrong <- tx; wrong$type <- "AUCTION_INIT"
stopifnot(!length(check(history = wrong)$accepted))
wrong$conference <- "NFC"
stopifnot(length(check(history = wrong)$accepted) == 1L)
ambiguous <- bind_rows(pool, mutate(pool, player_id = "other", player_name = "Other, Player"))
stopifnot(!length(check(players = ambiguous)$accepted))
named <- posts; named$body <- "Emergency add Cam Johnston because Tommy is out"
stopifnot(length(check(p = named)$accepted) == 1L)
html <- '<div class="frm pst"><div class="poster"><a>Houston Texans</a></div><table><tr><td class="message">Date Sun Nov 1 9:24:08 a.m. ET 2026</td></tr><tr><td class="message">I emergency added the PIT punter since my Tommy is out today</td></tr></table></div>'
parsed <- parse_emergency_add_posts(xml2::read_html(html), adds |> select(franchise, franchise_name), "https://example.test/post")
stopifnot(nrow(parsed) == 1L, parsed$franchise == "HOU", as.numeric(parsed$declared_at) == as.numeric(add_time + 103))
issued <- tibble(violation_key = c("illegal_waiver_claim|2026|HOU|13848|2026-11-01", "illegal_waiver_claim|2026|CHI|13848|2026-11-01"))
corrected <- reconcile_emergency_add_violations(issued, check()$accepted, 2026, add_time + 86400)
stopifnot(!is.na(corrected$rescinded_at[[1]]), is.na(corrected$rescinded_at[[2]]), nrow(corrected) == nrow(issued),
          identical(corrected, reconcile_emergency_add_violations(corrected, check()$accepted, 2026, add_time + 90000)))
franchise_lookup_table <- function(...) adds |> select(conference, franchise, franchise_name)
fetch_inseason_transactions <- function(...) tibble(franchise_id = "0025", player_id = "13848", player_name = "Johnston, Cam",
                                                   timestamp = add_time, type = "FREE_AGENT", type_desc = "added")
accepted_keys <- check(r = transform(roster, prev_salary = 2.01))$accepted
emergency_add_context <- function(...) list(accepted = accepted_keys)
stopifnot(nrow(evaluate_illegal_waiver_claims(2026, TRUE, add_time + 3600)) == 0L)
accepted_keys <- character()
stopifnot(nrow(evaluate_illegal_waiver_claims(2026, TRUE, add_time + 3600)) == 1L)
cat("Emergency declaration, unique identity, kickoff, auction and commissioner-only contract checks passed\n")
