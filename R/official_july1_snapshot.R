library(dplyr)
library(lubridate)
library(readr)
library(stringr)
library(tibble)

source("R/config_helpers.R")
source("R/mfl_helpers.R")

july1_salary_snapshot_dir <- function(output_dir = "data") {
  file.path(output_dir, "salary_snapshots")
}

july1_deadline_utc <- function(season) {
  lubridate::with_tz(
    as.POSIXct(paste0(season, "-07-01 00:00:00"), tz = "America/Toronto"),
    "UTC"
  )
}

official_july1_roster_path <- function(season, output_dir = "data") {
  file.path(july1_salary_snapshot_dir(output_dir), paste0("july1_official_roster_", season, ".csv"))
}

official_july1_reconstruction_audit_path <- function(season, output_dir = "data") {
  file.path(july1_salary_snapshot_dir(output_dir), paste0("july1_roster_reconstruction_audit_", season, ".csv"))
}

official_july1_eft_audit_path <- function(season, output_dir = "data") {
  file.path(july1_salary_snapshot_dir(output_dir), paste0("july1_eft_salary_audit_", season, ".csv"))
}

official_july1_salary_curve_path <- function(season, output_dir = "data") {
  file.path(july1_salary_snapshot_dir(output_dir), paste0("july1_final_salary_curve_", season, ".csv"))
}

official_july1_status_path <- function(season, output_dir = "data") {
  file.path(july1_salary_snapshot_dir(output_dir), paste0("july1_official_status_", season, ".csv"))
}

load_july1_snapshot_file <- function(path) {
  readr::read_csv(
    path,
    col_types = readr::cols(
      season = readr::col_integer(),
      snapshot_time = readr::col_datetime(),
      franchise_id = readr::col_character(),
      franchise_name = readr::col_character(),
      CONF = readr::col_character(),
      player_id = readr::col_character(),
      player_name = readr::col_character(),
      player_team = readr::col_character(),
      player_pos = readr::col_character(),
      player_status = readr::col_character(),
      roster_status = readr::col_character(),
      roster_salary = readr::col_double(),
      roster_years = readr::col_double(),
      roster_contractInfo = readr::col_character()
    ),
    show_col_types = FALSE
  )
}

find_bracketing_july1_snapshots <- function(season, snapshot_dir = file.path("data", "roster_snapshots")) {
  files <- list.files(
    snapshot_dir,
    pattern = paste0("^saladj_roster_snapshot_", season, "_[0-9]{8}_[0-9]{6}[.]csv$"),
    full.names = TRUE
  )
  if (!length(files)) {
    stop("No roster snapshot files found for ", season, " in ", snapshot_dir, call. = FALSE)
  }

  deadline <- july1_deadline_utc(season)
  index <- tibble(path = files) |>
    mutate(
      sample_time = vapply(.data$path, function(path) {
        rows <- suppressMessages(load_july1_snapshot_file(path))
        as.numeric(rows$snapshot_time[[1]])
      }, numeric(1)),
      snapshot_time = as.POSIXct(.data$sample_time, origin = "1970-01-01", tz = "UTC")
    ) |>
    select(-all_of("sample_time"))

  pre <- index |>
    filter(.data$snapshot_time <= .env$deadline) |>
    arrange(desc(.data$snapshot_time)) |>
    slice_head(n = 1)
  post <- index |>
    filter(.data$snapshot_time >= .env$deadline) |>
    arrange(.data$snapshot_time) |>
    slice_head(n = 1)

  if (!nrow(pre) || !nrow(post)) {
    stop("Could not find both pre- and post-July 1 roster snapshots for ", season, call. = FALSE)
  }

  list(pre = pre, post = post, deadline = deadline)
}

