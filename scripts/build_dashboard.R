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

report_date_from_commissioner_alert_file <- function(report_file) {
  report_date_text <- sub(
    "^commissioner_alert_report_([0-9]{4}-[0-9]{2}-[0-9]{2})_.*\\.csv$",
    "\\1",
    basename(report_file)
  )
  suppressWarnings(as.Date(report_date_text))
}

commissioner_alert_report_metadata_file <- function(report_file) {
  file.path(
    dirname(report_file),
    sub(
      "^commissioner_alert_report_",
      "commissioner_alert_report_metadata_",
      basename(report_file)
    )
  )
}

format_checked_at_et <- function(checked_at) {
  if (is.null(checked_at) || length(checked_at) == 0 || is.na(checked_at)) {
    checked_at <- ""
  }
  checked_at <- trimws(as.character(checked_at))
  if (!nzchar(checked_at)) return(NA_character_)

  parsed <- suppressWarnings(as.POSIXct(checked_at, tz = "UTC"))
  if (is.na(parsed)) {
    parsed <- suppressWarnings(lubridate::ymd_hms(checked_at, tz = "UTC", quiet = TRUE))
  }
  if (is.na(parsed)) return(NA_character_)

  format(lubridate::with_tz(parsed, "America/Toronto"), "%m/%d/%Y %I:%M %p %Z")
}

commissioner_alert_report_generated_at <- function(report_file) {
  metadata_file <- commissioner_alert_report_metadata_file(report_file)
  if (file.exists(metadata_file)) {
    metadata <- tryCatch(readr::read_csv(metadata_file, show_col_types = FALSE), error = function(e) NULL)
    if (!is.null(metadata) && nrow(metadata) && "checked_at" %in% names(metadata)) {
      return(format_checked_at_et(metadata$checked_at[[1]]))
    }
  }

  report <- tryCatch(readr::read_csv(report_file, show_col_types = FALSE), error = function(e) NULL)
  if (!is.null(report) && nrow(report) && "checked_at" %in% names(report)) {
    return(format_checked_at_et(report$checked_at[[1]]))
  }

  NA_character_
}

count_csv_data_rows <- function(report_file) {
  if (!file.exists(report_file)) return(NA_integer_)
  rows <- tryCatch(
    nrow(readr::read_csv(report_file, show_col_types = FALSE)),
    error = function(e) NA_integer_
  )
  as.integer(rows)
}

summarize_commissioner_alert_report_label <- function(report_file) {
  report_label <- basename(report_file)
  report <- tryCatch(
    readr::read_csv(
      report_file,
      col_types = readr::cols(.default = readr::col_character()),
      show_col_types = FALSE
    ),
    error = function(e) NULL
  )

  if (is.null(report)) {
    return(paste0(report_label, " (unable to read report)"))
  }

  violation_count <- nrow(report)
  if (violation_count == 0) {
    return(paste0(report_label, " (clean)"))
  }

  franchise_values <- if ("franchise" %in% names(report)) {
    report$franchise
  } else if ("franchise_name" %in% names(report)) {
    report$franchise_name
  } else {
    character()
  }
  franchise_values <- stringr::str_squish(dplyr::coalesce(franchise_values, ""))
  franchise_values <- franchise_values[nzchar(franchise_values)]

  franchise_summary <- ""
  if (length(franchise_values) > 0) {
    franchise_order <- unique(franchise_values)
    franchise_counts <- table(factor(franchise_values, levels = franchise_order))
    franchise_parts <- ifelse(
      as.integer(franchise_counts) == 1,
      names(franchise_counts),
      paste0(names(franchise_counts), " (", as.integer(franchise_counts), ")")
    )
    franchise_summary <- paste0(": ", paste(franchise_parts, collapse = ", "))
  }

  paste0(
    report_label,
    " (",
    violation_count,
    " violation",
    if (violation_count == 1) "" else "s",
    franchise_summary,
    ")"
  )
}

