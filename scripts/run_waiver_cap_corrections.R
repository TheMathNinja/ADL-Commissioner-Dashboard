source("R/config_helpers.R")
source("R/waiver_cap_corrections.R")
source("R/waiver_cap_sheet.R")

season <- get_current_season()
base_dir <- file.path("data", "cap_accounting", season)
ledger_dir <- file.path(base_dir, "adjustment_snapshots")
claim_path <- file.path("data", paste0("saladj_waiver_claims_", season, ".csv"))
state_path <- file.path(base_dir, "waiver_claim_correction_events.csv")
sheet_id <- Sys.getenv("CONTRACT_ADMIN_SHEET_ID", unset = "1Pyw8qVfiBlXNuX0lW0LdjRnBiijfbo2BXHfZMWwLLaw")
write_sheet <- tolower(Sys.getenv("ADL_WAIVER_CORRECTION_WRITE_SHEET", unset = "false")) == "true"
send_email <- tolower(Sys.getenv("ADL_WAIVER_CORRECTION_SEND_EMAIL", unset = "false")) == "true"

ledger_files <- list.files(ledger_dir, pattern = paste0("^", season, "w[0-9]+_ADLsalaryadjustments[.]csv$"), full.names = TRUE)
if (!length(ledger_files) || !file.exists(claim_path)) {
  message("No official adjustment ledger or waiver-claim evidence yet.")
  quit(save = "no", status = 0L)
}

snapshots <- do.call(rbind, lapply(ledger_files, function(path) read.csv(path, stringsAsFactors = FALSE, colClasses = c(franchise_id = "character", adjustment_id = "character"))))
claims <- read.csv(claim_path, stringsAsFactors = FALSE, colClasses = c(player_id = "character", drop_franchise_id = "character"))
if (!nrow(claims)) {
  message("No confirmed waiver claims yet.")
  quit(save = "no", status = 0L)
}

for (week in unique(snapshots$week)) {
  summary_path <- file.path(base_dir, "summaries", paste0(season, "w", week, "_ADLsalarycapsummary.csv"))
  if (!file.exists(summary_path)) stop("Missing official salary summary for Week ", week)
  summary <- read.csv(summary_path, check.names = FALSE, stringsAsFactors = FALSE)
  if (nrow(summary) != 32L) stop("Expected 32 franchises in Week ", week, " summary")
  adj_col <- paste0("W", week, "_Adj")
  if (!adj_col %in% names(summary)) stop("Missing official Adj column for Week ", week)
  for (fid in seq_len(32L)) {
    ledger_total <- sum(snapshots$amount[snapshots$week == week & as.integer(snapshots$franchise_id) == fid], na.rm = TRUE)
    summary_total <- as.numeric(summary[[adj_col]][fid])
    if (is.na(summary_total) || abs(ledger_total - summary_total) > 0.005) {
      stop("Adjustment ledger does not match official Week ", week, " snapshot for franchise ", sprintf("%04d", fid))
    }
  }
}

matches <- match_waiver_cap_corrections(claims, snapshots)
if (!nrow(matches)) {
  message("No post-snapshot waiver claims with a matching MFL penalty.")
  quit(save = "no", status = 0L)
}

empty_state <- transform(matches[FALSE, , drop = FALSE], franchise = character(),
  sheet_status = character(), mfl_status = character(), notified_at_utc = character())
prior <- if (file.exists(state_path)) {
  read.csv(state_path, stringsAsFactors = FALSE, colClasses = c(key = "character", franchise_id = "character", adjustment_id = "character", player_id = "character"))
} else empty_state
if (anyDuplicated(prior$key)) stop("Duplicate correction key in prior state")

current_ids <- tryCatch({
  url <- sprintf("https://api.myfantasyleague.com/%d/export?TYPE=salaryAdjustments&L=60206&JSON=1", season)
  response <- httr::GET(url, httr::timeout(30))
  httr::stop_for_status(response)
  entries <- jsonlite::fromJSON(httr::content(response, as = "text", encoding = "UTF-8"))$salaryAdjustments$salaryAdjustment
  as.character(entries$id)
}, error = function(e) {
  warning("Could not verify current MFL adjustment IDs: ", conditionMessage(e), call. = FALSE)
  NULL
})

