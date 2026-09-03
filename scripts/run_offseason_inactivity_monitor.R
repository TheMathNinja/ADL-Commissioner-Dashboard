library(dplyr)

source("R/offseason_inactivity_monitor.R")

arg_value <- function(name, default = NULL) {
  args <- commandArgs(trailingOnly = TRUE)
  prefix <- paste0("--", name, "=")
  matched <- args[startsWith(args, prefix)]
  if (!length(matched)) return(default)
  sub(prefix, "", matched[[1]], fixed = TRUE)
}

arg_flag <- function(name) paste0("--", name) %in% commandArgs(trailingOnly = TRUE)

season <- suppressWarnings(as.integer(arg_value("season", Sys.getenv("CURRENT_SEASON", unset = get_current_season()))))
force_live <- arg_flag("force-live") || tolower(Sys.getenv("ADL_INACTIVITY_FORCE_LIVE", unset = "true")) %in% c("1", "true", "yes")
send_email <- arg_flag("send-email") || tolower(Sys.getenv("ADL_INACTIVITY_SEND_EMAIL", unset = "false")) %in% c("1", "true", "yes")
send_empty <- arg_flag("send-empty") || tolower(Sys.getenv("ADL_INACTIVITY_SEND_EMPTY", unset = "true")) %in% c("1", "true", "yes")
include_info <- arg_flag("include-info") || tolower(Sys.getenv("ADL_INACTIVITY_INCLUDE_INFO", unset = "false")) %in% c("1", "true", "yes")
mark_issued <- arg_flag("mark-issued") || tolower(Sys.getenv("ADL_INACTIVITY_MARK_ISSUED", unset = "false")) %in% c("1", "true", "yes")

if (is.na(season)) stop("Provide a valid --season or CURRENT_SEASON.", call. = FALSE)

run_time <- Sys.time()
alerts <- build_offseason_inactivity_alerts(season = season, force_live = force_live, include_info = include_info, run_time = run_time)
message("Wrote ", nrow(alerts), " new offseason inactivity alert row(s).")
message(offseason_inactivity_path("alerts", season))
message("Review: ", offseason_inactivity_path("review", season))

if (send_email) {
  email_status <- send_offseason_inactivity_email(alerts, season = season, send_empty = send_empty)
  message("Email status: ", email_status$reason[[1]])
  message("Outbox: ", email_status$outbox_path[[1]])
  if (!isTRUE(email_status$sent[[1]]) && !identical(email_status$reason[[1]], "no_alerts")) {
    stop("Offseason inactivity email was requested but not sent: ", email_status$reason[[1]], call. = FALSE)
  }
  if (isTRUE(email_status$sent[[1]]) && nrow(alerts)) {
    issued <- mark_offseason_inactivity_issued(alerts, season = season, run_time = run_time)
    message("Marked ", nrow(alerts), " offseason inactivity violation row(s) as issued. Issued ledger rows: ", nrow(issued))
  }
} else if (mark_issued) {
  issued <- mark_offseason_inactivity_issued(alerts, season = season, run_time = run_time)
  message("Marked ", nrow(alerts), " offseason inactivity violation row(s) as issued without sending email. Issued ledger rows: ", nrow(issued))
}
