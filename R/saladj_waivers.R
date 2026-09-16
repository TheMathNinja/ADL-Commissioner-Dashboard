# Current MFL individual locks verify recent drop status. Historical transactions
# and contract snapshots still determine claims and salary-adjustment outcomes.
saladj_waiver_policy <- "20260916-mfl-drop-event-check-v1"

saladj_waiver_scalar <- function(x) if (is.null(x) || !length(x)) "" else as.character(x[[1]])
saladj_waiver_nodes <- function(x) {
  if (is.null(x) || !length(x)) return(list())
  if (!is.null(x$id)) return(list(x))
  x
}

saladj_lock_time_key <- function(text) {
  # Compare Eastern wall time with the transaction's known UTC instant. Parsing
  # an ambiguous fall-back hour into a guessed UTC offset would lose evidence.
  pattern <- "^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ([0-9]{1,2}) ([0-9]{1,2}):([0-9]{2}):([0-9]{2}) ([ap])[.]m[.] ET ([0-9]{4})$"
  parts <- regmatches(text, regexec(pattern, trimws(text)))[[1]]
  if (length(parts) != 9L) stop("Unrecognized MFL lock timestamp")
  month <- match(parts[3], month.abb); day <- as.integer(parts[4])
  hour <- as.integer(parts[5]); minute <- as.integer(parts[6]); second <- as.integer(parts[7])
  if (hour < 1L || hour > 12L || minute > 59L || second > 59L) stop("Invalid MFL lock time")
  date <- sprintf("%s-%02d-%02d", parts[9], month, day)
  if (is.na(as.Date(date, format = "%Y-%m-%d"))) stop("Invalid MFL lock date")
  hour <- hour %% 12L + if (parts[8] == "p") 12L else 0L
  paste(date, sprintf("%02d:%02d:%02d", hour, minute, second))
}