normalize_official_july1_transactions <- function(tx) {
  empty_transactions <- tibble(
    franchise_id = character(),
    player_id = character(),
    event = character(),
    transaction_time = as.POSIXct(character(), tz = "UTC")
  )
  if (is.null(tx) || !nrow(tx)) return(empty_transactions)
  tx <- tibble::as_tibble(tx)

  for (col in c("timestamp", "type", "type_desc", "franchise_id", "franchise", "player_id", "player_name", "added", "dropped", "comments")) {
    if (!col %in% names(tx)) tx[[col]] <- NA_character_
    tx[[col]] <- as.character(tx[[col]])
  }
  if (!"franchise_id" %in% names(tx) && "franchise" %in% names(tx)) {
    tx <- tx |> rename(franchise_id = "franchise")
  }

  expanded <- bind_rows(lapply(seq_len(nrow(tx)), function(i) {
    row <- tx[i, , drop = FALSE]
    added <- str_split(coalesce(row$added[[1]], ""), ",", simplify = FALSE)[[1]] |> trimws()
    dropped <- str_split(coalesce(row$dropped[[1]], ""), ",", simplify = FALSE)[[1]] |> trimws()
    added <- added[nzchar(added)]
    dropped <- dropped[nzchar(dropped)]
    bind_rows(
      lapply(added, function(player_id) {
        out <- row
        out$player_id <- player_id
        out$type_desc <- "added"
        out
      }),
      lapply(dropped, function(player_id) {
        out <- row
        out$player_id <- player_id
        out$type_desc <- "dropped"
        out
      })
    )
  }))

  tx <- bind_rows(tx, expanded) |>
    mutate(
      franchise_id = coalesce(.data$franchise_id, .data$franchise),
      player_id = as.character(.data$player_id),
      timestamp_chr = as.character(.data$timestamp),
      transaction_time = suppressWarnings(lubridate::ymd_hms(.data$timestamp_chr, quiet = TRUE, tz = "UTC")),
      transaction_time_numeric = suppressWarnings(as.POSIXct(as.numeric(.data$timestamp_chr), origin = "1970-01-01", tz = "UTC")),
      transaction_time = coalesce(.data$transaction_time, .data$transaction_time_numeric),
      event = case_when(
        str_to_lower(.data$type_desc) == "dropped" ~ "dropped",
        str_to_lower(.data$type_desc) == "added" ~ "added",
        TRUE ~ NA_character_
      )
    ) |>
    select(-all_of("transaction_time_numeric")) |>
    filter(!is.na(.data$transaction_time), !is.na(.data$player_id), nzchar(.data$player_id))

  if (!nrow(tx)) return(empty_transactions)
  tx
}

fetch_official_july1_transactions <- function(season) {
  conn <- connect_adl_mfl(season)
  ffscrapr_tx <- tryCatch(ffscrapr::ff_transactions(conn), error = function(e) tibble())
  raw_tx <- tryCatch(
    ffscrapr::mfl_getendpoint(conn, endpoint = "transactions")[["content"]][["transactions"]][["transaction"]],
    error = function(e) NULL
  )
  raw_tx <- if (is.null(raw_tx)) {
    tibble()
  } else if (is.data.frame(raw_tx)) {
    tibble::as_tibble(raw_tx)
  } else if (is.list(raw_tx) && is.null(names(raw_tx))) {
    bind_rows(lapply(raw_tx, function(row) tibble::as_tibble(as.list(row))))
  } else {
    tibble::as_tibble(as.list(raw_tx))
  }
  bind_rows(
    normalize_official_july1_transactions(ffscrapr_tx),
    normalize_official_july1_transactions(raw_tx)
  )
}

july1_row_key <- function(df) {
  paste(as.character(df$franchise_id), as.character(df$player_id), as.character(df$roster_status), sep = "|")
}

