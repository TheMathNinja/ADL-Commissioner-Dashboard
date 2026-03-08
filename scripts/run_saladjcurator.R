# run_saladjcurator.R
# -------------------
# This script runs the SalAdjCurator automation
# and writes the outputs used by the dashboard.

library(tidyverse)

source("R/saladj_helpers.R")

# -------------------
# Directories
# -------------------

# Raw cache directory:
# - On GitHub Actions, this comes from the workflow env var
# - Locally, it defaults to cache/raw_league_data
raw_cache_dir <- Sys.getenv("RAW_CACHE_DIR", unset = "cache/raw_league_data")

dir.create(raw_cache_dir, recursive = TRUE, showWarnings = FALSE)
dir.create("data", recursive = TRUE, showWarnings = FALSE)

message("Using raw cache dir: ", raw_cache_dir)

# -------------------
# Placeholder output
# -------------------

# For now, use placeholder data from helper function
saladj_summary <- get_placeholder_saladj_summary()

# Optional example cached file so the cache folder is actually used
placeholder_cache_file <- file.path(raw_cache_dir, "placeholder_saladj_summary.rds")
saveRDS(saladj_summary, placeholder_cache_file)

# -------------------
# Save dashboard output
# -------------------

readr::write_csv(saladj_summary, "data/saladj_summary.csv")

message("SalAdjCurator script ran successfully")