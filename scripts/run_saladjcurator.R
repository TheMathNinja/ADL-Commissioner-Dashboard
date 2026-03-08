# run_saladjcurator.R
# -------------------
# This script runs the SalAdjCurator automation
# and writes the outputs used by the dashboard.

library(tidyverse)

source("R/config_helpers.R")
source("R/cache_helpers.R")
source("R/saladj_helpers.R")

# -------------------
# Config
# -------------------

current_season <- get_current_season()

# -------------------
# Directories
# -------------------

raw_cache_dir <- get_raw_cache_dir()
dir.create("data", recursive = TRUE, showWarnings = FALSE)

message("Running SalAdjCurator for season: ", current_season)
message("Using raw cache dir: ", raw_cache_dir)

# -------------------
# Example cached raw object
# -------------------

saladj_summary <- read_or_build_rds(
  filename = paste0("saladj_summary_", current_season, ".rds"),
  builder_fun = function() {
    get_placeholder_saladj_summary()
  }
)

# -------------------
# Save dashboard output
# -------------------

readr::write_csv(saladj_summary, "data/saladj_summary.csv")

message("SalAdjCurator script ran successfully")