nearest_transaction <- function(transactions, franchise_id, player_id, event, deadline, after_deadline = NULL) {
  if (
    is.null(transactions) ||
      !nrow(transactions) ||
      !all(c("franchise_id", "player_id", "event", "transaction_time") %in% names(transactions))
  ) {
    return(as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"))
  }

  rows <- transactions |>
    filter(
      .data$franchise_id == .env$franchise_id,
      .data$player_id == .env$player_id,
      .data$event == .env$event
    )
  if (!is.null(after_deadline)) {
    rows <- rows |> filter(if (.env$after_deadline) .data$transaction_time > .env$deadline else .data$transaction_time <= .env$deadline)
  }
  if (!nrow(rows)) return(as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"))
  if (identical(after_deadline, TRUE)) {
    out <- rows |> arrange(.data$transaction_time) |> pull(.data$transaction_time)
  } else {
    out <- rows |> arrange(desc(.data$transaction_time)) |> pull(.data$transaction_time)
  }
  out[[1]]
}

reconstruct_july1_midnight_roster <- function(pre_snapshot, post_snapshot, transactions, season) {
  deadline <- july1_deadline_utc(season)
  pre <- pre_snapshot |> mutate(.july1_key = july1_row_key(pre_snapshot))
  post <- post_snapshot |> mutate(.july1_key = july1_row_key(post_snapshot))

  pre_only <- pre |> anti_join(post |> select(".july1_key"), by = ".july1_key")
  post_only <- post |> anti_join(pre |> select(".july1_key"), by = ".july1_key")

  pre_audit <- pre_only |>
    rowwise() |>
    mutate(
      transaction_time = nearest_transaction(.env$transactions, .data$franchise_id, .data$player_id, "dropped", .env$deadline),
      transaction_time_et = ifelse(is.na(.data$transaction_time), NA_character_, format(with_tz(.data$transaction_time, "America/Toronto"), "%Y-%m-%d %H:%M:%S %Z")),
      july1_action = case_when(
        is.na(.data$transaction_time) ~ "keep_pre_row_no_drop_transaction_found",
        .data$transaction_time > .env$deadline ~ "keep_pre_row_drop_after_deadline",
        TRUE ~ "remove_pre_row_drop_at_or_before_deadline"
      ),
      source_side = "pre_only"
    ) |>
    ungroup()

  post_audit <- post_only |>
    rowwise() |>
    mutate(
      transaction_time = nearest_transaction(.env$transactions, .data$franchise_id, .data$player_id, "added", .env$deadline),
      transaction_time_et = ifelse(is.na(.data$transaction_time), NA_character_, format(with_tz(.data$transaction_time, "America/Toronto"), "%Y-%m-%d %H:%M:%S %Z")),
      july1_action = case_when(
        !is.na(.data$transaction_time) & .data$transaction_time <= .env$deadline ~ "add_post_row_added_at_or_before_deadline",
        is.na(.data$transaction_time) ~ "exclude_post_row_no_add_transaction_found",
        TRUE ~ "exclude_post_row_added_after_deadline"
      ),
      source_side = "post_only"
    ) |>
    ungroup()

  remove_keys <- pre_audit |>
    filter(.data$july1_action == "remove_pre_row_drop_at_or_before_deadline") |>
    pull(".july1_key")
  add_rows <- post_audit |>
    filter(.data$july1_action == "add_post_row_added_at_or_before_deadline") |>
    select(all_of(names(post)))

  official <- bind_rows(
    pre |> filter(!.data$.july1_key %in% .env$remove_keys),
    add_rows
  ) |>
    select(-all_of(".july1_key")) |>
    mutate(snapshot_time = deadline) |>
    arrange(.data$franchise_id, .data$roster_status, .data$player_pos, .data$player_name)

  audit <- bind_rows(pre_audit, post_audit) |>
    transmute(
      season,
      deadline_et = format(with_tz(.env$deadline, "America/Toronto"), "%Y-%m-%d %H:%M:%S %Z"),
      source_side,
      july1_action,
      transaction_time_et,
      franchise_id,
      franchise_name,
      CONF,
      player_id,
      player_name,
      player_team,
      player_pos,
      roster_status,
      roster_salary,
      roster_years,
      roster_contractInfo
    )

  list(roster = official, audit = audit)
}

tag_position <- function(position) {
  ifelse(position %in% c("PK", "PN"), "PK/PN", position)
}

is_eft_contract <- function(contract_info) {
  str_detect(coalesce(contract_info, ""), regex("\\bEFT\\b", ignore_case = TRUE)) &
    !str_detect(coalesce(contract_info, ""), regex("\\bNEFT\\b", ignore_case = TRUE))
}

round_salary_millions <- function(x) {
  round(as.numeric(x) + 1e-9, 2)
}

apply_july1_eft_salaries <- function(roster, season) {
  base <- roster |>
    mutate(
      tag_position = tag_position(.data$player_pos),
      roster_salary = as.numeric(.data$roster_salary),
      is_eft = is_eft_contract(.data$roster_contractInfo)
    )

  eft_rows <- base |> filter(.data$is_eft)
  if (!nrow(eft_rows)) {
    return(list(roster = roster, audit = tibble()))
  }

  audit <- bind_rows(lapply(seq_len(nrow(eft_rows)), function(i) {
    row <- eft_rows[i, ]
    top_five <- base |>
      filter(.data$tag_position == row$tag_position[[1]], !is.na(.data$roster_salary)) |>
      arrange(desc(.data$roster_salary), .data$player_name, .data$CONF) |>
      slice_head(n = 5)
    top_five_average <- round_salary_millions(mean(top_five$roster_salary, na.rm = TRUE))
    final_salary <- max(row$roster_salary[[1]], top_five_average, na.rm = TRUE)

    tibble(
      season = season,
      franchise_id = row$franchise_id,
      franchise_name = row$franchise_name,
      CONF = row$CONF,
      player_id = row$player_id,
      player_name = row$player_name,
      player_team = row$player_team,
      player_pos = row$player_pos,
      tag_position = row$tag_position,
      roster_contractInfo = row$roster_contractInfo,
      placeholder_neft_salary = row$roster_salary,
      july1_top_five_average = top_five_average,
      official_eft_salary = final_salary,
      salary_delta = round_salary_millions(final_salary - row$roster_salary[[1]]),
      top_five_players = paste0(top_five$player_name, " ", top_five$player_team, " ", top_five$player_pos, " ", top_five$CONF, " $", sprintf("%.2f", top_five$roster_salary), "m", collapse = " | ")
    )
  }))

  updated <- base |>
    left_join(audit |> select(all_of(c("player_id", "franchise_id", "official_eft_salary"))), by = c("player_id", "franchise_id")) |>
    mutate(roster_salary = if_else(!is.na(.data$official_eft_salary), .data$official_eft_salary, .data$roster_salary)) |>
    select(-all_of(c("tag_position", "is_eft", "official_eft_salary")))

  list(roster = updated, audit = audit)
}

add_top_rank_extrapolation <- function(curve) {
  top_four <- curve |>
    filter(.data$rank %in% 1:4) |>
    arrange(.data$rank)
  if (nrow(top_four) < 4) return(curve)

  rank_one <- top_four$salary[top_four$rank == 1][1]
  rank_four <- top_four$salary[top_four$rank == 4][1]
  step <- (rank_one - rank_four) / 3

  bind_rows(
    tibble(
      salary_source = curve$salary_source[1],
      position = curve$position[1],
      rank = c(-1, 0),
      player = NA_character_,
      conference = NA_character_,
      salary = c(rank_one + 2 * step, rank_one + step)
    ),
    curve
  )
}

salary_curve_from_official_july1_roster <- function(roster) {
  positions <- c("QB", "RB", "WR", "TE", "PK/PN", "PK", "PN", "DT", "DE", "LB", "CB", "S")
  bind_rows(lapply(positions, function(position) {
    rows <- if (position == "PK/PN") {
      roster |> filter(.data$player_pos %in% c("PK", "PN"))
    } else {
      roster |> filter(.data$player_pos == .env$position)
    }

    curve <- rows |>
      filter(!is.na(.data$roster_salary)) |>
      arrange(desc(.data$roster_salary), .data$player_name, .data$CONF) |>
      mutate(
        salary_source = "Jul1 Sal",
        position = .env$position,
        rank = row_number(),
        player = trimws(paste(.data$player_name, .data$player_team, .data$player_pos)),
        conference = .data$CONF,
        salary = round_salary_millions(.data$roster_salary)
      ) |>
      select(all_of(c("salary_source", "position", "rank", "player", "conference", "salary")))

    add_top_rank_extrapolation(curve)
  }))
}

build_official_july1_salary_snapshot <- function(season = get_current_season(), output_dir = "data", transactions = NULL) {
  out_dir <- july1_salary_snapshot_dir(output_dir)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  bracket <- find_bracketing_july1_snapshots(season, snapshot_dir = file.path(output_dir, "roster_snapshots"))
  pre <- load_july1_snapshot_file(bracket$pre$path[[1]])
  post <- load_july1_snapshot_file(bracket$post$path[[1]])

  if (is.null(transactions)) {
    transactions <- tryCatch(fetch_official_july1_transactions(season), error = function(e) {
      warning("Could not fetch transactions for July 1 reconstruction: ", conditionMessage(e), call. = FALSE)
      tibble()
    })
  } else {
    transactions <- normalize_official_july1_transactions(transactions)
  }

  reconstructed <- reconstruct_july1_midnight_roster(pre, post, transactions, season)
  eft <- apply_july1_eft_salaries(reconstructed$roster, season)
  curve <- salary_curve_from_official_july1_roster(eft$roster)

  readr::write_csv(eft$roster, official_july1_roster_path(season, output_dir), na = "")
  readr::write_csv(reconstructed$audit, official_july1_reconstruction_audit_path(season, output_dir), na = "")
  readr::write_csv(eft$audit, official_july1_eft_audit_path(season, output_dir), na = "")
  readr::write_csv(curve, official_july1_salary_curve_path(season, output_dir), na = "")

  status <- tibble(
    season = season,
    built_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
    deadline_et = format(with_tz(july1_deadline_utc(season), "America/Toronto"), "%Y-%m-%d %H:%M:%S %Z"),
    pre_snapshot = basename(bracket$pre$path[[1]]),
    post_snapshot = basename(bracket$post$path[[1]]),
    official_roster = official_july1_roster_path(season, output_dir),
    reconstruction_audit = official_july1_reconstruction_audit_path(season, output_dir),
    eft_audit = official_july1_eft_audit_path(season, output_dir),
    final_salary_curve = official_july1_salary_curve_path(season, output_dir),
    roster_rows = nrow(eft$roster),
    curve_rows = nrow(curve),
    reconstruction_audit_rows = nrow(reconstructed$audit),
    eft_rows = nrow(eft$audit)
  )
  readr::write_csv(status, official_july1_status_path(season, output_dir), na = "")
  status
}
