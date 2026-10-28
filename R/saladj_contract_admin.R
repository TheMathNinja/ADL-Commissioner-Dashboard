# Shared read-only Contract Admin salary-adjustment access and identity helpers.

get_google_service_account_path <- function() {
  credentials_path <- Sys.getenv("GOOGLE_APPLICATION_CREDENTIALS", unset = "")
  if (nzchar(credentials_path)) return(credentials_path)

  credentials_json <- Sys.getenv("GOOGLE_SERVICE_ACCOUNT_JSON", unset = "")
  if (!nzchar(credentials_json)) return("")

  path <- tempfile(fileext = ".json")
  writeLines(credentials_json, path, useBytes = TRUE)
  path
}

parse_amount <- function(x) {
  raw <- trimws(as.character(x))
  raw <- gsub("[\u2212\u2012\u2013\u2014]", "-", raw, perl = TRUE)
  is_negative <- grepl("^\\s*-", raw) | grepl("^\\(.*\\)$", raw)
  match_at <- regexpr("[+-]?[0-9][0-9,]*(\\.[0-9]+)?", raw, perl = TRUE)
  cleaned <- rep(NA_character_, length(raw))
  found <- !is.na(match_at) & match_at > 0
  if (any(found)) {
    found_match_at <- regexpr("[+-]?[0-9][0-9,]*(\\.[0-9]+)?", raw[found], perl = TRUE)
    cleaned[found] <- regmatches(raw[found], found_match_at)
  }
  cleaned <- gsub(",", "", cleaned, fixed = TRUE)
  parsed <- suppressWarnings(as.numeric(cleaned))
  parsed[is_negative & !is.na(parsed)] <- -abs(parsed[is_negative & !is.na(parsed)])
  parsed
}

parse_saladj_date <- function(x, season) {
  x <- as.character(x)
  parsed <- suppressWarnings(as.POSIXct(x, format = "%m/%d/%Y %H:%M:%S", tz = "America/Toronto"))
  missing <- is.na(parsed)
  if (any(missing)) {
    parsed[missing] <- suppressWarnings(as.POSIXct(x[missing], format = "%m/%d/%Y", tz = "America/Toronto"))
  }
  parsed
}

is_marked <- function(x) {
  x <- toupper(trimws(as.character(x)))
  !is.na(x) & nzchar(x) & x %in% c("X", "TRUE", "YES", "1")
}

normalize_player_token <- function(x) {
  x |>
    as.character() |>
    toupper() |>
    gsub("[^A-Z0-9]+", " ", x = _) |>
    trimws()
}

player_last_name <- function(x) {
  x <- as.character(x)
  if (grepl(",", x, fixed = TRUE)) {
    return(trimws(strsplit(x, ",", fixed = TRUE)[[1]][[1]]))
  }
  parts <- strsplit(trimws(x), "\\s+")[[1]]
  if (!length(parts)) return("")
  parts[[length(parts)]]
}

player_first_initial <- function(x) {
  x <- trimws(as.character(x))
  if (!nzchar(x)) return("")
  if (grepl(",", x, fixed = TRUE)) {
    parts <- strsplit(x, ",", fixed = TRUE)[[1]]
    after_comma <- if (length(parts) >= 2) trimws(parts[[2]]) else ""
    return(substr(after_comma, 1, 1))
  }
  substr(x, 1, 1)
}

description_matches_expected <- function(description, player, is_cash_trade) {
  description <- normalize_player_token(description)
  if (isTRUE(is_cash_trade)) return(TRUE)
  last <- normalize_player_token(player_last_name(player))
  first <- normalize_player_token(player_first_initial(player))
  nzchar(last) && grepl(paste0("\\b", last, "\\b"), description, perl = TRUE) &&
    (!nzchar(first) || grepl(paste0("\\b", first, "[A-Z]*\\b"), description, perl = TRUE))
}

