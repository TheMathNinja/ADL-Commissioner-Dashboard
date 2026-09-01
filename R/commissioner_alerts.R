library(dplyr)
library(readr)
library(tibble)

source("R/roster_source.R")

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0 || (length(x) == 1 && is.na(x))) y else x
}

commissioner_alert_dir <- function() {
  Sys.getenv("ADL_ALERT_DIR", unset = file.path("data", "commissioner_alerts"))
}

commissioner_alert_path <- function(name, season = get_current_season(), week = NULL, ext = "csv") {
  dir.create(commissioner_alert_dir(), recursive = TRUE, showWarnings = FALSE)
  week_part <- if (is.null(week) || is.na(week)) "" else paste0("_week", sprintf("%02d", as.integer(week)))
  file.path(commissioner_alert_dir(), paste0(name, "_", season, week_part, ".", ext))
}

commissioner_alert_report_dir <- function() {
  Sys.getenv("ADL_ALERT_REPORT_DIR", unset = file.path("data", "commissioner_alert_reports"))
}

commissioner_alert_report_path <- function(season = get_current_season(), week = NULL, checked_date = Sys.Date()) {
  dir.create(commissioner_alert_report_dir(), recursive = TRUE, showWarnings = FALSE)
  week_part <- if (is.null(week) || is.na(week)) "" else paste0("_week", sprintf("%02d", as.integer(week)))
  file.path(
    commissioner_alert_report_dir(),
    paste0("commissioner_alert_report_", checked_date, "_", season, week_part, ".csv")
  )
}

commissioner_alert_report_metadata_path <- function(season = get_current_season(), week = NULL, checked_date = Sys.Date()) {
  dir.create(commissioner_alert_report_dir(), recursive = TRUE, showWarnings = FALSE)
  week_part <- if (is.null(week) || is.na(week)) "" else paste0("_week", sprintf("%02d", as.integer(week)))
  file.path(
    commissioner_alert_report_dir(),
    paste0("commissioner_alert_report_metadata_", checked_date, "_", season, week_part, ".csv")
  )
}

write_commissioner_alert_report <- function(alerts, season = get_current_season(), week = NULL, checked_at = Sys.time()) {
  checked_at <- as.POSIXct(checked_at, tz = "UTC")
  checked_date <- as.Date(lubridate::with_tz(checked_at, "America/New_York"))
  report_path <- commissioner_alert_report_path(season, week, checked_date = checked_date)
  metadata_path <- commissioner_alert_report_metadata_path(season, week, checked_date = checked_date)

  write_csv(alerts, report_path, na = "")
  write_csv(
    tibble(
      season = season,
      week = week %||% NA_integer_,
      checked_at = format(checked_at, "%Y-%m-%d %H:%M:%S %Z"),
      checked_date = as.character(checked_date),
      report_file = basename(report_path),
      row_count = nrow(alerts)
    ),
    metadata_path,
    na = ""
  )

  report_path
}

commissioner_salary_cap <- function(season = get_current_season()) {
  env_value <- suppressWarnings(as.numeric(Sys.getenv(paste0("ADL_SALARY_CAP_", season), unset = NA_character_)))
  if (!is.na(env_value)) return(env_value)

  caps <- c(
    `2025` = 226.20,
    `2026` = 244.00
  )
  value <- caps[[as.character(season)]]
  if (is.null(value) || is.na(value)) {
    stop("Missing ADL salary cap for ", season, ". Set ADL_SALARY_CAP_", season, ".", call. = FALSE)
  }
  value
}

fetch_mfl_salary_cap_adjustments <- function(season = get_current_season()) {
  conn <- connect_adl_mfl(season)
  franchise_tbl <- tibble::as_tibble(ffscrapr::ff_franchises(conn))
  franchises <- franchise_tbl |>
    transmute(
      franchise_id = as.character(.data$franchise_id),
      franchise_name = as.character(coalesce_col(franchise_tbl, c("franchise_name", "name"))),
      franchise = as.character(coalesce_col(franchise_tbl, c("franchise", "franchise_abbrev", "abbrev"), NA_character_))
    )

  raw <- ffscrapr::mfl_getendpoint(conn, "salaryAdjustments")[["content"]][["salaryAdjustments"]][["salaryAdjustment"]]
  if (is.null(raw) || length(raw) == 0) {
    return(franchises |> mutate(salary_cap_adjustments = 0, adjustment_count = 0L))
  }

  adjustments <- bind_rows(lapply(raw, tibble::as_tibble)) |>
    transmute(
      franchise_id = as.character(.data$franchise_id),
      amount = suppressWarnings(as.numeric(.data$amount))
    ) |>
    group_by(.data$franchise_id) |>
    summarize(
      salary_cap_adjustments = round(sum(.data$amount, na.rm = TRUE), 2),
      adjustment_count = n(),
      .groups = "drop"
    )

  franchises |>
    left_join(adjustments, by = "franchise_id") |>
    mutate(
      salary_cap_adjustments = coalesce(.data$salary_cap_adjustments, 0),
      adjustment_count = coalesce(.data$adjustment_count, 0L)
    )
}

normalize_alert_status <- function(x) {
  x <- toupper(trimws(as.character(x %||% "")))
  dplyr::case_when(
    x %in% c("ROSTER", "ACTIVE", "ACTIVE_ROSTER") ~ "Active",
    x %in% c("TAXI", "TAXI_SQUAD") ~ "Taxi",
    TRUE ~ trimws(as.character(x))
  )
}

active_roster_rows <- function(rosters) {
  rosters |>
    mutate(roster_status = normalize_alert_status(.data$roster_status)) |>
    filter(.data$roster_status == "Active")
}

taxi_roster_rows <- function(rosters) {
  rosters |>
    mutate(roster_status = normalize_alert_status(.data$roster_status)) |>
    filter(.data$roster_status == "Taxi")
}

injured_reserve_rows <- function(rosters) {
  rosters |>
    mutate(roster_status = toupper(normalize_alert_status(.data$roster_status))) |>
    filter(.data$roster_status %in% c("IR", "INJURED_RESERVE", "INJURED RESERVE"))
}

salary_cap_cutoff_date <- function(season = get_current_season()) {
  as.Date(paste0(season, "-07-01"))
}

salary_cap_uses_all_roster_salaries <- function(season = get_current_season(), checked_date = Sys.Date()) {
  as.Date(checked_date) >= salary_cap_cutoff_date(season)
}

salary_cap_suspension_excluded_rows <- function(rosters) {
  roster_tbl <- tibble::as_tibble(rosters)
  status <- toupper(normalize_alert_status(coalesce_col(roster_tbl, c("roster_status", "status"), "")))
  status == "SUSPENDED"
}

commissioner_alert_cutdown_datetime <- function(season = get_current_season(), cutdown_id) {
  defaults <- tibble(
    cutdown_id = c("roster_cutdown_1", "final_roster_cutdown"),
    month_day = c("08-31", "09-07"),
    hour = c(12L, 12L),
    minute = c(0L, 0L)
  )

  row <- defaults |> filter(.data$cutdown_id == .env$cutdown_id)
  if (!nrow(row)) stop("Unknown roster cutdown id: ", cutdown_id, call. = FALSE)

  env_name <- paste0("ADL_", toupper(cutdown_id), "_AT")
  configured <- Sys.getenv(env_name, unset = "")
  if (nzchar(configured)) {
    parsed <- as.POSIXct(configured, tz = "America/New_York")
    if (is.na(parsed)) stop(env_name, " must parse as a datetime.", call. = FALSE)
    return(parsed)
  }

  as.POSIXct(
    sprintf("%s-%s %02d:%02d:00", season, row$month_day[[1]], row$hour[[1]], row$minute[[1]]),
    tz = "America/New_York"
  )
}

commissioner_alert_roster_cap_rule <- function(season = get_current_season(), checked_at = Sys.time(), cutdown_id = NULL) {
  cutdown_id <- cutdown_id %||% {
    checked_at <- as.POSIXct(checked_at, tz = "America/New_York")
    if (checked_at >= commissioner_alert_cutdown_datetime(season, "final_roster_cutdown")) {
      "final_roster_cutdown"
    } else if (checked_at >= commissioner_alert_cutdown_datetime(season, "roster_cutdown_1")) {
      "roster_cutdown_1"
    } else {
      "offseason"
    }
  }

  if (identical(cutdown_id, "final_roster_cutdown")) {
    return(list(
      cutdown_id = "final_roster_cutdown",
      report_subject = "ADL Final Roster Cutdown report",
      violation_subject = "ADL Final Roster Cutdown violation",
      min_active = 40L,
      max_active_taxi = NULL,
      max_non_exempt_active_taxi = 45L,
      max_exempt_active_taxi = 2L,
      exempt_statuses = c("SUSPENDED", "HOLDOUT")
    ))
  }

  if (identical(cutdown_id, "roster_cutdown_1")) {
    return(list(
      cutdown_id = "roster_cutdown_1",
      report_subject = "ADL Roster Cutdown 1 report",
      violation_subject = "ADL Roster Cutdown 1 violation",
      min_active = 40L,
      max_active_taxi = 68L,
      max_non_exempt_active_taxi = NULL,
      max_exempt_active_taxi = NULL,
      exempt_statuses = character()
    ))
  }

  list(
    cutdown_id = "offseason",
    report_subject = NULL,
    violation_subject = NULL,
    min_active = 40L,
    max_active_taxi = 75L,
    max_non_exempt_active_taxi = NULL,
    max_exempt_active_taxi = NULL,
    exempt_statuses = character()
  )
}

roster_cutdown_rule <- function(season = get_current_season(), cutdown_id) {
  commissioner_alert_roster_cap_rule(season = season, cutdown_id = cutdown_id)
}

evaluate_roster_cap_alerts <- function(rosters, min_active = NULL, max_active_taxi = NULL, rule = NULL, season = get_current_season(), checked_at = Sys.time()) {
  rule <- rule %||% commissioner_alert_roster_cap_rule(season = season, checked_at = checked_at)
  min_active <- min_active %||% rule$min_active %||% 40L
  max_active_taxi <- max_active_taxi %||% rule$max_active_taxi
  max_non_exempt_active_taxi <- rule$max_non_exempt_active_taxi
  max_exempt_active_taxi <- rule$max_exempt_active_taxi
  exempt_statuses <- toupper(rule$exempt_statuses %||% character())

  roster_counts <- rosters |>
    mutate(
      roster_status = normalize_alert_status(.data$roster_status),
      roster_status_key = toupper(.data$roster_status),
      active_taxi_player = .data$roster_status %in% c("Active", "Taxi"),
      exempt_player = .data$roster_status_key %in% .env$exempt_statuses
    ) |>
    group_by(.data$conference, .data$franchise, .data$franchise_name) |>
    summarize(
      active_players = sum(.data$roster_status == "Active", na.rm = TRUE),
      taxi_players = sum(.data$roster_status == "Taxi", na.rm = TRUE),
      active_plus_taxi = sum(.data$roster_status %in% c("Active", "Taxi"), na.rm = TRUE),
      non_exempt_active_plus_taxi = sum(.data$active_taxi_player & !.data$exempt_player, na.rm = TRUE),
      exempt_active_plus_taxi = sum(.data$exempt_player, na.rm = TRUE),
      .groups = "drop"
    )

  bind_rows(
    roster_counts |>
      filter(.data$active_players < .env$min_active) |>
      transmute(
        alert_type = "Roster Cap Violation",
        severity = "violation",
        conference,
        franchise,
        franchise_name,
        rule = paste0("At least ", .env$min_active, " players on Active Roster"),
        observed = paste0(.data$active_players, " active players"),
        details = paste0(.env$min_active - .data$active_players, " below minimum")
      ),
    if (!is.null(max_active_taxi)) {
      roster_counts |>
        filter(.data$active_plus_taxi > .env$max_active_taxi) |>
        transmute(
          alert_type = "Roster Cap Violation",
          severity = "violation",
          conference,
          franchise,
          franchise_name,
          rule = paste0("Maximum ", .env$max_active_taxi, " players on Active Roster + Taxi Squad"),
          observed = paste0(.data$active_plus_taxi, " active/taxi players"),
          details = paste0(.data$active_plus_taxi - .env$max_active_taxi, " above maximum")
        )
    },
    if (!is.null(max_non_exempt_active_taxi)) {
      roster_counts |>
        filter(.data$non_exempt_active_plus_taxi > .env$max_non_exempt_active_taxi) |>
        transmute(
          alert_type = "Roster Cap Violation",
          severity = "violation",
          conference,
          franchise,
          franchise_name,
          rule = paste0("Maximum ", .env$max_non_exempt_active_taxi, " non-suspended/non-holdout players on Active Roster + Taxi Squad"),
          observed = paste0(.data$non_exempt_active_plus_taxi, " non-suspended/non-holdout active/taxi players"),
          details = paste0(.data$non_exempt_active_plus_taxi - .env$max_non_exempt_active_taxi, " above maximum")
        )
    },
    if (!is.null(max_exempt_active_taxi)) {
      roster_counts |>
        filter(.data$exempt_active_plus_taxi > .env$max_exempt_active_taxi) |>
        transmute(
          alert_type = "Roster Cap Violation",
          severity = "violation",
          conference,
          franchise,
          franchise_name,
          rule = paste0("Maximum ", .env$max_exempt_active_taxi, " Suspended/Holdout players on Active Roster + Taxi Squad"),
          observed = paste0(.data$exempt_active_plus_taxi, " suspended/holdout players"),
          details = paste0(.data$exempt_active_plus_taxi - .env$max_exempt_active_taxi, " above maximum")
        )
    }
  )
}

