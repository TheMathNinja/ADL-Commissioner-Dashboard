library(dplyr)
library(readr)
library(tibble)

source("R/config_helpers.R")
source("R/commissioner_alerts.R")
source("R/saladj_email.R")

arg_value <- function(name, default = "") {
  prefix <- paste0("--", name, "=")
  match <- commandArgs(trailingOnly = TRUE)[startsWith(commandArgs(trailingOnly = TRUE), prefix)]
  if (!length(match)) return(default)
  sub(prefix, "", match[[1]], fixed = TRUE)
}

report_date <- as.Date(arg_value("date", format(Sys.Date(), "%Y-%m-%d")))
recipient <- trimws(arg_value("to"))
if (!nzchar(recipient)) stop("A recipient is required.", call. = FALSE)

archive_dir <- file.path("data", "archive")
archive_path <- file.path(
  archive_dir,
  paste0(format(report_date, "%Y_%m_%d"), "_ADLSalAdjCurator.csv")
)
if (!file.exists(archive_path)) {
  stop("SalAdj archive not found: ", archive_path, call. = FALSE)
}

prior_archives <- list.files(
  archive_dir,
  pattern = "^[0-9]{4}_[0-9]{2}_[0-9]{2}_ADLSalAdjCurator\\.csv$",
  full.names = TRUE
)
prior_dates <- suppressWarnings(as.Date(
  sub("_ADLSalAdjCurator\\.csv$", "", basename(prior_archives)),
  format = "%Y_%m_%d"
))
prior_archives <- prior_archives[!is.na(prior_dates) & prior_dates < report_date]
prior_dates <- prior_dates[!is.na(prior_dates) & prior_dates < report_date]
if (!length(prior_archives)) stop("No prior SalAdj archive was found.", call. = FALSE)
prior_path <- prior_archives[[which.max(prior_dates)]]

current <- read_csv(archive_path, col_types = cols(.default = col_character()), show_col_types = FALSE)
prior <- read_csv(prior_path, col_types = cols(.default = col_character()), show_col_types = FALSE)
identity_cols <- c("CONF", "DATE", "FRAN", "PLAYER", "SALARY", "YEARS", "CONTRACT")
missing_cols <- setdiff(identity_cols, intersect(names(current), names(prior)))
if (length(missing_cols)) {
  stop("Archives lack identity columns: ", paste(missing_cols, collapse = ", "), call. = FALSE)
}

new_rows <- anti_join(current, prior[, identity_cols, drop = FALSE], by = identity_cols)
if (!nrow(new_rows)) stop("No new SalAdj rows were found for this archive.", call. = FALSE)

metadata_path <- sub("\\.csv$", "_metadata.csv", archive_path)
published_display <- format(report_date, "%m/%d/%Y")
if (file.exists(metadata_path)) {
  metadata <- read_csv(metadata_path, show_col_types = FALSE)
  if (nrow(metadata) && "generated_at_display" %in% names(metadata)) {
    published_display <- metadata$generated_at_display[[1]]
  }
}

scheduled_at <- as.POSIXct(
  paste(report_date, "05:17:00"),
  tz = "America/New_York"
)
format_audit_time <- function(x) {
  out <- format(x, "%b %-d, %Y at %-I:%M %p %Z", tz = "America/New_York")
  out <- sub(" AM ", " a.m. ", out, fixed = TRUE)
  sub(" PM ", " p.m. ", out, fixed = TRUE)
}

body <- render_saladj_email(
  new_rows = new_rows,
  archive_filename = basename(archive_path),
  run_time_display = published_display,
  run_audit = list(
    scheduled_display = format_audit_time(scheduled_at),
    started_display = "",
    completed_display = paste0(format_audit_time(Sys.time()), " (manual recipient-only resend)"),
    duration_display = "",
    trigger = "manual resend"
  )
)

status <- send_alert_mail(
  subject = "[ADL Commissioner Alerts] New salary adjustments to enter",
  body = body,
  to = recipient,
  html_body = render_saladj_email_html(body, basename(archive_path))
)
if (!isTRUE(status$sent)) stop("Email was not sent: ", status$reason, call. = FALSE)

message("Sent ", nrow(new_rows), " SalAdj rows to ", recipient, ".")
