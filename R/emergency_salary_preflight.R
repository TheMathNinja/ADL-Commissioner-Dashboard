emergency_salary_plan <- function(rosters, context, season) {
  zero <- rosters |> filter(!is.na(.data$prev_salary), .data$prev_salary == 0)
  zero$new_salary <- round_up_to_tenth(adl_sd_minimum(season))
  zero$matched <- FALSE
  for (i in seq_len(nrow(zero))) {
    row <- zero[i, ]
    tx <- context$transactions |>
      filter(.data$franchise == row$franchise, .data$player_id == row$player_id,
             .data$type_desc %in% c("added", "claimed", "dropped")) |>
      arrange(desc(.data$occurred_at))
    if (!nrow(tx) || !tx$type_desc[[1]] %in% c("added", "claimed")) next
    zero$matched[[i]] <- emergency_add_key(row$franchise, row$player_id, tx$occurred_at[[1]]) %in% context$accepted
  }
  zero
}

emergency_salary_unit <- function(league, franchise_id) {
  f <- Filter(function(f) identical(f$id, franchise_id), league$franchises$franchise)
  if (length(f) != 1L) stop("Cannot uniquely resolve salary franchise")
  d <- Filter(function(d) identical(d$id, f[[1]]$division), league$divisions$division)
  if (length(d) != 1L || !grepl("^[0-9]{2}$", d[[1]]$conference)) stop("Cannot verify salary conference")
  paste0("CONFERENCE", d[[1]]$conference)
}

emergency_salary_payload <- function(row, unit, league_id) {
  if (nrow(row) != 1L || !isTRUE(row$prev_salary[[1]] == 0) ||
      !grepl("^CONFERENCE[0-9]{2}$", unit) || !grepl("^[0-9]+$", row$player_id[[1]])) stop("Unsafe emergency salary write")
  # APPEND is MFL's documented overlay flag; omit all contract fields.
  list(TYPE = "salaries", L = league_id, APPEND = "1",
       DATA = sprintf('<salaries><leagueUnit unit="%s"><player id="%s" salary="%.2f" /></leagueUnit></salaries>',
                      unit, row$player_id[[1]], row$new_salary[[1]]))
}

verify_emergency_salary <- function(before, after, row) {
  fields <- c("franchise_id", "player_id", "prev_salary", "prev_years", "contract")
  before <- before[, fields]; after <- after[, fields]
  key <- function(x) paste(x$franchise_id, x$player_id, sep = "|")
  if (anyDuplicated(key(before)) || anyDuplicated(key(after)) || !setequal(key(before), key(after))) stop("Roster changed during salary correction; snapshot withheld")
  after <- after[match(key(before), key(after)), ]
  target <- before$franchise_id == row$franchise_id & before$player_id == row$player_id
  if (sum(target) != 1L) stop("Ambiguous correction target")
  before$prev_salary[target] <- row$new_salary[[1]]
  if (!isTRUE(all.equal(as.data.frame(before), as.data.frame(after), check.attributes = FALSE)))
    stop("Salary read-back mismatch or unrelated contract changed; snapshot withheld")
  TRUE
}

run_emergency_salary_preflight <- function(season, week) {
  fresh <- function() {
    ffscrapr::clear_cache()
    load_current_rosters(force_live = TRUE, source = "live", season = season)
  }
  before <- fresh()
  if (!any(before$prev_salary == 0, na.rm = TRUE)) return(invisible(NULL))
  context <- emergency_add_context(season, Sys.time(), before, lookback_days = 365)
  plan <- emergency_salary_plan(before, context, season)
  directory <- file.path("data", "cap_accounting", as.character(season), "emergency_salary_preflight")
  dir.create(directory, recursive = TRUE, showWarnings = FALSE)
  receipt <- file.path(directory, paste0(season, "w", week, "-", Sys.getenv("GITHUB_RUN_ID", unset = "local"), ".rds"))
  audit <- list(checked_at = Sys.time(), plan = plan, accepted = context$accepted, writes = list())
  saveRDS(audit, receipt)
  conn <- connect_adl_mfl(season)
  response <- httr::RETRY("GET", sprintf("https://api.myfantasyleague.com/%d/export", season),
    query = list(TYPE = "league", L = conn$league_id, JSON = 1), httr::timeout(25), times = 3, quiet = TRUE)
  httr::stop_for_status(response)
  league <- httr::content(response, as = "parsed")$league
  for (i in which(plan$matched)) {
    row <- plan[i, ]; before <- fresh()
    current <- before |> filter(.data$franchise_id == row$franchise_id, .data$player_id == row$player_id)
    if (nrow(current) != 1L || !isTRUE(current$prev_salary[[1]] == 0)) stop("Emergency salary target changed; rerun preflight")
    unit <- emergency_salary_unit(league, row$franchise_id[[1]])
    copies <- before |> filter(.data$player_id == row$player_id)
    scopes <- vapply(copies$franchise_id, function(id) emergency_salary_unit(league, id), character(1))
    if (sum(scopes == unit) != 1L) stop("More than one player copy in target salary scope; no write made")
    audit$writes[[length(audit$writes) + 1L]] <- list(franchise_id = row$franchise_id, player_id = row$player_id, unit = unit, status = "pending", before = before)
    saveRDS(audit, receipt)
    tryCatch({
      result <- do.call(httr::POST, c(list(url = sprintf("https://api.myfantasyleague.com/%d/import", season),
        body = emergency_salary_payload(row, unit, conn$league_id), encode = "form", httr::timeout(25)), mfl_import_cookie_headers(conn)))
      httr::stop_for_status(result)
      NULL
    }, error = identity)
    Sys.sleep(3)
    after <- fresh()
    verify_emergency_salary(before, after, row)
    audit$writes[[length(audit$writes)]]$status <- "verified"
    audit$writes[[length(audit$writes)]]$after <- after
    saveRDS(audit, receipt)
  }
  remaining <- fresh() |> filter(!is.na(.data$prev_salary), .data$prev_salary == 0)
  if (nrow(remaining)) stop("Snapshot withheld: unresolved $0 salaries: ", paste(paste(remaining$franchise, remaining$player_name), collapse = "; "))
  invisible(audit)
}