commissioner_roster_compliance_summary <- function(rosters, alerts) {
  franchises <- rosters |>
    distinct(.data$conference, .data$franchise, .data$franchise_name)
  violating <- unique(alerts$franchise %||% character())
  violating_teams <- sum(toupper(franchises$franchise) %in% toupper(violating))

  tibble(
    total_teams = nrow(franchises),
    violating_teams = violating_teams,
    compliant_teams = nrow(franchises) - violating_teams
  )
}

evaluate_contract_years_alerts <- function(rosters, max_active_years = 120L) {
  active_roster_rows(rosters) |>
    mutate(prev_years = suppressWarnings(as.numeric(.data$prev_years))) |>
    group_by(.data$conference, .data$franchise, .data$franchise_name) |>
    summarize(
      active_contract_years = sum(.data$prev_years, na.rm = TRUE),
      .groups = "drop"
    ) |>
    filter(.data$active_contract_years > .env$max_active_years) |>
    transmute(
      alert_type = "Contract Years Violation",
      severity = "violation",
      conference,
      franchise,
      franchise_name,
      rule = paste0("Active Roster contract years cannot exceed ", .env$max_active_years),
      observed = paste0(.data$active_contract_years, " active contract years"),
      details = paste0(.data$active_contract_years - .env$max_active_years, " over maximum")
    )
}

format_signed_millions <- function(x) {
  paste0(ifelse(x >= 0, "+$", "-$"), sprintf("%.2f", abs(x)), "m")
}

format_millions <- function(x) {
  paste0("$", sprintf("%.2f", as.numeric(x)), "m")
}

cap_accounting_dir <- function() {
  Sys.getenv(
    "ADL_CAP_ACCOUNTING_DIR",
    unset = file.path("data", "cap_accounting")
  )
}

cap_accounting_summary_dir <- function(season = get_current_season()) {
  file.path(cap_accounting_dir(), as.character(season), "summaries")
}

latest_cap_accounting_summary_path <- function(season = get_current_season()) {
  summary_dir <- cap_accounting_summary_dir(season)
  if (!dir.exists(summary_dir)) return(NA_character_)

  files <- list.files(
    summary_dir,
    pattern = paste0("^", season, "w\\d+_ADLsalarycapsummary\\.(rds|csv)$"),
    full.names = TRUE
  )
  if (!length(files)) return(NA_character_)

  weeks <- suppressWarnings(as.integer(sub(paste0("^.*", season, "w(\\d+)_ADLsalarycapsummary\\.(rds|csv)$"), "\\1", files)))
  files <- files[order(weeks, tools::file_ext(files) == "rds", decreasing = TRUE)]
  files[[1]]
}

read_cap_accounting_summary <- function(season = get_current_season(), path = latest_cap_accounting_summary_path(season)) {
  if (is.na(path) || !nzchar(path) || !file.exists(path)) return(NULL)
  if (identical(tolower(tools::file_ext(path)), "rds")) {
    return(readRDS(path))
  }
  read_csv(path, show_col_types = FALSE)
}

cap_numeric <- function(x) {
  suppressWarnings(as.numeric(gsub("[$,]", "", as.character(x))))
}

cap_col <- function(row, name, default = NA_real_) {
  if (!name %in% names(row)) return(default)
  row[[name]]
}

cap_accounting_week_numbers <- function(summary_tbl) {
  cols <- names(summary_tbl)
  weeks <- suppressWarnings(as.integer(sub("^W(\\d+)_.*$", "\\1", cols[grepl("^W\\d+_", cols)])))
  sort(unique(weeks[!is.na(weeks)]))
}

cap_accounting_week_expenditure <- function(row, week) {
  final <- cap_numeric(cap_col(row, paste0("W", week, "_Final")))
  if (!is.na(final)) return(final)

  rost_sal <- cap_numeric(cap_col(row, paste0("W", week, "_RostSal")))
  if (is.na(rost_sal)) return(NA_real_)

  adj <- cap_numeric(cap_col(row, paste0("W", week, "_Adj"), 0))
  corr <- cap_numeric(cap_col(row, paste0("W", week, "_Corr"), 0))
  round(rost_sal + coalesce(adj, 0) + coalesce(corr, 0), 2)
}

current_cap_accounting_expenditure <- function(rosters, season = get_current_season(), salary_cap_adjustments = NULL) {
  roster_tbl <- rosters |>
    mutate(
      roster_status_calc = toupper(normalize_alert_status(.data$roster_status)),
      salary_num = suppressWarnings(as.numeric(.data$prev_salary)),
      is_taxi_suspended = .data$roster_status_calc == "TAXI" & toupper(as.character(.data$roster_status)) == "SUSPENDED"
    )

  current <- roster_tbl |>
    group_by(.data$conference, .data$franchise, .data$franchise_name) |>
    summarize(
      live_salary = round(
        sum(.data$salary_num, na.rm = TRUE) -
          sum(if_else(.data$is_taxi_suspended, .data$salary_num, 0), na.rm = TRUE),
        2
      ),
      franchise_salary_cap = suppressWarnings(max(as.numeric(.data$franchise_salary_cap), na.rm = TRUE)),
      .groups = "drop"
    )

  if (!is.null(salary_cap_adjustments)) {
    adjustment_tbl <- tibble::as_tibble(salary_cap_adjustments) |>
      transmute(
        franchise = as.character(.data$franchise),
        live_adjustments = suppressWarnings(as.numeric(.data$salary_cap_adjustments))
      )

    current <- current |>
      left_join(adjustment_tbl, by = "franchise")
  } else {
    current$live_adjustments <- 0
  }

  current |>
    mutate(
      franchise_salary_cap = if_else(
        is.infinite(.data$franchise_salary_cap) | is.na(.data$franchise_salary_cap),
        commissioner_salary_cap(.env$season),
        .data$franchise_salary_cap
      ),
      live_adjustments = coalesce(.data$live_adjustments, 0),
      live_accounting_salary = round(.data$live_salary + .data$live_adjustments, 2)
    )
}

evaluate_salary_cap_average_warnings <- function(
  rosters,
  season = get_current_season(),
  salary_cap_adjustments = NULL,
  summary = read_cap_accounting_summary(season)
) {
  current <- current_cap_accounting_expenditure(rosters, season = season, salary_cap_adjustments = salary_cap_adjustments)

  history <- if (is.null(summary) || !nrow(summary) || !"FRANCHISE" %in% names(summary)) {
    tibble(
      franchise = character(),
      completed_snapshots = integer(),
      cumulative_spending = numeric(),
      last_average_spending = numeric()
    )
  } else {
    summary_tbl <- tibble::as_tibble(summary)
    weeks <- cap_accounting_week_numbers(summary_tbl)

    bind_rows(lapply(seq_len(nrow(summary_tbl)), function(i) {
      row <- summary_tbl[i, , drop = FALSE]
      weekly_values <- vapply(weeks, function(week) cap_accounting_week_expenditure(row, week), numeric(1))
      completed <- weekly_values[!is.na(weekly_values)]
      tibble(
        franchise = as.character(row$FRANCHISE[[1]]),
        completed_snapshots = length(completed),
        cumulative_spending = round(sum(completed, na.rm = TRUE), 2),
        last_average_spending = if (length(completed)) round(mean(completed, na.rm = TRUE), 2) else NA_real_
      )
    }))
  }

  current |>
    left_join(history, by = "franchise") |>
    mutate(
      completed_snapshots = coalesce(.data$completed_snapshots, 0L),
      cumulative_spending = coalesce(.data$cumulative_spending, 0),
      projected_average = round((.data$cumulative_spending + .data$live_accounting_salary) / (.data$completed_snapshots + 1), 2),
      required_live_salary = round(.data$franchise_salary_cap * (.data$completed_snapshots + 1) - .data$cumulative_spending, 2),
      projected_overage = round(.data$projected_average - .data$franchise_salary_cap, 2)
    ) |>
    filter(.data$projected_overage > 0) |>
    transmute(
      alert_type = "Salary Cap Warning",
      severity = "warning",
      conference,
      franchise,
      franchise_name,
      rule = if_else(
        .data$completed_snapshots == 0,
        paste0("First weekly salary snapshot must be at or below franchise cap of ", format_millions(.data$franchise_salary_cap), "."),
        paste0("Average weekly salary spending must remain at or below franchise cap of ", format_millions(.data$franchise_salary_cap), ".")
      ),
      observed = if_else(
        .data$completed_snapshots == 0,
        paste0("Current franchise expenditures are ", format_millions(.data$live_accounting_salary), " before the first salary snapshot."),
        paste0("Current rostered salary would raise projected average to ", format_millions(.data$projected_average), " at the next salary snapshot.")
      ),
      details = paste0("Required: Bring live salary down to ", format_millions(.data$required_live_salary), " to be cap-compliant at next snapshot.")
    )
}

evaluate_salary_cap_alerts <- function(
  rosters,
  season = get_current_season(),
  top_n = 43L,
  cap = commissioner_salary_cap(season),
  salary_cap_adjustments = NULL,
  checked_date = Sys.Date()
) {
  use_all_roster_salaries <- salary_cap_uses_all_roster_salaries(season, checked_date)
  salary_pool_label <- if (use_all_roster_salaries) {
    paste0("Top ", top_n, " Salaries")
  } else {
    paste0("Top ", top_n, " Active Roster Salaries")
  }

  salary_tbl <- if (use_all_roster_salaries) {
    rosters |> mutate(roster_status = normalize_alert_status(.data$roster_status))
  } else {
    active_roster_rows(rosters)
  }
  if (!"franchise_salary_cap" %in% names(salary_tbl)) {
    salary_tbl$franchise_salary_cap <- NA_real_
  }
  salary_tbl <- salary_tbl[!salary_cap_suspension_excluded_rows(salary_tbl), , drop = FALSE]

  salary_summary <- salary_tbl |>
    mutate(prev_salary = suppressWarnings(as.numeric(.data$prev_salary))) |>
    filter(!is.na(.data$prev_salary)) |>
    group_by(.data$conference, .data$franchise, .data$franchise_name) |>
    arrange(desc(.data$prev_salary), .data$player_name, .by_group = TRUE) |>
    slice_head(n = top_n) |>
    summarize(
      top_salary_count = n(),
      top_salary_total = round(sum(.data$prev_salary, na.rm = TRUE), 2),
      franchise_salary_cap = coalesce(
        suppressWarnings(max(as.numeric(.data$franchise_salary_cap), na.rm = TRUE)),
        .env$cap
      ),
      .groups = "drop"
    )

  if (!is.null(salary_cap_adjustments)) {
    adjustment_tbl <- tibble::as_tibble(salary_cap_adjustments) |>
      transmute(
        franchise = as.character(.data$franchise),
        salary_cap_adjustments = suppressWarnings(as.numeric(.data$salary_cap_adjustments))
      )

    salary_summary <- salary_summary |>
      left_join(adjustment_tbl, by = "franchise")
  } else {
    salary_summary$salary_cap_adjustments <- 0
  }

  salary_summary |>
    mutate(
      franchise_salary_cap = if_else(is.infinite(.data$franchise_salary_cap), .env$cap, .data$franchise_salary_cap),
      salary_cap_adjustments = coalesce(.data$salary_cap_adjustments, 0),
      final_expenditure = round(.data$top_salary_total + .data$salary_cap_adjustments, 2),
      overage = round(.data$final_expenditure - .data$franchise_salary_cap, 2)
    ) |>
    filter(.data$overage > 0) |>
    transmute(
      alert_type = "Salary Cap Violation",
      severity = "violation",
      conference,
      franchise,
      franchise_name,
      rule = paste0(.env$salary_pool_label, " plus cap adjustments exceeds franchise cap of $", sprintf("%.2f", .data$franchise_salary_cap), "m."),
      observed = paste0("$", sprintf("%.2f", .data$final_expenditure), "m"),
      details = paste0(
        .env$salary_pool_label, ": $", sprintf("%.2f", .data$top_salary_total), "m\n",
        "Salary Adjustments: ", format_signed_millions(.data$salary_cap_adjustments), "\n",
        "Total Expenditures: $", sprintf("%.2f", .data$final_expenditure), "m\n",
        "$", sprintf("%.2f", .data$overage), "m over cap."
      )
    )
}

