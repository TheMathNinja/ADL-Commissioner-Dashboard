source("R/commissioner_alerts.R")
contract <- .mfl_team_contract
stopifnot(length(mfl_team_codes()) == 32L, all(nchar(mfl_team_codes()) == 3L))
for (provider in names(contract$providers)) {
  stopifnot(identical(mfl_player_team(mfl_team_to_provider(mfl_team_codes(), provider)), mfl_team_codes()))
}
stopifnot(identical(mfl_player_team(c(" lv ", "GB", "JAX", "WSH", NA, "FA")),
                    c("LVR", "GBP", "JAC", "WAS", NA, "FA")))
stopifnot(inherits(try(mfl_player_team("XYZ", strict = TRUE), silent = TRUE), "try-error"))

# Replay HOU's healthy first-string kicker with provider-coded schedule evidence.
now <- as.POSIXct("2026-11-18 20:00:00", tz = "UTC")
roster <- tibble(conference="AFC", franchise="HOU", franchise_name="Houston Texans",
  player_id=c("14244","17222"), player_name=c("Matt Gay","Tyler Loop"),
  player_team=c("LVR","BAL"), player_pos="PK", roster_status=c("Active","INJURED_RESERVE"), player_status="")
roles <- tibble(player_id=roster$player_id, player_team=roster$player_team, player_pos="PK", depth_rank=1L, source="verified fixture")
lineup <- tibble(franchise=character(), player_pos=character(), player_id=character())
schedule <- tibble(player_team=c("LV","BAL"), kickoff_at=now+4*86400)
check <- function(r=roster, k=schedule) evaluate_roster_readiness(r,lineup,roles,k,c(LVR=13,BAL=13),11,now)
result <- check()
stopifnot(!nrow(result) || !any(grepl("starting PK",result$rule)))
injured <- roster; injured$player_status[1] <- "OUT"
stopifnot(any(grepl("starting PK",check(injured)$rule)))
missing <- suppressWarnings(check(k=schedule[2,,drop=FALSE]))
stopifnot(!nrow(missing) || !any(grepl("starting PK",missing$rule)),
          any(attr(missing,"held")$key == "position:PK"))
stopifnot(franchise_code_from_name("Jacksonville Jaguars") == "JAC")
source("R/nfl_realism.R")
history <- data.frame(season=2026L, week=11L, team=c("LVR","DEN"), game_type="REG",
  gsis_id=c("a","b"), full_name=c("Player A","Player B"), birth_date="2000-01-01",
  position="PK", depth_chart_position="K", status="ACT", status_description_abbr="A", adl_position="PK")
games <- data.frame(season=2026L, week=11L, home_team="DEN", away_team="LV", game_type="REG", result=1)
normalized <- summarize_nfl_realism(history,games,seasons=2026L)
stopifnot(setequal(normalized$players$team,c("LVR","DEN")),nrow(normalized$players)==2L)
message("PASS: 32-team provider round trips; HOU false warning fixed; true OUT retained; missing schedule held.")
