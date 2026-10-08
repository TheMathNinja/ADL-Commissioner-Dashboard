# Applies an audited post-snapshot correction to the dashboard summary and/or
# Contract Admin's Cap Rollover tab. Corrections are idempotent by audit key.

source("R/config_helpers.R")

arg_value <- function(name, default = NULL) {
  args <- commandArgs(trailingOnly = TRUE)
  prefix <- paste0("--", name, "=")
  match <- args[startsWith(args, prefix)]
  if (!length(match)) return(default)
  sub(prefix, "", match[[1]], fixed = TRUE)
}

column_letter <- function(n) {
  out <- character()
  while (n > 0L) {
    rem <- (n - 1L) %% 26L
    out <- c(LETTERS[[rem + 1L]], out)
    n <- (n - 1L) %/% 26L
  }
  paste(out, collapse = "")
}

parse_corrections <- function(value) {
  pieces <- strsplit(value, ",", fixed = TRUE)[[1]]
  rows <- lapply(pieces, function(piece) {
    fields <- strsplit(trimws(piece), ":", fixed = TRUE)[[1]]
    if (length(fields) != 2L) stop("Invalid correction: ", piece)
    amount <- suppressWarnings(as.numeric(fields[[2]]))
    if (!nzchar(fields[[1]]) || !is.finite(amount) || amount == 0) stop("Invalid correction: ", piece)
    data.frame(FRANCHISE = toupper(trimws(fields[[1]])), amount = amount, stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}

cell_input <- function(cells) {
  if (!nrow(cells)) return("")
  value <- cells$cell[[1]]$userEnteredValue
  if (is.null(value)) return("")
  if (!is.null(value$formulaValue)) return(as.character(value$formulaValue))
  if (!is.null(value$numberValue)) return(as.character(value$numberValue))
  if (!is.null(value$stringValue)) return(as.character(value$stringValue))
  ""
}

correction_formula <- function(existing, amount, marker) {
  existing <- trimws(as.character(existing))
  if (grepl(marker, existing, fixed = TRUE)) return(existing)
  expression <- if (!nzchar(existing)) {
    "0"
  } else if (startsWith(existing, "=")) {
    substring(existing, 2L)
  } else if (!is.na(suppressWarnings(as.numeric(existing)))) {
    existing
  } else {
    stop("CORR cell contains nonnumeric text; manual review required")
  }
  paste0(
    "=SUM(", expression, ",", formatC(amount, format = "f", digits = 2L),
    ")+N(\"", marker, "\")"
  )
}

service_account_path <- function() {
  key <- Sys.getenv("GOOGLE_SERVICE_ACCOUNT_JSON", unset = "")
  if (!nzchar(key)) stop("GOOGLE_SERVICE_ACCOUNT_JSON is not configured")
  path <- tempfile(fileext = ".json")
  writeLines(key, path, useBytes = TRUE)
  path
}

season <- as.integer(arg_value("season", get_current_season()))
week <- as.integer(arg_value("week", ""))
key <- arg_value("key", "")
reason <- arg_value("reason", "")
corrections <- parse_corrections(arg_value("corrections", ""))
apply_files <- tolower(arg_value("apply-files", "true")) %in% c("1", "true", "yes")
apply_sheet <- tolower(arg_value("apply-sheet", "false")) %in% c("1", "true", "yes")

if (is.na(season) || is.na(week) || week < 1L || week > 17L) stop("Valid season and week are required")
if (!grepl("^[A-Za-z0-9._-]+$", key)) stop("Correction key must contain only letters, numbers, dot, underscore, or hyphen")

base_dir <- file.path("data", "cap_accounting", season)
summary_csv <- file.path(base_dir, "summaries", paste0(season, "w", week, "_ADLsalarycapsummary.csv"))
summary_rds <- sub("\\.csv$", ".rds", summary_csv)
ledger_csv <- file.path(base_dir, "manual_cap_corrections.csv")
corr_col <- paste0("W", week, "_Corr")

if (apply_files) {
  if (!file.exists(summary_csv) || !file.exists(summary_rds)) stop("Official summary CSV/RDS is missing for week ", week)
  ledger <- if (file.exists(ledger_csv)) {
    read.csv(ledger_csv, stringsAsFactors = FALSE, check.names = FALSE)
  } else {
    data.frame(season = integer(), week = integer(), key = character(), franchise = character(),
               amount = numeric(), reason = character(), applied_at_utc = character())
  }
  csv_lines <- readLines(summary_csv, warn = FALSE)
  csv_header <- strsplit(csv_lines[[1]], ",", fixed = TRUE)[[1]]
  corr_index <- match(corr_col, csv_header)
  summary_rds_data <- readRDS(summary_rds)

  for (i in seq_len(nrow(corrections))) {
    franchise <- corrections$FRANCHISE[[i]]
    amount <- corrections$amount[[i]]
    already <- ledger$season == season & ledger$week == week & ledger$key == key & ledger$franchise == franchise
    if (any(already)) next

    csv_row <- which(startsWith(csv_lines[-1L], paste0(franchise, ","))) + 1L
    rds_row <- which(summary_rds_data$FRANCHISE == franchise)
    if (length(csv_row) != 1L || length(rds_row) != 1L || is.na(corr_index) || !corr_col %in% names(summary_rds_data)) {
      stop("Could not uniquely locate ", franchise, " / ", corr_col, " in both summary files")
    }
    csv_line <- csv_lines[[csv_row]]
    trailing_commas <- nchar(csv_line) - nchar(sub(",+$", "", csv_line))
    csv_body <- if (trailing_commas > 0L) substr(csv_line, 1L, nchar(csv_line) - trailing_commas) else csv_line
    csv_fields <- strsplit(csv_body, ",", fixed = TRUE)[[1]]
    if (trailing_commas > 0L) csv_fields <- c(csv_fields, rep("", trailing_commas))
    csv_current <- suppressWarnings(as.numeric(gsub("[$,]", "", csv_fields[[corr_index]])))
    rds_current <- suppressWarnings(as.numeric(summary_rds_data[[corr_col]][[rds_row]]))
    if (is.na(csv_current)) csv_current <- 0
    if (is.na(rds_current)) rds_current <- 0
    csv_fields[[corr_index]] <- sprintf("%.2f", csv_current + amount)
    csv_lines[[csv_row]] <- paste(csv_fields, collapse = ",")
    summary_rds_data[[corr_col]][[rds_row]] <- rds_current + amount
    ledger <- rbind(ledger, data.frame(
      season = season, week = week, key = key, franchise = franchise, amount = amount,
      reason = reason, applied_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    ))
  }

  writeLines(csv_lines, summary_csv, useBytes = TRUE)
  saveRDS(summary_rds_data, summary_rds)
  write.csv(ledger, ledger_csv, row.names = FALSE, na = "", quote = TRUE)
  message("Updated dashboard summary CSV/RDS and correction ledger for week ", week, ".")
}

if (apply_sheet) {
  if (!requireNamespace("googlesheets4", quietly = TRUE)) stop("googlesheets4 is required")
  googlesheets4::gs4_auth(path = service_account_path())
  sheet_id <- Sys.getenv("CONTRACT_ADMIN_SHEET_ID", unset = "1Pyw8qVfiBlXNuX0lW0LdjRnBiijfbo2BXHfZMWwLLaw")
  tab <- Sys.getenv("CONTRACT_ADMIN_CAP_ROLLOVER_TAB", unset = "Cap Rollover")
  teams <- googlesheets4::read_sheet(sheet_id, sheet = tab, range = "A3:A34", col_names = FALSE, col_types = "c")[[1]]
  corr_column <- column_letter(2L + ((week - 1L) * 12L) + 10L)

  for (i in seq_len(nrow(corrections))) {
    franchise <- corrections$FRANCHISE[[i]]
    amount <- corrections$amount[[i]]
    row <- which(trimws(teams) == franchise) + 2L
    if (length(row) != 1L) stop("Could not uniquely locate ", franchise, " in Cap Rollover")
    cell <- paste0(corr_column, row)
    header <- paste0(corr_column, "2")
    header_value <- googlesheets4::read_sheet(sheet_id, sheet = tab, range = header, col_names = FALSE, col_types = "c")[[1]][[1]]
    if (toupper(trimws(header_value)) != "CORR") stop("Expected CORR header at ", header)
    current <- cell_input(googlesheets4::range_read_cells(sheet_id, sheet = tab, range = cell, cell_data = "full"))
    marker <- paste0("ADL-CAP-CORR:", key, ":", franchise)
    formula <- correction_formula(current, amount, marker)
    if (!identical(formula, current)) {
      googlesheets4::range_write(
        sheet_id, data = data.frame(value = googlesheets4::gs4_formula(formula)),
        sheet = tab, range = cell, col_names = FALSE, reformat = FALSE
      )
    }
    verified <- cell_input(googlesheets4::range_read_cells(sheet_id, sheet = tab, range = cell, cell_data = "full"))
    if (!grepl(marker, verified, fixed = TRUE)) stop("Correction write did not verify at ", cell)
    message("Verified ", tab, "!", cell, " for ", franchise, ": ", verified)
  }
}