normalize_lineups <- function(starters, franchises = NULL) {
  starters_tbl <- tibble::as_tibble(starters)
  if (!nrow(starters_tbl)) {
    return(tibble(
      franchise_id = character(), franchise = character(), franchise_name = character(),
      player_id = character(), player_name = character(), player_team = character(),
      player_pos = character(), lineup_slot = character()
    ))
  }

  lineups <- starters_tbl |>
    transmute(
      franchise_id = as.character(coalesce_col(starters_tbl, c("franchise_id", "franchiseId"))),
      player_id = as.character(coalesce_col(starters_tbl, c("player_id", "playerId", "id"))),
      player_name = as.character(coalesce_col(starters_tbl, c("player_name", "player", "name"))),
      player_team = as.character(coalesce_col(starters_tbl, c("team", "player_team"))),
      player_pos = as.character(coalesce_col(starters_tbl, c("pos", "position", "player_pos"))),
      lineup_slot = as.character(coalesce_col(starters_tbl, c("lineup_slot", "slot", "starter_position", "starter_position")))
    )

  if (!is.null(franchises)) {
    franchise_tbl <- tibble::as_tibble(franchises)
    fr <- franchise_tbl |>
      transmute(
        franchise_id = as.character(.data$franchise_id),
        franchise_name = as.character(coalesce_col(franchise_tbl, c("franchise_name", "name"))),
        franchise = as.character(coalesce_col(franchise_tbl, c("franchise", "franchise_abbrev", "abbrev"), NA_character_))
      )
  } else {
    fr <- tibble(franchise_id = character(), franchise_name = character(), franchise = character())
  }

  lineups |>
    left_join(fr, by = "franchise_id") |>
    mutate(
      franchise = coalesce(.data$franchise, franchise_code_from_name(.data$franchise_name)),
      conference = case_when(
        suppressWarnings(as.integer(.data$franchise_id)) <= 16L ~ "NFC",
        suppressWarnings(as.integer(.data$franchise_id)) >= 17L ~ "AFC",
        TRUE ~ NA_character_
      )
    ) |>
    select(conference, franchise, franchise_name, franchise_id, player_id, player_name, player_team, player_pos, lineup_slot)
}

list_records <- function(x, record_names = character()) {
  if (is.null(x) || length(x) == 0) return(list())
  if (is.data.frame(x)) {
    return(lapply(seq_len(nrow(x)), function(i) x[i, , drop = FALSE]))
  }
  if (is.list(x) && !is.null(names(x)) && any(names(x) %in% record_names)) {
    return(list(x))
  }
  if (is.list(x)) return(x)
  list()
}

record_field <- function(x, name, default = NA_character_) {
  if (is.null(x) || !name %in% names(x)) return(default)
  value <- x[[name]]
  if (is.null(value) || length(value) == 0) return(default)
  if (is.data.frame(value)) return(as.character(value[[1]][[1]] %||% default))
  as.character(value[[1]] %||% default)
}

normalize_mfl_weekly_result_lineups <- function(raw) {
  matchups <- list_records(raw, record_names = c("franchise"))
  rows <- list()

  for (matchup in matchups) {
    franchises <- list_records(matchup[["franchise"]], record_names = c("id", "player"))
    for (franchise in franchises) {
      franchise_id <- record_field(franchise, "id")
      players <- list_records(franchise[["player"]], record_names = c("id", "status"))
      for (player in players) {
        rows[[length(rows) + 1L]] <- tibble(
          franchise_id = franchise_id,
          player_id = record_field(player, "id"),
          starter_status = record_field(player, "status"),
          should_start = suppressWarnings(as.numeric(record_field(player, "shouldStart", NA_character_))),
          player_score = suppressWarnings(as.numeric(record_field(player, "score", NA_character_)))
        )
      }
    }
  }

  if (!length(rows)) {
    return(tibble(
      franchise_id = character(),
      player_id = character(),
      starter_status = character(),
      should_start = numeric(),
      player_score = numeric()
    ))
  }

  result <- bind_rows(rows) |>
    filter(!is.na(.data$franchise_id), nzchar(.data$franchise_id), !is.na(.data$player_id), nzchar(.data$player_id)) |>
    distinct(.data$franchise_id, .data$player_id, .keep_all = TRUE)

  starter_status_key <- tolower(trimws(result$starter_status %||% character()))
  starter_status_present <- any(nzchar(starter_status_key) & !is.na(starter_status_key))
  if (starter_status_present) {
    result <- result |>
      filter(tolower(trimws(.data$starter_status)) %in% c("starter", "start", "s", "1", "true"))
  }

  result
}

fetch_live_lineups <- function(season = get_current_season(), week) {
  conn <- connect_adl_mfl(season)
  franchises <- ffscrapr::ff_franchises(conn)
  weekly_results <- ffscrapr::mfl_getendpoint(conn, "weeklyResults", W = week, YEAR = season)[["content"]][["weeklyResults"]][["matchup"]]
  starters <- normalize_mfl_weekly_result_lineups(weekly_results)
  players_response <- ffscrapr::mfl_getendpoint(conn, "players")
  players_raw <- players_response[["content"]][["players"]][["player"]]
  player_records <- list_records(players_raw, record_names = c("id", "name", "team", "position"))
  players <- tibble(
    player_id = vapply(player_records, record_field, character(1), name = "id"),
    player_name = vapply(player_records, record_field, character(1), name = "name"),
    team = vapply(player_records, record_field, character(1), name = "team"),
    pos = vapply(player_records, record_field, character(1), name = "position")
  ) |>
    filter(!is.na(.data$player_id), nzchar(.data$player_id)) |>
    distinct(.data$player_id, .keep_all = TRUE)

  starters <- starters |>
    mutate(player_id = as.character(.data$player_id)) |>
    left_join(players, by = "player_id")

  normalize_lineups(starters, franchises)
}

cache_lineups_snapshot <- function(season = get_current_season(), week, force_live = TRUE) {
  lineups <- if (force_live) {
    fetch_live_lineups(season = season, week = week)
  } else {
    path <- commissioner_alert_path("lineups_snapshot", season, week)
    if (!file.exists(path)) stop("Missing lineup snapshot: ", path)
    read_csv(path, show_col_types = FALSE)
  }

  write_csv(lineups, commissioner_alert_path("lineups_snapshot", season, week), na = "")
  lineups
}

normalize_mfl_injury_designations <- function(raw) {
  if (is.null(raw) || length(raw) == 0) {
    return(tibble(player_id = character(), player_status = character()))
  }

  raw_tbl <- if (is.data.frame(raw)) {
    tibble::as_tibble(raw)
  } else if (is.list(raw) && !is.null(names(raw)) && all(c("id", "status") %in% names(raw))) {
    tibble::as_tibble(raw)
  } else if (is.list(raw)) {
    bind_rows(lapply(raw, tibble::as_tibble))
  } else {
    tibble()
  }

  if (!all(c("id", "status") %in% names(raw_tbl))) {
    return(tibble(player_id = character(), player_status = character()))
  }

  raw_tbl |>
    transmute(
      player_id = as.character(.data$id),
      player_status = as.character(.data$status)
    ) |>
    filter(
      !is.na(.data$player_id),
      nzchar(.data$player_id),
      !is.na(.data$player_status),
      nzchar(.data$player_status)
    ) |>
    distinct(.data$player_id, .keep_all = TRUE)
}

fetch_mfl_injury_payload <- function(season = get_current_season(), week = NULL) {
  query <- list(
    TYPE = "injuries",
    L = as.integer(get_env_or_default("ADL_LEAGUE_ID", "60206")),
    JSON = 1
  )
  if (!is.null(week) && !is.na(week)) query$W <- as.integer(week)

  response <- tryCatch(
    httr::GET(
      url = paste0("https://api.myfantasyleague.com/", season, "/export"),
      query = query,
      httr::user_agent(get_env_or_default("MFL_USER_AGENT", "ADLCommissionerDashboard"))
    ),
    error = function(e) e
  )

  if (inherits(response, "error")) {
    warning("MFL injury endpoint unavailable: ", conditionMessage(response), call. = FALSE)
    return(NULL)
  }

  injury_text <- httr::content(response, "text", encoding = "UTF-8")
  injury_json <- tryCatch(jsonlite::fromJSON(injury_text, flatten = TRUE), error = function(e) e)

  if (inherits(injury_json, "error")) {
    warning("Could not parse MFL injury endpoint response: ", conditionMessage(injury_json), call. = FALSE)
    return(NULL)
  }

  if ("error" %in% names(injury_json)) {
    warning("MFL injury endpoint returned error: ", injury_json$error$`$t` %||% "unknown error", call. = FALSE)
    return(NULL)
  }

  injury_json[["injuries"]][["injury"]]
}

fetch_mfl_weekly_designations <- function(season = get_current_season(), week) {
  raw_payloads <- list(
    fetch_mfl_injury_payload(season = season, week = week),
    fetch_mfl_injury_payload(season = season, week = NULL)
  )

  bind_rows(lapply(raw_payloads, normalize_mfl_injury_designations)) |>
    distinct(.data$player_id, .keep_all = TRUE)
}

mfl_player_team <- function(team) {
  team <- toupper(trimws(as.character(team %||% "")))
  dplyr::recode(
    team,
    ARZ = "ARI",
    JAX = "JAC",
    KC = "KCC",
    GB = "GBP",
    NO = "NOS",
    NE = "NEP",
    SF = "SFO",
    TB = "TBB",
    LA = "LAR",
    STL = "LAR",
    OAK = "LVR",
    SD = "LAC",
    .default = team
  )
}

nfl_schedule_type_col <- function(schedule) {
  dplyr::case_when(
    "season_type" %in% names(schedule) ~ "season_type",
    "game_type" %in% names(schedule) ~ "game_type",
    TRUE ~ NA_character_
  )
}

nfl_game_kickoff_at <- function(schedule) {
  if ("game_datetime" %in% names(schedule)) {
    kickoff <- lubridate::ymd_hms(schedule$game_datetime, quiet = TRUE, tz = "UTC")
    if (all(is.na(kickoff))) {
      kickoff <- as.POSIXct(schedule$game_datetime, tz = "UTC")
    }
    return(kickoff)
  }

  if (all(c("gameday", "gametime") %in% names(schedule))) {
    return(as.POSIXct(
      paste(schedule$gameday, schedule$gametime),
      format = "%Y-%m-%d %H:%M",
      tz = "America/New_York"
    ))
  }

  if ("gameday" %in% names(schedule)) {
    return(as.POSIXct(paste(schedule$gameday, "00:00"), format = "%Y-%m-%d %H:%M", tz = "America/New_York"))
  }

  rep(as.POSIXct(NA), nrow(schedule))
}

