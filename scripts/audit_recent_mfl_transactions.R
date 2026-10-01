library(dplyr)
library(ffscrapr)
library(readr)
library(tibble)

source("R/config_helpers.R")
source("R/mfl_helpers.R")

season <- get_current_season()
conn <- connect_adl_mfl(season)

flatten_raw_transactions <- function(x) {
  if (is.null(x) || !length(x)) return(tibble())
  if (is.data.frame(x)) return(as_tibble(x))
  if (is.list(x) && is.null(names(x))) {
    return(bind_rows(lapply(x, function(row) as_tibble(as.list(row)))))
  }
  as_tibble(as.list(x))
}

raw <- ffscrapr::mfl_getendpoint(conn, endpoint = "transactions")[["content"]][["transactions"]][["transaction"]] |>
  flatten_raw_transactions()

if (!nrow(raw)) {
  write_csv(tibble(), "data/saladj_transaction_audit.csv")
  quit(save = "no", status = 0)
}

for (name in c("timestamp", "type", "franchise", "franchise_id", "player_id", "player_name", "added", "dropped", "transaction", "comments")) {
  if (!name %in% names(raw)) raw[[name]] <- NA_character_
  raw[[name]] <- as.character(raw[[name]])
}

players <- tryCatch(ffscrapr::ff_players(conn), error = function(e) tibble())
if (nrow(players)) {
  player_id_col <- intersect(names(players), c("player_id", "id"))[1]
  player_name_col <- intersect(names(players), c("player_name", "name"))[1]
  if (!is.na(player_id_col) && !is.na(player_name_col)) {
    player_lookup <- players |>
      transmute(player_id_lookup = as.character(.data[[player_id_col]]), player_name_lookup = as.character(.data[[player_name_col]])) |>
      distinct(.data$player_id_lookup, .keep_all = TRUE)
  } else {
    player_lookup <- tibble(player_id_lookup = character(), player_name_lookup = character())
  }
} else {
  player_lookup <- tibble(player_id_lookup = character(), player_name_lookup = character())
}

recent_cutoff <- as.numeric(Sys.time() - as.difftime(3, units = "days"))
audit <- raw |>
  mutate(
    franchise_id = coalesce(na_if(.data$franchise_id, ""), .data$franchise),
    timestamp_numeric = suppressWarnings(as.numeric(.data$timestamp)),
    raw_text = paste(.data$type, .data$comments, .data$player_name, .data$added, .data$dropped, .data$transaction)
  ) |>
  filter(
    .data$timestamp_numeric >= .env$recent_cutoff |
    grepl("roster|load|unload|marquise|brown", .data$raw_text, ignore.case = TRUE)
  ) |>
  arrange(desc(.data$timestamp_numeric)) |>
  select(any_of(c("timestamp", "type", "franchise_id", "player_id", "player_name", "added", "dropped", "transaction", "comments")))

write_csv(audit, "data/saladj_transaction_audit.csv", na = "")
print(audit, n = Inf, width = Inf)