credentials <- if (write_sheet) waiver_cap_service_account_path() else NULL
on.exit <- NULL
if (!is.null(credentials)) on.exit <- function() unlink(credentials)
updates <- list()
new_for_email <- list()
for (i in seq_len(nrow(matches))) {
  item <- matches[i, , drop = FALSE]
  old <- prior[prior$key == item$key, , drop = FALSE]
  if (nrow(old) && identical(old$sheet_status[[1]], "entered") && nzchar(old$notified_at_utc[[1]])) next
  summary_path <- file.path(base_dir, "summaries", paste0(season, "w", item$week, "_ADLsalarycapsummary.csv"))
  summary <- read.csv(summary_path, check.names = FALSE, stringsAsFactors = FALSE)
  franchise <- summary$FRANCHISE[as.integer(item$franchise_id)]
  sheet_status <- if (nrow(old)) old$sheet_status[[1]] else "not_entered"
  if (write_sheet && !is.null(credentials)) {
    sheet_status <- tryCatch({
      waiver_cap_apply_sheet(item, franchise, sheet_id, credentials)
      "entered"
    }, error = function(e) {
      warning("Could not write ", item$corr_cell, ": ", conditionMessage(e), call. = FALSE)
      "needs_review"
    })
  } else if (write_sheet && is.null(credentials)) {
    sheet_status <- "credentials_missing"
  }
  mfl_status <- if (is.null(current_ids)) "unverified" else if (item$adjustment_id %in% current_ids) "remove_entry" else "already_removed"
  record <- cbind(item, franchise = franchise, sheet_status = sheet_status,
                  mfl_status = mfl_status,
                  notified_at_utc = if (nrow(old)) old$notified_at_utc[[1]] else "")
  updates[[length(updates) + 1L]] <- record
  if (!nzchar(record$notified_at_utc[[1]]) || (nrow(old) && old$sheet_status[[1]] != "entered" && sheet_status == "entered")) {
    new_for_email[[length(new_for_email) + 1L]] <- record
  }
}

if (length(new_for_email)) {
  notices <- do.call(rbind, new_for_email)
  lines <- c("Update with Correction", "",
    "A confirmed waiver claim voided a salary adjustment that was counted in an official cap snapshot.", "")
  for (i in seq_len(nrow(notices))) {
    row <- notices[i, , drop = FALSE]
    lines <- c(lines,
      paste0(row$franchise, ": ", row$player, " (Week ", row$week, ")"),
      paste0("Claimed: ", row$claim_at_utc, " UTC"),
      paste0("Reverse $", formatC(row$amount, format = "f", digits = 2L), "m from the snapshot; Cap Rollover!", row$corr_cell, " should include -$", formatC(row$amount, format = "f", digits = 2L), "m."),
      paste0("Contract Admin CORR: ", row$sheet_status),
      if (row$mfl_status == "remove_entry") paste0("Remove MFL salary adjustment ID ", row$adjustment_id, ": ", row$description)
        else if (row$mfl_status == "already_removed") paste0("MFL adjustment ID ", row$adjustment_id, " has already been removed.")
        else paste0("Verify MFL adjustment ID ", row$adjustment_id, " manually; live lookup failed."),
      "")
  }
  body <- paste(lines, collapse = "\n")
  dir.create(dirname(state_path), recursive = TRUE, showWarnings = FALSE)
  writeLines(body, file.path(base_dir, "waiver_claim_correction_email_preview.txt"))
  if (send_email) {
    source("R/commissioner_alerts.R")
    recipients <- resolve_commissioner_alert_recipients(season = season)
    status <- send_alert_mail("[ADL Commissioner Alerts] Update with Correction", body, to = recipients$email)
    if (!isTRUE(status$sent)) stop("Waiver correction email failed: ", status$reason)
    sent_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%S", tz = "UTC")
    updates <- lapply(updates, function(row) {
      if (row$key %in% notices$key) row$notified_at_utc <- sent_at
      row
    })
  }
}

if (length(updates)) {
  updated <- do.call(rbind, updates)
  prior <- prior[!prior$key %in% updated$key, , drop = FALSE]
  readr::write_csv(rbind(prior, updated), state_path, na = "")
  message(nrow(updated), " waiver cap correction(s) evaluated; ", sum(updated$sheet_status == "entered"), " entered in Contract Admin.")
}
if (!is.null(on.exit)) on.exit()