read_nfl_team_kickoffs <- function(season = get_current_season(), week) {
  if (!requireNamespace("nflreadr", quietly = TRUE)) {
    warning("nflreadr is not installed; kickoff-aware lineup alert severity is unavailable.", call. = FALSE)
    return(tibble(player_team = character(), kickoff_at = as.POSIXct(character())))
  }

  schedule <- nflreadr::load_schedules(seasons = season)
  schedule_type_col <- nfl_schedule_type_col(schedule)
  if (is.na(schedule_type_col)) {
    warning("NFL schedule has no season_type or game_type column; kickoff-aware lineup alert severity is unavailable.", call. = FALSE)
    return(tibble(player_team = character(), kickoff_at = as.POSIXct(character())))
  }

  games <- schedule |>
    filter(.data[[schedule_type_col]] == "REG", .data$week == .env$week) |>
    mutate(kickoff_at = nfl_game_kickoff_at(dplyr::cur_data_all()))

  if (!nrow(games)) {
    return(tibble(player_team = character(), kickoff_at = as.POSIXct(character())))
  }

  bind_rows(
    games |> transmute(player_team = mfl_player_team(.data$home_team), kickoff_at),
    games |> transmute(player_team = mfl_player_team(.data$away_team), kickoff_at)
  ) |>
    filter(!is.na(.data$kickoff_at), nzchar(.data$player_team)) |>
    distinct(.data$player_team, .keep_all = TRUE)
}

commissioner_alert_designation_snapshot_dir <- function(season = get_current_season(), week = NULL) {
  week_part <- if (is.null(week) || is.na(week)) "weekNA" else paste0("week", sprintf("%02d", as.integer(week)))
  file.path(commissioner_alert_dir(), "designation_snapshots", as.character(season), week_part)
}

commissioner_alert_designation_snapshot_path <- function(season = get_current_season(), week = NULL, snapshot_time = Sys.time()) {
  dir <- commissioner_alert_designation_snapshot_dir(season, week)
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  stamp <- format(lubridate::with_tz(snapshot_time, "UTC"), "%Y%m%d_%H%M%S")
  file.path(dir, paste0("designation_snapshot_", season, "_week", sprintf("%02d", as.integer(week)), "_", stamp, ".csv"))
}

cache_designation_snapshot <- function(season = get_current_season(), week = NULL, force_live = TRUE) {
  snapshot_time <- Sys.time()
  rosters <- load_current_rosters(
    force_live = force_live,
    source = if (force_live) "live" else "auto",
    season = season,
    week = week,
    cache_path = commissioner_alert_path("designation_rosters_cache", season, week)
  )

  weekly_designations <- if (force_live && !is.null(week) && !is.na(week)) {
    tryCatch(
      fetch_mfl_weekly_designations(season = season, week = week),
      error = function(e) {
        warning("MFL weekly designations unavailable; using roster player status: ", conditionMessage(e), call. = FALSE)
        tibble(player_id = character(), player_status = character())
      }
    )
  } else {
    tibble(player_id = character(), player_status = character())
  }

  snapshot <- rosters |>
    left_join(
      weekly_designations |> rename(weekly_player_status = player_status),
      by = "player_id"
    ) |>
    transmute(
      captured_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
      snapshot_time = lubridate::with_tz(.env$snapshot_time, "UTC"),
      season = .env$season,
      week = .env$week %||% NA_integer_,
      conference,
      franchise,
      franchise_name,
      player_id,
      player_name,
      player_team,
      player_pos,
      roster_status = normalize_alert_status(.data$roster_status),
      player_status = coalesce(na_if(.data$weekly_player_status, ""), na_if(.data$player_status, ""))
    )

  write_csv(snapshot, commissioner_alert_designation_snapshot_path(season, week, snapshot_time), na = "")
  write_csv(snapshot, commissioner_alert_path("designation_snapshot", season, week), na = "")
  snapshot
}

read_designation_snapshot <- function(season = get_current_season(), week = NULL) {
  path <- commissioner_alert_path("designation_snapshot", season, week)
  if (!file.exists(path)) return(NULL)
  normalize_designation_snapshot_time(read_csv(path, show_col_types = FALSE))
}

normalize_designation_snapshot_time <- function(snapshot) {
  snapshot <- tibble::as_tibble(snapshot)
  if (!nrow(snapshot)) {
    snapshot$snapshot_time <- as.POSIXct(character())
    return(snapshot)
  }

  if ("snapshot_time" %in% names(snapshot)) {
    parsed <- suppressWarnings(lubridate::ymd_hms(snapshot$snapshot_time, quiet = TRUE, tz = "UTC"))
    needs_fallback <- is.na(parsed)
    parsed[needs_fallback] <- suppressWarnings(as.POSIXct(snapshot$snapshot_time[needs_fallback], tz = "UTC"))
  } else if ("captured_at" %in% names(snapshot)) {
    parsed <- suppressWarnings(lubridate::parse_date_time(
      snapshot$captured_at,
      orders = c("Ymd HMS z", "Ymd HMS", "Ymd HM z", "Ymd HM"),
      tz = "America/New_York"
    ))
  } else {
    parsed <- rep(as.POSIXct(NA), nrow(snapshot))
  }

  snapshot$snapshot_time <- lubridate::with_tz(parsed, "UTC")
  snapshot
}

read_designation_snapshot_history <- function(season = get_current_season(), week = NULL) {
  snapshot_dir <- commissioner_alert_designation_snapshot_dir(season, week)
  snapshot_files <- if (dir.exists(snapshot_dir)) {
    list.files(snapshot_dir, pattern = "^designation_snapshot_.*\\.csv$", full.names = TRUE)
  } else {
    character()
  }

  snapshots <- bind_rows(lapply(snapshot_files, function(path) {
    read_csv(path, show_col_types = FALSE) |>
      normalize_designation_snapshot_time()
  }))

  latest_snapshot <- read_designation_snapshot(season, week)
  bind_rows(snapshots, latest_snapshot) |>
    filter(!is.na(.data$snapshot_time)) |>
    distinct(.data$player_id, .data$snapshot_time, .keep_all = TRUE)
}

select_72h_designations_for_lineup <- function(lineups, designation_history, kickoffs) {
  if (is.null(designation_history) || !nrow(designation_history) || is.null(kickoffs) || !nrow(kickoffs)) {
    return(tibble(
      player_id = character(),
      designation_72h = character(),
      designation_snapshot_time = as.POSIXct(character()),
      kickoff_at = as.POSIXct(character())
    ))
  }

  lineups |>
    transmute(
      player_id = as.character(.data$player_id),
      player_team = mfl_player_team(.data$player_team)
    ) |>
    left_join(kickoffs, by = "player_team") |>
    filter(!is.na(.data$kickoff_at)) |>
    left_join(
      designation_history |>
        transmute(
          player_id = as.character(.data$player_id),
          designation_72h = as.character(coalesce_col(designation_history, c("player_status", "roster_status"), NA_character_)),
          designation_snapshot_time = .data$snapshot_time
        ),
      by = "player_id"
    ) |>
    filter(!is.na(.data$designation_snapshot_time), .data$designation_snapshot_time <= .data$kickoff_at - lubridate::hours(72)) |>
    arrange(.data$player_id, desc(.data$designation_snapshot_time)) |>
    group_by(.data$player_id) |>
    slice_head(n = 1L) |>
    ungroup() |>
    select(player_id, designation_72h, designation_snapshot_time, kickoff_at)
}

inactive_designation <- function(x) {
  x <- toupper(trimws(as.character(x %||% "")))
  grepl("\\((S|I|H|O)\\)", x) |
    x %in% c("S", "I", "H", "O", "SUSPENDED", "INJURED", "INJURED RESERVE", "INJURED_RESERVE", "IR", "IR-R", "HOLDOUT", "OUT")
}

lineup_alert_severity <- function(kickoff_at, checked_at = Sys.time()) {
  kickoff_at <- as.POSIXct(kickoff_at, tz = "UTC")
  checked_at <- as.POSIXct(checked_at, tz = "UTC")
  ifelse(!is.na(kickoff_at) & checked_at >= kickoff_at, "violation", "warning")
}

lineup_alert_type <- function(severity) {
  ifelse(identical(severity, "warning") | severity == "warning", "Illegal Lineup Warning", "Illegal Lineup")
}

lineup_alert_date <- function(x) {
  as.Date(lubridate::with_tz(as.POSIXct(x, tz = "UTC"), "America/New_York"))
}

lineup_week_first_game_date <- function(kickoffs) {
  if (is.null(kickoffs) || !nrow(kickoffs) || !"kickoff_at" %in% names(kickoffs)) {
    return(as.Date(NA))
  }

  kickoff_dates <- lineup_alert_date(kickoffs$kickoff_at)
  kickoff_dates <- kickoff_dates[!is.na(kickoff_dates)]
  if (!length(kickoff_dates)) as.Date(NA) else min(kickoff_dates)
}

franchise_lineup_lock_times <- function(lineups, kickoffs) {
  if (is.null(kickoffs) || !nrow(kickoffs)) {
    return(tibble(franchise_id = unique(lineups$franchise_id), lineup_lock_at = as.POSIXct(NA)))
  }

  lineups |>
    transmute(
      franchise_id = as.character(.data$franchise_id),
      player_team = mfl_player_team(.data$player_team)
    ) |>
    left_join(kickoffs, by = "player_team") |>
    group_by(.data$franchise_id) |>
    summarize(
      lineup_lock_at = {
        kickoff_values <- .data$kickoff_at[!is.na(.data$kickoff_at)]
        if (length(kickoff_values)) min(kickoff_values) else as.POSIXct(NA)
      },
      .groups = "drop"
    )
}

adl_lineup_position_rules <- function() {
  tibble(
    player_pos = c("QB", "RB", "WR", "TE", "PK", "PN", "DT", "DE", "LB", "CB", "S"),
    min_starters = c(1L, 1L, 2L, 1L, 1L, 1L, 2L, 2L, 1L, 2L, 2L),
    max_starters = c(1L, 2L, 4L, 2L, 1L, 1L, 3L, 3L, 3L, 4L, 3L),
    lineup_group = c("OFF", "OFF", "OFF", "OFF", "SPEC", "SPEC", "DEF", "DEF", "DEF", "DEF", "DEF")
  )
}

adl_lineup_group_rules <- function() {
  tibble(
    lineup_group = c("OFF", "DEF"),
    group_label = c("QB/RB/WR/TE", "DT/DE/LB/CB/S"),
    required_starters = c(7L, 12L)
  )
}

format_additional_starters <- function(count, positions) {
  positions <- positions[!is.na(positions) & nzchar(positions)]
  if (!length(positions)) return("below required starter count")
  paste0("Must start ", count, " additional ", paste(positions, collapse = "/"))
}

format_and_list <- function(x) {
  x <- x[!is.na(x) & nzchar(x)]
  if (!length(x)) return("")
  if (length(x) == 1L) return(x)
  paste0(paste(head(x, -1L), collapse = ", "), " and ", tail(x, 1L))
}

replacement_family <- function(player_pos) {
  player_pos <- toupper(trimws(as.character(player_pos %||% "")))
  if (player_pos == "QB") return("QB")
  if (player_pos %in% c("RB", "WR", "TE")) return(c("RB", "WR", "TE"))
  if (player_pos == "PK") return("PK")
  if (player_pos == "PN") return("PN")
  if (player_pos %in% c("DT", "DE", "LB", "CB", "S")) return(c("DT", "DE", "LB", "CB", "S"))
  player_pos
}

format_group_starter_shortage <- function(group_name, short, position_status) {
  group_positions <- position_status |>
    filter(.data$lineup_group == .env$group_name)

  below_minimum <- group_positions |>
    mutate(short = .data$min_starters - .data$starter_count) |>
    filter(.data$short > 0L)

  requirement_parts <- character()
  adjusted_counts <- group_positions

  if (nrow(below_minimum)) {
    requirement_parts <- paste(below_minimum$short, "additional", below_minimum$player_pos)
    adjusted_counts <- adjusted_counts |>
      left_join(
        below_minimum |> transmute(player_pos, min_short = .data$short),
        by = "player_pos"
      ) |>
      mutate(
        min_short = coalesce(.data$min_short, 0L),
        starter_count = .data$starter_count + .data$min_short
      ) |>
      select(-min_short)
  }

  remaining_short <- short - sum(below_minimum$short)
  if (remaining_short > 0L) {
    eligible_positions <- adjusted_counts |>
      filter(.data$starter_count < .data$max_starters) |>
      pull(.data$player_pos)
    requirement_parts <- c(
      requirement_parts,
      paste(remaining_short, "additional", paste(eligible_positions, collapse = "/"))
    )
  }

  paste0("Must start ", format_and_list(requirement_parts))
}

