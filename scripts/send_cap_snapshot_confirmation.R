source("R/config_helpers.R")

split_recipients <- function(x) {
  values <- trimws(strsplit(x, "[,;]")[[1]])
  unique(values[nzchar(values)])
}

format_snapshot_confirmation <- function(metadata) {
  taken <- as.POSIXct(metadata$snapshot_taken_at_utc[[1]], tz = "UTC")
  taken_et <- as.POSIXct(format(taken, tz = "America/New_York", usetz = FALSE), tz = "America/New_York")
  date_text <- paste0(format(taken_et, "%A, %b "), as.integer(format(taken_et, "%d")), format(taken_et, ", %Y at %I:%M:%S %p ET"))
  c(
    paste0("ADL Week ", metadata$week[[1]], " Official Cap Snapshot"),
    "",
    paste0("The official Week ", metadata$week[[1]], " salary cap snapshot completed successfully."),
    paste0("Snapshot taken: ", date_text),
    paste0("Contract Admin Cap Rollover tab: ", Sys.getenv("ADL_CAP_SNAPSHOT_SHEET_STATUS", unset = "updated successfully")),
    paste0("Workflow: ", metadata$workflow_run_url[[1]])
  ) |> paste(collapse = "\n")
}

send_snapshot_mail <- function(subject, body, recipients) {
  from <- Sys.getenv("ADL_ALERT_EMAIL_FROM", unset = "")
  smtp_server <- Sys.getenv("ADL_SMTP_SERVER", unset = "")
  if (!length(recipients) || !nzchar(from) || !nzchar(smtp_server)) stop("Snapshot confirmation email is not configured.")
  message <- paste0(
    "From: ", from, "\r\n",
    "To: ", paste(recipients, collapse = ", "), "\r\n",
    "Subject: ", subject, "\r\n",
    "Content-Type: text/plain; charset=UTF-8\r\n\r\n",
    body
  )
  curl::send_mail(
    mail_from = from,
    mail_rcpt = recipients,
    smtp_server = smtp_server,
    message = charToRaw(message),
    username = Sys.getenv("ADL_SMTP_USERNAME", unset = ""),
    password = Sys.getenv("ADL_SMTP_PASSWORD", unset = ""),
    use_ssl = Sys.getenv("ADL_SMTP_SSL", unset = "try")
  )
}

season <- get_current_season()
week <- get_snapshot_week(season)
metadata_path <- Sys.getenv(
  "ADL_CAP_SNAPSHOT_METADATA_PATH",
  unset = file.path("data", "cap_accounting", season, paste0(season, "w", week, "_ADLsalarycapmetadata.csv"))
)
if (!file.exists(metadata_path)) stop("Official cap snapshot metadata is missing: ", metadata_path)
metadata <- readr::read_csv(metadata_path, show_col_types = FALSE)
if (nrow(metadata) != 1L || metadata$week[[1]] != week) stop("Official cap snapshot metadata is invalid.")

body <- format_snapshot_confirmation(metadata)
preview_path <- Sys.getenv(
  "ADL_CAP_SNAPSHOT_PREVIEW_PATH",
  unset = file.path("data", "cap_accounting", season, paste0(season, "w", week, "_ADLsalarycap_confirmation_email.txt"))
)
writeLines(body, preview_path)

if (tolower(Sys.getenv("ADL_CAP_SNAPSHOT_SEND_EMAIL", unset = "false")) %in% c("1", "true", "yes")) {
  recipients <- split_recipients(Sys.getenv("ADL_CAP_SNAPSHOT_EMAIL_TO", unset = ""))
  subject <- paste0("[ADL Commissioner Alerts] Week ", week, " official cap snapshot complete")
  send_snapshot_mail(subject, body, recipients)
  message("Sent official cap snapshot confirmation to ", paste(recipients, collapse = ", "))
} else {
  message("Wrote cap snapshot confirmation preview without sending email.")
}
