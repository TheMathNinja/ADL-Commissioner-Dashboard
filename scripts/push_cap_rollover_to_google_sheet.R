# push_cap_rollover_to_google_sheet.R
# -----------------------------------
# Pushes the official weekly salary cap summary into the Contract Admin
# "Cap Rollover" tab after a successful weekly cap accounting run.

source("R/config_helpers.R")

column_letter <- function(n) {
  if (length(n) != 1 || is.na(n) || n < 1) {
    stop("Column number must be a positive integer.")
  }

  out <- character()
  while (n > 0) {
    rem <- (n - 1) %% 26
    out <- c(LETTERS[rem + 1], out)
    n <- (n - 1) %/% 26
  }

  paste(out, collapse = "")
}

week_target_range <- function(snapshot_week, first_week_start_col = 2L, width = 10L, start_row = 3L, n_teams = 32L) {
  start_col <- first_week_start_col + ((snapshot_week - 1L) * width)
  end_col <- start_col + width - 1L
  paste0(column_letter(start_col), start_row, ":", column_letter(end_col), start_row + n_teams - 1L)
}

get_snapshot_week_for_writeback <- function(current_season) {
  snapshot_week_env <- Sys.getenv("SNAPSHOT_WEEK", unset = "")
  if (nzchar(snapshot_week_env)) {
    snapshot_week <- suppressWarnings(as.integer(snapshot_week_env))
    if (is.na(snapshot_week) || snapshot_week < 1) {
      stop("SNAPSHOT_WEEK must be a positive integer when provided.")
    }
    return(snapshot_week)
  }

  summary_dir <- file.path("data", "cap_accounting", as.character(current_season), "summaries")
  files <- list.files(
    summary_dir,
    pattern = paste0("^", current_season, "w[0-9]+_ADLsalarycapsummary\\.csv$"),
    full.names = TRUE
  )

  if (length(files) == 0) {
    stop("SNAPSHOT_WEEK is not set and no salary cap summary CSV exists in ", summary_dir, ".")
  }

  latest_file <- files[which.max(file.info(files)$mtime)]
  snapshot_week <- suppressWarnings(as.integer(sub(
    paste0("^.*", current_season, "w([0-9]+)_ADLsalarycapsummary\\.csv$"),
    "\\1",
    latest_file
  )))

  if (is.na(snapshot_week) || snapshot_week < 1) {
    stop("Could not infer SNAPSHOT_WEEK from latest summary file: ", latest_file)
  }

  snapshot_week
}

get_service_account_path <- function() {
  credentials_json <- Sys.getenv("GOOGLE_SERVICE_ACCOUNT_JSON", unset = "")
  credentials_path <- Sys.getenv("GOOGLE_APPLICATION_CREDENTIALS", unset = "")

  if (nzchar(credentials_path)) {
    return(credentials_path)
  }

  if (!nzchar(credentials_json)) {
    stop(
      "Google Sheets credentials are not configured. ",
      "Set GOOGLE_SERVICE_ACCOUNT_JSON to a Google service account JSON key ",
      "and share the Contract Admin spreadsheet with that service account email."
    )
  }

  path <- tempfile(fileext = ".json")
  writeLines(credentials_json, path, useBytes = TRUE)
  path
}

current_season <- get_current_season()
snapshot_week <- get_snapshot_week_for_writeback(current_season)

sheet_id <- Sys.getenv(
  "CONTRACT_ADMIN_SHEET_ID",
  unset = "1Pyw8qVfiBlXNuX0lW0LdjRnBiijfbo2BXHfZMWwLLaw"
)
sheet_name <- Sys.getenv("CONTRACT_ADMIN_CAP_ROLLOVER_TAB", unset = "Cap Rollover")
summary_csv <- Sys.getenv(
  "CAP_ACCOUNTING_SUMMARY_CSV",
  unset = file.path(
    "data",
    "cap_accounting",
    as.character(current_season),
    "summaries",
    paste0(current_season, "w", snapshot_week, "_ADLsalarycapsummary.csv")
  )
)

if (!file.exists(summary_csv)) {
  stop("Salary cap summary CSV does not exist: ", summary_csv)
}

summary <- utils::read.csv(
  summary_csv,
  stringsAsFactors = FALSE,
  check.names = FALSE,
  na.strings = ""
)

week_prefix <- paste0("W", snapshot_week, "_")
paste_columns <- paste0(week_prefix, c("A", "IR", "S", "TE", "Yrs", "Ill?", "Paid", "Vac$", "RostSal", "Adj"))
missing_columns <- setdiff(paste_columns, names(summary))
if (length(missing_columns) > 0) {
  stop("Summary CSV is missing expected columns: ", paste(missing_columns, collapse = ", "))
}

if (!"FRANCHISE" %in% names(summary)) {
  stop("Summary CSV is missing FRANCHISE column.")
}

if (nrow(summary) != 32L) {
  stop("Expected 32 franchise rows in summary CSV, found ", nrow(summary), ".")
}

values <- summary[, paste_columns, drop = FALSE]
numeric_columns <- setdiff(names(values), paste0(week_prefix, "Ill?"))
values[numeric_columns] <- lapply(values[numeric_columns], function(x) suppressWarnings(as.numeric(x)))

target_range <- week_target_range(snapshot_week)
message("Prepared ", nrow(values), " rows x ", ncol(values), " columns from ", summary_csv)
message("Target: ", sheet_name, "!", target_range)

if (tolower(Sys.getenv("ADL_CONTRACT_ADMIN_DRY_RUN", unset = "false")) %in% c("1", "true", "yes")) {
  print(summary[, c("FRANCHISE", paste_columns), drop = FALSE])
  quit(save = "no", status = 0)
}

if (!requireNamespace("googlesheets4", quietly = TRUE)) {
  stop("The googlesheets4 package is required to update the Contract Admin Google Sheet.")
}

googlesheets4::gs4_auth(path = get_service_account_path())

team_range <- paste0(sheet_name, "!A3:A34")
sheet_teams <- googlesheets4::read_sheet(
  ss = sheet_id,
  range = team_range,
  col_names = FALSE,
  col_types = "c"
)

sheet_team_values <- trimws(as.character(sheet_teams[[1]]))
summary_team_values <- trimws(summary$FRANCHISE)

if (!identical(sheet_team_values, summary_team_values)) {
  mismatch <- which(sheet_team_values != summary_team_values)
  stop(
    "Contract Admin team order does not match the salary cap summary CSV. First mismatches: ",
    paste(
      utils::head(
        paste0(
          "row ", mismatch + 2L,
          " sheet=", sheet_team_values[mismatch],
          " csv=", summary_team_values[mismatch]
        ),
        5L
      ),
      collapse = "; "
    )
  )
}

googlesheets4::range_write(
  ss = sheet_id,
  data = values,
  sheet = sheet_name,
  range = target_range,
  col_names = FALSE,
  reformat = FALSE
)

message("Updated Contract Admin ", sheet_name, "!", target_range, " for week ", snapshot_week, ".")
