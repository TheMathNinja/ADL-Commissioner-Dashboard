library(dplyr)
source("R/config_helpers.R")
source("R/saladj_contract_admin.R")
source("R/saladj_notification_policy.R")
rows <- data.frame(FRAN=c("NYG","NYG","PHI"),
  PLAYER=c("Jaylen Wright","Robert Spillane","Will McDonald"),
  DATE=c("10/27/2026 10:26:49","10/27/2026 10:27:04","10/27/2026 15:33:32"),
  SALARY=c(2.1,3.24,3.7), stringsAsFactors=FALSE)
entries <- data.frame(franchise=c("NYG","NYG"),description=c("J. Wright","R. Spillane"),
  entered_at=c("10/27/2026","10/27/2026"),input_salary=c(2.1,3.24))
stopifnot(identical(saladj_contract_admin_status(rows,entries),c("recorded","recorded","missing")))
all_entered <- rbind(entries,data.frame(franchise="PHI",description="W. McDonald",entered_at="10/27/2026",input_salary=3.7))
stopifnot(all(saladj_contract_admin_status(rows,all_entered)=="recorded"))
# Incorrect recorded rows need correction, not a second add request.
wrong <- entries;wrong$input_salary[1] <- 9
stopifnot(saladj_contract_admin_status(rows,wrong)[1]=="recorded")
wrong <- entries;wrong$franchise[1] <- "DAL"
stopifnot(saladj_contract_admin_status(rows,wrong)[1]=="recorded_needs_review")
old <- entries;old$entered_at[1] <- "10/20/2026"
stopifnot(saladj_contract_admin_status(rows,old)[1]=="missing")
stopifnot(all(saladj_contract_admin_status(rows,entries[FALSE,])=="missing"))
cash <- data.frame(FRAN="KCC",PLAYER="Cash Trade",DATE="10/21/2026 13:22:02",SALARY=-1.7)
cash_entry <- data.frame(franchise="KCC",description="Cash Trade",entered_at="10/21/2026",input_salary=-1.7)
stopifnot(saladj_contract_admin_status(cash,cash_entry)=="recorded")
cash_entry$input_salary <- 1.7
stopifnot(saladj_contract_admin_status(cash,cash_entry)=="missing")
cash_entry$input_salary <- -1.7;cash_entry$entered_at <- "10/20/2026"
stopifnot(saladj_contract_admin_status(cash,cash_entry)=="missing")
reversed <- rows;reversed[["RVSD?"]] <- "x"
stopifnot(all(saladj_contract_admin_status(reversed,entries)=="reversed"))
report <- tibble(issue=c("MISSING_ENTRY","WRONG_AMOUNT","PENDING_MFL_ENTRY"),
  stage=c("SalAdj Curator -> Contract Admin Sal Adj","Contract Admin history -> MFL","Contract Admin totals -> MFL"),
  issue_key=c("missing","wrong","pending"))
utc <- function(x) as.POSIXct(x,tz="UTC")
wednesday <- saladj_checker_email_findings(report,utc("2026-10-28 09:26:00"))
stopifnot(identical(wednesday$issue,"WRONG_AMOUNT"))
monday <- saladj_checker_email_findings(report,utc("2026-11-02 10:17:00"))
stopifnot(identical(monday$issue,c("WRONG_AMOUNT","PENDING_MFL_ENTRY")),
  monday$issue_key[2]=="pending|snapshot-reminder-2026-11-02",
  saladj_pending_reminder_window(utc("2026-10-26 09:17:00")),
  !saladj_pending_reminder_window(utc("2026-11-01 23:00:00")),
  !saladj_pending_reminder_window(utc("2026-11-02 17:00:00")),
  !saladj_pending_reminder_window(utc("2026-11-03 10:17:00")))
next_monday <- saladj_checker_email_findings(report,utc("2026-11-09 10:17:00"))
stopifnot(next_monday$issue_key[2]!=monday$issue_key[2],
  identical(saladj_checker_email_findings(report[FALSE,]),report[FALSE,]))
# Exercise the real send function without SMTP calls or sheet writes.
source("R/saladj_email.R")
test_env <- new.env(parent=globalenv())
for (expression in parse("scripts/run_saladjcurator.R")) {
  if (is.call(expression) && identical(expression[[1]],as.name("<-")) &&
      identical(expression[[2]],as.name("send_saladj_email"))) eval(expression,test_env)
}
test_env$contract_admin_saladj_entries <- function(...) all_entered
test_env$write_commissioner_alert_outbox <- function(...) "test-outbox"
test_env$resolve_commissioner_alert_recipients <- function(...) stop("Unexpected email recipient lookup")
rows$CONF <- "NFC"
rows$YEARS <- c(1,3,1)
rows$CONTRACT <- c("2026 UFA","2026 UFA","2023 3.18^")
quiet <- test_env$send_saladj_email(rows,"test.csv","test",season=2026)
stopifnot(!quiet$sent,quiet$reason=="already_recorded_in_contract_admin")
test_env$contract_admin_saladj_entries <- function(...) entries
test_env$resolve_commissioner_alert_recipients <- function(...) tibble(email="test@example.test")
test_env$send_alert_mail <- function(subject,body,...) {
  stopifnot(grepl("Will McDonald",body,fixed=TRUE),!grepl("Jaylen Wright|Robert Spillane",body))
  list(sent=TRUE,reason="test")
}
stopifnot(test_env$send_saladj_email(rows,"test.csv","test",season=2026)$sent)
test_env$contract_admin_saladj_entries <- function(...) stop("Sheet read unavailable")
failure <- tryCatch(test_env$send_saladj_email(rows,"test.csv","test",season=2026),error=identity)
stopifnot(inherits(failure,"error"),conditionMessage(failure)=="Sheet read unavailable")
message("PASS: digest excludes recorded/reversed entries; checker errors stay daily; pending reminders are Monday morning, once per week, DST-aware.")
