waiver_cap_column_letter <- function(n) {
  out <- ""
  while (n > 0L) {
    out <- paste0(LETTERS[(n - 1L) %% 26L + 1L], out)
    n <- (n - 1L) %/% 26L
  }
  out
}

waiver_cap_corr_cell <- function(week, franchise_id) {
  week <- as.integer(week)
  franchise_id <- as.integer(franchise_id)
  if (is.na(week) || week < 1L || is.na(franchise_id) || franchise_id < 1L || franchise_id > 32L) {
    stop("Invalid correction week or franchise ID")
  }
  paste0(waiver_cap_column_letter(12L * week), franchise_id + 2L)
}

waiver_cap_name_key <- function(name) {
  name <- iconv(as.character(name), to = "ASCII//TRANSLIT")
  name[is.na(name)] <- ""
  vapply(name, function(value) {
    value <- trimws(value)
    if (grepl(",", value, fixed = TRUE)) {
      parts <- strsplit(value, ",", fixed = TRUE)[[1]]
      value <- paste(trimws(parts[-1]), trimws(parts[1]))
    }
    words <- strsplit(gsub("[^A-Za-z -]", "", value), "[[:space:]]+")[[1]]
    words <- words[nzchar(words)]
    if (length(words) < 2L) return("")
    paste0(toupper(substr(words[1], 1L, 1L)), toupper(gsub("[^A-Za-z]", "", tail(words, 1L))))
  }, character(1))
}

waiver_cap_description_key <- function(description) {
  name <- sub("[[:space:]]+-.*$", "", as.character(description))
  waiver_cap_name_key(name)
}

waiver_cap_drop_date <- function(description) {
  matches <- regmatches(description, regexec("dropped[[:space:]]+([0-9]{1,2}/[0-9]{1,2}/[0-9]{2,4})", description, ignore.case = TRUE))
  vapply(matches, function(x) {
    if (length(x) != 2L) return("")
    year <- tail(strsplit(x[2], "/", fixed = TRUE)[[1]], 1L)
    as.character(as.Date(x[2], format = if (nchar(year) == 4L) "%m/%d/%Y" else "%m/%d/%y"))
  }, character(1))
}

waiver_cap_event_date <- function(timestamp_utc) {
  x <- as.POSIXct(timestamp_utc, format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
  format(x, "%Y-%m-%d", tz = "America/New_York")
}

match_waiver_cap_corrections <- function(claims, snapshots) {
  empty <- data.frame(key = character(), season = integer(), week = integer(),
    franchise_id = character(), player_id = character(), player = character(),
    drop_at_utc = character(), claim_at_utc = character(), adjustment_id = character(),
    description = character(), amount = numeric(), corr_cell = character(), stringsAsFactors = FALSE)
  if (!nrow(claims) || !nrow(snapshots)) return(empty)
  required_claim <- c("player_id", "player", "drop_franchise_id", "dropped_at_utc", "claimed_at_utc")
  required_snap <- c("season", "week", "franchise_id", "adjustment_id", "description", "amount", "captured_at_utc")
  if (!all(required_claim %in% names(claims)) || !all(required_snap %in% names(snapshots))) stop("Missing waiver correction evidence")
  if (anyDuplicated(snapshots[c("season", "week", "adjustment_id")])) stop("Duplicate MFL adjustment in snapshot ledger")
  rows <- list()
  for (i in seq_len(nrow(claims))) {
    claim <- claims[i, , drop = FALSE]
    claim_at <- as.POSIXct(claim$claimed_at_utc, format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
    drop_at <- as.POSIXct(claim$dropped_at_utc, format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
    if (is.na(claim_at) || is.na(drop_at) || claim_at <= drop_at) next
    for (week in unique(snapshots$week)) {
      ledger <- snapshots[snapshots$week == week, , drop = FALSE]
      captured <- as.POSIXct(ledger$captured_at_utc, format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
      candidate <- ledger[
        ledger$franchise_id == claim$drop_franchise_id &
        waiver_cap_description_key(ledger$description) == waiver_cap_name_key(claim$player) &
        waiver_cap_drop_date(ledger$description) == waiver_cap_event_date(claim$dropped_at_utc) &
        !is.na(captured) & captured >= drop_at & captured < claim_at &
        !is.na(ledger$amount) & ledger$amount > 0,
        , drop = FALSE
      ]
      if (nrow(candidate) != 1L) next
      entry <- candidate[1, , drop = FALSE]
      rows[[length(rows) + 1L]] <- data.frame(
        key = paste(entry$season, entry$week, entry$adjustment_id, sep = "-"),
        season = as.integer(entry$season), week = as.integer(entry$week),
        franchise_id = entry$franchise_id, player_id = claim$player_id,
        player = claim$player, drop_at_utc = claim$dropped_at_utc,
        claim_at_utc = claim$claimed_at_utc, adjustment_id = entry$adjustment_id,
        description = entry$description, amount = as.numeric(entry$amount),
        corr_cell = waiver_cap_corr_cell(entry$week, entry$franchise_id),
        stringsAsFactors = FALSE
      )
    }
  }
  if (!length(rows)) return(empty)
  out <- do.call(rbind, rows)
  if (anyDuplicated(out$key)) stop("Ambiguous waiver claim matched the same MFL adjustment twice")
  out
}