saladj_parse_individual_locks <- function(path, league, season, league_id) {
  if (saladj_waiver_scalar(league$id) != as.character(league_id)) stop("Wrong MFL league metadata")
  conf <- do.call(rbind, lapply(saladj_waiver_nodes(league$conferences$conference), function(x) {
    data.frame(id = saladj_waiver_scalar(x$id), CONF = toupper(saladj_waiver_scalar(x$name)))
  }))
  div <- do.call(rbind, lapply(saladj_waiver_nodes(league$divisions$division), function(x) {
    data.frame(id = saladj_waiver_scalar(x$id), conference = saladj_waiver_scalar(x$conference))
  }))
  fran <- do.call(rbind, lapply(saladj_waiver_nodes(league$franchises$franchise), function(x) {
    data.frame(id = saladj_waiver_scalar(x$id), division = saladj_waiver_scalar(x$division))
  }))
  if (is.null(conf) || is.null(div) || is.null(fran) || anyDuplicated(conf$id) || anyDuplicated(div$id) || anyDuplicated(fran$id) ||
      !setequal(conf$CONF, c("NFC", "AFC")) || saladj_waiver_scalar(league$playerLimitUnit) != "CONFERENCE" ||
      saladj_waiver_scalar(league$rostersPerPlayer) != "1") stop("Unverified ADL conference/player-copy rules")
  fran$CONF <- conf$CONF[match(div$conference[match(fran$division, div$id)], conf$id)]
  expected <- ifelse(as.integer(fran$id) <= 16L, "NFC", "AFC")
  if (nrow(fran) != 32L || anyNA(fran$CONF) || any(fran$CONF != expected)) stop("Curator conference mapping disagrees with MFL")

  doc <- xml2::read_html(path)
  title <- trimws(xml2::xml_text(xml2::xml_find_first(doc, "//title")))
  if (title != paste0("Fantasy Football: ", saladj_waiver_scalar(league$name), " Locked Players")) stop("Wrong locked-player report identity")
  links <- xml2::xml_attr(xml2::xml_find_all(doc, "//a"), "href")
  body <- xml2::xml_text(doc)
  if (!any(grepl(sprintf("/%d/home/%s", season, league_id), links, fixed = TRUE)) || !grepl("Page Generated", body, fixed = TRUE)) {
    stop("Locked-player report has wrong season/league or is incomplete")
  }
  tables <- xml2::xml_find_all(doc, "//table[.//h4[contains(.,'Players With Individual Locks')]]")
  if (length(tables) != 1L) stop("Individual-lock table missing or ambiguous")
  rows <- xml2::xml_find_all(tables[[1]], ".//tr"); current <- ""; records <- list()
  for (row in rows) {
    text <- trimws(xml2::xml_text(row)); headers <- xml2::xml_find_all(row, "./th")
    if (length(headers) && startsWith(text, "Locked players in ")) {
      current <- toupper(sub("^Locked players in ", "", text))
      if (!current %in% conf$CONF) stop("Unknown locked-player conference")
      next
    }
    cells <- xml2::xml_find_all(row, "./td")
    if (!length(cells)) next
    player <- xml2::xml_find_all(cells[[1]], ".//a[contains(@href,'launch_player_modal')]")
    if (!length(player)) {
      if (grepl("no .*locked|no players|none", text, ignore.case = TRUE)) next
      stop("Unrecognized individual-lock row")
    }
    if (!nzchar(current) || length(cells) != 4L || length(player) != 1L) stop("Malformed individual-lock row")
    pattern <- sprintf("^javascript:launch_player_modal\\('%s','([0-9]+)'\\);$", league_id)
    href <- xml2::xml_attr(player, "href")
    if (!grepl(pattern, href)) stop("Invalid player ID on lock report")
    values <- trimws(xml2::xml_text(cells))
    if (!startsWith(values[3], "Waivers After ")) stop("Unknown individual-lock release condition")
    actor <- xml2::xml_find_all(cells[[4]], ".//a[contains(@class,'franchise_')]")
    fid <- NA_character_; kind <- "system"
    if (length(actor)) {
      if (length(actor) != 1L) stop("Ambiguous dropping franchise")
      class <- xml2::xml_attr(actor, "class")
      fid <- sub(".*franchise_([0-9]+).*", "\\1", class)
      if (!fid %in% fran$id || fran$CONF[match(fid, fran$id)] != current) stop("Dropping franchise/conference mismatch")
      kind <- "drop"
    } else if (values[4] != "Added To System") stop("Unrecognized lock origin")
    records[[length(records) + 1L]] <- data.frame(
      player_id = sub(pattern, "\\1", href), CONF = current, franchise_id = fid,
      drop_time_key = saladj_lock_time_key(values[2]), lock_kind = kind,
      date_locked_text = values[2], release_condition = values[3], dropped_by = values[4], stringsAsFactors = FALSE)
  }
  empty <- data.frame(player_id = character(), CONF = character(), franchise_id = character(),
    drop_time_key = character(), lock_kind = character(), date_locked_text = character(), release_condition = character(), dropped_by = character())
  locks <- if (length(records)) do.call(rbind, records) else empty
  if (anyDuplicated(locks[c("player_id", "CONF")])) stop("Duplicate player copy in current lock report")
  list(locks = locks, global_lock = any(trimws(xml2::xml_text(xml2::xml_find_all(doc, "//h4"))) == "All Players Are Currently Locked"))
}

saladj_waiver_fetch <- function(url, path) {
  response <- httr::GET(url, httr::user_agent("ADLCommissionerDashboard/SalAdjWaivers"), httr::timeout(30))
  httr::stop_for_status(response)
  writeBin(httr::content(response, as = "raw"), path)
  list(url = url, status = httr::status_code(response), captured_at = as.numeric(Sys.time()), md5 = unname(tools::md5sum(path)))
}

