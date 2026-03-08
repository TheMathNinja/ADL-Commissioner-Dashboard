# saladj_helpers.R
# ----------------
# Helper functions for SalAdjCurator and dashboard generation.

source("R/config_helpers.R")

get_placeholder_saladj_summary <- function() {
  current_season <- get_current_season()
  
  tibble::tibble(
    season = current_season,
    players_adjusted = 0,
    total_adjustments = 0
  )
}