# run_saladjcurator.R
# -------------------
# Runs the SalAdjCurator automation and writes dashboard outputs.
# A dated archive CSV is created only when the actionable output changes.

library(readr)
library(tibble)

source("R/config_helpers.R")
source("R/saladj_engine.R")
source("R/commissioner_alerts.R")

current_season <- get_current_season()

format_run_time <- function(x) {
  if (!inherits(x, "POSIXt")) {
    x_chr <- as.character(x)
    x <- suppressWarnings(as.POSIXct(x_chr, tz = "America/Toronto"))
    if (is.na(x) && !is.na(suppressWarnings(as.numeric(x_chr)))) {
      x <- as.POSIXct(as.numeric(x_chr), origin = "1970-01-01", tz = "UTC")
    }
  }
  out <- format(lubridate::with_tz(x, "America/Toronto"), format = "%m/%d/%Y %I:%M %p %Z")
  out <- gsub("^0", "", out)
  out <- gsub("/0", "/", out)
  out <- gsub(" 0", " ", out)
  out <- gsub(" AM ", " a.m. ", out)
  out <- gsub(" PM ", " p.m. ", out)
  out
}

saladj_archive_metadata_file <- function(archive_file) {
  file.path(
    dirname(archive_file),
    sub("_ADLSalAdjCurator\\.csv$", "_ADLSalAdjCurator_metadata.csv", basename(archive_file))
  )
}

write_saladj_archive_metadata <- function(archive_file, generated_at, rows) {
  readr::write_csv(
    tibble::tibble(
      archive_filename = basename(archive_file),
      generated_at = format(generated_at, "%Y-%m-%d %H:%M:%S %Z"),
      generated_at_display = format_run_time(generated_at),
      rows = rows
    ),
    saladj_archive_metadata_file(archive_file),
    na = ""
  )
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

new_saladj_rows <- function(new_df, old_df) {
  if (is.null(old_df) || !nrow(old_df)) {
    return(new_df)
  }

  new_norm <- tibble::as_tibble(normalize_for_compare(new_df))
  old_norm <- tibble::as_tibble(normalize_for_compare(old_df))
  common_cols <- intersect(names(new_norm), names(old_norm))
  if (!length(common_cols)) {
    return(new_df)
  }

  new_norm$row_position <- seq_len(nrow(new_norm))
  old_norm <- old_norm[, common_cols, drop = FALSE]

  new_norm |>
    dplyr::anti_join(old_norm, by = common_cols) |>
    dplyr::arrange(.data$row_position) |>
    dplyr::pull(.data$row_position) |>
    {\(idx) new_df[idx, , drop = FALSE]}()
}

format_saladj_digest_amount <- function(x) {
  x_chr <- trimws(as.character(x %||% ""))
  if (!nzchar(x_chr)) return("")
  x_num <- suppressWarnings(as.numeric(gsub("[$,]", "", x_chr)))
  if (is.na(x_num)) return(x_chr)
  paste0("$", format(x_num, trim = TRUE, scientific = FALSE))
}

format_saladj_digest_row <- function(row) {
  player <- as.character(row$PLAYER[[1]] %||% "")
  fran <- as.character(row$FRAN[[1]] %||% "")
  date <- as.character(row$DATE[[1]] %||% "")
  salary <- format_saladj_digest_amount(row$SALARY[[1]] %||% "")
  years <- as.character(row$YEARS[[1]] %||% "")
  contract <- as.character(row$CONTRACT[[1]] %||% "")
  notes <- as.character(row$NOTES[[1]] %||% "")
  rvsd <- as.character(row$`RVSD?`[[1]] %||% "")

  details <- c(
    if (nzchar(salary)) paste0("salary ", salary) else NULL,
    if (nzchar(years)) paste0(years, " yr") else NULL,
    if (nzchar(contract)) contract else NULL,
    if (nzchar(notes)) paste0("notes: ", notes) else NULL,
    if (nzchar(rvsd)) paste0("RVSD?: ", rvsd) else NULL
  )

  paste0("- ", date, " | ", fran, " | ", player, if (length(details)) paste0(" | ", paste(details, collapse = "; ")) else "")
}

render_saladj_email <- function(new_rows, archive_filename, run_time_display) {
  title <- "There are new salary adjustments to enter"
  if (!nrow(new_rows)) {
    return(paste(c(title, "", "No new SalAdj rows were found."), collapse = "\n"))
  }

  groups <- split(new_rows, new_rows$CONF)
  groups <- groups[order(names(groups))]

  lines <- c(
    title,
    "",
    paste0("SalAdj Curator published ", nrow(new_rows), " new row(s) at ", run_time_display, "."),
    paste0("Dashboard CSV: ", archive_filename),
    "",
    "Please enter the following new salary adjustments in the Contract Admin sheet.",
    ""
  )

  for (conf in names(groups)) {
    rows <- groups[[conf]]
    lines <- c(lines, conf, strrep("-", nchar(conf)))
    for (i in seq_len(nrow(rows))) {
      lines <- c(lines, format_saladj_digest_row(rows[i, , drop = FALSE]))
    }
    lines <- c(lines, "")
  }

  paste(lines, collapse = "\n")
}

send_saladj_email <- function(new_rows, archive_filename, run_time_display, season = get_current_season()) {
  body <- render_saladj_email(new_rows, archive_filename, run_time_display)
  outbox_path <- write_commissioner_alert_outbox(body, season = season, name = "email_outbox_saladj_digest")

  if (!nrow(new_rows)) {
    return(tibble::tibble(sent = FALSE, reason = "no_new_rows", outbox_path = outbox_path, recipients = ""))
  }

  recipients <- resolve_commissioner_alert_recipients(season = season)
  if (!nrow(recipients)) {
    return(tibble::tibble(sent = FALSE, reason = "no_recipients", outbox_path = outbox_path, recipients = ""))
  }

  status <- send_alert_mail(
    subject = "There are new salary adjustments to enter",
    body = body,
    to = recipients$email
  )

  tibble::tibble(
    sent = isTRUE(status$sent),
    reason = status$reason,
    outbox_path = outbox_path,
    recipients = paste(recipients$email, collapse = ", ")
  )
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
email_rows <- new_saladj_rows(saladj_rows, prior_latest_df)
archive_missing <- is.na(prior_archive_file) || !file.exists(prior_archive_file)
should_publish_archive <- output_changed || !file.exists(latest_csv) || archive_missing

if (should_publish_archive) {
  readr::write_csv(saladj_rows, latest_csv, na = "")
  readr::write_csv(saladj_rows, archive_file, na = "")
  write_saladj_archive_metadata(archive_file, run_time_toronto, nrow(saladj_rows))
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

send_email <- tolower(Sys.getenv("ADL_SALADJ_SEND_EMAIL", unset = "false")) %in% c("1", "true", "yes")
if (send_email && should_publish_archive) {
  email_status <- send_saladj_email(
    email_rows,
    archive_filename = latest_archive_filename,
    run_time_display = run_time_display,
    season = current_season
  )
  readr::write_csv(email_status, file.path("data", "saladj_email_status.csv"), na = "")
  message("SalAdj email status: ", email_status$reason[[1]])
  message("SalAdj email outbox: ", email_status$outbox_path[[1]])
  if (!isTRUE(email_status$sent[[1]]) && !identical(email_status$reason[[1]], "no_new_rows")) {
    stop("SalAdj email was requested but not sent: ", email_status$reason[[1]], call. = FALSE)
  }
}

message("SalAdjCurator script ran successfully with ", nrow(saladj_rows), " qualifying rows")