format_group_observed_note <- function(group_name, position_status) {
  group_positions <- position_status |>
    filter(.data$lineup_group == .env$group_name)

  below_minimum <- group_positions |>
    filter(.data$starter_count < .data$min_starters)

  if (identical(as.character(group_name), "OFF")) {
    qb_count <- group_positions |>
      filter(.data$player_pos == "QB") |>
      pull(.data$starter_count)
    flex_count <- group_positions |>
      filter(.data$player_pos %in% c("RB", "WR", "TE")) |>
      summarise(total = sum(.data$starter_count), .groups = "drop") |>
      pull(.data$total)
    return(paste0(qb_count %||% 0L, " QB, ", flex_count %||% 0L, " RB/WR/TE"))
  }

  if (nrow(below_minimum)) {
    return(paste(paste0(below_minimum$starter_count, " ", below_minimum$player_pos), collapse = ", "))
  }

  paste(paste0(group_positions$starter_count, " ", group_positions$player_pos), collapse = ", ")
}

lineup_position_status <- function(franchise_id, lineups) {
  position_counts <- lineups |>
    filter(.data$franchise_id == .env$franchise_id) |>
    mutate(player_pos = toupper(trimws(as.character(.data$player_pos)))) |>
    count(.data$player_pos, name = "starter_count")

  adl_lineup_position_rules() |>
    left_join(position_counts, by = "player_pos") |>
    mutate(starter_count = coalesce(.data$starter_count, 0L))
}

lineup_starter_count_context <- function(franchise_id, starter_count, lineups, expected_starters = 21L) {
  position_status <- lineup_position_status(franchise_id, lineups)
  group_rules <- adl_lineup_group_rules()
  default_context <- list(
    rule = paste0("Exactly ", expected_starters, " starters submitted"),
    observed = paste0(starter_count, " starters"),
    details = "starter count is correct"
  )

  if (starter_count > expected_starters) {
    extra <- starter_count - expected_starters
    default_context$details <- paste0(extra, " above required starter count")
    return(default_context)
  }

  missing_starters <- expected_starters - starter_count
  if (missing_starters <= 0L) return(default_context)

  below_minimum <- position_status |>
    mutate(short = .data$min_starters - .data$starter_count) |>
    filter(.data$short > 0L)

  if (nrow(below_minimum)) {
    primary_shortage <- below_minimum |> slice_head(n = 1L)
    return(list(
      rule = paste0(
        "Starting lineups require ", expected_starters,
        " starters, including minimum ", primary_shortage$min_starters[[1]],
        " ", primary_shortage$player_pos[[1]]
      ),
      observed = paste0(
        starter_count, " starters (",
        primary_shortage$starter_count[[1]], " ",
        primary_shortage$player_pos[[1]], ")"
      ),
      details = paste(
        paste0("Must start ", below_minimum$short, " additional ", below_minimum$player_pos),
        collapse = "; "
      )
    ))
  }

  group_status <- position_status |>
    filter(.data$lineup_group %in% group_rules$lineup_group) |>
    group_by(.data$lineup_group) |>
    summarise(group_starters = sum(.data$starter_count), .groups = "drop") |>
    right_join(group_rules, by = "lineup_group") |>
    mutate(
      group_starters = coalesce(.data$group_starters, 0L),
      short = .data$required_starters - .data$group_starters
    ) |>
    filter(.data$short > 0L)

  if (nrow(group_status)) {
    group_details <- vapply(seq_len(nrow(group_status)), function(i) {
      group_name <- group_status$lineup_group[[i]]
      eligible_positions <- position_status |>
        filter(.data$lineup_group == .env$group_name, .data$starter_count < .data$max_starters) |>
        pull(.data$player_pos)
      format_additional_starters(group_status$short[[i]], eligible_positions)
    }, character(1))
    primary_group <- group_status |> slice_head(n = 1L)
    return(list(
      rule = paste0(
        "Starting lineups require ", expected_starters,
        " starters, including exactly ", primary_group$required_starters[[1]],
        " ", primary_group$group_label[[1]]
      ),
      observed = paste0(
        starter_count, " starters (",
        primary_group$group_starters[[1]], " ",
        primary_group$group_label[[1]], ")"
      ),
      details = paste(group_details, collapse = "; ")
    ))
  }

  eligible_positions <- position_status |>
    filter(.data$starter_count < .data$max_starters) |>
    pull(.data$player_pos)
  default_context$details <- format_additional_starters(missing_starters, eligible_positions)
  default_context
}

lineup_starter_count_rule <- function(franchise_id, starter_count, lineups, expected_starters = 21L) {
  lineup_starter_count_context(franchise_id, starter_count, lineups, expected_starters)$rule
}

lineup_starter_count_observed <- function(franchise_id, starter_count, lineups, expected_starters = 21L) {
  lineup_starter_count_context(franchise_id, starter_count, lineups, expected_starters)$observed
}

lineup_starter_count_details <- function(franchise_id, starter_count, lineups, expected_starters = 21L) {
  lineup_starter_count_context(franchise_id, starter_count, lineups, expected_starters)$details
}

lineup_starter_count_alert_rows <- function(franchise_id, starter_count, lineups, expected_starters = 21L) {
  position_status <- lineup_position_status(franchise_id, lineups)
  group_rules <- adl_lineup_group_rules()

  below_minimum <- position_status |>
    mutate(short = .data$min_starters - .data$starter_count) |>
    filter(.data$short > 0L)

  total_alerts <- if (starter_count < expected_starters && nrow(below_minimum)) {
    tibble(
      rule = paste0(
        "Starting lineups require ", .env$expected_starters,
        " total starters, including minimum ",
        format_and_list(paste(below_minimum$min_starters, below_minimum$player_pos))
      ),
      observed = paste0(
        .env$starter_count, " total starters (",
        paste(paste0(below_minimum$starter_count, " ", below_minimum$player_pos), collapse = ", "),
        ")"
      ),
      details = paste0(
        "Must start ",
        format_and_list(paste(below_minimum$short, "additional", below_minimum$player_pos))
      )
    )
  } else if (starter_count < expected_starters) {
    missing_starters <- expected_starters - starter_count
    eligible_positions <- position_status |>
      filter(.data$starter_count < .data$max_starters) |>
      pull(.data$player_pos)
    tibble(
      rule = paste0("Starting lineups require ", expected_starters, " total starters"),
      observed = paste0(starter_count, " total starters"),
      details = format_additional_starters(missing_starters, eligible_positions)
    )
  } else if (starter_count > expected_starters) {
    extra_starters <- starter_count - expected_starters
    tibble(
      rule = paste0("Starting lineups require ", expected_starters, " total starters"),
      observed = paste0(starter_count, " total starters"),
      details = paste0("Must remove ", extra_starters, " starter", if_else(extra_starters == 1L, "", "s"))
    )
  } else {
    tibble(rule = character(), observed = character(), details = character())
  }

  group_status <- position_status |>
    filter(.data$lineup_group %in% group_rules$lineup_group) |>
    group_by(.data$lineup_group) |>
    summarise(group_starters = sum(.data$starter_count), .groups = "drop") |>
    right_join(group_rules, by = "lineup_group") |>
    mutate(
      group_starters = coalesce(.data$group_starters, 0L),
      short = .data$required_starters - .data$group_starters
    ) |>
    filter(.data$short != 0L) |>
    mutate(lineup_group = factor(.data$lineup_group, levels = group_rules$lineup_group)) |>
    arrange(.data$lineup_group)

  group_alerts <- if (nrow(group_status)) {
    group_details <- vapply(seq_len(nrow(group_status)), function(i) {
      group_name <- group_status$lineup_group[[i]]
      short <- group_status$short[[i]]
      starter_label <- if (identical(group_name, "OFF")) {
        "offensive starter"
      } else if (identical(group_name, "DEF")) {
        "defensive starter"
      } else {
        "starter"
      }

      if (short < 0L) {
        return(paste0("Must remove ", abs(short), " ", starter_label, if_else(abs(short) == 1L, "", "s")))
      }

      format_group_starter_shortage(group_name, short, position_status)
    }, character(1))

    group_status |>
      mutate(
        details = group_details,
        observed_note = vapply(
          as.character(.data$lineup_group),
          format_group_observed_note,
          character(1),
          position_status = position_status
        ),
        starter_label = case_when(
          .data$lineup_group == "OFF" ~ "offensive starters",
          .data$lineup_group == "DEF" ~ "defensive starters",
          TRUE ~ paste0(.data$group_label, " starters")
        )
      ) |>
      transmute(
        rule = paste0("Starting lineups require ", .data$required_starters, " ", .data$starter_label),
        observed = paste0(
          .data$group_starters, " ", .data$starter_label,
          if_else(nzchar(.data$observed_note), paste0(" (", .data$observed_note, ")"), "")
        ),
        details
      )
  } else {
    tibble(rule = character(), observed = character(), details = character())
  }

  bind_rows(total_alerts, group_alerts)
}

eligible_replacement_positions <- function(franchise_id, player_id, lineups) {
  position_rules <- adl_lineup_position_rules()
  group_rules <- adl_lineup_group_rules()

  removed_player <- lineups |>
    filter(.data$franchise_id == .env$franchise_id, .data$player_id == .env$player_id) |>
    mutate(player_pos = toupper(trimws(as.character(.data$player_pos)))) |>
    slice_head(n = 1L) |>
    left_join(position_rules, by = "player_pos")

  remaining_lineup <- lineups |>
    filter(.data$franchise_id == .env$franchise_id, .data$player_id != .env$player_id)

  position_counts <- remaining_lineup |>
    mutate(player_pos = toupper(trimws(as.character(.data$player_pos)))) |>
    count(.data$player_pos, name = "starter_count")

  position_status <- position_rules |>
    left_join(position_counts, by = "player_pos") |>
    mutate(starter_count = coalesce(.data$starter_count, 0L))

  if (nrow(removed_player)) {
    removed_group <- removed_player$lineup_group[[1]]
    removed_pos <- removed_player$player_pos[[1]]
    allowed_positions <- replacement_family(removed_pos)

    removed_position_status <- position_status |>
      filter(.data$player_pos == .env$removed_pos)

    if (nrow(removed_position_status) && removed_position_status$starter_count[[1]] < removed_position_status$min_starters[[1]]) {
      return(removed_pos)
    }

    removed_group_rule <- group_rules |>
      filter(.data$lineup_group == .env$removed_group)

    if (nrow(removed_group_rule)) {
      removed_group_count <- position_status |>
        filter(.data$lineup_group == .env$removed_group) |>
        summarise(group_starters = sum(.data$starter_count), .groups = "drop") |>
        pull(.data$group_starters)

      if (length(removed_group_count) && removed_group_count < removed_group_rule$required_starters[[1]]) {
        return(position_status |>
          filter(
            .data$lineup_group == .env$removed_group,
            .data$player_pos %in% .env$allowed_positions,
            .data$starter_count < .data$max_starters
          ) |>
          pull(.data$player_pos))
      }
    }
  } else {
    allowed_positions <- position_rules$player_pos
  }

  group_status <- position_status |>
    filter(.data$lineup_group %in% group_rules$lineup_group) |>
    group_by(.data$lineup_group) |>
    summarise(group_starters = sum(.data$starter_count), .groups = "drop") |>
    right_join(group_rules, by = "lineup_group") |>
    mutate(
      group_starters = coalesce(.data$group_starters, 0L),
      short = .data$required_starters - .data$group_starters
    ) |>
    filter(.data$short > 0L)

  if (nrow(group_status)) {
    return(position_status |>
      filter(
        .data$lineup_group %in% group_status$lineup_group,
        .data$player_pos %in% .env$allowed_positions,
        .data$starter_count < .data$max_starters
      ) |>
      pull(.data$player_pos))
  }

  position_status |>
    filter(.data$player_pos %in% .env$allowed_positions, .data$starter_count < .data$max_starters) |>
    pull(.data$player_pos)
}

