# mfl_helpers.R
# -------------
# MFL connection helpers for local runs and GitHub Actions.

library(ffscrapr)

if (!exists(".adl_mfl_connection_cache", inherits = FALSE)) {
  .adl_mfl_connection_cache <- new.env(parent = emptyenv())
}

cached_adl_mfl_connection <- function(args, create = ffscrapr::mfl_connect, now = Sys.time) {
  key <- digest::digest(args, algo = "sha256")
  clock <- as.numeric(now())
  saved <- .adl_mfl_connection_cache[[key]]
  if (!is.null(saved) && clock >= saved$at && clock - saved$at < 1800)
    return(saved$connection)
  # Reconnecting resets ffscrapr's process-wide limiter and repeats MFL login.
  connection <- do.call(create, args)
  .adl_mfl_connection_cache[[key]] <- list(at = clock, connection = connection)
  connection
}

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
  
  cached_adl_mfl_connection(args)
}
