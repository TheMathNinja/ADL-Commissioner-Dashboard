source("R/commissioner_alerts.R")
alerts <- tibble::tibble(
  alert_type = c(rep("Illegal Lineup Warning", 4), "Illegal Lineup"),
  severity = c(rep("warning", 4), "violation"),
  franchise = c(rep("NYJ", 4), "KCC"),
  franchise_name = c(rep("New York Jets", 4), "Kansas City Chiefs"),
  conference = "AFC",
  violation_category = "",
  rule = c(rep("No starters on bye", 4), "Starting lineups require minimum 1 PK and 1 PN"),
  observed = c("Kittle on Bye", "Reese on Bye", "Brown on Bye", "Bullock on Bye", "0 PK, 0 PN"),
  details = c(rep("", 4), "Must start 1 additional PK and 1 additional PN")
)
count <- function(text, pattern) sum(gregexpr(pattern, text, fixed = TRUE)[[1]] > 0)
digest <- render_commissioner_alert_email(alerts, 2026, 8, as.Date("2026-11-01"))
stopifnot(count(digest, "**Illegal Lineup**") == 0L,
          count(digest, "New York Jets") == 0L,
          count(digest, "Rule: No starters on bye") == 0L,
          !grepl("Illegal Lineup Warning", digest, fixed = TRUE))
gm <- render_commissioner_gm_alert_email(alerts[1:4, ], 2026, 8)
stopifnot(count(gm, "Rule: No starters on bye") == 1L)
for (player in c("Kittle", "Reese", "Brown", "Bullock")) stopifnot(grepl(player, gm, fixed = TRUE))
stopifnot(identical(alerts$alert_type[[1]], "Illegal Lineup Warning"))
cat("Lineup email grouping tests passed.\n")

mixed <- dplyr::bind_rows(alerts, dplyr::mutate(alerts[1, ], alert_type = "Roster Warning"),
                         dplyr::mutate(alerts[1, ], alert_type = "In-Season Inactivity Violation"))
for (day in 9:15) {
  when <- as.POSIXct(sprintf("2026-11-%02d 05:25:00", day), tz = "America/New_York")
  result <- filter_lineup_email_days(mixed, when)
  stopifnot(nrow(result) == if (day %in% c(10, 11)) 2L else nrow(mixed))
}
stopifnot(nrow(filter_lineup_email_days(alerts, as.POSIXct("2026-11-10 04:59:00", tz = "UTC"))) == 5L,
          nrow(filter_lineup_email_days(alerts, as.POSIXct("2026-11-10 05:00:00", tz = "UTC"))) == 0L,
          nrow(filter_lineup_email_days(alerts, as.POSIXct("2026-07-07 04:00:00", tz = "UTC"))) == 0L,
          nrow(filter_lineup_email_days(alerts[0, ], as.POSIXct("2026-11-10", tz = "UTC"))) == 0L)
stopifnot(grepl("alerts <- filter_lineup_email_days", paste(deparse(body(send_commissioner_alert_email)), collapse = "\n"), fixed = TRUE))
cat("Lineup email weekday policy tests passed.\n")

# Exercise actual delivery routing without network, SMTP, or production files.
fetch_mfl_franchise_recipients <- function(...) tibble(franchise = c("NYJ", "KCC"), email = c("nyj@example.test", "kcc@example.test"))
resolve_commissioner_alert_recipients <- function(...) tibble(email = "commissioner@example.test")
write_commissioner_alert_recipients <- function(...) tempfile()
write_commissioner_alert_outbox <- function(...) tempfile()
commissioner_alert_path <- function(...) tempfile()
conference_cc_email <- function(...) "conference@example.test"
render_commissioner_clean_run_lines <- function(...) character()
delivered <- list()
send_alert_mail <- function(subject, body, to, cc = "", ...) {
  delivered[[length(delivered) + 1L]] <<- list(body = body, to = to, cc = cc)
  list(sent = TRUE, reason = "sent")
}
friday <- as.POSIXct("2026-11-13 05:25:00", tz = "America/New_York")
status <- send_commissioner_alert_email(alerts, 2026, 10, run_time = friday)
stopifnot(status$sent, status$gm_emails_sent == 2L, length(delivered) == 2L,
          all(vapply(delivered, function(x) identical(x$cc, ""), logical(1))),
          !any(vapply(delivered, function(x) "commissioner@example.test" %in% x$to, logical(1))))
delivered <- list()
status <- send_commissioner_alert_email(mixed, 2026, 10, run_time = friday)
commissioner_mail <- Filter(function(x) "commissioner@example.test" %in% x$to, delivered)
stopifnot(status$sent, length(commissioner_mail) == 1L,
          !grepl("**Illegal Lineup**", commissioner_mail[[1]]$body, fixed = TRUE),
          grepl("In-Season Inactivity", commissioner_mail[[1]]$body, fixed = TRUE),
          grepl("Roster Warning", commissioner_mail[[1]]$body, fixed = TRUE))
delivered <- list()
status <- send_commissioner_alert_email(dplyr::mutate(alerts, franchise = NA_character_), 2026, 10, run_time = friday)
stopifnot(!status$sent, status$reason == "offender_franchise_not_found", length(delivered) == 0L)
fetch_mfl_franchise_recipients <- function(...) tibble(franchise = character(), email = character())
status <- send_commissioner_alert_email(alerts, 2026, 10, run_time = friday)
stopifnot(!status$sent, grepl("offender_email_not_found", status$reason), length(delivered) == 0L)
fetch_mfl_franchise_recipients <- function(...) tibble(franchise = c("NYJ", "KCC"), email = c("nyj@example.test", "kcc@example.test"))
send_alert_mail <- function(...) list(sent = FALSE, reason = "smtp_rejected")
status <- send_commissioner_alert_email(alerts, 2026, 10, run_time = friday)
stopifnot(!status$sent, grepl("gm_email_failed", status$reason))
cat("GM-only lineup routing, mixed digests, and delivery failure regressions passed.\n")