bye_replacement_observed <- function(player_name, player_team, player_pos, franchise_id, player_id, week, lineups) {
  eligible_positions <- eligible_replacement_positions(franchise_id, player_id, lineups)
  replacement_text <- if (length(eligible_positions)) {
    paste0("Must replace with eligible ", paste(eligible_positions, collapse = "/"), ".")
  } else {
    "Must replace with eligible player."
  }
  paste0(player_name, " ", player_team, " ", player_pos, " on Bye in Week ", week, ".  ", replacement_text)
}

read_bye_weeks <- function(season = get_current_season()) {
  path <- Sys.getenv("ADL_BYE_WEEKS_CSV", unset = file.path("data", paste0("nfl_bye_weeks_", season, ".csv")))
  if (file.exists(path)) {
    byes <- read_csv(path, show_col_types = FALSE)
    return(setNames(as.integer(byes$week), as.character(byes$team)))
  }

  if (season == 2026L) {
    return(c(
      CAR = 5, KCC = 5,
      CIN = 6, DET = 6, MIA = 6, MIN = 6,
      BUF = 7, JAC = 7, LAC = 7, WAS = 7,
      HOU = 8, NOS = 8, NYG = 8, SFO = 8,
      PIT = 9, TEN = 9,
      CHI = 10, DEN = 10, PHI = 10, TBB = 10,
      ATL = 11, CLE = 11, GBP = 11, LAR = 11, NEP = 11, SEA = 11,
      BAL = 13, IND = 13, LVR = 13, NYJ = 13,
      ARI = 14, DAL = 14
    ))
  }

  integer()
}

evaluate_illegal_lineup_alerts <- function(
  lineups,
  rosters,
  season = get_current_season(),
  week,
  expected_starters = 21L,
  designation_snapshot = NULL,
  designation_history = NULL,
  current_designations = NULL,
  kickoffs = NULL,
  checked_at = Sys.time()
) {
  roster_tbl <- tibble::as_tibble(rosters)
  lineup_tbl <- tibble::as_tibble(lineups)
  roster_franchise_index <- tibble(
    conference = as.character(coalesce_col(roster_tbl, c("conference"), NA_character_)),
    franchise = as.character(coalesce_col(roster_tbl, c("franchise"), NA_character_)),
    franchise_name = as.character(coalesce_col(roster_tbl, c("franchise_name"), NA_character_)),
    franchise_id = as.character(coalesce_col(roster_tbl, c("franchise_id"), NA_character_))
  )
  lineup_franchise_index <- tibble(
    conference = as.character(coalesce_col(lineup_tbl, c("conference"), NA_character_)),
    franchise = as.character(coalesce_col(lineup_tbl, c("franchise"), NA_character_)),
    franchise_name = as.character(coalesce_col(lineup_tbl, c("franchise_name"), NA_character_)),
    franchise_id = as.character(coalesce_col(lineup_tbl, c("franchise_id"), NA_character_))
  )
  franchise_index <- bind_rows(lineup_franchise_index, roster_franchise_index) |>
    filter(!is.na(.data$franchise_id), nzchar(.data$franchise_id)) |>
    distinct(.data$franchise_id, .keep_all = TRUE)
  kickoffs <- kickoffs %||% read_nfl_team_kickoffs(season = season, week = week)
  lineup_lock_times <- franchise_lineup_lock_times(lineups, kickoffs)
  checked_date <- lineup_alert_date(checked_at)
  first_game_date <- lineup_week_first_game_date(kickoffs)
  is_first_game_warning_day <- !is.na(first_game_date) && checked_date == first_game_date
  first_game_at <- if (!is.null(kickoffs) && nrow(kickoffs) && "kickoff_at" %in% names(kickoffs)) {
    kickoff_values <- as.POSIXct(kickoffs$kickoff_at, tz = "UTC")
    kickoff_values <- kickoff_values[!is.na(kickoff_values)]
    if (length(kickoff_values)) min(kickoff_values) else as.POSIXct(NA)
  } else {
    as.POSIXct(NA)
  }

  lineup_counts <- franchise_index |>
    left_join(
      lineups |> count(.data$franchise_id, name = "starter_count"),
      by = "franchise_id"
    ) |>
    left_join(
      lineup_lock_times,
      by = "franchise_id"
    ) |>
    mutate(
      starter_count = coalesce(.data$starter_count, 0L),
      severity = if (isTRUE(.env$is_first_game_warning_day)) {
        rep("warning", dplyr::n())
      } else {
        lineup_alert_severity(.data$lineup_lock_at, checked_at = .env$checked_at)
      },
      alert_type = lineup_alert_type(.data$severity)
    )

  count_alerts <- bind_rows(lapply(seq_len(nrow(lineup_counts)), function(i) {
    row <- lineup_counts[i, ]
    lineup_starter_count_alert_rows(
      franchise_id = row$franchise_id[[1]],
      starter_count = row$starter_count[[1]],
      lineups = lineups,
      expected_starters = expected_starters
    ) |>
      mutate(
        alert_type = row$alert_type[[1]],
        severity = row$severity[[1]],
        conference = row$conference[[1]],
        franchise = row$franchise[[1]],
        franchise_name = row$franchise_name[[1]],
        franchise_id_temp = row$franchise_id[[1]],
        .before = 1
      )
  }))

  if (!nrow(count_alerts)) {
    count_alerts <- tibble(
      alert_type = character(),
      severity = character(),
      conference = character(),
      franchise = character(),
      franchise_name = character(),
      franchise_id_temp = character(),
      rule = character(),
      observed = character(),
      details = character()
    )
  }

  status_source <- rosters |>
    transmute(
      player_id,
      current_roster_status = normalize_alert_status(.data$roster_status),
      current_player_status = as.character(coalesce_col(rosters, c("player_status"), NA_character_))
    )

  if (!is.null(current_designations)) {
    current_designation_tbl <- current_designations |>
      transmute(
        player_id,
        current_weekly_designation = as.character(coalesce_col(current_designations, c("player_status", "roster_status"), NA_character_))
      )

    status_source <- status_source |>
      left_join(current_designation_tbl, by = "player_id") |>
      mutate(current_player_status = coalesce(na_if(.data$current_weekly_designation, ""), na_if(.data$current_player_status, ""))) |>
      select(-current_weekly_designation)
  }

  designation_history <- designation_history %||% designation_snapshot
  selected_designations <- select_72h_designations_for_lineup(lineups, designation_history, kickoffs)

  if (!is.null(selected_designations) && nrow(selected_designations)) {
    status_source <- selected_designations |>
      right_join(status_source, by = "player_id")
  } else {
    status_source <- status_source |>
      mutate(
        designation_72h = NA_character_,
        designation_snapshot_time = as.POSIXct(NA),
        kickoff_at = as.POSIXct(NA)
      )
  }

  player_checks <- lineups |>
    mutate(player_team_key = mfl_player_team(.data$player_team)) |>
    left_join(status_source, by = "player_id") |>
    left_join(
      kickoffs |> rename(player_kickoff_at = kickoff_at),
      by = c("player_team_key" = "player_team")
    ) |>
    left_join(lineup_lock_times, by = "franchise_id") |>
    mutate(
      kickoff_at = coalesce(.data$kickoff_at, .data$player_kickoff_at, .data$lineup_lock_at),
      missing_72h_snapshot = is.na(.data$designation_72h),
      missing_current_designation = is.na(.data$current_player_status),
      bye_week = unname(read_bye_weeks(season)[.data$player_team]),
      on_bye = !is.na(.data$bye_week) & .data$bye_week == .env$week,
      current_bad_designation = !.data$missing_current_designation & inactive_designation(.data$current_player_status),
      bad_72h_designation = !.data$missing_72h_snapshot & inactive_designation(.data$designation_72h),
      designation_game_date = lineup_alert_date(.data$kickoff_at),
      designation_warning_today = .data$current_bad_designation & !is.na(.data$designation_game_date) &
        (.data$designation_game_date == .env$checked_date | isTRUE(.env$is_first_game_warning_day)),
      bye_warning_today = .data$on_bye & !is.na(.env$first_game_date) & .env$first_game_date == .env$checked_date,
      player_warning_today = .data$designation_warning_today | .data$bye_warning_today,
      designation_violation = .data$current_bad_designation & .data$bad_72h_designation &
        !is.na(.data$kickoff_at) & as.POSIXct(.env$checked_at, tz = "UTC") >= .data$kickoff_at,
      bye_violation = .data$on_bye & !is.na(.env$first_game_at) &
        as.POSIXct(.env$checked_at, tz = "UTC") >= .env$first_game_at,
      player_lineup_severity = lineup_alert_severity(.data$kickoff_at, checked_at = .env$checked_at),
      bad_designation = .data$designation_violation
    )

  if (!"franchise_id" %in% names(player_checks)) {
    player_checks <- tibble(
      conference = character(),
      franchise = character(),
      franchise_name = character(),
      franchise_id = character(),
      player_id = character(),
      player_name = character(),
      player_team = character(),
      player_pos = character(),
      current_player_status = character(),
      designation_72h = character(),
      kickoff_at = as.POSIXct(character()),
      player_warning_today = logical(),
      current_bad_designation = logical(),
      designation_violation = logical(),
      on_bye = logical(),
      bye_violation = logical(),
      player_lineup_severity = character()
    )
  } else {
    player_checks <- player_checks |>
      distinct(
        .data$franchise_id,
        .data$player_id,
        .data$current_player_status,
        .data$designation_72h,
        .data$on_bye,
        .keep_all = TRUE
      )
  }

  player_warning_franchise_ids <- if ("franchise_id" %in% names(player_checks) && nrow(player_checks)) {
    player_checks |>
      filter(.data$player_warning_today) |>
      distinct(.data$franchise_id) |>
      pull(franchise_id)
  } else {
    character()
  }

  structural_warning_franchise_ids <- if (
    isTRUE(is_first_game_warning_day) &&
      nrow(count_alerts) &&
      "franchise_id_temp" %in% names(count_alerts)
  ) {
    count_alerts |>
      filter(.data$severity == "warning") |>
      distinct(.data$franchise_id_temp) |>
      pull(franchise_id_temp)
  } else {
    character()
  }

  warning_franchise_ids <- unique(c(player_warning_franchise_ids, structural_warning_franchise_ids))

  count_alerts <- count_alerts |>
    filter(.data$severity == "violation" | .data$franchise_id_temp %in% .env$warning_franchise_ids) |>
    select(-franchise_id_temp)

  designation_violation_alerts <- player_checks |>
    filter(.data$designation_violation) |>
    transmute(
      alert_type = "Illegal Lineup",
      severity = "violation",
      conference,
      franchise,
      franchise_name,
      rule = "No starters with (S), (I), (H), or (O) designation at kickoff after 72-hour grace period",
      observed = paste0(.data$player_name, " ", .data$player_team, " ", .data$player_pos),
      details = paste0("72-hour designation was ", .data$designation_72h, "; current designation is ", .data$current_player_status)
    )

  designation_warning_alerts <- player_checks |>
    filter(
      .data$current_bad_designation,
      .data$franchise_id %in% .env$warning_franchise_ids,
      !.data$designation_violation
    ) |>
    transmute(
      alert_type = "Illegal Lineup Warning",
      severity = "warning",
      conference,
      franchise,
      franchise_name,
      rule = "No starters with (S), (I), (H), or (O) designation",
      observed = paste0(.data$player_name, " ", .data$player_team, " ", .data$player_pos),
      details = paste0("Current designation is ", .data$current_player_status, ".")
    )

  bye_players <- player_checks |>
    filter(.data$on_bye, .data$bye_violation | .data$franchise_id %in% .env$warning_franchise_ids)

  bye_alerts <- if (nrow(bye_players)) {
    bye_players |>
      transmute(
        alert_type = if_else(.data$bye_violation, "Illegal Lineup", "Illegal Lineup Warning"),
        severity = if_else(.data$bye_violation, "violation", "warning"),
        conference,
        franchise,
        franchise_name,
        rule = "No starters on bye",
        observed = mapply(
          bye_replacement_observed,
          .data$player_name,
          .data$player_team,
          .data$player_pos,
          .data$franchise_id,
          .data$player_id,
          MoreArgs = list(week = week, lineups = lineups),
          USE.NAMES = FALSE
        ),
        details = ""
      )
  } else {
    tibble(
      alert_type = character(), severity = character(), conference = character(),
      franchise = character(), franchise_name = character(), rule = character(),
      observed = character(), details = character()
    )
  }

  bind_rows(count_alerts, designation_violation_alerts, designation_warning_alerts, bye_alerts)
}