description_suspected_name_match <- function(description, player, is_cash_trade) {
  if (isTRUE(is_cash_trade) || description_matches_expected(description, player, FALSE)) return(FALSE)
  description <- normalize_player_token(description)
  last <- normalize_player_token(player_last_name(player))
  first <- normalize_player_token(player_first_initial(player))
  if (!nzchar(last) || !nzchar(description) ||
      (nzchar(first) && !grepl(paste0("\\b", first, "[A-Z]*\\b"), description, perl = TRUE))) {
    return(FALSE)
  }
  description_words <- strsplit(description, "\\s+")[[1]]
  last_word_count <- length(strsplit(last, "\\s+")[[1]])
  if (length(description_words) < last_word_count) return(FALSE)
  candidates <- vapply(seq_len(length(description_words) - last_word_count + 1L), function(i) {
    paste(description_words[i:(i + last_word_count - 1L)], collapse = " ")
  }, character(1))
  min(utils::adist(last, candidates)) <= 1L
}

contract_admin_saladj_entries <- function(season) {
  if (!requireNamespace("googlesheets4", quietly = TRUE)) {
    stop("Package googlesheets4 is required for the Contract Admin audit.", call. = FALSE)
  }
  credentials <- get_google_service_account_path()
  if (!nzchar(credentials)) {
    stop("GOOGLE_SERVICE_ACCOUNT_JSON or GOOGLE_APPLICATION_CREDENTIALS is required for the Contract Admin audit.", call. = FALSE)
  }

  googlesheets4::gs4_auth(path = credentials)
  sheet_id <- Sys.getenv(
    "CONTRACT_ADMIN_SHEET_ID",
    unset = "1Pyw8qVfiBlXNuX0lW0LdjRnBiijfbo2BXHfZMWwLLaw"
  )
  penalty_col <- paste0(season, " PEN")

  bind_rows(lapply(c("NFC Sal Adj", "AFC Sal Adj"), function(tab) {
    rows <- googlesheets4::read_sheet(
      ss = sheet_id,
      sheet = tab,
      range = "A1:X",
      col_names = FALSE,
      col_types = "c",
      .name_repair = "minimal"
    )
    rows <- as.data.frame(rows, stringsAsFactors = FALSE)
    headers <- trimws(as.character(unlist(rows[1, ], use.names = FALSE)))
    required <- c(
      "DATE", "FRAN", "PLAYER", "SALARY", "B/R", "TR/IB", "FG", "(S)",
      "JT", "ACC", "1.XX+", penalty_col, paste0(season + 1L, " PEN"), "RVSD?", "ENTD?"
    )
    missing <- setdiff(required, headers)
    if (length(missing)) {
      stop(tab, " is missing columns: ", paste(missing, collapse = ", "), call. = FALSE)
    }
    column_index <- vapply(required, function(name) which(headers == name)[[1]], integer(1))
    values <- rows[-1, , drop = FALSE]

    tibble(
      sheet_row = seq_len(nrow(values)) + 1L,
      franchise = toupper(trimws(as.character(values[[column_index[["FRAN"]]]]))),
      player = trimws(as.character(values[[column_index[["PLAYER"]]]])),
      input_salary = parse_amount(values[[column_index[["SALARY"]]]]),
      penalty_amount = parse_amount(values[[column_index[[penalty_col]]]]),
      future_penalty_amount = parse_amount(values[[column_index[[paste0(season + 1L, " PEN")]]]]),
      entered_at = as.character(values[[column_index[["DATE"]]]]),
      description = trimws(as.character(values[[column_index[["PLAYER"]]]])),
      is_br = is_marked(values[[column_index[["B/R"]]]]),
      is_trade_or_ib = is_marked(values[[column_index[["TR/IB"]]]]),
      is_fg = is_marked(values[[column_index[["FG"]]]]),
      is_suspended = is_marked(values[[column_index[["(S)"]]]]),
      is_jt = is_marked(values[[column_index[["JT"]]]]),
      is_accelerated = is_marked(values[[column_index[["ACC"]]]]),
      plus_raw = trimws(as.character(values[[column_index[["1.XX+"]]]])),
      plus_amount = case_when(
        is.na(.data$plus_raw) | !nzchar(.data$plus_raw) ~ 0,
        TRUE ~ parse_amount(.data$plus_raw)
      ),
      is_reversed = is_marked(values[[column_index[["RVSD?"]]]]),
      is_entered = is_marked(values[[column_index[["ENTD?"]]]]),
      sheet_tab = tab
    ) |>
      filter(nzchar(.data$franchise), nzchar(.data$player), !.data$is_reversed)
  })) |>
    mutate(actual_id = row_number())
}

