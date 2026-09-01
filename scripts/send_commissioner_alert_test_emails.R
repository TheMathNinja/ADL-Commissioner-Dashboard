library(dplyr)
library(tibble)

source("R/commissioner_alerts.R")

arg_value <- function(name, default = NULL) {
  args <- commandArgs(trailingOnly = TRUE)
  prefix <- paste0("--", name, "=")
  matched <- args[startsWith(args, prefix)]
  if (!length(matched)) return(default)
  sub(prefix, "", matched[[1]], fixed = TRUE)
}

recipient <- arg_value("to", Sys.getenv("ADL_ALERT_TEST_TO", unset = "fili.mikey@gmail.com"))
season <- suppressWarnings(as.integer(arg_value("season", Sys.getenv("CURRENT_SEASON", unset = get_current_season()))))
week <- suppressWarnings(as.integer(arg_value("week", Sys.getenv("ADL_ALERT_TEST_WEEK", unset = "11"))))
checked_date <- as.Date(arg_value("date", Sys.getenv("ADL_ALERT_TEST_DATE", unset = Sys.Date())))

if (is.na(season)) stop("Provide a valid --season or CURRENT_SEASON.", call. = FALSE)
if (is.na(week)) stop("Provide a valid --week or ADL_ALERT_TEST_WEEK.", call. = FALSE)
if (is.na(checked_date)) stop("Provide a valid --date or ADL_ALERT_TEST_DATE.", call. = FALSE)

sample_alerts <- tibble(
  alert_type = c(
    "Illegal Lineup Warning",
    "Illegal Lineup Warning",
    "Illegal Lineup Warning",
    "Illegal Lineup Warning",
    "Salary Cap Warning",
    "Roster Cap Violation"
  ),
  severity = c("warning", "warning", "warning", "warning", "warning", "violation"),
  conference = c("NFC", "NFC", "NFC", "NFC", "NFC", "NFC"),
  franchise = c("ATL", "ATL", "ATL", "ATL", "DET", "DET"),
  franchise_name = c(
    "Atlanta Falcons",
    "Atlanta Falcons",
    "Atlanta Falcons",
    "Atlanta Falcons",
    "Detroit Lions",
    "Detroit Lions"
  ),
  rule = c(
    "Starting lineups require 21 total starters, including minimum 1 PN",
    "Starting lineups require 12 defensive starters",
    "No starters with (S), (I), (H), or (O) designation",
    "No starters on bye",
    "Average active roster salary must remain below franchise salary cap",
    "Maximum 68 players on Active Roster + Taxi Squad"
  ),
  observed = c(
    "20 total starters (0 PN)",
    "11 defensive starters (0 LB)",
    "Bryant, Coby SEA S",
    "Brown, A.J. NEP WR on Bye in Week 11.  Must replace with eligible RB/WR/TE.",
    "$254.20m current weekly salary would exceed Detroit Lions franchise cap of $251.85m at the next snapshot",
    "69 active/taxi players"
  ),
  details = c(
    "Must start 1 additional PN",
    "Must start 1 additional LB",
    "Current designation is (O).",
    "",
    "Required: Bring live salary down to $249.50m to be cap-compliant at next snapshot.",
    "1 above maximum"
  )
)

commissioner_body <- render_commissioner_alert_email(
  sample_alerts,
  season = season,
  week = week,
  checked_date = checked_date,
  gm_emails_sent = TRUE,
  title = paste0("ADL Commissioner Alerts TEST - ", commissioner_alert_date_label(checked_date), " Week ", week)
)

atl_alerts <- sample_alerts |> filter(.data$franchise == "ATL")
atl_body <- render_commissioner_gm_alert_email(
  atl_alerts,
  season = season,
  week = week,
  checked_date = checked_date,
  title_prefix = "ADL Roster Warning TEST"
)

det_alerts <- sample_alerts |> filter(.data$franchise == "DET")
det_body <- render_commissioner_gm_alert_email(
  det_alerts,
  season = season,
  week = week,
  checked_date = checked_date,
  title_prefix = "ADL Roster Violation TEST"
)

outbox_paths <- c(
  write_commissioner_alert_outbox(commissioner_body, season = season, week = week, name = "email_outbox_test_commissioner_digest"),
  write_commissioner_alert_outbox(atl_body, season = season, week = week, name = "email_outbox_test_gm_atl_lineup_warning"),
  write_commissioner_alert_outbox(det_body, season = season, week = week, name = "email_outbox_test_gm_det_cap_roster")
)

statuses <- bind_rows(
  tibble(
    message = "commissioner_digest",
    sent = isTRUE(send_alert_mail(
      subject = paste0("TEST ADL Commissioner Alerts ", commissioner_alert_date_label(checked_date), " Week ", week),
      body = commissioner_body,
      to = recipient
    )$sent)
  ),
  tibble(
    message = "gm_atl_lineup_warning",
    sent = isTRUE(send_alert_mail(
      subject = paste0("TEST ADL Roster Warning ", commissioner_alert_date_label(checked_date), " Week ", week),
      body = atl_body,
      to = recipient
    )$sent)
  ),
  tibble(
    message = "gm_det_cap_roster",
    sent = isTRUE(send_alert_mail(
      subject = paste0("TEST ADL Roster Violation ", commissioner_alert_date_label(checked_date), " Week ", week),
      body = det_body,
      to = recipient
    )$sent)
  )
)

status_path <- commissioner_alert_path("email_test_status", season, week)
write_csv(statuses, status_path, na = "")

message("Wrote test email outboxes:")
message(paste(outbox_paths, collapse = "\n"))
message("Wrote test email status: ", status_path)
message("Recipient: ", recipient)

if (any(!statuses$sent)) {
  stop("One or more test emails were not sent.", call. = FALSE)
}
