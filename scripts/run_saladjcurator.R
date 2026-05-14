# run_saladjcurator.R
# -------------------
# Runs the SalAdjCurator automation and writes dashboard outputs.

library(readr)
library(tibble)

source("R/config_helpers.R")
source("R/saladj_engine.R")

current_season <- get_current_season()

run_time_toronto <- as.POSIXct(
  format(Sys.time(), tz = "America/Toronto", usetz = TRUE),
  tz = "America/Toronto"
)

run_date_file <- format(run_time_toronto, "%Y_%m_%d")
run_time_display <- format(run_time_toronto, "%m/%d/%Y %I:%M %p %Z")
run_time_display <- gsub("^0", "", run_time_display)
run_time_display <- gsub("/0", "/", run_time_display)
run_time_display <- gsub(" 0", " ", run_time_display)
run_time_display <- gsub(" AM ", " a.m. ", run_time_display)
run_time_display <- gsub(" PM ", " p.m. ", run_time_display)

archive_filename <- paste0(run_date_file, "_ADLSalAdjCurator.csv")

dir.create("data", recursive = TRUE, showWarnings = FALSE)
dir.create(file.path("data", "archive"), recursive = TRUE, showWarnings = FALSE)

message("Running SalAdjCurator for season: ", current_season)

saladj_rows <- build_saladj_curator(
  current_season = current_season,
  output_dir = "data"
)

latest_csv <- file.path("data", "SalAdjCurator_latest.csv")
archive_file <- file.path("data", "archive", archive_filename)

readr::write_csv(saladj_rows, latest_csv, na = "")
readr::write_csv(saladj_rows, archive_file, na = "")

run_meta <- tibble::tibble(
  season = current_season,
  run_time_display = run_time_display,
  latest_csv_data_path = latest_csv,
  latest_archive_data_path = archive_file,
  latest_archive_filename = archive_filename,
  qualifying_rows = nrow(saladj_rows)
)

readr::write_csv(run_meta, "data/run_metadata.csv")

message("SalAdjCurator script ran successfully with ", nrow(saladj_rows), " qualifying rows")