saladj_collect_current_waivers <- function(conn, season, directory, fetch = saladj_waiver_fetch) {
  dir.create(directory, recursive = TRUE, showWarnings = FALSE)
  run <- tempfile(paste0("saladj_waivers_", season, "_", format(Sys.time(), "%Y%m%dT%H%M%S", tz = "UTC"), "_"), tmpdir = directory)
  dir.create(run)
  league_id <- as.character(conn$league_id)
  receipts <- list()
  result <- tryCatch({
    lp <- file.path(run, "league.json"); hp <- file.path(run, "locked_players.html")
    receipts <- list(fetch(sprintf("https://api.myfantasyleague.com/%d/export?TYPE=league&L=%s&JSON=1", season, league_id), lp))
    league <- jsonlite::fromJSON(lp, simplifyVector = FALSE)$league
    base <- saladj_waiver_scalar(league$baseURL)
    if (!grepl("^https://www[0-9]+[.]myfantasyleague[.]com$", base)) stop("Unrecognized MFL host")
    receipts[[2]] <- fetch(sprintf("%s/%d/locked_players?L=%s", base, season, league_id), hp)
    parsed <- saladj_parse_individual_locks(hp, league, season, league_id)
    write.csv(parsed$locks, file.path(run, "individual_locks.csv"), row.names = FALSE)
    list(ok = TRUE, locks = parsed$locks, global_lock = parsed$global_lock, receipts = receipts)
  }, error = function(e) {
    warning("SalAdj current waiver check unavailable: ", conditionMessage(e), ". Recent unresolved drops require review.", call. = FALSE)
    list(ok = FALSE, error = conditionMessage(e), receipts = receipts)
  })
  result$policy <- saladj_waiver_policy; result$season <- as.integer(season)
  result$league_id <- league_id; result$checked_at <- as.numeric(Sys.time()); result$directory <- run
  jsonlite::write_json(result[setdiff(names(result), "locks")], file.path(run, "receipt.json"), auto_unbox = TRUE, pretty = TRUE, na = "null")
  saveRDS(result, file.path(run, "snapshot.rds"))
  result
}

