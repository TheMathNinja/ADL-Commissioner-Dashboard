# run_saladjcurator.R
# -------------------
# This script runs the SalAdjCurator automation
# and writes the outputs used by the dashboard.

library(tidyverse)

source("R/cache_helpers.R")
source("R/saladj_helpers.R")

# -------------------
# Directories
# -------------------

raw_cache_dir <- get_raw_cache_dir()
dir.create("data", recursive = TRUE, showWarnings = FALSE)

message("Using raw cache dir: ", raw_cache_dir)

# -------------------
# Example cached raw object
# -------------------
# For now this is still placeholder data, but it is now using the real cache system.

saladj_summary <- read_or_build_rds(
  filename = "placeholder_saladj_summary.rds",
  builder_fun = function() {
    get_placeholder_saladj_summary()
  }
)

# -------------------
# Save dashboard output
# -------------------

readr::write_csv(saladj_summary, "data/saladj_summary.csv")

message("SalAdjCurator script ran successfully")