commissioner_alert_sort_order <- function(alert_type, rule) {
  case_when(
    alert_type %in% c("Illegal Lineup", "Illegal Lineup Warning") & startsWith(rule, "Starting lineups require 21 total starters") ~ 1L,
    alert_type %in% c("Illegal Lineup", "Illegal Lineup Warning") & startsWith(rule, "Starting lineups require 7 offensive starters") ~ 2L,
    alert_type %in% c("Illegal Lineup", "Illegal Lineup Warning") & startsWith(rule, "Starting lineups require 12 defensive starters") ~ 3L,
    alert_type %in% c("Illegal Lineup", "Illegal Lineup Warning") & rule == "No starters on bye" ~ 4L,
    alert_type %in% c("Illegal Lineup", "Illegal Lineup Warning") ~ 5L,
    TRUE ~ 99L
  )
}

build_commissioner_alerts <- function(
  season = get_current_season(),
  week = NULL,
  include_offseason = TRUE,
  include_inseason = !is.null(week),
  force_live = FALSE,
  include_contract_years = TRUE,
  include_salary_cap = TRUE,
  roster_cap_rule = NULL,
  checked_at = Sys.time()
) {
  rosters <- load_current_rosters(force_live = force_live, source = "auto", season = season, week = week)
  alerts <- list()

  if (include_offseason) {
    alerts$roster_cap <- evaluate_roster_cap_alerts(rosters, rule = roster_cap_rule, season = season, checked_at = checked_at)
    if (isTRUE(include_contract_years)) {
      alerts$contract_years <- evaluate_contract_years_alerts(rosters)
    }
    if (isTRUE(include_salary_cap)) {
      use_inseason_salary_accounting <- checked_at >= commissioner_alert_cutdown_datetime(season, "final_roster_cutdown")
      salary_cap_adjustments <- if (isTRUE(force_live)) {
        tryCatch(fetch_mfl_salary_cap_adjustments(season = season), error = function(e) {
          warning("MFL salary cap adjustments unavailable; using zero adjustments: ", conditionMessage(e), call. = FALSE)
          NULL
        })
      } else {
        NULL
      }
      alerts$salary_cap <- if (isTRUE(use_inseason_salary_accounting)) {
        evaluate_salary_cap_average_warnings(rosters, season = season, salary_cap_adjustments = salary_cap_adjustments)
      } else {
        evaluate_salary_cap_alerts(rosters, season = season, salary_cap_adjustments = salary_cap_adjustments)
      }
    }
  }

  if (include_inseason) {
    if (is.null(week) || is.na(week)) stop("week is required for in-season lineup alerts.", call. = FALSE)
    lineups <- cache_lineups_snapshot(season = season, week = week, force_live = force_live)
    kickoffs <- read_nfl_team_kickoffs(season = season, week = week)
    designation_history <- read_designation_snapshot_history(season = season, week = week)
    current_designations <- if (isTRUE(force_live)) {
      tryCatch(
        fetch_mfl_weekly_designations(season = season, week = week),
        error = function(e) {
          warning("MFL current weekly designations unavailable; designation lineup alerts require current evidence: ", conditionMessage(e), call. = FALSE)
          NULL
        }
      )
    } else {
      NULL
    }
    alerts$illegal_lineup <- evaluate_illegal_lineup_alerts(
      lineups = lineups,
      rosters = rosters,
      season = season,
      week = week,
      designation_snapshot = read_designation_snapshot(season, week),
      designation_history = designation_history,
      current_designations = current_designations,
      kickoffs = kickoffs,
      checked_at = checked_at
    )
  }

  result <- bind_rows(alerts) |>
    mutate(
      season = .env$season,
      week = .env$week %||% NA_integer_,
      checked_at = format(as.POSIXct(.env$checked_at, tz = "UTC"), "%Y-%m-%d %H:%M:%S %Z"),
      alert_sort_order = commissioner_alert_sort_order(.data$alert_type, .data$rule),
      .before = 1
    ) |>
    arrange(.data$alert_type, .data$conference, .data$franchise, .data$alert_sort_order, .data$rule) |>
    select(-alert_sort_order)

  write_csv(result, commissioner_alert_path("alerts", season, week), na = "")
  write_commissioner_alert_report(result, season = season, week = week, checked_at = checked_at)
  result
}

build_roster_cutdown_alerts <- function(season = get_current_season(), cutdown_id, force_live = TRUE) {
  rosters <- load_current_rosters(force_live = force_live, source = "auto", season = season, week = NULL)
  rule <- roster_cutdown_rule(season = season, cutdown_id = cutdown_id)
  alerts <- evaluate_roster_cap_alerts(rosters, rule = rule, season = season, checked_at = commissioner_alert_cutdown_datetime(season, cutdown_id)) |>
    mutate(
      season = .env$season,
      week = NA_integer_,
      checked_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
      alert_sort_order = commissioner_alert_sort_order(.data$alert_type, .data$rule),
      .before = 1
    ) |>
    arrange(.data$alert_type, .data$conference, .data$franchise, .data$alert_sort_order, .data$rule) |>
    select(-alert_sort_order)

  write_csv(alerts, commissioner_alert_path(paste0("alerts_", cutdown_id), season), na = "")
  write_commissioner_alert_report(alerts, season = season, week = NULL, checked_at = Sys.time())

  list(
    alerts = alerts,
    rule = rule,
    compliance = commissioner_roster_compliance_summary(rosters, alerts)
  )
}

read_commissioner_alert_reports <- function(max_reports = 10L) {
  report_files <- list.files(
    commissioner_alert_report_dir(),
    pattern = "^commissioner_alert_report_.*[.]csv$",
    full.names = TRUE
  )

  legacy_files <- if (length(report_files)) {
    character()
  } else {
    list.files(
      commissioner_alert_dir(),
      pattern = "^alerts_.*[.]csv$",
      full.names = TRUE
    )
  }

  files <- unique(c(report_files, legacy_files))
  if (!length(files)) return(tibble())

  files <- files[order(file.info(files)$mtime, decreasing = TRUE)]
  files <- head(files, max_reports)

  bind_rows(lapply(files, function(path) {
    report <- tryCatch(read_csv(path, show_col_types = FALSE), error = function(e) tibble())
    if (!nrow(report)) return(tibble())
    report |>
      mutate(
        report_file = basename(path),
        report_mtime = format(file.info(path)$mtime, "%Y-%m-%d %H:%M:%S %Z"),
        .before = 1
      )
  }))
}

render_alert_detail_lines <- function(row, prefix = NULL) {
  franchise_label <- row$franchise_name[[1]] %||% paste(row$conference[[1]], row$franchise[[1]])
  header <- if (is.null(prefix)) {
    paste0(franchise_label, ": ", row$rule)
  } else {
    paste0(prefix, ": ", row$rule)
  }

  if (identical(row$alert_type[[1]], "Salary Cap Violation")) {
    return(c(header, strsplit(row$details[[1]] %||% "", "\n", fixed = TRUE)[[1]], ""))
  }

  if (identical(row$alert_type[[1]], "Salary Cap Warning")) {
    lines <- if (is.null(prefix)) {
      c(header, paste0("Observed: ", row$observed))
    } else {
      c(prefix, paste0("Rule: ", row$rule), paste0("Observed: ", row$observed))
    }
    return(c(lines, row$details[[1]] %||% "", ""))
  }

  details <- row$details[[1]] %||% ""
  lines <- if (is.null(prefix)) {
    c(header, paste0("Observed: ", row$observed))
  } else {
    c(prefix, paste0("Rule: ", row$rule), paste0("Observed: ", row$observed))
  }

  if (nzchar(trimws(details))) {
    lines <- c(lines, paste0("Details: ", details))
  }

  c(lines, "")
}

commissioner_alert_date_label <- function(checked_date = Sys.Date()) {
  format(as.Date(checked_date), "%Y-%m-%d")
}

render_commissioner_alert_email <- function(
  alerts,
  season = get_current_season(),
  week = NULL,
  checked_date = Sys.Date(),
  gm_emails_sent = FALSE,
  title = NULL,
  compliant_teams = NULL
) {
  title <- title %||% paste0("ADL Commissioner Alerts - ", commissioner_alert_date_label(checked_date), if (!is.null(week) && !is.na(week)) paste0(" Week ", week) else "")
  compliance_line <- if (!is.null(compliant_teams) && !is.na(compliant_teams)) {
    paste0(compliant_teams, " teams roster compliant.")
  } else {
    NULL
  }

  if (!nrow(alerts)) {
    return(paste(c(title, "", compliance_line, "No ADL roster violations were found."), collapse = "\n"))
  }

  groups <- split(alerts, alerts$alert_type)
  lines <- c(title, "", compliance_line, paste0(nrow(alerts), " alert(s) found."), "")
  if (isTRUE(gm_emails_sent)) {
    lines <- c(lines, "Individual emails have been sent to all franchises in violation.", "")
  }
  for (alert_type in names(groups)) {
    rows <- groups[[alert_type]]
    lines <- c(lines, alert_type, strrep("-", nchar(alert_type)))
    for (i in seq_len(nrow(rows))) {
      row <- rows[i, ]
      lines <- c(lines, render_alert_detail_lines(row))
    }
  }

  paste(lines, collapse = "\n")
}

render_commissioner_gm_alert_email <- function(alerts, season = get_current_season(), week = NULL, checked_date = Sys.Date(), title_prefix = "ADL Roster Violation") {
  if (!nrow(alerts)) return("")

  franchise_label <- paste(unique(alerts$franchise_name), collapse = ", ")
  title <- paste0(title_prefix, " - ", franchise_label, " - ", commissioner_alert_date_label(checked_date), if (!is.null(week) && !is.na(week)) paste0(" Week ", week) else "")

  lines <- c(
    title,
    "",
    "This is a private commissioner alert for your franchise.",
    "",
    paste0(nrow(alerts), " violation(s) found."),
    ""
  )

  for (i in seq_len(nrow(alerts))) {
    row <- alerts[i, ]
    lines <- c(lines, render_alert_detail_lines(row, prefix = row$alert_type))
  }

  paste(lines, collapse = "\n")
}

safe_file_slug <- function(x) {
  x <- tolower(gsub("[^A-Za-z0-9]+", "_", x))
  gsub("^_+|_+$", "", x)
}

write_commissioner_alert_outbox <- function(body, season = get_current_season(), week = NULL, name = "email_outbox") {
  path <- commissioner_alert_path(name, season, week, ext = "txt")
  writeLines(body, path)
  path
}

write_commissioner_alert_recipients <- function(recipients, season = get_current_season(), week = NULL) {
  path <- commissioner_alert_path("email_recipients", season, week)
  write_csv(recipients, path, na = "")
  path
}

split_env_list <- function(value) {
  values <- trimws(strsplit(value %||% "", "[,;]")[[1]])
  unique(values[nzchar(values)])
}

commissioner_alert_default_digest_franchises <- function() {
  configured <- Sys.getenv("ADL_ALERT_DIGEST_FRANCHISES", unset = Sys.getenv("ADL_ALERT_RECIPIENT_FRANCHISES", unset = ""))
  if (nzchar(configured)) {
    return(split_env_list(configured))
  }
  c("CHI", "KCC", "IND", "SEA")
}

extract_email_addresses <- function(x) {
  x <- paste(as.character(x), collapse = " ")
  matches <- gregexpr("[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", x, ignore.case = TRUE, perl = TRUE)
  found <- regmatches(x, matches)[[1]]
  unique(tolower(found[found != "-1"]))
}

