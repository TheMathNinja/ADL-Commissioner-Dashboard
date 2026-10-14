# Appends audited manual SalAdj rows to Contract Admin without duplicating them.

source("R/config_helpers.R")

service_account_path <- function() {
  key <- Sys.getenv("GOOGLE_SERVICE_ACCOUNT_JSON", unset = "")
  if (!nzchar(key)) stop("GOOGLE_SERVICE_ACCOUNT_JSON is not configured")
  path <- tempfile(fileext = ".json")
  writeLines(key, path, useBytes = TRUE)
  path
}

season <- get_current_season()
source_csv <- file.path("data", paste0("manual_saladj_adjustments_", season, ".csv"))
if (!file.exists(source_csv)) stop("Manual SalAdj source not found: ", source_csv)
if (!requireNamespace("googlesheets4", quietly = TRUE)) stop("googlesheets4 is required")

rows <- readr::read_csv(
  source_csv,
  col_types = readr::cols(.default = readr::col_character()),
  show_col_types = FALSE
)
rows <- rows[toupper(trimws(rows$CONF)) == "NFC", , drop = FALSE]
if (!nrow(rows)) quit(save = "no", status = 0L)

googlesheets4::gs4_auth(path = service_account_path())
sheet_id <- Sys.getenv(
  "CONTRACT_ADMIN_SHEET_ID",
  unset = "1Pyw8qVfiBlXNuX0lW0LdjRnBiijfbo2BXHfZMWwLLaw"
)
tab <- "NFC Sal Adj"
existing <- googlesheets4::read_sheet(
  sheet_id, sheet = tab, range = "A1:S", col_names = TRUE, col_types = "c"
)

row_key <- function(date, fran, player, salary) {
  date <- sub(" .*", "", trimws(as.character(date)))
  date <- ifelse(
    grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", date),
    date,
    format(as.Date(date, format = "%m/%d/%Y"), "%Y-%m-%d")
  )
  paste(date, toupper(trimws(fran)), toupper(trimws(player)),
        sprintf("%.2f", as.numeric(salary)), sep = "|")
}
existing_keys <- row_key(existing$DATE, existing$FRAN, existing$PLAYER, existing$SALARY)
source_keys <- row_key(rows$DATE, rows$FRAN, rows$PLAYER, rows$SALARY)
to_add <- rows[!(source_keys %in% existing_keys), , drop = FALSE]

if (nrow(to_add)) {
  sheet_rows <- data.frame(
    `PRE-J1` = "",
    DATE = as.Date(sub(" .*", "", to_add$DATE), format = "%m/%d/%Y"),
    FRAN = to_add$FRAN,
    PLAYER = to_add$PLAYER,
    SALARY = as.numeric(to_add$SALARY),
    YEARS = "",
    CONTRACT = "",
    `2026 PEN` = as.numeric(to_add$SALARY),
    `2027 PEN` = 0,
    `B/R` = "",
    `TR/IB` = "x",
    FG = "",
    `(S)` = "",
    JT = "",
    ACC = "",
    `1.XX+` = "",
    NOTES = to_add$NOTES,
    `ENTD?` = "x",
    `RVSD?` = "",
    check.names = FALSE
  )
  googlesheets4::sheet_append(sheet_id, data = sheet_rows, sheet = tab)
}

verified <- googlesheets4::read_sheet(
  sheet_id, sheet = tab, range = "A1:S", col_names = TRUE, col_types = "c"
)
verified_keys <- row_key(verified$DATE, verified$FRAN, verified$PLAYER, verified$SALARY)
missing <- setdiff(source_keys, verified_keys)
if (length(missing)) stop("Contract Admin write did not verify: ", paste(missing, collapse = ", "))
message("Verified ", length(source_keys), " manual cash-only SalAdj rows in ", tab, ".")
