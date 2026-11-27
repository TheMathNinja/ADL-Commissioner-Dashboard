library(dplyr)
library(readr)
source("R/config_helpers.R")
source("R/saladj_contract_admin.R")
source("R/saladj_notification_policy.R")
source("R/saladj_action_report.R")

# Load pure checker functions, not its live Sheet/MFL processing.
expressions <- parse("scripts/check_saladj_reconciliation.R")
for (expression in expressions) {
  if (is.call(expression) && identical(expression[[1]], as.name("<-")) &&
      is.call(expression[[3]]) && identical(expression[[3]][[1]], as.name("function"))) eval(expression)
}
rows <- tibble(CONF = "NFC", DATE = "11/15/2026 10:00:00", FRAN = "NYG",
  PLAYER = "Jaylen Wright", SALARY = "2.1", YEARS = "1", CONTRACT = "2026 UFA")
sheet <- tibble(franchise = character(), description = character(),
  entered_at = character(), input_salary = double())
# Frozen replay of the November 16 DET/ATL/TEN pending-entry incident.
pending <- tibble(issue = "PENDING_MFL_ENTRY", expected_franchise = c("DET", "ATL", "TEN"),
  actual_franchise = expected_franchise, player = "2026 ADJ total",
  expected_amount = c(31.31, 103.66, 0), actual_amount = c(32.87, 119.73, 2.46),
  mfl_description = "MFL roster-page Salary Adjustments total", transaction_date = "", mfl_entered_at = "",
  action = "Enter pending adjustments before snapshot; confirm MFL entries, then mark ENTD?.",
  stage = "Contract Admin 2026 ADJ totals -> MFL roster page", actual_system = "Contract Admin Sal Adj totals",
  discrepancy_nature = "PENDING_MFL_ENTRY", sheet_tab = c("NFC Sal Adj", "NFC Sal Adj", "AFC Sal Adj"),
  sheet_entry_total = actual_amount, sheet_entered_total = expected_amount,
  sheet_pending_total = c(1.56, 16.07, 2.46),
  pending_entry_details = c("T. McKee ($1.56; NFC Sal Adj row 154)",
    "J. Fields ($16.07; NFC Sal Adj row 153)", "D. Payne ($2.46; AFC Sal Adj row 125)"),
  mfl_entry_total = expected_amount, total_difference = sheet_pending_total,
  issue_key = paste0("pending-", expected_franchise))
issued <- tibble(issue_key = character(), issued_at = character())
monday <- as.POSIXct("2026-11-16 10:22:00", tz = "UTC")
wednesday <- as.POSIXct("2026-11-18 10:22:00", tz = "UTC")
plan <- prepare_saladj_action_report(rows, sheet, pending, issued, rows[FALSE, ], 2026, monday)
body <- render_saladj_action_report(plan, rows, 2026)
category <- function(text, number) {
  start <- regexpr(paste0(number, ". Items"), text, fixed = TRUE)[[1]]
  end <- if (number < 3) regexpr(paste0(number + 1, ". Items"), text, fixed = TRUE)[[1]] - 1 else nchar(text)
  substr(text, start, end)
}
stopifnot(length(plan$new_keys) == 4L,
  grepl("1. Items to Enter into Contract Admin and MFL", body, fixed = TRUE),
  grepl("2. Items in Contract Admin to be Entered into MFL", body, fixed = TRUE),
  grepl("3. Items that Need Correcting in Contract Admin or MFL", body, fixed = TRUE),
  grepl("Enter these missing source contracts in Contract Admin and verify the calculated adjustment.",
    category(body, 1), fixed = TRUE),
  !grepl("Compare with MFL first:", category(body, 1), fixed = TRUE),
  !grepl("Contract salary below is not the penalty amount.", category(body, 1), fixed = TRUE),
  grepl("Jaylen Wright", category(body, 1), fixed = TRUE),
  grepl("TEN | $2.46", category(body, 2), fixed = TRUE),
  grepl("DET | $32.87", category(body, 2), fixed = TRUE),
  grepl("ATL | $119.73", category(body, 2), fixed = TRUE),
  !grepl("Error Type:", body, fixed = TRUE))

received <- tibble(issue_key = plan$new_keys, issued_at = "test")
stopifnot(!length(prepare_saladj_action_report(rows, sheet, pending, received, rows, 2026, monday)$new_keys))
# Old digest receipts transfer; outstanding context does not itself trigger email.
legacy <- prepare_saladj_action_report(rows, sheet, pending, issued, rows, 2026, wednesday)
stopifnot(!length(legacy$new_keys), !any(legacy$entry_new),
  grepl("Previously reported; still outstanding:", render_saladj_action_report(legacy, rows, 2026), fixed = TRUE))
group_rows <- bind_rows(rows, mutate(rows, PLAYER = "New One"), mutate(rows, PLAYER = "Prior Two"),
                        mutate(rows, PLAYER = "New Two"))
group_plan <- prepare_saladj_action_report(group_rows, sheet, pending, issued, group_rows[c(1,3), ], 2026, wednesday)
group_body <- strsplit(category(render_saladj_action_report(group_plan, group_rows, 2026), 1), "\n", fixed = TRUE)[[1]]
old_header <- which(group_body == "Previously reported; still outstanding:")
new_header <- which(group_body == "New entry request:")
stopifnot(length(old_header) == 1L, length(new_header) == 1L,
  old_header < grep("Jaylen Wright", group_body), grep("Prior Two", group_body) < new_header,
  new_header < grep("New One", group_body), grep("New One", group_body) < grep("New Two", group_body))
