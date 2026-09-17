waiver_cap_formula <- function(existing, amount, key) {
  marker <- paste0("ADL-WAIVER-CORR:", key)
  existing <- trimws(as.character(existing))
  if (grepl(marker, existing, fixed = TRUE)) return(existing)
  if (!is.finite(amount) || amount <= 0 || !grepl("^[0-9]+-[0-9]+-[0-9]+$", key)) stop("Invalid waiver correction")
  expression <- if (!nzchar(existing)) {
    "0"
  } else if (startsWith(existing, "=")) {
    substring(existing, 2L)
  } else if (!is.na(suppressWarnings(as.numeric(existing)))) {
    existing
  } else {
    stop("CORR cell contains nonnumeric text; manual review required")
  }
  paste0("=SUM(", expression, ")-", formatC(amount, format = "f", digits = 2L), "+N(\"", marker, "\")")
}

waiver_cap_cell_input <- function(cells) {
  if (!nrow(cells)) return("")
  if (nrow(cells) != 1L) stop("Expected one Google Sheets cell")
  value <- cells$cell[[1]]$userEnteredValue
  if (is.null(value)) return("")
  if (!is.null(value$formulaValue)) return(as.character(value$formulaValue))
  if (!is.null(value$numberValue)) return(as.character(value$numberValue))
  if (!is.null(value$stringValue)) return(as.character(value$stringValue))
  ""
}

waiver_cap_service_account_path <- function() {
  key <- Sys.getenv("GOOGLE_SERVICE_ACCOUNT_JSON", unset = "")
  if (!nzchar(key)) return(NULL)
  path <- tempfile(fileext = ".json")
  writeLines(key, path, useBytes = TRUE)
  path
}

waiver_cap_apply_sheet <- function(correction, franchise, sheet_id, credentials_path) {
  googlesheets4::gs4_auth(path = credentials_path)
  tab <- "Cap Rollover"
  cell <- correction$corr_cell[[1]]
  header <- sub("[0-9]+$", "2", cell)
  header_value <- googlesheets4::read_sheet(sheet_id, sheet = tab, range = header, col_names = FALSE, col_types = "c")
  if (nrow(header_value) != 1L || toupper(trimws(header_value[[1]][1])) != "CORR") stop("Expected CORR header at ", header)
  team_cell <- paste0("A", sub("^[A-Z]+", "", cell))
  sheet_team <- googlesheets4::read_sheet(sheet_id, sheet = tab, range = team_cell, col_names = FALSE, col_types = "c")
  if (nrow(sheet_team) != 1L || trimws(sheet_team[[1]][1]) != franchise) stop("Contract Admin team mismatch at ", team_cell)
  current <- waiver_cap_cell_input(googlesheets4::range_read_cells(sheet_id, sheet = tab, range = cell, cell_data = "full"))
  formula <- waiver_cap_formula(current, correction$amount[[1]], correction$key[[1]])
  if (!identical(formula, current)) {
    value <- data.frame(correction = googlesheets4::gs4_formula(formula))
    googlesheets4::range_write(sheet_id, data = value, sheet = tab, range = cell, col_names = FALSE, reformat = FALSE)
  }
  verified <- waiver_cap_cell_input(googlesheets4::range_read_cells(sheet_id, sheet = tab, range = cell, cell_data = "full"))
  if (!grepl(paste0("ADL-WAIVER-CORR:", correction$key[[1]]), verified, fixed = TRUE)) stop("CORR write did not verify at ", cell)
  cell
}
