library(dplyr)
library(readr)

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

arg_flag <- function(name) paste0("--", name) %in% commandArgs(trailingOnly = TRUE)

current_commissioner_alert_week <- function(today = Sys.Date(), season = get_current_season()) {
  week_one_start <- as.Date(Sys.getenv("ADL_WEEK_ONE_START", unset = paste0(season, "-09-10")))
  if (is.na(week_one_start) || today < week_one_start) return(NA_integer_)
  max(1L, min(17L, floor(as.numeric(today - week_one_start) / 7) + 1L))
}

recipient <- arg_value("to", Sys.getenv("ADL_ALERT_TEST_TO", unset = "fili.mikey@gmail.com"))
season <- suppressWarnings(as.integer(arg_value("season", Sys.getenv("CURRENT_SEASON", unset = get_current_season()))))
week <- suppressWarnings(as.integer(arg_value("week", Sys.getenv("ADL_ALERT_TEST_WEEK", unset = NA_character_))))
mode <- arg_value("mode", Sys.getenv("ADL_ALERT_MODE", unset = "check"))
gm_count <- suppressWarnings(as.integer(arg_value("gm-count", Sys.getenv("ADL_ALERT_TEST_GM_COUNT", unset = "2"))))
force_live <- arg_flag("force-live") || tolower(Sys.getenv("ADL_ALERT_FORCE_LIVE", unset = "true")) %in% c("1", "true", "yes")
send_empty <- arg_flag("send-empty") || tolower(Sys.getenv("ADL_ALERT_SEND_EMPTY", unset = "true")) %in% c("1", "true", "yes")
auto_week <- !arg_flag("no-auto-week") && tolower(Sys.getenv("ADL_ALERT_AUTO_WEEK", unset = "true")) %in% c("1", "true", "yes")

if (is.na(season)) stop("Provide a valid --season or CURRENT_SEASON.", call. = FALSE)
if (!mode %in% c("check", "offseason", "inseason")) {
  stop("--mode must be one of: check, offseason, inseason.", call. = FALSE)
}
if (is.na(gm_count) || gm_count < 0L) gm_count <- 2L

if (is.na(week) && mode %in% c("check", "inseason") && auto_week) {
  week <- current_commissioner_alert_week(season = season)
  if (!is.na(week)) message("Auto-selected Week ", week, " for in-season alerts.")
}

include_offseason <- mode %in% c("check", "offseason", "inseason")
include_inseason <- mode %in% c("check", "inseason") && !is.na(week)
checked_at <- Sys.time()
checked_date <- Sys.Date()

alerts <- build_commissioner_alerts(
  season = season,
  week = if (is.na(week)) NULL else week,
  include_offseason = include_offseason,
  include_inseason = include_inseason,
  force_live = force_live,
  checked_at = checked_at
)

if (mode %in% c("check", "inseason") && exists("build_inseason_inactivity_alerts", mode = "function")) {
  inactivity_alerts <- build_inseason_inactivity_alerts(
    season = season,
    force_live = force_live,
    run_time = checked_at,
    persist = FALSE
  )
  if (nrow(inactivity_alerts)) {
    inactivity_alerts <- inactivity_alerts |>
      mutate(
        week = if ("week" %in% names(inactivity_alerts)) .data$week else (if (is.na(.env$week)) NA_integer_ else .env$week),
        checked_at = format(as.POSIXct(.env$checked_at, tz = "UTC"), "%Y-%m-%d %H:%M:%S %Z")
      ) |>
      select(any_of(names(alerts)), everything())
    alerts <- bind_rows(alerts, inactivity_alerts) |>
      select(any_of(names(alerts)))
  }
}

digest_body <- render_commissioner_alert_email(
  alerts,
  season = season,
  week = if (is.na(week)) NULL else week,
  checked_date = checked_date,
  gm_emails_sent = nrow(alerts) > 0,
  title = paste0("ADL Commissioner Alerts LIVE DRY RUN - ", commissioner_alert_date_label(checked_date), if (!is.na(week)) paste0(" Week ", week) else "")
)
digest_outbox <- write_commissioner_alert_outbox(
  digest_body,
  season = season,
  week = if (is.na(week)) NULL else week,
  name = "email_outbox_live_dry_run_commissioner_digest"
)

status_rows <- list(tibble(
  message = "commissioner_digest",
  franchise = NA_character_,
  sent = isTRUE(send_alert_mail(
    subject = paste0("LIVE DRY RUN ADL Commissioner Alerts ", commissioner_alert_date_label(checked_date), if (!is.na(week)) paste0(" Week ", week) else ""),
    body = digest_body,
    to = recipient
  )$sent),
  outbox_path = digest_outbox
))

offender_franchises <- alerts |>
  filter(!is.na(.data$franchise), nzchar(.data$franchise)) |>
  mutate(franchise_sort_order = commissioner_alert_franchise_order(.data$franchise)) |>
  arrange(.data$franchise_sort_order, .data$franchise) |>
  distinct(.data$franchise) |>
  pull(.data$franchise)

if (gm_count > 0L && length(offender_franchises)) {
  for (franchise in head(offender_franchises, gm_count)) {
    franchise_alerts <- alerts |> filter(.data$franchise == .env$franchise)
    title_prefix <- if (all(franchise_alerts$severity == "warning", na.rm = TRUE)) {
      "ADL Roster Warning LIVE DRY RUN"
    } else {
      "ADL Roster Violation LIVE DRY RUN"
    }
    gm_body <- render_commissioner_gm_alert_email(
      franchise_alerts,
      season = season,
      week = if (is.na(week)) NULL else week,
      checked_date = checked_date,
      title_prefix = title_prefix
    )
    gm_outbox <- write_commissioner_alert_outbox(
      gm_body,
      season = season,
      week = if (is.na(week)) NULL else week,
      name = paste0("email_outbox_live_dry_run_gm_", safe_file_slug(franchise))
    )
    status <- send_alert_mail(
      subject = paste0("LIVE DRY RUN ", title_prefix, " ", commissioner_alert_date_label(checked_date), if (!is.na(week)) paste0(" Week ", week) else ""),
      body = gm_body,
      to = recipient
    )
    status_rows[[length(status_rows) + 1L]] <- tibble(
      message = "gm_dry_run",
      franchise = franchise,
      sent = isTRUE(status$sent),
      outbox_path = gm_outbox
    )
  }
}

status_tbl <- bind_rows(status_rows)
status_path <- commissioner_alert_path("email_live_dry_run_status", season, if (is.na(week)) NULL else week)
write_csv(status_tbl, status_path, na = "")

message("Live dry run produced ", nrow(alerts), " alert row(s).")
message("Recipient: ", recipient)
message("Status: ", status_path)
message("Outboxes:")
message(paste(status_tbl$outbox_path, collapse = "\n"))

if (!send_empty && !nrow(alerts)) {
  quit(save = "no")
}
if (any(!status_tbl$sent)) {
  stop("One or more live dry-run emails were not sent.", call. = FALSE)
}
