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

run_time_toronto <- as.POSIXct(
  format(Sys.time(), tz = "America/Toronto", usetz = TRUE),
  tz = "America/Toronto"
)

run_date_file <- format(run_time_toronto, "%Y_%m_%d")
run_time_display <- format(run_time_toronto, "%m/%d/%Y %I:%M %p %Z")

# Make display friendlier:
# 03/08/2026 06:17 AM EDT -> 3/8/2026 6:17 a.m. EDT
run_time_display <- gsub("^0", "", run_time_display)
run_time_display <- gsub("/0", "/", run_time_display)
run_time_display <- gsub(" 0", " ", run_time_display)
run_time_display <- gsub(" AM ", " a.m. ", run_time_display)
run_time_display <- gsub(" PM ", " p.m. ", run_time_display)

archive_filename <- paste0(run_date_file, "_ADLSalAdjSummary.csv")

# -------------------
# Directories
# -------------------

raw_cache_dir <- get_raw_cache_dir()
dir.create("data", recursive = TRUE, showWarnings = FALSE)
dir.create(file.path("data", "archive"), recursive = TRUE, showWarnings = FALSE)

message("Running SalAdjCurator for season: ", current_season)
message("Using raw cache dir: ", raw_cache_dir)

# -------------------
# Build data
# -------------------

saladj_summary <- read_or_build_rds(
  filename = paste0("saladj_summary_", current_season, ".rds"),
  builder_fun = function() {
    get_placeholder_saladj_summary()
  }
)

# -------------------
# Write current CSV
# -------------------

readr::write_csv(saladj_summary, "data/saladj_summary.csv")

# -------------------
# Write archived CSV
# -------------------

archive_file <- file.path("data", "archive", archive_filename)
readr::write_csv(saladj_summary, archive_file)

# -------------------
# Write metadata
# -------------------

run_meta <- tibble::tibble(
  season = current_season,
  run_time_display = run_time_display,
  latest_csv_data_path = "data/saladj_summary.csv",
  latest_archive_data_path = archive_file,
  latest_archive_filename = archive_filename
)

readr::write_csv(run_meta, "data/run_metadata.csv")

message("SalAdjCurator script ran successfully")