next_monday <- as.POSIXct("2026-11-23 10:22:00", tz = "UTC")
stopifnot(length(prepare_saladj_action_report(rows, sheet, pending, received, rows, 2026, next_monday)$new_keys) == 3L)
wrong <- pending[1, ]; wrong$issue <- "WRONG_AMOUNT"; wrong$actual_system <- "MFL"
wrong$player <- "Test Player"; wrong$issue_key <- "independent-wrong-amount"
mixed <- prepare_saladj_action_report(rows, sheet, bind_rows(pending, wrong), received, rows, 2026, wednesday)
stopifnot(identical(mixed$new_keys, "independent-wrong-amount"),
  grepl("Test Player", category(render_saladj_action_report(mixed, rows, 2026), 3), fixed = TRUE))
recorded <- tibble(franchise = "NYG", description = "J. Wright", entered_at = "11/15/2026", input_salary = 9)
stopifnot(!nrow(prepare_saladj_action_report(rows, recorded, pending, received, rows, 2026, wednesday)$entries))
reversed <- rows; reversed[["RVSD?"]] <- "x"
stopifnot(!nrow(prepare_saladj_action_report(reversed, sheet, pending, issued, rows, 2026, monday)$entries))

# Replay the two audited October entries plus a genuinely unentered cash trade.
cash <- read_csv("data/manual_saladj_adjustments_2026.csv", show_col_types = FALSE,
  col_types = cols(.default = col_character())) |>
  filter(FRAN %in% c("NOS", "WAS"), DATE == "8/26/2026 08:41:41")
cash_sheet <- tibble(franchise = c("NOS", "WAS"), description = "Cash Trade",
  entered_at = c("10/14/2026", "2026-10-14"), input_salary = c(-0.05, 0.05))
stopifnot(nrow(cash) == 2L, all(saladj_contract_admin_status(cash, cash_sheet, 2026) == "recorded"))
unrelated <- cash[cash$FRAN == "WAS", ]; unrelated$DATE <- "8/27/2026 08:41:41"
unrelated$NOTES <- "Unentered cash trade"
cash_rows <- bind_rows(cash, unrelated)
cash_plan <- prepare_saladj_action_report(cash_rows, cash_sheet, pending[FALSE, ], issued, cash, 2026, wednesday)
stopifnot(identical(cash_plan$entries$DATE, unrelated$DATE), length(cash_plan$new_keys) == 1L,
  !grepl("8/26/2026", render_saladj_action_report(cash_plan, cash_rows, 2026), fixed = TRUE))
wrong_sheet <- cash_sheet
wrong_sheet$description[1] <- "Unrelated player penalty"
wrong_sheet$input_salary[2] <- 0.054
stopifnot(all(saladj_contract_admin_status(cash, wrong_sheet, 2026) == "missing"))
stopifnot(sum(saladj_contract_admin_status(bind_rows(cash, cash[1, ]), cash_sheet, 2026) == "missing") == 1L)

# Exercise the actual delivery block with local files and a fake transport.
delivery <- Filter(function(x) is.call(x) && identical(x[[1]], as.name("if")) &&
  grepl("send_email && \\(combined_action_email", paste(deparse(x[[2]]), collapse = " ")), expressions)
stopifnot(length(delivery) == 1L)
workflow <- readLines(".github/workflows/update_dashboard.yml")
curator <- readLines("scripts/run_saladjcurator.R")
stopifnot(any(grepl("ADL_SALADJ_COMBINED_ACTION_EMAIL: 'true'", workflow, fixed = TRUE)),
  any(grepl('if (send_email && Sys.getenv("ADL_SALADJ_COMBINED_ACTION_EMAIL") != "true")', curator, fixed = TRUE)),
  any(grepl("steps.reconciliation.outputs.mail_unconfirmed", workflow, fixed = TRUE)))
old_dir <- getwd()
scratch <- tempfile("saladj-action-test-"); dir.create(scratch)
setwd(scratch)
dir.create("data")
readr::write_csv(rows, "data/source.csv")
readr::write_csv(tibble(latest_archive_filename = "test.csv"), "data/run_metadata.csv")
send_email <- TRUE; combined_action_email <- TRUE
email_report <- pending[FALSE, ]; error_report <- pending
saladj_csv <- "data/source.csv"; issued_csv <- "data/issued.csv"
sheet_entries <- sheet; season <- 2026; email_to <- "test@example.invalid"
send_alert_mail <- function(...) list(sent = FALSE, reason = "simulated SMTP failure")
failure <- tryCatch(suppressWarnings(eval(delivery[[1]])), error = identity)
stopifnot(inherits(failure, "error"), !file.exists(issued_csv),
  !file.exists("data/SalAdjCurator_last_emailed.csv"))
old_output <- Sys.getenv("GITHUB_OUTPUT")
old_defer <- Sys.getenv("DEFER_SALADJ_MAIL_FAILURE")
Sys.setenv(GITHUB_OUTPUT = file.path(scratch, "outputs"), DEFER_SALADJ_MAIL_FAILURE = "true")
suppressWarnings(eval(delivery[[1]]))
stopifnot("mail_unconfirmed=true" %in% readLines("outputs"), !file.exists(issued_csv),
  !file.exists("data/SalAdjCurator_last_emailed.csv"))
Sys.setenv(GITHUB_OUTPUT = old_output, DEFER_SALADJ_MAIL_FAILURE = old_defer)
sent_count <- 0L
send_alert_mail <- function(...) { sent_count <<- sent_count + 1L; list(sent = TRUE) }
eval(delivery[[1]])
stopifnot(sent_count == 1L, file.exists(issued_csv), file.exists("data/SalAdjCurator_last_emailed.csv"))
eval(delivery[[1]])
stopifnot(sent_count == 1L)
setwd(old_dir)
message("PASS: one combined action email; TEN/DET/ATL context; legacy receipts; independent errors; failed delivery retries without consuming receipts.")
