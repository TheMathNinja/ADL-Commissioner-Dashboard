# saladj_helpers.R
# ----------------
# Helper functions for SalAdjCurator and dashboard generation.

get_placeholder_saladj_summary <- function() {
  tibble::tibble(
    season = 2025,
    players_adjusted = 0,
    total_adjustments = 0
  )
}