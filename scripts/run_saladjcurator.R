# run_saladjcurator.R
# -------------------
# Runs the SalAdjCurator automation and writes dashboard outputs.
# A dated archive CSV is created only when the actionable output changes.

library(readr)
library(tibble)

source("R/config_helpers.R")
source("R/saladj_engine.R")

current_season <- get_current_season()

format_run_time <- function(x) {
  out <- format(x, "%m/%d/%Y %I:%M %p %Z")
  out <- gsub("^0", "", out)
  out <- gsub("/0", "/", out)
  out <- gsub(" 0", " ", out)
  out <- gsub(" AM ", " a.m. ", out)
  out <- gsub(" PM ", " p.m. ", out)
  out
}

normalize_for_compare <- function(df) {
  if (is.null(df)) return(NULL)
  df <- as.data.frame(df, stringsAsFactors = FALSE)
  df[] <- lapply(df, function(x) {
    x <- as.character(x)
    x[is.na(x)] <- ""
    x
  })
  df
}

same_csv_output <- function(new_df, old_csv) {
  if (!file.exists(old_csv)) return(FALSE)
  old_df <- readr::read_csv(old_csv, col_types = readr::cols(.default = readr::col_character()), show_col_types = FALSE)
  identical(normalize_for_compare(new_df), normalize_for_compare(old_df))
}

same_df_output <- function(new_df, old_df) {
  if (is.null(old_df)) return(FALSE)
  identical(normalize_for_compare(new_df), normalize_for_compare(old_df))
}

find_latest_matching_archive <- function(new_df, archive_dir, current_season) {
  archive_files <- list.files(
    archive_dir,
    pattern = paste0("^", current_season, "_\\d{2}_\\d{2}_ADLSalAdjCurator\\.csv$"),
    full.names = TRUE
  )
  archive_files <- sort(archive_files, decreasing = TRUE)
  for (archive_path in archive_files) {
    if (same_csv_output(new_df, archive_path)) {
      return(archive_path)
    }
  }
  NA_character_
}

run_time_toronto <- as.POSIXct(
  format(Sys.time(), tz = "America/Toronto", usetz = TRUE),
  tz = "America/Toronto"
)

run_date_file <- format(run_time_toronto, "%Y_%m_%d")
run_time_display <- format_run_time(run_time_toronto)
archive_filename <- paste0(run_date_file, "_ADLSalAdjCurator.csv")

dir.create("data", recursive = TRUE, showWarnings = FALSE)
dir.create(file.path("data", "archive"), recursive = TRUE, showWarnings = FALSE)

latest_csv <- file.path("data", "SalAdjCurator_latest.csv")
archive_file <- file.path("data", "archive", archive_filename)
metadata_file <- file.path("data", "run_metadata.csv")

prior_latest_df <- if (file.exists(latest_csv)) {
  readr::read_csv(latest_csv, col_types = readr::cols(.default = readr::col_character()), show_col_types = FALSE)
} else {
  NULL
}

prior_meta <- if (file.exists(metadata_file)) {
  readr::read_csv(metadata_file, show_col_types = FALSE)
} else {
  tibble::tibble()
}

prior_archive_filename <- if ("latest_archive_filename" %in% names(prior_meta) && nrow(prior_meta) > 0) {
  as.character(prior_meta$latest_archive_filename[1])
} else {
  NA_character_
}

prior_archive_file <- if (!is.na(prior_archive_filename) && nzchar(prior_archive_filename)) {
  file.path("data", "archive", prior_archive_filename)
} else {
  NA_character_
}

message("Running SalAdjCurator for season: ", current_season)

saladj_rows <- build_saladj_curator(
  current_season = current_season,
  output_dir = "data"
)

output_changed <- !same_df_output(saladj_rows, prior_latest_df)
archive_missing <- is.na(prior_archive_file) || !file.exists(prior_archive_file)
should_publish_archive <- output_changed || !file.exists(latest_csv) || archive_missing

if (should_publish_archive) {
  readr::write_csv(saladj_rows, latest_csv, na = "")
  readr::write_csv(saladj_rows, archive_file, na = "")
  latest_archive_data_path <- archive_file
  latest_archive_filename <- archive_filename
  last_changed_display <- run_time_display
  message("Published new SalAdjCurator archive: ", archive_file)
} else {
  matching_archive_file <- find_latest_matching_archive(saladj_rows, file.path("data", "archive"), current_season)
  latest_archive_data_path <- if (!is.na(matching_archive_file)) matching_archive_file else prior_archive_file
  latest_archive_filename <- basename(latest_archive_data_path)
  last_changed_display <- if (!is.na(matching_archive_file) && !identical(latest_archive_filename, prior_archive_filename)) {
    format_run_time(as.POSIXct(file.info(matching_archive_file)$mtime, tz = "America/Toronto"))
  } else if ("last_changed_display" %in% names(prior_meta) && nrow(prior_meta) > 0) {
    as.character(prior_meta$last_changed_display[1])
  } else if ("run_time_display" %in% names(prior_meta) && nrow(prior_meta) > 0) {
    as.character(prior_meta$run_time_display[1])
  } else {
    NA_character_
  }
  message("No SalAdjCurator output change; archive not updated.")
}

run_meta <- tibble::tibble(
  season = current_season,
  run_time_display = run_time_display,
  last_checked_display = run_time_display,
  last_changed_display = last_changed_display,
  latest_csv_changed = should_publish_archive,
  latest_csv_data_path = latest_csv,
  latest_archive_data_path = latest_archive_data_path,
  latest_archive_filename = latest_archive_filename,
  qualifying_rows = nrow(saladj_rows)
)

readr::write_csv(run_meta, metadata_file)

message("SalAdjCurator script ran successfully with ", nrow(saladj_rows), " qualifying rows")
