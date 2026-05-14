# build_dashboard.R
# -----------------
# This script builds the dashboard website files.

source("R/config_helpers.R")
source("R/dashboard_helpers.R")

current_season <- get_current_season()

# Read metadata
run_meta <- readr::read_csv("data/run_metadata.csv", show_col_types = FALSE)

# Make sure docs directories exist
dir.create("docs", recursive = TRUE, showWarnings = FALSE)
dir.create(file.path("docs", "downloads"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path("docs", "downloads", "daily-salary-snapshots"), recursive = TRUE, showWarnings = FALSE)
unlink(file.path("docs", "downloads", "daily-salary-snapshots", "*.csv"))

# Find archived CSVs for current season only
archive_files_data <- list.files(
  path = file.path("data", "archive"),
  pattern = paste0("^", current_season, "_\\d{2}_\\d{2}_ADLSalAdjCurator\\.csv$"),
  full.names = TRUE
)

archive_files_data <- sort(archive_files_data, decreasing = TRUE)

# Copy archived CSVs into docs/downloads so GitHub Pages can serve them
archive_filenames <- basename(archive_files_data)

if (length(archive_files_data) > 0) {
  invisible(file.copy(
    from = archive_files_data,
    to = file.path("docs", "downloads", archive_filenames),
    overwrite = TRUE
  ))
}

# Public links for HTML
archive_files_public <- file.path("downloads", archive_filenames)

# Publish daily salary snapshots from the SalAdj roster snapshot history.
snapshot_files_data <- list.files(
  path = file.path("data", "roster_snapshots"),
  pattern = paste0("^saladj_roster_snapshot_", current_season, "_[0-9]{8}_[0-9]{6}\\.csv$"),
  full.names = TRUE
)

snapshot_files_data <- sort(snapshot_files_data, decreasing = TRUE)
snapshot_filenames <- sub(
  paste0("^saladj_roster_snapshot_", current_season, "_([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{6})\\.csv$"),
  "\\1_\\2_\\3_\\4_ADLDailySalarySnapshot.csv",
  basename(snapshot_files_data)
)

latest_snapshot_data <- file.path(
  "data",
  "roster_snapshots",
  paste0("saladj_roster_snapshot_", current_season, "_latest.csv")
)
latest_snapshot_filename <- paste0(current_season, "_latest_ADLDailySalarySnapshot.csv")

if (length(snapshot_files_data) > 0) {
  invisible(file.copy(
    from = snapshot_files_data,
    to = file.path("docs", "downloads", "daily-salary-snapshots", snapshot_filenames),
    overwrite = TRUE
  ))
}

if (file.exists(latest_snapshot_data)) {
  invisible(file.copy(
    from = latest_snapshot_data,
    to = file.path("docs", "downloads", "daily-salary-snapshots", latest_snapshot_filename),
    overwrite = TRUE
  ))
}

snapshot_files_public <- file.path("downloads", "daily-salary-snapshots", snapshot_filenames)
latest_snapshot_public <- if (file.exists(latest_snapshot_data)) {
  file.path("downloads", "daily-salary-snapshots", latest_snapshot_filename)
} else {
  NA_character_
}

# Build landing page
index_html <- build_dashboard_index_html(
  latest_daily_salary_snapshot_public = latest_snapshot_public
)
writeLines(index_html, file.path("docs", "index.html"))

# Build SalAdjCurator page
saladj_html <- build_saladjcurator_html(
  run_meta = run_meta,
  archive_files_public = archive_files_public
)

writeLines(saladj_html, file.path("docs", "saladjcurator.html"))

# Build daily salary snapshots page
daily_salary_snapshots_html <- build_daily_salary_snapshots_html(
  snapshot_files_public = snapshot_files_public,
  latest_snapshot_public = latest_snapshot_public
)

writeLines(daily_salary_snapshots_html, file.path("docs", "daily-salary-snapshots.html"))

message("Dashboard build complete for season: ", current_season)
