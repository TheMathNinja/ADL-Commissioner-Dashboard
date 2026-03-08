# build_dashboard.R
# -----------------
# This script builds the dashboard website files.

library(tidyverse)

source("R/config_helpers.R")
source("R/dashboard_helpers.R")

current_season <- get_current_season()

# Read metadata
run_meta <- readr::read_csv("data/run_metadata.csv", show_col_types = FALSE)

# Make sure docs directories exist
dir.create("docs", recursive = TRUE, showWarnings = FALSE)
dir.create(file.path("docs", "downloads"), recursive = TRUE, showWarnings = FALSE)

# Find archived CSVs for current season only
archive_files_data <- list.files(
  path = file.path("data", "archive"),
  pattern = paste0("^", current_season, "_\\d{2}_\\d{2}_ADLSalAdjSummary\\.csv$"),
  full.names = TRUE
)

archive_files_data <- sort(archive_files_data, decreasing = TRUE)

# Copy archived CSVs into docs/downloads so GitHub Pages can serve them
archive_filenames <- basename(archive_files_data)

if (length(archive_files_data) > 0) {
  file.copy(
    from = archive_files_data,
    to = file.path("docs", "downloads", archive_filenames),
    overwrite = TRUE
  )
}

# Public links for HTML
archive_files_public <- file.path("downloads", archive_filenames)

# Build landing page
index_html <- build_dashboard_index_html()
writeLines(index_html, file.path("docs", "index.html"))

# Build SalAdjCurator page
saladj_html <- build_saladjcurator_html(
  run_meta = run_meta,
  archive_files_public = archive_files_public
)

writeLines(saladj_html, file.path("docs", "saladjcurator.html"))

message("Dashboard build complete for season: ", current_season)