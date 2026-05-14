# mfl_helpers.R
# -------------
# MFL connection helpers for local runs and GitHub Actions.

library(ffscrapr)

get_env_or_default <- function(name, default = "") {
  value <- Sys.getenv(name, unset = default)
  if (is.na(value) || !nzchar(value)) default else value
}

connect_adl_mfl <- function(season = get_current_season()) {
  league_id <- as.integer(get_env_or_default("ADL_LEAGUE_ID", "60206"))
  if (is.na(league_id)) {
    stop("ADL_LEAGUE_ID must be numeric when provided.")
  }
  
  user_name <- get_env_or_default("MFL_USERNAME")
  password <- get_env_or_default("MFL_PASSWORD")
  user_agent <- get_env_or_default("MFL_USER_AGENT", "ADLCommissionerDashboard")
  
  args <- list(
    season = season,
    league_id = league_id,
    user_agent = user_agent,
    rate_limit_number = 3,
    rate_limit_seconds = 6
  )
  
  if (nzchar(user_name)) args$user_name <- user_name
  if (nzchar(password)) args$password <- password
  
  do.call(ffscrapr::mfl_connect, args)
}
