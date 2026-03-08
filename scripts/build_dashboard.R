# build_dashboard.R
# -----------------
# This script builds the dashboard website files.

library(tidyverse)

source("R/config_helpers.R")
source("R/dashboard_helpers.R")

current_season <- get_current_season()

# Read metadata
run_meta <- readr::read_csv("data/run_metadata.csv", show_col_types = FALSE)

# Make sure docs directory exists
dir.create("docs", recursive = TRUE, showWarnings = FALSE)

# Find archived CSVs for current season only
archive_files <- list.files(
  path = file.path("data", "archive"),
  pattern = paste0("^saladj_summary_", current_season, "_.*\\.csv$"),
  full.names = TRUE
)

archive_files <- sort(archive_files, decreasing = TRUE)

# Build landing page
index_html <- build_dashboard_index_html()
writeLines(index_html, file.path("docs", "index.html"))

# Build SalAdjCurator page
saladj_html <- build_saladjcurator_html(
  run_meta = run_meta,
  archive_files = archive_files
)

writeLines(saladj_html, file.path("docs", "saladjcurator.html"))

message("Dashboard build complete for season: ", current_season)