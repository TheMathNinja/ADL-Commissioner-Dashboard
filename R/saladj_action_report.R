# The daily checker owns delivery; the Curator only publishes its source data.
source("R/saladj_email.R")

saladj_action_row_keys <- function(rows) {
  columns <- c("CONF", "DATE", "FRAN", "PLAYER", "SALARY", "YEARS", "CONTRACT")
  values <- lapply(columns, function(column) {
    value <- if (column %in% names(rows)) as.character(rows[[column]]) else rep("", nrow(rows))
    value[is.na(value)] <- ""
    vapply(trimws(value), utils::URLencode, character(1), reserved = TRUE)
  })
  if (!nrow(rows)) return(character())
  paste0("saladj-action|", do.call(paste, c(values, sep = "|")))
}

prepare_saladj_action_report <- function(rows, sheet_entries, report, issued,
                                        prior_emailed, season, now = Sys.time()) {
  missing <- saladj_contract_admin_status(rows, sheet_entries, season) == "missing"
  entries <- rows[missing, , drop = FALSE]
  entry_keys <- saladj_action_row_keys(entries)
  # Import the old digest receipts so changing senders does not resend old work.
  known <- unique(c(issued$issue_key, saladj_action_row_keys(prior_emailed)))
  eligible <- saladj_checker_email_findings(report, now)
  missing_sheet <- report$issue == "MISSING_ENTRY" &
    report$stage == "SalAdj Curator -> Contract Admin Sal Adj"
  eligible <- dplyr::bind_rows(eligible, report[missing_sheet, , drop = FALSE])
  new_keys <- unique(c(entry_keys[!entry_keys %in% known],
                       eligible$issue_key[!eligible$issue_key %in% issued$issue_key]))
  list(entries = entries, report = report, new_keys = new_keys,
       entry_new = !entry_keys %in% known)
}

render_saladj_action_report <- function(plan, all_rows, season, archive_filename = "") {
  report <- group_control_flag_consequences(plan$report)
  missing_sheet <- report$issue == "MISSING_ENTRY" &
    report$stage == "SalAdj Curator -> Contract Admin Sal Adj"
  pending_mfl <- report$issue %in% c("PENDING_MFL_ENTRY", "OVERDUE_MFL_ENTRY") |
    (report$issue == "MISSING_ENTRY" & report$actual_system == "MFL")
  pending_mfl[is.na(pending_mfl)] <- FALSE
  render_findings <- function(findings) {
    if (!nrow(findings)) return("None outstanding.")
    unlist(lapply(seq_len(nrow(findings)), function(i) format_checker_finding(findings[i, ])))
  }
  entry_lines <- if (!nrow(plan$entries)) "None outstanding." else c(
    "Enter these missing source contracts in Contract Admin and verify the calculated adjustment. Compare with MFL first: add only missing adjustments, correct incorrect existing entries, and never enter a duplicate. After confirming MFL, mark ENTD?. Contract salary below is not the penalty amount.",
    unlist(lapply(seq_len(nrow(plan$entries)), function(i) c(
      if (plan$entry_new[[i]]) "New entry request:" else "Previously reported; still outstanding:",
      format_saladj_digest_row(plan$entries[i, , drop = FALSE])
    )))
  )
  # Snapshot violations remain explicit, but do not repeat the source row details.
  if (any(missing_sheet)) entry_lines <- c(entry_lines,
    "Overdue at a completed official cap snapshot:", render_findings(report[missing_sheet, , drop = FALSE]))
  cash_franchises <- toupper(as.character(plan$entries$FRAN[
    toupper(trimws(as.character(plan$entries$PLAYER))) == "CASH TRADE"]))
  cash <- evaluate_cash_trade_limit(all_rows, season = season)
  cash <- cash[cash$franchise %in% cash_franchises, , drop = FALSE]
  corrections <- render_findings(report[!missing_sheet & !pending_mfl, , drop = FALSE])
  if (nrow(cash)) corrections <- c(corrections, "Cash Trade Limit Violation:",
    vapply(seq_len(nrow(cash)), function(i) sprintf(
      "%s: Net cash %s $%.2fm; maximum $%.2fm; overage $%.2fm ($%.2fm given; $%.2fm acquired).",
      cash$franchise[i], cash$net_direction[i], cash$net_amount[i], cash$limit[i],
      cash$overage[i], cash$total_given[i], cash$total_acquired[i]), character(1)))
  if (nrow(cash)) corrections <- corrections[corrections != "None outstanding."]
  paste(c(
    "Salary-adjustment action report",
    "This is the complete current worklist. Previously reported items are included for context, not as new errors. Unchecked ENTD? entries are warnings until a completed official snapshot is missed.",
    if (nzchar(archive_filename)) paste0("Dashboard CSV here: ", saladj_public_csv_url(archive_filename)),
    "", "1. Items to Enter into Contract Admin and MFL", entry_lines,
    "", "2. Items in Contract Admin to be Entered into MFL",
    render_findings(report[pending_mfl & !missing_sheet, , drop = FALSE]),
    "", "3. Items that Need Correcting in Contract Admin or MFL", corrections,
    "", "This checker is read-only. No Contract Admin or MFL entries were changed automatically."
  ), collapse = "\n")
}
