# run_saladjcurator.R
# -------------------
# This script will run the SalAdjCurator automation
# and write the outputs used by the dashboard.

library(tidyverse)

# Example placeholder data (we'll replace this later)
saladj_summary <- tibble(
  season = 2025,
  players_adjusted = 0,
  total_adjustments = 0
)

# Make sure data directory exists
dir.create("data", showWarnings = FALSE)

# Save output
write_csv(saladj_summary, "data/saladj_summary.csv")

print("SalAdjCurator script ran successfully")