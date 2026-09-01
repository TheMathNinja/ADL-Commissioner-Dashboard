library(dplyr)

source("R/commissioner_alerts.R")
if (file.exists("R/inseason_inactivity_monitor.R")) {
  source("R/inseason_inactivity_monitor.R")
}

arg_value <- function(name, default = NULL) {
  args <- commandArgs(trailingOnly = TRUE)
  prefix <- paste0("--", name, "=")
  matched <- args[startsWith(args, prefix)]
  if (!length(matched)) return(default)
  sub(prefix, "", matched[[1]], fixed = TRUE)
}

arg_flag <- function(name) {
  paste0("--", name) %in% commandArgs(trailingOnly = TRUE)
}

season <- suppressWarnings(as.integer(arg_value("season", Sys.getenv("CURRENT_SEASON", unset = get_current_season()))))
week <- suppressWarnings(as.integer(arg_value("week", Sys.getenv("ADL_ALERT_WEEK", unset = NA_character_))))
mode <- arg_value("mode", Sys.getenv("ADL_ALERT_MODE", unset = "check"))
cutdown_id <- arg_value("cutdown", Sys.getenv("ADL_ALERT_CUTDOWN_ID", unset = ""))
force_live <- arg_flag("force-live") || tolower(Sys.getenv("ADL_ALERT_FORCE_LIVE", unset = "false")) %in% c("1", "true", "yes")
send_email <- arg_flag("send-email") || tolower(Sys.getenv("ADL_ALERT_SEND_EMAIL", unset = "false")) %in% c("1", "true", "yes")
send_empty <- arg_flag("send-empty") || tolower(Sys.getenv("ADL_ALERT_SEND_EMPTY", unset = "false")) %in% c("1", "true", "yes")
auto_week <- !arg_flag("no-auto-week") && tolower(Sys.getenv("ADL_ALERT_AUTO_WEEK", unset = "true")) %in% c("1", "true", "yes")
skip_completed_cutdown <- arg_flag("skip-completed-cutdown") || tolower(Sys.getenv("ADL_ALERT_SKIP_COMPLETED_CUTDOWN", unset = "false")) %in% c("1", "true", "yes")

if (is.na(season)) stop("Provide a valid --season or CURRENT_SEASON.", call. = FALSE)

current_commissioner_alert_week <- function(today = Sys.Date(), season = get_current_season()) {
  week_one_start <- as.Date(Sys.getenv("ADL_WEEK_ONE_START", unset = paste0(season, "-09-10")))
  if (is.na(week_one_start) || today < week_one_start) return(NA_integer_)
  max(1L, min(17L, floor(as.numeric(today - week_one_start) / 7) + 1L))
}

if (is.na(week) && mode %in% c("snapshot", "check", "inseason") && auto_week) {
  week <- current_commissioner_alert_week(season = season)
  if (!is.na(week)) message("Auto-selected Week ", week, " for in-season alerts.")
}

if (identical(mode, "snapshot")) {
  if (is.na(week)) {
    message("No current in-season week found; skipping designation snapshot.")
    quit(save = "no")
  }
  snapshot <- cache_designation_snapshot(season = season, week = week, force_live = TRUE)
  message("Wrote lineup designation snapshot with ", nrow(snapshot), " rows.")
  message(commissioner_alert_path("designation_snapshot", season, week))
  quit(save = "no")
}

if (!mode %in% c("check", "offseason", "inseason", "cutdown")) {
  stop("--mode must be one of: snapshot, check, offseason, inseason, cutdown.", call. = FALSE)
}

if (identical(mode, "cutdown")) {
  if (!nzchar(cutdown_id)) stop("--cutdown is required when --mode=cutdown.", call. = FALSE)
  marker_path <- file.path(
    commissioner_alert_report_dir(),
    paste0("commissioner_alert_", cutdown_id, "_completed_", Sys.Date(), "_", season, ".txt")
  )
  if (isTRUE(skip_completed_cutdown) && file.exists(marker_path)) {
    message("Skipping completed roster cutdown run because marker exists: ", marker_path)
    quit(save = "no")
  }

  cutdown <- build_roster_cutdown_alerts(
    season = season,
    cutdown_id = cutdown_id,
    force_live = force_live
  )
  alerts <- cutdown$alerts
  compliance <- cutdown$compliance
  alerts_path <- commissioner_alert_path(paste0("alerts_", cutdown_id), season)

  message("Wrote ", nrow(alerts), " commissioner roster cutdown alert row(s).")
  message(alerts_path)
  message(compliance$compliant_teams[[1]], " teams roster compliant.")

  if (send_email) {
    email_status <- send_commissioner_alert_email(
      alerts,
      season = season,
      week = NULL,
      send_empty = TRUE,
      digest_subject = cutdown$rule$report_subject,
      gm_subject = cutdown$rule$violation_subject,
      digest_title = cutdown$rule$report_subject,
      gm_title_prefix = cutdown$rule$violation_subject,
      compliant_teams = compliance$compliant_teams[[1]]
    )
    message("Email status: ", email_status$reason[[1]])
    message("Outbox: ", email_status$outbox_path[[1]])
    if (!isTRUE(email_status$sent[[1]])) {
      stop("Roster cutdown email was requested but not sent: ", email_status$reason[[1]], call. = FALSE)
    }
    dir.create(dirname(marker_path), recursive = TRUE, showWarnings = FALSE)
    writeLines(
      c(
        paste0("cutdown_id=", cutdown_id),
        paste0("season=", season),
        paste0("sent_at=", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"))
      ),
      marker_path
    )
  }

  quit(save = "no")
}

include_offseason <- mode %in% c("check", "offseason", "inseason")
include_inseason <- mode %in% c("check", "inseason") && !is.na(week)

alerts <- build_commissioner_alerts(
  season = season,
  week = if (is.na(week)) NULL else week,
  include_offseason = include_offseason,
  include_inseason = include_inseason,
  force_live = force_live
)

if (mode %in% c("check", "inseason") && exists("build_inseason_inactivity_alerts", mode = "function")) {
  inactivity_alerts <- build_inseason_inactivity_alerts(season = season, force_live = force_live)
  if (nrow(inactivity_alerts)) {
    inactivity_alerts <- inactivity_alerts |>
      mutate(
        week = if ("week" %in% names(inactivity_alerts)) .data$week else (if (is.na(.env$week)) NA_integer_ else .env$week),
        checked_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")
      ) |>
      select(any_of(names(alerts)), everything())
    alerts <- bind_rows(alerts, inactivity_alerts) |>
      select(any_of(names(alerts)))
    write_csv(alerts, commissioner_alert_path("alerts", season, if (is.na(week)) NULL else week), na = "")
    write_commissioner_alert_report(alerts, season = season, week = if (is.na(week)) NULL else week, checked_at = Sys.time())
  }
}

alerts_path <- commissioner_alert_path("alerts", season, if (is.na(week)) NULL else week)
message("Wrote ", nrow(alerts), " commissioner alert row(s).")
message(alerts_path)

if (send_email) {
  email_status <- send_commissioner_alert_email(
    alerts,
    season = season,
    week = if (is.na(week)) NULL else week,
    send_empty = send_empty
  )
  message("Email status: ", email_status$reason[[1]])
  message("Outbox: ", email_status$outbox_path[[1]])
  if (!isTRUE(email_status$sent[[1]]) && !identical(email_status$reason[[1]], "no_alerts")) {
    stop("Commissioner alert email was requested but not sent: ", email_status$reason[[1]], call. = FALSE)
  }
}
