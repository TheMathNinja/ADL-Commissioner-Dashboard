# Manual-only MFL salary no-op write test.
# Writes one player's existing salary back to MFL, then verifies salary/contract fields still match.

.libPaths(c(Sys.getenv("R_LIBS_USER"), .libPaths()))

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tibble)
})

source("R/config_helpers.R")
source("R/mfl_helpers.R")
source("R/official_july1_snapshot.R")

coalesce_roster_col <- function(df, candidates, default = NA_character_) {
  hit <- intersect(candidates, names(df))
  if (!length(hit)) return(rep(default, nrow(df)))
  out <- as.character(df[[hit[[1]]]])
  for (nm in hit[-1]) out <- dplyr::coalesce(out, as.character(df[[nm]]))
  out
}

normalize_noop_rosters <- function(rosters) {
  rosters <- tibble::as_tibble(rosters)
  tibble(
    franchise_id = as.character(coalesce_roster_col(rosters, c("franchise_id", "franchise"))),
    franchise_name = as.character(coalesce_roster_col(rosters, c("franchise_name", "franchise_abbr", "franchise"))),
    player_id = as.character(coalesce_roster_col(rosters, c("player_id", "mfl_id", "id"))),
    player_name = as.character(coalesce_roster_col(rosters, c("player_name", "player", "name"))),
    player_team = as.character(coalesce_roster_col(rosters, c("player_team", "team", "pro_team"))),
    player_pos = as.character(coalesce_roster_col(rosters, c("player_pos", "pos", "position"))),
    roster_salary = suppressWarnings(as.numeric(coalesce_roster_col(rosters, c("salary", "player_salary", "contract_salary", "roster_salary"), NA_real_))),
    roster_years = suppressWarnings(as.numeric(coalesce_roster_col(rosters, c("contract_years", "years", "contractYears", "roster_years"), NA_real_))),
    roster_contractInfo = as.character(coalesce_roster_col(rosters, c("contractInfo", "contract_info", "contractinfo", "roster_contractInfo"), ""))
  ) |>
    filter(!is.na(.data$player_id), nzchar(.data$player_id), !is.na(.data$franchise_id), nzchar(.data$franchise_id))
}

season_env <- Sys.getenv("CURRENT_SEASON", unset = "")
season <- suppressWarnings(as.integer(season_env))
if (is.na(season)) season <- get_current_season()

player_id_filter <- trimws(Sys.getenv("ADL_MFL_NOOP_PLAYER_ID", unset = ""))
franchise_id_filter <- trimws(Sys.getenv("ADL_MFL_NOOP_FRANCHISE_ID", unset = ""))

conn <- connect_adl_mfl(season)
before <- normalize_noop_rosters(ffscrapr::ff_rosters(conn))

candidates <- before |>
  filter(!is.na(.data$roster_salary)) |>
  arrange(.data$franchise_id, .data$player_name, .data$player_id)

if (nzchar(player_id_filter)) candidates <- candidates |> filter(.data$player_id == .env$player_id_filter)
if (nzchar(franchise_id_filter)) candidates <- candidates |> filter(.data$franchise_id == .env$franchise_id_filter)
if (!nrow(candidates)) stop("No salary-bearing roster row found for the requested no-op write test.", call. = FALSE)

row_before <- candidates[1, , drop = FALSE]
write_row <- tibble(
  season = season,
  franchise_id = row_before$franchise_id,
  franchise_name = row_before$franchise_name,
  CONF = NA_character_,
  player_id = row_before$player_id,
  player_name = row_before$player_name,
  player_team = row_before$player_team,
  player_pos = row_before$player_pos,
  roster_contractInfo = row_before$roster_contractInfo,
  roster_years = row_before$roster_years,
  old_salary = row_before$roster_salary,
  new_salary = row_before$roster_salary
)

response_text <- write_single_mfl_salary_update(conn, write_row, import_type = "salaries")
Sys.sleep(8)

after <- normalize_noop_rosters(ffscrapr::ff_rosters(conn))
row_after <- after |>
  filter(.data$franchise_id == row_before$franchise_id[[1]], .data$player_id == row_before$player_id[[1]]) |>
  slice_head(n = 1)
if (!nrow(row_after)) stop("No-op write test failed: player was not found after re-scraping rosters.", call. = FALSE)

salary_match <- isTRUE(abs(row_after$roster_salary[[1]] - row_before$roster_salary[[1]]) < 0.001)
years_match <- isTRUE(is.na(row_before$roster_years[[1]]) || is.na(row_after$roster_years[[1]]) || abs(row_after$roster_years[[1]] - row_before$roster_years[[1]]) < 0.001)
contract_match <- isTRUE(trimws(row_after$roster_contractInfo[[1]] %||% "") == trimws(row_before$roster_contractInfo[[1]] %||% ""))

result <- tibble(
  tested_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
  season = season,
  franchise_id = row_before$franchise_id,
  franchise_name = row_before$franchise_name,
  player_id = row_before$player_id,
  player_name = row_before$player_name,
  player_team = row_before$player_team,
  player_pos = row_before$player_pos,
  before_salary = row_before$roster_salary,
  after_salary = row_after$roster_salary,
  before_years = row_before$roster_years,
  after_years = row_after$roster_years,
  before_contractInfo = row_before$roster_contractInfo,
  after_contractInfo = row_after$roster_contractInfo,
  salary_match = salary_match,
  years_match = years_match,
  contract_match = contract_match,
  response_preview = substr(response_text, 1, 240)
)

dir.create(file.path("data", "salary_snapshots"), recursive = TRUE, showWarnings = FALSE)
out <- file.path("data", "salary_snapshots", paste0("mfl_salary_noop_write_test_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".csv"))
readr::write_csv(result, out, na = "")

print(result |> select(season, franchise_id, player_id, player_name, before_salary, after_salary, salary_match, years_match, contract_match))
cat("No-op test audit written to", out, "\n")

if (!salary_match || !years_match || !contract_match) {
  stop("MFL salary no-op write did not round-trip cleanly. See audit output.", call. = FALSE)
}
