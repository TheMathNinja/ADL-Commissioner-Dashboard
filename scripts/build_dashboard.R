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
      snapshot_date_et = as.Date(snapshot_time_et, tz = "America/Toronto"),
      public_filename = paste0(
        format(snapshot_time_et, "%Y_%m_%d_%H%M%S"),
        "_ADLDailyRosterSnapshot.csv"
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

format_salary <- function(x) {
  salary <- suppressWarnings(as.numeric(x))
  dplyr::if_else(
    is.na(salary),
    "",
    paste0("$", format(round(salary, 2), nsmall = 2, trim = TRUE, scientific = FALSE))
  )
}

format_player_display <- function(player_name, player_team, player_pos) {
  suffix <- paste(
    dplyr::coalesce(player_team, ""),
    dplyr::coalesce(player_pos, "")
  )
  suffix <- stringr::str_squish(suffix)

  dplyr::if_else(
    nzchar(suffix),
    paste(dplyr::coalesce(player_name, ""), suffix),
    dplyr::coalesce(player_name, "")
  )
}

player_last_name <- function(player_name) {
  player_name <- dplyr::coalesce(player_name, "")
  ifelse(
    stringr::str_detect(player_name, ","),
    stringr::str_trim(stringr::str_extract(player_name, "^[^,]+")),
    stringr::str_trim(stringr::word(player_name, -1))
  )
}

write_public_roster_snapshot <- function(snapshot_file, public_file, franchises) {
  snapshot <- read_snapshot_csv(snapshot_file)

  if (!"franchise_name" %in% names(snapshot)) snapshot$franchise_name <- NA_character_
  if (!"roster_status" %in% names(snapshot)) snapshot$roster_status <- NA_character_
  if (!"player_team" %in% names(snapshot)) snapshot$player_team <- NA_character_
  if (!"player_pos" %in% names(snapshot)) snapshot$player_pos <- NA_character_

  position_order <- c("QB", "RB", "WR", "TE", "PK", "PN", "DT", "DE", "LB", "CB", "S")

  public_snapshot <- snapshot %>%
    dplyr::mutate(
      franchise_id = as.character(.data$franchise_id),
      snapshot_time_et = format(lubridate::with_tz(.data$snapshot_time, "America/Toronto"), "%m/%d/%Y %I:%M %p %Z"),
      roster_status_sort = dplyr::case_when(
        .data$roster_status == "Active" ~ 1L,
        .data$roster_status == "Taxi" ~ 2L,
        TRUE ~ 3L
      ),
      player_pos_sort = match(.data$player_pos, position_order),
      player_pos_sort = dplyr::coalesce(.data$player_pos_sort, length(position_order) + 1L),
      player_last_name = player_last_name(.data$player_name)
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
    dplyr::arrange(
      suppressWarnings(as.integer(.data$franchise_id)),
      .data$roster_status_sort,
      .data$player_pos_sort,
      .data$player_last_name,
      .data$player_name
    ) %>%
    dplyr::transmute(
      SNAPSHOT_TIME_ET = .data$snapshot_time_et,
      CONF = .data$CONF,
      FRANCHISE = .data$franchise_name,
      PLAYER_ID = .data$player_id,
      PLAYER = format_player_display(.data$player_name, .data$player_team, .data$player_pos),
      SALARY = format_salary(.data$roster_salary),
      YEARS = .data$roster_years,
      CONTRACT = .data$roster_contractInfo,
      ROSTER_STATUS = .data$roster_status
    )

  readr::write_csv(public_snapshot, public_file, na = "")
}

add_file_versions <- function(public_files) {
  if (length(public_files) == 0) return(public_files)

  vapply(public_files, function(public_file) {
    docs_file <- file.path("docs", public_file)
    if (!file.exists(docs_file)) return(public_file)

    paste0(public_file, "?v=", unname(tools::md5sum(docs_file)))
  }, character(1), USE.NAMES = FALSE)
}

file_generated_at_et <- function(files) {
  if (length(files) == 0) {
    return(list())
  }

  generated_at <- file.info(files)$mtime
  generated_at_et <- lubridate::with_tz(generated_at, "America/Toronto")
  generated_at_text <- format(generated_at_et, "%m/%d/%Y %I:%M %p %Z")
  stats::setNames(as.list(generated_at_text), basename(files))
}

# Read metadata
run_meta <- readr::read_csv("data/run_metadata.csv", show_col_types = FALSE)
franchises <- readRDS(file.path("data", paste0("adl_franchises_", current_season, ".rds")))

# Make sure docs directories exist
dir.create("docs", recursive = TRUE, showWarnings = FALSE)
dir.create(file.path("docs", "downloads"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path("docs", "downloads", "daily-roster-snapshots"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path("docs", "downloads", "salary-cap-accounting", "snapshots"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path("docs", "downloads", "salary-cap-accounting", "summaries"), recursive = TRUE, showWarnings = FALSE)
unlink(file.path("docs", "downloads", "daily-roster-snapshots", "*.csv"))
unlink(file.path("docs", "downloads", "salary-cap-accounting", "snapshots", "*.csv"))
unlink(file.path("docs", "downloads", "salary-cap-accounting", "summaries", "*.csv"))

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

# Publish daily roster snapshots from the SalAdj roster snapshot history.
snapshot_files_data <- list.files(
  path = file.path("data", "roster_snapshots"),
  pattern = paste0("^saladj_roster_snapshot_", current_season, "_[0-9]{8}_[0-9]{6}\\.csv$"),
  full.names = TRUE
)

snapshot_files_data <- sort(snapshot_files_data, decreasing = TRUE)
snapshot_index <- build_snapshot_index(snapshot_files_data)
snapshot_filenames <- snapshot_index$public_filename

if (nrow(snapshot_index) > 0) {
  invisible(mapply(
    write_public_roster_snapshot,
    snapshot_file = snapshot_index$snapshot_file,
    public_file = file.path("docs", "downloads", "daily-roster-snapshots", snapshot_index$public_filename),
    MoreArgs = list(franchises = franchises)
  ))
}

snapshot_files_public <- file.path("downloads", "daily-roster-snapshots", snapshot_filenames)
snapshot_files_public <- add_file_versions(snapshot_files_public)
latest_snapshot_public <- if (length(snapshot_files_public) > 0) {
  snapshot_files_public[1]
} else {
  NA_character_
}

snapshot_checks_file <- file.path(
  "data",
  "roster_snapshots",
  paste0("saladj_roster_snapshot_checks_", current_season, ".csv")
)

latest_snapshot_date_et <- if (nrow(snapshot_index) > 0) {
  as.Date(snapshot_index$snapshot_date_et[1])
} else {
  as.Date(NA)
}

no_change_check_text <- if (file.exists(snapshot_checks_file) && !is.na(latest_snapshot_date_et)) {
  snapshot_checks <- readr::read_csv(
    snapshot_checks_file,
    col_types = readr::cols(
      check_date_et = readr::col_date(),
      snapshot_changed = readr::col_logical(),
      .default = readr::col_character()
    ),
    show_col_types = FALSE
  )

  snapshot_checks %>%
    dplyr::filter(
      .data$check_date_et > latest_snapshot_date_et,
      !.data$snapshot_changed
    ) %>%
    dplyr::arrange(.data$check_date_et) %>%
    dplyr::transmute(
      text = paste0(
        format(.data$check_date_et, "%m/%d/%Y"),
        ": checked at ",
        .data$last_checked_at_et,
        "; no roster/salary changes found"
      )
    ) %>%
    dplyr::pull(.data$text)
} else {
  character()
}

# Publish salary cap accounting snapshots and summaries.
cap_base_dir <- file.path("data", "cap_accounting", as.character(current_season))
cap_snapshot_files_data <- list.files(
  path = file.path(cap_base_dir, "snapshots"),
  pattern = paste0("^", current_season, "w\\d+_ADLsalarycapsnapshot\\.csv$"),
  full.names = TRUE
)
cap_summary_files_data <- list.files(
  path = file.path(cap_base_dir, "summaries"),
  pattern = paste0("^", current_season, "w\\d+_ADLsalarycapsummary\\.csv$"),
  full.names = TRUE
)
cap_warning_files_data <- list.files(
  path = cap_base_dir,
  pattern = paste0("^", current_season, "w\\d+_ADLsalarycapwarnings\\.csv$"),
  full.names = TRUE
)

cap_week_from_file <- function(x, file_type) {
  as.integer(stringr::str_match(
    basename(x),
    paste0("^", current_season, "w(\\d+)_ADLsalarycap", file_type, "\\.csv$")
  )[, 2])
}

cap_snapshot_files_data <- cap_snapshot_files_data[order(cap_week_from_file(cap_snapshot_files_data, "snapshot"), decreasing = TRUE)]
cap_summary_files_data <- cap_summary_files_data[order(cap_week_from_file(cap_summary_files_data, "summary"), decreasing = TRUE)]
cap_generated_at_by_file <- c(
  file_generated_at_et(cap_summary_files_data),
  file_generated_at_et(cap_snapshot_files_data)
)

if (length(cap_snapshot_files_data) > 0) {
  invisible(file.copy(
    from = cap_snapshot_files_data,
    to = file.path("docs", "downloads", "salary-cap-accounting", "snapshots", basename(cap_snapshot_files_data)),
    overwrite = TRUE
  ))
}

if (length(cap_summary_files_data) > 0) {
  invisible(file.copy(
    from = cap_summary_files_data,
    to = file.path("docs", "downloads", "salary-cap-accounting", "summaries", basename(cap_summary_files_data)),
    overwrite = TRUE
  ))
}

cap_snapshot_files_public <- file.path("downloads", "salary-cap-accounting", "snapshots", basename(cap_snapshot_files_data))
cap_summary_files_public <- file.path("downloads", "salary-cap-accounting", "summaries", basename(cap_summary_files_data))
cap_snapshot_files_public <- add_file_versions(cap_snapshot_files_public)
cap_summary_files_public <- add_file_versions(cap_summary_files_public)

cap_warning_rows <- if (length(cap_warning_files_data) > 0) {
  dplyr::bind_rows(lapply(cap_warning_files_data, function(warning_file) {
    readr::read_csv(
      warning_file,
      col_types = readr::cols(.default = readr::col_character()),
      show_col_types = FALSE
    )
  }))
} else {
  tibble::tibble(filename = character(), warning = character())
}

cap_warnings_by_file <- if (nrow(cap_warning_rows) > 0) {
  split(cap_warning_rows$warning, cap_warning_rows$filename)
} else {
  list()
}

current_cap_summary_public <- if (length(cap_summary_files_public) > 0) {
  cap_summary_files_public[1]
} else {
  NA_character_
}

# Build landing page
index_html <- build_dashboard_index_html(
  latest_daily_roster_snapshot_public = latest_snapshot_public,
  latest_cap_summary_public = current_cap_summary_public
)
writeLines(index_html, file.path("docs", "index.html"))

# Build SalAdjCurator page
saladj_html <- build_saladjcurator_html(
  run_meta = run_meta,
  archive_files_public = archive_files_public
)

writeLines(saladj_html, file.path("docs", "saladjcurator.html"))

# Build daily roster snapshots page
daily_roster_snapshots_html <- build_daily_roster_snapshots_html(
  snapshot_files_public = snapshot_files_public,
  latest_snapshot_public = latest_snapshot_public,
  no_change_check_text = no_change_check_text
)

writeLines(daily_roster_snapshots_html, file.path("docs", "daily-roster-snapshots.html"))

# Build salary cap accounting page
cap_accounting_html <- build_cap_accounting_html(
  current_summary_public = current_cap_summary_public,
  summary_files_public = cap_summary_files_public,
  snapshot_files_public = cap_snapshot_files_public,
  warnings_by_file = cap_warnings_by_file,
  generated_at_by_file = cap_generated_at_by_file
)

writeLines(cap_accounting_html, file.path("docs", "salary-cap-accounting.html"))

message("Dashboard build complete for season: ", current_season)
