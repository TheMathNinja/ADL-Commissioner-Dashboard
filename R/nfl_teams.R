# Internal NFL identity is always MFL; translate only at named provider boundaries.
.mfl_team_contract <- jsonlite::fromJSON("config/nfl_teams.json")
mfl_team_codes <- function() .mfl_team_contract$teams
mfl_player_team <- function(team, strict = FALSE) {
  result <- toupper(trimws(as.character(team)))
  aliases <- unlist(.mfl_team_contract$aliases, use.names = TRUE)
  found <- !is.na(result) & result %in% names(aliases)
  result[found] <- unname(aliases[result[found]])
  if (strict && any(!is.na(result) & !result %in% c(mfl_team_codes(), .mfl_team_contract$sentinels))) {
    stop("Unknown NFL team code: ", paste(unique(result[!is.na(result) & !result %in%
      c(mfl_team_codes(), .mfl_team_contract$sentinels)]), collapse = ", "), call. = FALSE)
  }
  result
}
mfl_team_to_provider <- function(team, provider) {
  if (!provider %in% names(.mfl_team_contract$providers)) stop("Unknown NFL team provider: ", provider)
  result <- mfl_player_team(team, strict = TRUE)
  aliases <- unlist(.mfl_team_contract$providers[[provider]], use.names = TRUE)
  found <- !is.na(result) & result %in% names(aliases)
  result[found] <- unname(aliases[result[found]])
  result
}