missing_commissioner_alert_report_dates <- function(report_files, timezone = "America/Toronto") {
  report_dates <- report_date_from_commissioner_alert_file(report_files)
  report_dates <- report_dates[!is.na(report_dates)]

  if (length(report_dates) == 0) {
    return(as.Date(character()))
  }

  expected_dates <- seq.Date(min(report_dates), lubridate::today(tzone = timezone), by = "day")
  missing_dates <- setdiff(as.numeric(expected_dates), as.numeric(report_dates))
  sort(as.Date(missing_dates, origin = "1970-01-01"), decreasing = TRUE)
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
dir.create(file.path("docs", "downloads", "salary-cap-accounting", "waiver-corrections"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path("docs", "downloads", "commissioner-alerts"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path("docs", "downloads", "commissioner-alerts", "clean"), recursive = TRUE, showWarnings = FALSE)
unlink(file.path("docs", "downloads", "daily-roster-snapshots", "*.csv"))
unlink(file.path("docs", "downloads", "salary-cap-accounting", "snapshots", "*.csv"))
unlink(file.path("docs", "downloads", "salary-cap-accounting", "summaries", "*.csv"))
unlink(file.path("docs", "downloads", "salary-cap-accounting", "waiver-corrections", "*.csv"))
unlink(file.path("docs", "downloads", "commissioner-alerts", "*.csv"))
unlink(file.path("docs", "downloads", "commissioner-alerts", "clean", "*.csv"))

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
cap_waiver_correction_files_data <- list.files(
  path = file.path(cap_base_dir, "waiver_corrections"),
  pattern = paste0("^", current_season, "w\\d+_ADLwaivercorrections\\.csv$"),
  full.names = TRUE
)
cap_warning_files_data <- list.files(
  path = cap_base_dir,
  pattern = paste0("^", current_season, "w\\d+_ADLsalarycapwarnings\\.csv$"),
  full.names = TRUE
)

cap_week_from_file <- function(x, file_pattern) {
  as.integer(stringr::str_match(
    basename(x),
    paste0("^", current_season, "w(\\d+)_", file_pattern, "\\.csv$")
  )[, 2])
}

cap_snapshot_files_data <- cap_snapshot_files_data[order(cap_week_from_file(cap_snapshot_files_data, "ADLsalarycapsnapshot"), decreasing = TRUE)]
cap_summary_files_data <- cap_summary_files_data[order(cap_week_from_file(cap_summary_files_data, "ADLsalarycapsummary"), decreasing = TRUE)]
cap_waiver_correction_files_data <- cap_waiver_correction_files_data[order(cap_week_from_file(cap_waiver_correction_files_data, "ADLwaivercorrections"), decreasing = TRUE)]
cap_generated_at_by_file <- c(
  file_generated_at_et(cap_summary_files_data),
  file_generated_at_et(cap_snapshot_files_data),
  file_generated_at_et(cap_waiver_correction_files_data)
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

if (length(cap_waiver_correction_files_data) > 0) {
  invisible(file.copy(
    from = cap_waiver_correction_files_data,
    to = file.path("docs", "downloads", "salary-cap-accounting", "waiver-corrections", basename(cap_waiver_correction_files_data)),
    overwrite = TRUE
  ))
}

cap_snapshot_files_public <- file.path("downloads", "salary-cap-accounting", "snapshots", basename(cap_snapshot_files_data))
cap_summary_files_public <- file.path("downloads", "salary-cap-accounting", "summaries", basename(cap_summary_files_data))
cap_waiver_correction_files_public <- file.path("downloads", "salary-cap-accounting", "waiver-corrections", basename(cap_waiver_correction_files_data))
cap_snapshot_files_public <- add_file_versions(cap_snapshot_files_public)
cap_summary_files_public <- add_file_versions(cap_summary_files_public)
cap_waiver_correction_files_public <- add_file_versions(cap_waiver_correction_files_public)

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

# Publish commissioner alert report history.
commissioner_alert_report_files_data <- list.files(
  path = file.path("data", "commissioner_alert_reports"),
  pattern = paste0("^commissioner_alert_report_[0-9]{4}-[0-9]{2}-[0-9]{2}_", current_season, ".*\\.csv$"),
  full.names = TRUE
)
commissioner_alert_report_files_data <- sort(commissioner_alert_report_files_data, decreasing = TRUE)

commissioner_alert_report_row_counts <- vapply(
  commissioner_alert_report_files_data,
  count_csv_data_rows,
  integer(1),
  USE.NAMES = FALSE
)
commissioner_alert_report_files_with_violations_data <- commissioner_alert_report_files_data[
  !is.na(commissioner_alert_report_row_counts) & commissioner_alert_report_row_counts > 0
]
commissioner_alert_report_files_clean_data <- commissioner_alert_report_files_data[
  !is.na(commissioner_alert_report_row_counts) & commissioner_alert_report_row_counts == 0
]

if (length(commissioner_alert_report_files_with_violations_data) > 0) {
  invisible(file.copy(
    from = commissioner_alert_report_files_with_violations_data,
    to = file.path("docs", "downloads", "commissioner-alerts", basename(commissioner_alert_report_files_with_violations_data)),
    overwrite = TRUE
  ))
}

if (length(commissioner_alert_report_files_clean_data) > 0) {
  invisible(file.copy(
    from = commissioner_alert_report_files_clean_data,
    to = file.path("docs", "downloads", "commissioner-alerts", "clean", basename(commissioner_alert_report_files_clean_data)),
    overwrite = TRUE
  ))
}

commissioner_alert_report_files_public <- file.path(
  "downloads",
  "commissioner-alerts",
  basename(commissioner_alert_report_files_data)
)
commissioner_alert_report_files_public <- ifelse(
  !is.na(commissioner_alert_report_row_counts) & commissioner_alert_report_row_counts == 0,
  file.path("downloads", "commissioner-alerts", "clean", basename(commissioner_alert_report_files_data)),
  commissioner_alert_report_files_public
)
commissioner_alert_report_files_public <- add_file_versions(commissioner_alert_report_files_public)
commissioner_alert_report_files_with_violations_public <- file.path(
  "downloads",
  "commissioner-alerts",
  basename(commissioner_alert_report_files_with_violations_data)
)
commissioner_alert_report_files_with_violations_public <- add_file_versions(commissioner_alert_report_files_with_violations_public)
commissioner_alert_report_files_with_violations_labels <- vapply(
  commissioner_alert_report_files_with_violations_data,
  summarize_commissioner_alert_report_label,
  character(1),
  USE.NAMES = FALSE
)
commissioner_alert_report_files_clean_public <- file.path(
  "downloads",
  "commissioner-alerts",
  "clean",
  basename(commissioner_alert_report_files_clean_data)
)
commissioner_alert_report_files_clean_public <- add_file_versions(commissioner_alert_report_files_clean_public)
commissioner_alert_missing_report_dates <- missing_commissioner_alert_report_dates(commissioner_alert_report_files_data)
latest_commissioner_alert_report_public <- if (length(commissioner_alert_report_files_public) > 0) {
  commissioner_alert_report_files_public[1]
} else {
  NA_character_
}
latest_commissioner_alert_report_rows <- if (length(commissioner_alert_report_files_data) > 0) {
  nrow(readr::read_csv(commissioner_alert_report_files_data[1], show_col_types = FALSE))
} else {
  NA_integer_
}
latest_commissioner_alert_report_generated_at <- if (length(commissioner_alert_report_files_data) > 0) {
  commissioner_alert_report_generated_at(commissioner_alert_report_files_data[1])
} else {
  NA_character_
}

# Build landing page
index_html <- build_dashboard_index_html(
  latest_daily_roster_snapshot_public = latest_snapshot_public,
  latest_cap_summary_public = current_cap_summary_public,
  latest_commissioner_alert_report_public = latest_commissioner_alert_report_public
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

# Build commissioner alerts page
commissioner_alerts_html <- build_commissioner_alerts_html(
  report_files_public = commissioner_alert_report_files_public,
  latest_report_public = latest_commissioner_alert_report_public,
  latest_report_rows = latest_commissioner_alert_report_rows,
  latest_report_generated_at = latest_commissioner_alert_report_generated_at,
  violation_report_files_public = commissioner_alert_report_files_with_violations_public,
  violation_report_file_labels = commissioner_alert_report_files_with_violations_labels,
  clean_archive_public = "downloads/commissioner-alerts/clean/",
  clean_report_count = length(commissioner_alert_report_files_clean_public),
  failed_report_dates = commissioner_alert_missing_report_dates
)

writeLines(commissioner_alerts_html, file.path("docs", "commissioner-alerts.html"))

commissioner_alert_clean_archive_html <- build_commissioner_alert_clean_archive_html(
  clean_report_files_public = commissioner_alert_report_files_clean_public
)

writeLines(
  commissioner_alert_clean_archive_html,
  file.path("docs", "downloads", "commissioner-alerts", "clean", "index.html")
)

# Build salary cap accounting page
cap_accounting_html <- build_cap_accounting_html(
  current_summary_public = current_cap_summary_public,
  summary_files_public = cap_summary_files_public,
  snapshot_files_public = cap_snapshot_files_public,
  waiver_correction_files_public = cap_waiver_correction_files_public,
  warnings_by_file = cap_warnings_by_file,
  generated_at_by_file = cap_generated_at_by_file
)

writeLines(cap_accounting_html, file.path("docs", "salary-cap-accounting.html"))

message("Dashboard build complete for season: ", current_season)