saladj_apply_current_waivers <- function(drops, snapshot, now, season) {
  n <- nrow(drops)
  drops$waiver_pending_estimated <- drops$waiver_pending
  drops$waiver_check_status <- rep("historical", n)
  drops$waiver_check_reason <- rep("Historical timing retained", n)
  if (!n) return(drops)
  stamp <- as.numeric(drops$DATE_raw)
  keys <- format(drops$DATE_raw, "%Y-%m-%d %H:%M:%S", tz = "America/New_York")
  player_key <- paste(drops$player_id, drops$CONF, sep = "|")
  latest <- ave(stamp, player_key, FUN = function(v) if (any(is.finite(v))) max(v[is.finite(v)]) else NA_real_)
  eligible <- is.finite(stamp) & stamp <= as.numeric(now) & stamp == latest
  recent <- eligible & ((as.numeric(now) - stamp <= 7 * 86400) | drops$waiver_pending_estimated %in% TRUE)
  valid <- isTRUE(snapshot$ok) && identical(snapshot$policy, saladj_waiver_policy) &&
    identical(snapshot$season, as.integer(season)) && length(snapshot$checked_at) == 1L && is.finite(snapshot$checked_at) &&
    abs(as.numeric(now) - snapshot$checked_at) <= 600
  valid <- valid && identical(as.character(snapshot$league_id), "60206") &&
    length(snapshot$receipts) == 2L && is.data.frame(snapshot$locks) &&
    all(c("player_id", "CONF", "franchise_id", "drop_time_key", "lock_kind") %in% names(snapshot$locks)) &&
    length(snapshot$global_lock) == 1L && !is.na(snapshot$global_lock)
  locks <- if (valid) snapshot$locks else NULL
  if (valid) {
    for (r in snapshot$receipts) {
      path <- file.path(snapshot$directory, if (grepl("TYPE=league", r$url, fixed = TRUE)) "league.json" else "locked_players.html")
      if (!file.exists(path) || !identical(unname(tools::md5sum(path)), r$md5) || r$status != 200L) valid <- FALSE
    }
  }
  for (i in seq_len(n)) {
    match_rows <- if (valid) which(locks$player_id == drops$player_id[i] & locks$CONF == drops$CONF[i]) else integer()
    exact <- if (length(match_rows)) match_rows[which(locks$lock_kind[match_rows] == "drop" &
      !is.na(locks$franchise_id[match_rows]) & locks$franchise_id[match_rows] == drops$franchise_id[i] & locks$drop_time_key[match_rows] == keys[i])] else integer()
    if (!isTRUE(recent[i]) && !length(exact)) next
    # Existing transaction/contract proof survives a temporary failed live
    # request. An exact lock conflicting with that proof still needs review.
    if (drops$waiver_pending_estimated[i] %in% FALSE &&
        "waiver_claim_evidence" %in% names(drops) && isTRUE(drops$waiver_claim_evidence[i]) && !length(exact)) {
      drops$waiver_check_reason[i] <- "Existing transaction/contract claim evidence retained"
      next
    }
    status <- "unknown"; reason <- "Live waiver check unavailable or unverified"
    if (valid) {
      # Duplicate normalized transaction rows are OK. Distinct UTC drops at a
      # repeated DST wall time cannot establish which event owns the current lock.
      same_event <- which(player_key == player_key[i] & drops$franchise_id == drops$franchise_id[i] & keys == keys[i])
      ambiguous <- length(unique(stamp[same_event])) > 1L
      if (length(exact) == 1L && !ambiguous && isTRUE(eligible[i])) {
        status <- "pending"; reason <- "Exact drop remains on MFL individual-waiver list"
      } else if (!length(match_rows) && !snapshot$global_lock && drops$waiver_pending_estimated[i] %in% FALSE) {
        status <- "not_listed"; reason <- "Not individually locked after estimated hold; claim outcome still comes from transactions/contracts"
      } else if (length(match_rows) && !length(exact) &&
                 all(locks$drop_time_key[match_rows] > keys[i]) && drops$waiver_pending_estimated[i] %in% FALSE) {
        status <- "historical"; reason <- "Current lock belongs to a later event; earlier adjustment preserved"
      } else {
        reason <- if (snapshot$global_lock) "League-wide lock requires review" else "Lock absence, timestamp or dropping team conflicts with this drop"
      }
    }
    drops$waiver_check_status[i] <- status; drops$waiver_check_reason[i] <- reason
    if (status == "pending") drops$waiver_pending[i] <- TRUE
    if (status == "not_listed") drops$waiver_pending[i] <- FALSE
    if (status == "unknown") drops$waiver_pending[i] <- NA
  }
  audit <- drops[, c("row_key", "player_id", "CONF", "franchise_id", "DATE_raw", "waiver_matures_at",
    "waiver_pending_estimated", "waiver_pending", "waiver_check_status", "waiver_check_reason")]
  write.csv(audit, file.path(snapshot$directory, "drop_event_checks.csv"), row.names = FALSE, na = "")
  message("SalAdj live waiver check: ", sum(drops$waiver_check_status == "pending"), " confirmed pending; ",
    sum(drops$waiver_check_status == "unknown"), " need review. Historical contract/claim evidence retained.")
  drops
}

saladj_waiver_note <- function(note, status, matures_at) {
  note[is.na(note)] <- ""
  for (i in seq_along(note)) {
    if (status[i] == "pending") {
      old <- paste0("PENDING WAIVER UNTIL ", format(lubridate::with_tz(matures_at[i], "America/Toronto"), "%m/%d/%Y %I:%M %p %Z"))
      note[i] <- gsub(old, "PENDING WAIVER - STILL LISTED BY MFL", note[i], fixed = TRUE)
    }
    if (status[i] == "unknown") note[i] <- paste0("WAIVER STATUS UNKNOWN - CHECK MFL", if (nzchar(note[i])) paste0("; ", note[i]) else "")
  }
  note
}
