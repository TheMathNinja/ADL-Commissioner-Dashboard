# saladj_engine.R
# ---------------
# Builds the copy-pasteable ADL salary adjustment transaction table.

library(dplyr)
library(tibble)
library(ffscrapr)
library(nflreadr)
library(lubridate)

source("R/config_helpers.R")
source("R/mfl_helpers.R")

build_saladj_curator <- function(current_season = get_current_season(), output_dir = "data") {
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
# ----------------------------
# Config
# ----------------------------

# current_season is supplied by build_saladj_curator()

sd_min_by_season <- tibble::tribble(
  ~season, ~sd_min,
  2020, 1.32,
  2021, 1.22,
  2022, 1.39,
  2023, 1.50,
  2024, 1.70,
  2025, 1.86,
  2026, 2.01
)

sd_min <- sd_min_by_season %>%
  dplyr::filter(.data$season == current_season) %>%
  dplyr::pull(.data$sd_min)

if (length(sd_min) != 1 || is.na(sd_min)) {
  stop(paste0("No sd_min found for season ", current_season, ". Update sd_min_by_season."))
}

draft_rd1_by_season <- tibble::tribble(
  ~season, ~rd1_date,
  2020, as.Date("2020-04-23"),
  2021, as.Date("2021-04-29"),
  2022, as.Date("2022-04-28"),
  2023, as.Date("2023-04-27"),
  2024, as.Date("2024-04-25"),
  2025, as.Date("2025-04-24"),
  2026, as.Date("2026-04-23")
)

draft_rd1_date <- draft_rd1_by_season %>%
  dplyr::filter(.data$season == current_season) %>%
  dplyr::pull(.data$rd1_date)

if (length(draft_rd1_date) != 1 || is.na(draft_rd1_date)) {
  stop(paste0("No rd1_date found for season ", current_season, ". Update draft_rd1_by_season."))
}

cutoff_end_local <- as.POSIXct(
  paste0(format(draft_rd1_date, "%Y-%m-%d"), " 23:59:59"),
  tz = "America/Toronto"
)


missing_snapshot_review_days <- suppressWarnings(as.integer(
  get_env_or_default("SALADJ_MISSING_SNAPSHOT_REVIEW_DAYS", "3")
))
if (length(missing_snapshot_review_days) != 1 || is.na(missing_snapshot_review_days) || missing_snapshot_review_days < 1) {
  missing_snapshot_review_days <- 3L
}
# ----------------------------
# Directory Setup
# ----------------------------

script_dir <- output_dir
if (!dir.exists(script_dir)) dir.create(script_dir, recursive = TRUE)

franchises_rds <- file.path(script_dir, paste0("adl_franchises_", current_season, ".rds"))
qualified_rds  <- file.path(script_dir, paste0("saladj_qualified_", current_season, ".rds"))

out_csv <- file.path(script_dir, paste0("SalAdjCurator_", current_season, ".csv"))
out_rds <- file.path(script_dir, paste0("SalAdjCurator_", current_season, ".rds"))
snapshot_dir <- file.path(script_dir, "roster_snapshots")

# ----------------------------
# MFL Conn
# ----------------------------

adl_conn <- connect_adl_mfl(current_season)

# ----------------------------
# Helpers
# ----------------------------

# League rule: 0001-0016 NFC, 0017-0032 AFC
franchise_to_conf <- function(franchise_id_num) {
  dplyr::case_when(
    is.na(franchise_id_num) ~ NA_character_,
    franchise_id_num >= 1  & franchise_id_num <= 16 ~ "NFC",
    franchise_id_num >= 17 & franchise_id_num <= 32 ~ "AFC",
    TRUE ~ NA_character_
  )
}

add_conf_fields <- function(df, franchise_id_col = "franchise_id") {
  if (!franchise_id_col %in% names(df)) {
    df[[franchise_id_col]] <- NA_character_
  }
  
  df %>%
    dplyr::mutate(
      franchise_id_num = suppressWarnings(as.integer(as.character(.data[[franchise_id_col]]))),
      CONF = franchise_to_conf(.data$franchise_id_num)
    )
}

make_row_key <- function(df) {
  txn_id_col <- intersect(names(df), c("transaction_id", "trans_id", "id", "transactionId"))
  txn_id_val <- if (length(txn_id_col) == 1) as.character(df[[txn_id_col]]) else ""
  
  franchise_val <- if ("franchise_id" %in% names(df)) as.character(df[["franchise_id"]]) else ""
  player_val    <- if ("player_id" %in% names(df)) as.character(df[["player_id"]]) else ""
  ts_val        <- if ("timestamp" %in% names(df)) as.character(df[["timestamp"]]) else ""
  type_val      <- if ("type" %in% names(df)) as.character(df[["type"]]) else ""
  desc_val      <- if ("type_desc" %in% names(df)) as.character(df[["type_desc"]]) else ""
  comm_val      <- if ("comments" %in% names(df)) as.character(df[["comments"]]) else ""
  
  paste0(
    "txn=", txn_id_val,
    "|fr=", franchise_val,
    "|pl=", player_val,
    "|ts=", ts_val,
    "|ty=", type_val,
    "|td=", desc_val,
    "|cm=", comm_val
  )
}

is_fg <- function(contractInfo) {
  x <- dplyr::coalesce(contractInfo, "")
  stringr::str_detect(x, "(1\\.XX|2\\.XX|FT|TT|5YO)")
}

has_plus <- function(contractInfo) {
  x <- dplyr::coalesce(contractInfo, "")
  stringr::str_detect(x, "\\+")
}

is_xx_caret_3plus <- function(contractInfo) {
  x <- dplyr::coalesce(contractInfo, "")
  m <- stringr::str_match(x, "^([0-9]+)\\.XX\\^$")
  n <- suppressWarnings(as.integer(m[, 2]))
  !is.na(n) & n >= 3
}

format_mdy_hms <- function(x) {
  lt <- as.POSIXlt(x)
  paste0(
    lt$mon + 1, "/",
    lt$mday, "/",
    lt$year + 1900, " ",
    sprintf("%02d:%02d:%02d", lt$hour, lt$min, lt$sec)
  )
}

load_roster_snapshot_history <- function(snapshot_dir, season) {
  if (!dir.exists(snapshot_dir)) return(tibble::tibble())
  
  snapshot_files <- list.files(
    snapshot_dir,
    pattern = paste0("^saladj_roster_snapshot_", season, "_[0-9]{8}_[0-9]{6}\\.csv$"),
    full.names = TRUE
  )
  
  if (length(snapshot_files) == 0) return(tibble::tibble())
  
  dplyr::bind_rows(lapply(snapshot_files, function(snapshot_file) {
    readr::read_csv(
      snapshot_file,
      col_types = readr::cols(
        season = readr::col_integer(),
        snapshot_time = readr::col_datetime(),
        franchise_id = readr::col_character(),
        CONF = readr::col_character(),
        player_id = readr::col_character(),
        roster_salary = readr::col_double(),
        roster_years = readr::col_double(),
        roster_contractInfo = readr::col_character(),
        .default = readr::col_character()
      ),
      show_col_types = FALSE
    )
  }))
}

roster_snapshot_values <- function(df) {
  if (is.null(df) || nrow(df) == 0) return(tibble::tibble())
  df %>%
    dplyr::select(-dplyr::any_of("snapshot_time")) %>%
    dplyr::mutate(dplyr::across(dplyr::everything(), as.character)) %>%
    dplyr::arrange(.data$franchise_id, .data$player_id)
}

write_roster_snapshot <- function(roster_snapshot, snapshot_dir, season, snapshot_time) {
  dir.create(snapshot_dir, recursive = TRUE, showWarnings = FALSE)
  snapshot_stamp <- format(lubridate::with_tz(snapshot_time, "UTC"), "%Y%m%d_%H%M%S")
  snapshot_file <- file.path(
    snapshot_dir,
    paste0("saladj_roster_snapshot_", season, "_", snapshot_stamp, ".csv")
  )
  latest_file <- file.path(snapshot_dir, paste0("saladj_roster_snapshot_", season, "_latest.csv"))
  
  if (file.exists(latest_file)) {
    latest_snapshot <- readr::read_csv(latest_file, show_col_types = FALSE)
    if (identical(roster_snapshot_values(roster_snapshot), roster_snapshot_values(latest_snapshot))) {
      return(latest_file)
    }
  }
  
  readr::write_csv(roster_snapshot, snapshot_file, na = "")
  readr::write_csv(roster_snapshot, latest_file, na = "")
  
  snapshot_file
}

normalize_and_dedupe_cache <- function(df) {
  if (nrow(df) == 0) return(df)
  
  df <- df %>%
    dplyr::mutate(
      YEARS = dplyr::if_else(.data$PLAYER == "Cash Trade", "1", dplyr::coalesce(.data$YEARS, "")),
      CONTRACT = dplyr::if_else(.data$PLAYER == "Cash Trade", "", dplyr::coalesce(.data$CONTRACT, ""))
    )
  
  df <- df %>%
    dplyr::mutate(
      dedupe_key = dplyr::case_when(
        .data$PLAYER == "Cash Trade" ~ paste0(
          "CASH|", .data$CONF, "|", as.character(.data$DATE_sort), "|", .data$FRAN, "|", .data$SALARY
        ),
        TRUE ~ paste0(
          "DROP|", .data$CONF, "|", as.character(.data$DATE_sort), "|", .data$FRAN, "|",
          .data$PLAYER, "|", .data$SALARY, "|", .data$YEARS
        )
      )
    ) %>%
    dplyr::group_by(.data$dedupe_key) %>%
    dplyr::slice(1) %>%
    dplyr::ungroup() %>%
    dplyr::select(-"dedupe_key")
  
  df
}

# ----------------------------
# Cash trade helpers
# ----------------------------

norm_text <- function(x) {
  x %>%
    dplyr::coalesce("") %>%
    stringr::str_to_lower() %>%
    stringr::str_replace_all("[^a-z0-9\\.\\s\\-\\>]", " ") %>%
    stringr::str_replace_all("\\s+", " ") %>%
    stringr::str_trim()
}

# Only allow weak 2-letter aliases if comment clearly looks like money movement
is_cash_direction_comment <- function(comm) {
  comm_raw <- dplyr::coalesce(comm, "")
  comm_norm <- norm_text(comm)
  
  has_direction <- stringr::str_detect(
    comm_norm,
    stringr::regex("\\b(send|sends|sent|give|gives|gave|pay|pays|paid)\\b|\\-\\>")
  )
  
  has_money <- stringr::str_detect(comm_raw, stringr::regex("\\$")) |
    stringr::str_detect(comm_norm, stringr::regex("\\d+(?:\\.\\d+)?")) |
    stringr::str_detect(comm_norm, stringr::regex("\\d+(?:\\.\\d+)?\\s*(mm|m|mil|mill|million)\\b"))
  
  has_direction && has_money
}

extract_cash_millions <- function(comments) {
  comm <- norm_text(comments)
  
  # Prefer explicit suffix versions first: 9.31m / 2mm / 7.5 mil / 3 million
  m_tagged <- stringr::str_match(comm, "(\\d+(?:\\.\\d+)?)\\s*(mm|m|mil|mill|million)\\b")
  out <- suppressWarnings(as.numeric(m_tagged[, 2]))
  
  # Fallback: plain number like $5 or 9.3 $
  need_fallback <- is.na(out)
  if (any(need_fallback)) {
    m_num <- stringr::str_match(comm[need_fallback], "(\\d+(?:\\.\\d+)?)")
    out[need_fallback] <- suppressWarnings(as.numeric(m_num[, 2]))
  }
  
  out
}

# Returns strong + weak tokens separately
build_team_tokens <- function(abbrev, franchise_name) {
  ab <- norm_text(abbrev)
  nm <- norm_text(franchise_name)
  
  words <- nm %>%
    stringr::str_split("\\s+") %>%
    purrr::pluck(1)
  
  words <- unique(words[nzchar(words)])
  
  initials_2 <- if (length(words) >= 2) paste0(substr(words[1:2], 1, 1), collapse = "") else ""
  ab2 <- if (nchar(ab) >= 2) substr(ab, 1, 2) else ""
  
  prefixes <- purrr::map(words, function(w) {
    L <- nchar(w)
    if (L < 4) return(character(0))
    lens <- 4:min(8, L)
    unique(substr(w, 1, lens))
  }) %>% unlist(use.names = FALSE)
  
  strong_tokens <- unique(c(
    ab,
    words,
    prefixes
  ))
  
  weak_tokens <- unique(c(
    ab2,
    initials_2
  ))
  
  list(
    strong = strong_tokens[nzchar(strong_tokens)],
    weak = weak_tokens[nzchar(weak_tokens)]
  )
}

team_positions <- function(comm, token_list, allow_weak = FALSE) {
  comm <- norm_text(comm)
  positions <- c()
  
  toks <- token_list$strong
  if (allow_weak) {
    toks <- unique(c(toks, token_list$weak))
  }
  
  for (tok in toks) {
    if (!nzchar(tok)) next
    
    # Short tokens must be exact whole words only.
    # Longer tokens can match start-of-word to support fragments like "balt".
    pat <- if (nchar(tok) <= 3) {
      paste0("\\b", stringr::str_replace_all(tok, "([\\W])", "\\\\\\1"), "\\b")
    } else {
      paste0("\\b", stringr::str_replace_all(tok, "([\\W])", "\\\\\\1"))
    }
    
    locs <- stringr::str_locate_all(comm, stringr::regex(pat))[[1]]
    if (nrow(locs) > 0) {
      positions <- c(positions, locs[, 1])
    }
  }
  
  sort(unique(positions))
}

# IMPORTANT:
# This function identifies ONLY the sender, restricted to the two actual teams in the timestamp pair.
# Receiver is always the OTHER team in the pair.
infer_sender_from_comment <- function(comm_blob, pair_franchise_ids, franchises_df) {
  comm <- norm_text(comm_blob)
  pair_ids <- as.character(pair_franchise_ids)
  
  pair <- tibble::tibble(franchise_id = pair_ids) %>%
    dplyr::left_join(
      franchises_df %>%
        dplyr::transmute(
          franchise_id = as.character(.data$franchise_id),
          abbrev = .data$abbrev,
          franchise_name = .data$franchise_name
        ),
      by = "franchise_id"
    )
  
  tok1 <- build_team_tokens(pair$abbrev[1], pair$franchise_name[1])
  tok2 <- build_team_tokens(pair$abbrev[2], pair$franchise_name[2])
  
  allow_weak <- is_cash_direction_comment(comm)
  
  pos1 <- team_positions(comm, tok1, allow_weak = allow_weak)
  pos2 <- team_positions(comm, tok2, allow_weak = allow_weak)
  
  cue_loc <- stringr::str_locate(
    comm,
    stringr::regex("\\b(send|sends|sent|give|gives|gave|pay|pays|paid)\\b|\\-\\>")
  )
  cue_start <- if (!is.na(cue_loc[1, 1])) cue_loc[1, 1] else NA_integer_
  
  # Pattern 1: sender is nearest valid pair-team mention before the directional cue
  if (!is.na(cue_start)) {
    before1 <- pos1[pos1 < cue_start]
    before2 <- pos2[pos2 < cue_start]
    
    if (length(before1) > 0 || length(before2) > 0) {
      cand_pos <- c(
        if (length(before1) > 0) max(before1) else NA,
        if (length(before2) > 0) max(before2) else NA
      )
      return(pair_ids[which.max(replace(cand_pos, is.na(cand_pos), -Inf))])
    }
  }
  
  # Pattern 2: "from X" -> sender is first valid pair-team mention after FROM
  from_loc <- stringr::str_locate(comm, stringr::regex("\\bfrom\\b"))
  if (!is.na(from_loc[1, 1])) {
    after_from1 <- pos1[pos1 > from_loc[1, 2]]
    after_from2 <- pos2[pos2 > from_loc[1, 2]]
    
    if (length(after_from1) > 0 || length(after_from2) > 0) {
      cand_pos <- c(
        if (length(after_from1) > 0) min(after_from1) else NA,
        if (length(after_from2) > 0) min(after_from2) else NA
      )
      return(pair_ids[which.min(replace(cand_pos, is.na(cand_pos), Inf))])
    }
  }
  
  NA_character_
}

franchise_id_to_abbrev <- function(franchise_id_chr, franchises_df) {
  franchises_df$abbrev[match(as.character(franchise_id_chr), as.character(franchises_df$franchise_id))]
}

# ----------------------------
# Load / cache franchises
# ----------------------------

if (file.exists(franchises_rds)) {
  franchises <- readRDS(franchises_rds)
} else {
  franchises <- ffscrapr::ff_franchises(adl_conn) %>%
    dplyr::select(franchise_id, abbrev, franchise_name)
  saveRDS(franchises, franchises_rds)
}

if (!"franchise_name" %in% names(franchises)) franchises$franchise_name <- NA_character_
if (all(is.na(franchises$franchise_name))) {
  stop("franchises_rds does not contain usable franchise_name values. Delete franchises_rds and rerun.")
}

franchises <- add_conf_fields(franchises, "franchise_id")

# ----------------------------
# Load existing cache
# ----------------------------
# DEBUG MODE: always rebuild cache from scratch while debugging

qualified_existing <- tibble::tibble()
existing_keys <- character(0)

# ----------------------------
# Pull transactions (all post-cutoff, since cache is rebuilt every run)
# ----------------------------

tx <- ffscrapr::ff_transactions(adl_conn)

if (!"comments" %in% names(tx)) tx$comments <- NA_character_
if (!"player_name" %in% names(tx)) tx$player_name <- NA_character_
if (!"player_id" %in% names(tx)) tx$player_id <- NA_character_

tx <- tx %>%
  dplyr::mutate(
    player_id = as.character(.data$player_id),
    row_key = make_row_key(dplyr::pick(dplyr::everything()))
  )

# ----------------------------
# Pull rosters once per run
# ----------------------------

rosters_now <- ffscrapr::ff_rosters(adl_conn)

salary_col <- intersect(names(rosters_now), c("salary", "player_salary", "contract_salary"))
years_col  <- intersect(names(rosters_now), c("contract_years", "years", "contractYears"))
info_col   <- intersect(names(rosters_now), c("contractInfo", "contract_info", "contractinfo"))

if (length(salary_col) == 0) rosters_now$salary <- NA_real_ else rosters_now <- rosters_now %>% dplyr::rename(salary = dplyr::all_of(salary_col[1]))
if (length(years_col) == 0)  rosters_now$contract_years <- NA_real_ else rosters_now <- rosters_now %>% dplyr::rename(contract_years = dplyr::all_of(years_col[1]))
if (length(info_col) == 0)   rosters_now$contractInfo <- NA_character_ else rosters_now <- rosters_now %>% dplyr::rename(contractInfo = dplyr::all_of(info_col[1]))

if (!"franchise_id" %in% names(rosters_now)) rosters_now$franchise_id <- NA_character_
if (!"player_id" %in% names(rosters_now)) rosters_now$player_id <- NA_character_

rosters_now <- rosters_now %>%
  dplyr::mutate(player_id = as.character(.data$player_id)) %>%
  add_conf_fields("franchise_id")

snapshot_time <- lubridate::with_tz(Sys.time(), "UTC")
missing_snapshot_review_start <- snapshot_time - lubridate::days(missing_snapshot_review_days)
snapshot_history <- load_roster_snapshot_history(snapshot_dir, current_season)

current_roster_snapshot <- rosters_now %>%
  dplyr::transmute(
    season = current_season,
    snapshot_time = snapshot_time,
    franchise_id = as.character(.data$franchise_id),
    CONF = .data$CONF,
    player_id = as.character(.data$player_id),
    player_name = as.character(.data$player_name),
    roster_salary = .data$salary,
    roster_years = .data$contract_years,
    roster_contractInfo = as.character(.data$contractInfo)
  )

snapshot_file <- write_roster_snapshot(
  current_roster_snapshot,
  snapshot_dir,
  current_season,
  snapshot_time
)
message("Wrote roster snapshot: ", snapshot_file)

roster_snapshot_history <- dplyr::bind_rows(snapshot_history, current_roster_snapshot) %>%
  dplyr::filter(!is.na(.data$snapshot_time)) %>%
  dplyr::distinct(
    .data$season,
    .data$snapshot_time,
    .data$franchise_id,
    .data$player_id,
    .keep_all = TRUE
  )

# ----------------------------
# Enrich tx
# ----------------------------

tx_enriched <- tx %>%
  dplyr::mutate(player_id = as.character(.data$player_id)) %>%
  add_conf_fields("franchise_id") %>%
  dplyr::left_join(franchises %>% dplyr::select(franchise_id, abbrev), by = "franchise_id") %>%
  dplyr::mutate(
    PLAYER = nflreadr::clean_player_names(dplyr::coalesce(.data$player_name, "")),
    DATE_raw = lubridate::ymd_hms(.data$timestamp, quiet = TRUE, tz = "UTC")
  )

if (all(is.na(tx_enriched$DATE_raw))) {
  warning("Could not parse timestamp via ymd_hms(); using as.POSIXct fallback.")
  tx_enriched <- tx_enriched %>%
    dplyr::mutate(DATE_raw = as.POSIXct(.data$timestamp, tz = "UTC"))
}

tx_enriched <- tx_enriched %>%
  dplyr::mutate(DATE_local = lubridate::with_tz(.data$DATE_raw, tzone = "America/Toronto")) %>%
  dplyr::filter(.data$DATE_local > cutoff_end_local) %>%
  dplyr::select(-"DATE_local") %>%
  dplyr::distinct(.data$row_key, .keep_all = TRUE)

historical_roster_matches <- tx_enriched %>%
  dplyr::select(dplyr::all_of(c("row_key", "player_id", "franchise_id", "DATE_raw"))) %>%
  dplyr::left_join(
    roster_snapshot_history,
    by = c("player_id", "franchise_id"),
    relationship = "many-to-many"
  ) %>%
  dplyr::filter(!is.na(.data$snapshot_time), .data$snapshot_time <= .data$DATE_raw) %>%
  dplyr::group_by(.data$row_key) %>%
  dplyr::arrange(dplyr::desc(.data$snapshot_time), .by_group = TRUE) %>%
  dplyr::slice(1) %>%
  dplyr::ungroup() %>%
  dplyr::transmute(
    row_key = .data$row_key,
    salary_snap = .data$roster_salary,
    years_snap = .data$roster_years,
    info_snap = .data$roster_contractInfo,
    salary_snapshot_time = .data$snapshot_time
  )

current_player_fallback <- current_roster_snapshot %>%
  dplyr::left_join(
    franchises %>%
      dplyr::transmute(
        current_player_franchise_id = as.character(.data$franchise_id),
        current_player_abbrev = .data$abbrev
      ),
    by = c("franchise_id" = "current_player_franchise_id")
  ) %>%
  dplyr::group_by(.data$player_id) %>%
  dplyr::arrange(
    dplyr::desc(.data$roster_salary),
    dplyr::desc(.data$roster_years),
    .by_group = TRUE
  ) %>%
  dplyr::slice(1) %>%
  dplyr::ungroup() %>%
  dplyr::transmute(
    player_id = .data$player_id,
    current_player_salary = .data$roster_salary,
    current_player_years = .data$roster_years,
    current_player_contractInfo = .data$roster_contractInfo,
    current_player_franchise_id = .data$franchise_id,
    current_player_abbrev = .data$current_player_abbrev
  )

tx_enriched <- tx_enriched %>%
  dplyr::left_join(historical_roster_matches, by = "row_key") %>%
  dplyr::left_join(current_player_fallback, by = "player_id")

# ----------------------------
# Output columns for penalties
# ----------------------------

pen_col_1 <- paste0(current_season, " PEN")
pen_col_2 <- paste0(current_season + 1, " PEN")

# ----------------------------
# 1) Cash trade rows
# ----------------------------

trade_groups <- tx_enriched %>%
  dplyr::filter(.data$type == "TRADE") %>%
  dplyr::mutate(comm = dplyr::coalesce(.data$comments, "")) %>%
  dplyr::group_by(.data$timestamp) %>%
  dplyr::summarise(
    DATE_sort = dplyr::first(.data$DATE_raw),
    comm_blob = paste(unique(.data$comm[nzchar(.data$comm)]), collapse = " | "),
    franchise_ids = list(unique(as.character(.data$franchise_id))),
    .groups = "drop"
  ) %>%
  dplyr::mutate(
    comm_blob_lc = norm_text(.data$comm_blob),
    n_fr = purrr::map_int(.data$franchise_ids, length),
    skip_comment = stringr::str_detect(.data$comm_blob_lc, "\\b(retain|buyout|restructure)\\b")
  ) %>%
  dplyr::filter(.data$n_fr >= 2, !.data$skip_comment) %>%
  dplyr::mutate(
    franchise_ids = purrr::map(.data$franchise_ids, ~ .x[1:2]),
    cash_amt_m = extract_cash_millions(.data$comm_blob),
    sender_franchise_id = purrr::map2_chr(.data$comm_blob, .data$franchise_ids, ~ infer_sender_from_comment(.x, .y, franchises)),
    receiver_franchise_id = purrr::map2_chr(.data$franchise_ids, .data$sender_franchise_id, ~ {
      if (is.na(.y)) return(NA_character_)
      setdiff(as.character(.x), as.character(.y))[1]
    }),
    notes_flag = dplyr::if_else(is.na(.data$sender_franchise_id), "CHECK DIR", ""),
    sender_abbrev = franchise_id_to_abbrev(.data$sender_franchise_id, franchises),
    receiver_abbrev = franchise_id_to_abbrev(.data$receiver_franchise_id, franchises),
    sender_conf = franchise_to_conf(suppressWarnings(as.integer(.data$sender_franchise_id))),
    receiver_conf = franchise_to_conf(suppressWarnings(as.integer(.data$receiver_franchise_id)))
  ) %>%
  dplyr::filter(
    !is.na(.data$cash_amt_m),
    !is.na(.data$sender_franchise_id),
    !is.na(.data$receiver_franchise_id),
    .data$sender_franchise_id != .data$receiver_franchise_id
  )

cash_trade_rows <- tibble::tibble()

if (nrow(trade_groups) > 0) {
  # Positive first (sender)
  sender_rows <- trade_groups %>%
    dplyr::transmute(
      row_key = paste0("cash|ts=", .data$timestamp, "|fr=", .data$sender_abbrev, "|amt=", abs(.data$cash_amt_m)),
      pair_key = paste0("cashpair|", .data$timestamp, "|", .data$sender_abbrev, "|", .data$receiver_abbrev, "|", .data$cash_amt_m),
      pair_ord = 1L,
      CONF = .data$sender_conf,
      DATE_sort = .data$DATE_sort,
      FRAN = .data$sender_abbrev,
      PLAYER = "Cash Trade",
      SALARY = as.character(abs(.data$cash_amt_m)),
      YEARS = "1",
      CONTRACT = "",
      !!pen_col_1 := "",
      !!pen_col_2 := "",
      `B/R` = "",
      `TR/IB` = "x",
      FG = "",
      `(S)` = "",
      JT = "",
      `1.XX+` = "",
      NOTES = .data$notes_flag,
      `ENTD?` = "",
      `RVSD?` = ""
    )
  
  # Negative second (receiver)
  receiver_rows <- trade_groups %>%
    dplyr::transmute(
      row_key = paste0("cash|ts=", .data$timestamp, "|fr=", .data$receiver_abbrev, "|amt=", -abs(.data$cash_amt_m)),
      pair_key = paste0("cashpair|", .data$timestamp, "|", .data$sender_abbrev, "|", .data$receiver_abbrev, "|", .data$cash_amt_m),
      pair_ord = 2L,
      CONF = .data$receiver_conf,
      DATE_sort = .data$DATE_sort,
      FRAN = .data$receiver_abbrev,
      PLAYER = "Cash Trade",
      SALARY = as.character(-abs(.data$cash_amt_m)),
      YEARS = "1",
      CONTRACT = "",
      !!pen_col_1 := "",
      !!pen_col_2 := "",
      `B/R` = "",
      `TR/IB` = "x",
      FG = "",
      `(S)` = "",
      JT = "",
      `1.XX+` = "",
      NOTES = .data$notes_flag,
      `ENTD?` = "",
      `RVSD?` = ""
    )
  
  cash_trade_rows <- dplyr::bind_rows(sender_rows, receiver_rows) %>%
    dplyr::group_by(.data$pair_key, .data$pair_ord) %>%
    dplyr::slice(1) %>%
    dplyr::ungroup()
}

# ----------------------------
# 2) Salary-adjustment rows
# ----------------------------

sd_rows <- tx_enriched %>%
  dplyr::filter(.data$type == "FREE_AGENT", .data$type_desc == "dropped") %>%
  dplyr::mutate(
    missing_salary_snapshot = is.na(.data$salary_snap) & is.na(.data$info_snap),
    current_player_qualifies = .data$missing_salary_snapshot &
      .data$DATE_raw >= missing_snapshot_review_start & (
        dplyr::coalesce(.data$current_player_salary, -Inf) >= sd_min |
          is_fg(.data$current_player_contractInfo)
      ),
    RVSD_flag = is_xx_caret_3plus(.data$info_snap),
    qualifies = (.data$current_player_qualifies) |
      (dplyr::coalesce(.data$salary_snap, -Inf) >= sd_min) |
      is_fg(.data$info_snap)
  ) %>%
  dplyr::filter(.data$qualifies) %>%
  dplyr::mutate(
    SALARY = dplyr::if_else(.data$missing_salary_snapshot, "CHECK", as.character(.data$salary_snap)),
    YEARS  = dplyr::if_else(.data$missing_salary_snapshot, "CHECK", as.character(.data$years_snap)),
    CONTRACT = dplyr::if_else(
      .data$missing_salary_snapshot,
      "",
      dplyr::coalesce(as.character(.data$info_snap), "")
    ),
    FG = dplyr::if_else(!.data$missing_salary_snapshot & is_fg(.data$info_snap), "x", ""),
    `1.XX+` = dplyr::if_else(!.data$missing_salary_snapshot & has_plus(.data$info_snap), "fill", ""),
    NOTES = dplyr::case_when(
      .data$current_player_qualifies ~ paste0(
        "CHECK SALARY - NO PRIOR FRANCHISE SNAPSHOT; CURRENT ",
        dplyr::coalesce(.data$current_player_abbrev, .data$current_player_franchise_id, "TEAM"),
        " ",
        dplyr::coalesce(as.character(.data$current_player_salary), "?"),
        " ",
        dplyr::coalesce(.data$current_player_contractInfo, "")
      ),
      .data$RVSD_flag ~ "NG PPE",
      .data$FG == "x" ~ dplyr::coalesce(.data$info_snap, ""),
      TRUE ~ ""
    ),
    `RVSD?` = dplyr::if_else(.data$RVSD_flag, "x", "")
  ) %>%
  dplyr::transmute(
    row_key = .data$row_key,
    pair_key = paste0("drop|", .data$row_key),
    pair_ord = 1L,
    CONF = .data$CONF,
    DATE_sort = .data$DATE_raw,
    FRAN = .data$abbrev,
    PLAYER = .data$PLAYER,
    SALARY = .data$SALARY,
    YEARS = .data$YEARS,
    CONTRACT = .data$CONTRACT,
    !!pen_col_1 := "",
    !!pen_col_2 := "",
    `B/R` = "",
    `TR/IB` = "",
    FG = .data$FG,
    `(S)` = "",
    JT = "",
    `1.XX+` = .data$`1.XX+`,
    NOTES = .data$NOTES,
    `ENTD?` = "",
    `RVSD?` = .data$`RVSD?`
  )

# ----------------------------
# Combine, cache, output
# ----------------------------

new_qualified <- dplyr::bind_rows(sd_rows, cash_trade_rows)

if (nrow(new_qualified) == 0) {
  final_out_csv <- tibble::tibble()
  readr::write_csv(final_out_csv, out_csv, na = "")
  saveRDS(final_out_csv, out_rds)
  saveRDS(final_out_csv, qualified_rds)
  message("No qualifying rows after filtering. Outputs refreshed.")
  return(final_out_csv)
}

qualified_all <- dplyr::bind_rows(qualified_existing, new_qualified) %>%
  dplyr::distinct(.data$row_key, .keep_all = TRUE) %>%
  dplyr::mutate(DATE_sort_local = lubridate::with_tz(.data$DATE_sort, tzone = "America/Toronto")) %>%
  dplyr::filter(.data$DATE_sort_local > cutoff_end_local) %>%
  dplyr::select(-"DATE_sort_local")

qualified_all <- normalize_and_dedupe_cache(qualified_all)

saveRDS(qualified_all, qualified_rds)

final_out_csv <- qualified_all %>%
  dplyr::mutate(
    DATE_local = lubridate::with_tz(.data$DATE_sort, tzone = "America/Toronto"),
    DATE = format_mdy_hms(.data$DATE_local),
    pair_key = dplyr::coalesce(.data$pair_key, paste0("noncash|", .data$row_key)),
    pair_ord = dplyr::coalesce(.data$pair_ord, 1L)
  ) %>%
  dplyr::arrange(.data$CONF, .data$DATE_sort, .data$pair_key, .data$pair_ord) %>%
  dplyr::select(
    dplyr::all_of(c(
      "CONF",
      "DATE",
      "FRAN",
      "PLAYER",
      "SALARY",
      "YEARS",
      "CONTRACT",
      pen_col_1,
      pen_col_2,
      "B/R",
      "TR/IB",
      "FG",
      "(S)",
      "JT",
      "1.XX+",
      "NOTES",
      "ENTD?",
      "RVSD?"
    ))
  )

readr::write_csv(final_out_csv, out_csv, na = "")
saveRDS(final_out_csv, out_rds)

message("Wrote: ", out_csv)
message("Wrote: ", out_rds)
message("Cached qualified rows: ", qualified_rds)
  final_out_csv
}
