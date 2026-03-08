# config_helpers.R
# ----------------
# Central config helpers for the dashboard project.

get_current_season <- function() {
  as.integer(Sys.getenv("CURRENT_SEASON", unset = "2026"))
}