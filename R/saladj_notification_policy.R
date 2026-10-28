# Missing Contract Admin rows belong to the digest; entered-row errors belong
# to the checker. Pending MFL work is a Monday-morning snapshot reminder.
saladj_pending_reminder_window <- function(now = Sys.time()) {
  local <- as.POSIXlt(now, tz = "America/New_York")
  local$wday == 1L && local$hour < 12L
}

saladj_checker_email_findings <- function(report, now = Sys.time()) {
  if (!nrow(report)) return(report)
  missing_sheet <- report$issue == "MISSING_ENTRY" &
    report$stage == "SalAdj Curator -> Contract Admin Sal Adj"
  pending <- report$issue == "PENDING_MFL_ENTRY"
  keep <- !missing_sheet & (!pending | saladj_pending_reminder_window(now))
  keep[is.na(keep)] <- FALSE
  result <- report[keep, , drop = FALSE]
  # One reminder per pending issue per Monday, without reissuing actual errors.
  if ("issue_key" %in% names(result)) {
    reminders <- result$issue == "PENDING_MFL_ENTRY"
    result$issue_key[reminders] <- paste0(result$issue_key[reminders],
      "|snapshot-reminder-", format(now, "%Y-%m-%d", tz = "America/New_York"))
  }
  result
}

saladj_contract_admin_status <- function(rows, entries, season = get_current_season()) {
  if (!nrow(rows)) return(character())
  used <- integer()
  vapply(seq_len(nrow(rows)), function(i) {
    row <- rows[i, , drop = FALSE]
    if ("RVSD?" %in% names(row) && is_marked(row[["RVSD?"]][[1]])) return("reversed")
    player <- as.character(row$PLAYER[[1]])
    franchise <- toupper(trimws(as.character(row$FRAN[[1]])))
    cash <- identical(toupper(trimws(player)), "CASH TRADE")
    amount <- parse_amount(row$SALARY[[1]])
    date <- as.Date(parse_saladj_date(row$DATE[[1]], season), tz = "America/New_York")
    dates <- as.Date(parse_saladj_date(entries$entered_at, season), tz = "America/New_York")
    identity <- vapply(entries$description, function(name) {
      description_matches_expected(name, player, cash) ||
        description_suspected_name_match(name, player, cash)
    }, logical(1))
    amount_matches <- !is.na(entries$input_salary) & !is.na(amount) &
      abs(entries$input_salary - amount) < 0.005
    same_date <- !is.na(dates) & !is.na(date) & dates == date
    # Undated legacy rows need matching salary evidence, not just a name.
    compatible_date <- same_date | ((is.na(dates) | is.na(date)) & amount_matches)
    candidates <- which(identity & compatible_date & !(seq_len(nrow(entries)) %in% used))
    if (cash) candidates <- candidates[amount_matches[candidates]]
    same_franchise <- candidates[entries$franchise[candidates] == franchise]
    if (length(same_franchise)) {
      used <<- c(used, same_franchise[[1]])
      return("recorded")
    }
    # An exact player/contract/date under the wrong franchise needs correction,
    # not a second entry. Cash amounts alone never establish another trade.
    other <- if (cash) integer() else candidates[same_date[candidates] & amount_matches[candidates]]
    if (length(other) == 1L) {
      used <<- c(used, other[[1]])
      return("recorded_needs_review")
    }
    "missing"
  }, character(1))
}
