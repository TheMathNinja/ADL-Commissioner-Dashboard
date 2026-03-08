# run_saladjcurator.R
# -------------------
# This script runs the SalAdjCurator automation
# and writes the outputs used by the dashboard.

library(tidyverse)

source("R/saladj_helpers.R")

# Make sure data directory exists
dir.create("data", showWarnings = FALSE)

# For now, use placeholder data from helper function
saladj_summary <- get_placeholder_saladj_summary()

# Save output
readr::write_csv(saladj_summary, "data/saladj_summary.csv")

print("SalAdjCurator script ran successfully")