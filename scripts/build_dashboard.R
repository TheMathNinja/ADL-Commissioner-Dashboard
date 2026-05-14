# build_dashboard.R
# -----------------
# This script builds the dashboard website files.

library(dplyr)

source("R/config_helpers.R")
source("R/dashboard_helpers.R")

current_season <- get_current_season()

read_snapshot_csv <- function(snapshot_file) {
  readr::read_csv(
    snapshot_file,
    col_types = readr::cols(
      snapshot_time = readr::col_datetime(),
      .default = readr::col_character()
    ),
    show_col_types = FALSE
  )
}

snapshot_time_from_file <- function(snapshot_file) {
  snapshot <- read_snapshot_csv(snapshot_file)
  if ("snapshot_time" %in% names(snapshot) && nrow(snapshot) > 0 && !is.na(snapshot$snapshot_time[1])) {
    return(snapshot$snapshot_time[1])
  }

  stamp <- sub("^.*_([0-9]{8}_[0-9]{6})\\.csv$", "\\1", basename(snapshot_file))
  as.POSIXct(stamp, format = "%Y%m%d_%H%M%S", tz = "UTC")
}

build_snapshot_index <- function(snapshot_files) {
  if (length(snapshot_files) == 0) {
    return(tibble::tibble(
      snapshot_file = character(),
      snapshot_time = as.POSIXct(character()),
      snapshot_time_et = as.POSIXct(character()),
      snapshot_date_et = as.Date(character()),
      public_filename = character()
    ))
  }

  snapshot_index <- dplyr::bind_rows(lapply(snapshot_files, function(snapshot_file) {
    snapshot_time <- snapshot_time_from_file(snapshot_file)
    snapshot_time_et <- lubridate::with_tz(snapshot_time, "America/Toronto")
    tibble::tibble(
      snapshot_file = snapshot_file,
      snapshot_time = snapshot_time,
      snapshot_time_et = snapshot_time_et,
      snapshot_date_et = as.Date(snapshot_time_et),
      public_filename = paste0(
        format(snapshot_time_et, "%Y_%m_%d_%H%M%S"),
        "_ADLDailySalarySnapshot.csv"
      )
    )
  }))

  snapshot_index %>%
    dplyr::arrange(dplyr::desc(.data$snapshot_time_et)) %>%
    dplyr::group_by(.data$snapshot_date_et) %>%
    dplyr::slice(1) %>%
    dplyr::ungroup() %>%
    dplyr::arrange(dplyr::desc(.data$snapshot_time_et))
}

write_public_salary_snapshot <- function(snapshot_file, public_file, franchises) {
  snapshot <- read_snapshot_csv(snapshot_file)

  if (!"franchise_name" %in% names(snapshot)) snapshot$franchise_name <- NA_character_
  if (!"roster_status" %in% names(snapshot)) snapshot$roster_status <- NA_character_

  public_snapshot <- snapshot %>%
    dplyr::mutate(
      franchise_id = as.character(.data$franchise_id),
      snapshot_time_et = format(lubridate::with_tz(.data$snapshot_time, "America/Toronto"), "%m/%d/%Y %I:%M %p %Z")
    ) %>%
    dplyr::left_join(
      franchises %>%
        dplyr::transmute(
          franchise_id = as.character(.data$franchise_id),
          franchise_name_lookup = .data$franchise_name
        ),
      by = "franchise_id"
    ) %>%
    dplyr::mutate(
      franchise_name = dplyr::coalesce(.data$franchise_name, .data$franchise_name_lookup)
    ) %>%
    dplyr::transmute(
      SNAPSHOT_TIME_ET = .data$snapshot_time_et,
      CONF = .data$CONF,
      FRANCHISE = .data$franchise_name,
      ROSTER_STATUS = .data$roster_status,
      PLAYER_ID = .data$player_id,
      PLAYER = .data$player_name,
      SALARY = .data$roster_salary,
      YEARS = .data$roster_years,
      CONTRACT = .data$roster_contractInfo
    )

  readr::write_csv(public_snapshot, public_file, na = "")
}

# Read metadata
run_meta <- readr::read_csv("data/run_metadata.csv", show_col_types = FALSE)
franchises <- readRDS(file.path("data", paste0("adl_franchises_", current_season, ".rds")))

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
snapshot_index <- build_snapshot_index(snapshot_files_data)
snapshot_filenames <- snapshot_index$public_filename

latest_snapshot_data <- file.path(
  "data",
  "roster_snapshots",
  paste0("saladj_roster_snapshot_", current_season, "_latest.csv")
)
latest_snapshot_filename <- paste0(current_season, "_latest_ADLDailySalarySnapshot.csv")

if (nrow(snapshot_index) > 0) {
  invisible(mapply(
    write_public_salary_snapshot,
    snapshot_file = snapshot_index$snapshot_file,
    public_file = file.path("docs", "downloads", "daily-salary-snapshots", snapshot_index$public_filename),
    MoreArgs = list(franchises = franchises)
  ))
}

if (file.exists(latest_snapshot_data)) {
  write_public_salary_snapshot(
    snapshot_file = latest_snapshot_data,
    public_file = file.path("docs", "downloads", "daily-salary-snapshots", latest_snapshot_filename),
    franchises = franchises
  )
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