normalize_mfl_franchise_email_rows <- function(franchise_tbl, franchises = NULL) {
  franchise_tbl <- tibble::as_tibble(franchise_tbl)
  if (!nrow(franchise_tbl)) {
    return(tibble(franchise = character(), franchise_name = character(), email = character(), source = character()))
  }

  franchise_tbl <- franchise_tbl |>
    mutate(
      franchise_id = as.character(coalesce_col(franchise_tbl, c("franchise_id", "franchiseId", "id"))),
      franchise_name = as.character(coalesce_col(franchise_tbl, c("franchise_name", "name"))),
      franchise = coalesce(
        as.character(coalesce_col(franchise_tbl, c("franchise", "franchise_abbrev", "abbrev", "franchise_code", "code"), NA_character_)),
        franchise_code_from_name(.data$franchise_name)
      )
    )

  if (!is.null(franchises)) {
    franchise_tbl <- franchise_tbl |>
      filter(toupper(.data$franchise) %in% toupper(.env$franchises))
  }

  if (!nrow(franchise_tbl)) {
    return(tibble(franchise = character(), franchise_name = character(), email = character(), source = character()))
  }

  bind_rows(lapply(seq_len(nrow(franchise_tbl)), function(i) {
    row <- franchise_tbl[i, , drop = FALSE]
    emails <- extract_email_addresses(row)
    if (!length(emails)) {
      return(tibble(franchise = character(), franchise_name = character(), email = character(), source = character()))
    }
    tibble(
      franchise = row$franchise[[1]],
      franchise_name = row$franchise_name[[1]],
      email = emails,
      source = "ffscrapr::ff_franchises()"
    )
  })) |>
    distinct(.data$email, .keep_all = TRUE)
}

fetch_mfl_franchise_recipients <- function(
  season = get_current_season(),
  franchises = NULL
) {
  if (!requireNamespace("ffscrapr", quietly = TRUE)) {
    stop("Package ffscrapr is required to fetch MFL alert recipients.", call. = FALSE)
  }

  conn <- connect_adl_mfl(season)
  franchise_tbl <- tibble::as_tibble(ffscrapr::ff_franchises(conn))
  normalize_mfl_franchise_email_rows(franchise_tbl, franchises = franchises)
}

fetch_mfl_commissioner_alert_recipients <- function(
  season = get_current_season(),
  franchises = commissioner_alert_default_digest_franchises()
) {
  fetch_mfl_franchise_recipients(season = season, franchises = franchises)
}

configured_commissioner_alert_recipient_rows <- function(emails, source) {
  emails <- unique(tolower(trimws(as.character(emails))))
  emails <- emails[nzchar(emails)]
  if (!length(emails)) {
    return(tibble(franchise = character(), franchise_name = character(), email = character(), source = character()))
  }

  tibble(
    franchise = NA_character_,
    franchise_name = NA_character_,
    email = emails,
    source = source
  )
}

commissioner_alert_extra_digest_recipients <- function() {
  configured_commissioner_alert_recipient_rows(
    split_env_list(Sys.getenv("ADL_ALERT_DIGEST_EXTRA_EMAILS", unset = "")),
    "ADL_ALERT_DIGEST_EXTRA_EMAILS"
  )
}

resolve_commissioner_alert_recipients <- function(season = get_current_season()) {
  extra_recipients <- commissioner_alert_extra_digest_recipients()
  mfl_recipients <- tryCatch(
    fetch_mfl_commissioner_alert_recipients(season = season),
    error = function(e) {
      attr(e, "recipient_lookup_failed") <- TRUE
      e
    }
  )

  if (!inherits(mfl_recipients, "error") && nrow(mfl_recipients)) {
    return(bind_rows(mfl_recipients, extra_recipients) |>
      filter(nzchar(.data$email)) |>
      distinct(.data$email, .keep_all = TRUE))
  }

  fallback <- configured_commissioner_alert_recipient_rows(
    split_env_list(Sys.getenv("ADL_ALERT_EMAIL_TO", unset = "")),
    source = if (inherits(mfl_recipients, "error")) {
      paste0("ADL_ALERT_EMAIL_TO fallback after MFL lookup failed: ", conditionMessage(mfl_recipients))
    } else {
      "ADL_ALERT_EMAIL_TO fallback"
    }
  )
  resolved <- bind_rows(fallback, extra_recipients) |>
    filter(nzchar(.data$email)) |>
    distinct(.data$email, .keep_all = TRUE)

  if (!nrow(resolved)) {
    return(tibble(franchise = NA_character_, franchise_name = NA_character_, email = character(), source = "none"))
  }

  resolved
}

conference_cc_email <- function(conference) {
  conference <- toupper(trimws(as.character(conference %||% "")))
  if (identical(conference, "NFC")) {
    configured <- Sys.getenv("ADL_ALERT_NFC_CC", unset = "")
    return(if (nzchar(configured)) configured else "wittecarson@gmail.com")
  }
  if (identical(conference, "AFC")) {
    configured <- Sys.getenv("ADL_ALERT_AFC_CC", unset = "")
    return(if (nzchar(configured)) configured else "andrewrmast@gmail.com")
  }
  ""
}

send_alert_mail <- function(subject, body, to, cc = character()) {
  to <- unique(trimws(to[nzchar(trimws(to))]))
  cc <- unique(trimws(cc[nzchar(trimws(cc))]))
  from <- Sys.getenv("ADL_ALERT_EMAIL_FROM", unset = "")
  smtp_server <- Sys.getenv("ADL_SMTP_SERVER", unset = "")

  if (!length(to) || !nzchar(from) || !nzchar(smtp_server)) {
    return(list(sent = FALSE, reason = "email_not_configured"))
  }
  if (!requireNamespace("curl", quietly = TRUE)) {
    return(list(sent = FALSE, reason = "curl_package_not_installed"))
  }

  message <- paste0(
    "From: ", from, "\r\n",
    "To: ", paste(to, collapse = ", "), "\r\n",
    if (length(cc)) paste0("Cc: ", paste(cc, collapse = ", "), "\r\n") else "",
    "Subject: ", subject, "\r\n",
    "Content-Type: text/plain; charset=UTF-8\r\n\r\n",
    body
  )

  curl::send_mail(
    mail_from = from,
    mail_rcpt = unique(c(to, cc)),
    smtp_server = smtp_server,
    message = charToRaw(message),
    username = Sys.getenv("ADL_SMTP_USERNAME", unset = ""),
    password = Sys.getenv("ADL_SMTP_PASSWORD", unset = ""),
    use_ssl = Sys.getenv("ADL_SMTP_SSL", unset = "try")
  )

  list(sent = TRUE, reason = "sent")
}

send_commissioner_alert_email <- function(
  alerts,
  season = get_current_season(),
  week = NULL,
  send_empty = FALSE,
  digest_subject = NULL,
  gm_subject = NULL,
  digest_title = NULL,
  gm_title_prefix = NULL,
  compliant_teams = NULL
) {
  checked_date <- Sys.Date()
  date_label <- commissioner_alert_date_label(checked_date)

  if (!nrow(alerts) && !send_empty) {
    body <- render_commissioner_alert_email(alerts, season = season, week = week, checked_date = checked_date, title = digest_title, compliant_teams = compliant_teams)
    outbox_path <- write_commissioner_alert_outbox(body, season = season, week = week, name = "email_outbox_digest")
    return(tibble(sent = FALSE, reason = "no_alerts", outbox_path = outbox_path))
  }

  recipients <- resolve_commissioner_alert_recipients(season = season)
  recipients_path <- write_commissioner_alert_recipients(recipients, season = season, week = week)
  subject <- digest_subject %||% paste0("ADL Commissioner Alerts - ", date_label, if (!is.null(week) && !is.na(week)) paste0(" Week ", week) else "")

  if (!nrow(alerts)) {
    body <- render_commissioner_alert_email(alerts, season = season, week = week, checked_date = checked_date, title = digest_title, compliant_teams = compliant_teams)
    outbox_path <- write_commissioner_alert_outbox(body, season = season, week = week, name = "email_outbox_digest")
    digest_status <- send_alert_mail(subject = subject, body = body, to = recipients$email)
    return(tibble(
      sent = isTRUE(digest_status$sent),
      reason = digest_status$reason,
      outbox_path = outbox_path,
      recipients_path = recipients_path,
      recipients = paste(recipients$email, collapse = ", ")
    ))
  }

  offender_franchises <- unique(alerts$franchise)
  offender_recipients <- tryCatch(
    fetch_mfl_franchise_recipients(season = season, franchises = offender_franchises),
    error = function(e) e
  )
  if (inherits(offender_recipients, "error")) {
    body <- render_commissioner_alert_email(alerts, season = season, week = week, checked_date = checked_date, title = digest_title, compliant_teams = compliant_teams)
    outbox_path <- write_commissioner_alert_outbox(body, season = season, week = week, name = "email_outbox_digest")
    return(tibble(sent = FALSE, reason = paste0("offender_recipient_lookup_failed: ", conditionMessage(offender_recipients)), outbox_path = outbox_path, recipients_path = recipients_path, recipients = paste(recipients$email, collapse = ", ")))
  }

  offender_recipient_path <- commissioner_alert_path("email_recipients_offenders", season, week)
  write_csv(offender_recipients, offender_recipient_path, na = "")

  gm_status <- bind_rows(lapply(offender_franchises, function(franchise) {
    franchise_alerts <- alerts |> filter(.data$franchise == .env$franchise)
    franchise_recipients <- offender_recipients |> filter(toupper(.data$franchise) == toupper(.env$franchise))
    gm_to <- franchise_recipients$email
    gm_cc <- conference_cc_email(franchise_alerts$conference[[1]])
    franchise_title_prefix <- gm_title_prefix %||% if (all(franchise_alerts$severity == "warning", na.rm = TRUE)) {
      "ADL Roster Warning"
    } else {
      "ADL Roster Violation"
    }
    gm_body <- render_commissioner_gm_alert_email(franchise_alerts, season = season, week = week, checked_date = checked_date, title_prefix = franchise_title_prefix)
    gm_outbox <- write_commissioner_alert_outbox(
      gm_body,
      season = season,
      week = week,
      name = paste0("email_outbox_gm_", safe_file_slug(franchise))
    )

    if (!length(gm_to)) {
      return(tibble(franchise = franchise, sent = FALSE, reason = "offender_email_not_found", outbox_path = gm_outbox, recipients = "", cc = gm_cc))
    }

    gm_subject_line <- gm_subject %||% paste0(franchise_title_prefix, " ", date_label, if (!is.null(week) && !is.na(week)) paste0(" Week ", week) else "")
    status <- send_alert_mail(subject = gm_subject_line, body = gm_body, to = gm_to, cc = gm_cc)

    tibble(
      franchise = franchise,
      sent = isTRUE(status$sent),
      reason = status$reason,
      outbox_path = gm_outbox,
      recipients = paste(gm_to, collapse = ", "),
      cc = gm_cc
    )
  }))

  gm_status_path <- commissioner_alert_path("email_gm_status", season, week)
  write_csv(gm_status, gm_status_path, na = "")

  gm_emails_sent <- nrow(gm_status) > 0 && all(gm_status$sent)
  body <- render_commissioner_alert_email(
    alerts,
    season = season,
    week = week,
    checked_date = checked_date,
    gm_emails_sent = gm_emails_sent,
    title = digest_title,
    compliant_teams = compliant_teams
  )
  outbox_path <- write_commissioner_alert_outbox(body, season = season, week = week, name = "email_outbox_digest")
  digest_status <- send_alert_mail(subject = subject, body = body, to = recipients$email)
  if (!isTRUE(digest_status$sent)) {
    return(tibble(
      sent = FALSE,
      reason = digest_status$reason,
      outbox_path = outbox_path,
      recipients_path = recipients_path,
      offender_recipients_path = offender_recipient_path,
      gm_status_path = gm_status_path,
      recipients = paste(recipients$email, collapse = ", ")
    ))
  }

  if (!isTRUE(gm_emails_sent)) {
    return(tibble(
      sent = FALSE,
      reason = paste0("gm_email_failed: ", paste(unique(gm_status$reason[!gm_status$sent]), collapse = ", ")),
      outbox_path = outbox_path,
      recipients_path = recipients_path,
      offender_recipients_path = offender_recipient_path,
      gm_status_path = gm_status_path,
      recipients = paste(recipients$email, collapse = ", ")
    ))
  }

  tibble(
    sent = TRUE,
    reason = "sent",
    outbox_path = outbox_path,
    recipients_path = recipients_path,
    offender_recipients_path = offender_recipient_path,
    gm_status_path = gm_status_path,
    recipients = paste(recipients$email, collapse = ", "),
    gm_emails_sent = nrow(gm_status)
  )
}
