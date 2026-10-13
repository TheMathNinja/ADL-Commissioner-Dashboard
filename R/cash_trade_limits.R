adl_net_cash_trade_limit <- function(season = get_current_season()) {
  env_name <- paste0("ADL_NET_CASH_TRADE_LIMIT_", season)
  env_value <- suppressWarnings(as.numeric(Sys.getenv(env_name, unset = NA_character_)))
  if (!is.na(env_value)) return(env_value)

  limits <- c(`2026` = 12.20)
  value <- limits[[as.character(season)]]
  if (is.null(value) || is.na(value)) {
    stop("Missing ADL net cash trade limit for ", season, ". Set ", env_name, ".", call. = FALSE)
  }
  value
}

summarize_cash_trade_net <- function(saladj_rows) {
  rows <- tibble::as_tibble(saladj_rows)
  required <- c("FRAN", "PLAYER", "SALARY")
  if (!all(required %in% names(rows))) {
    return(tibble::tibble(
      conference = character(), franchise = character(), total_given = numeric(),
      total_acquired = numeric(), net_given = numeric(), net_amount = numeric(),
      net_direction = character()
    ))
  }

  if (!"CONF" %in% names(rows)) rows$CONF <- NA_character_

  rows |>
    dplyr::mutate(
      cash_amount = suppressWarnings(as.numeric(gsub("[$,]", "", as.character(.data$SALARY)))),
      PLAYER = toupper(trimws(as.character(.data$PLAYER))),
      FRAN = toupper(trimws(as.character(.data$FRAN))),
      CONF = toupper(trimws(as.character(.data$CONF)))
    ) |>
    dplyr::filter(.data$PLAYER == "CASH TRADE", nzchar(.data$FRAN), !is.na(.data$cash_amount)) |>
    dplyr::group_by(.data$FRAN) |>
    dplyr::summarize(
      conference = dplyr::first(.data$CONF[nzchar(.data$CONF)], default = NA_character_),
      total_given = round(sum(pmax(.data$cash_amount, 0), na.rm = TRUE), 2),
      total_acquired = round(sum(pmax(-.data$cash_amount, 0), na.rm = TRUE), 2),
      net_given = round(sum(.data$cash_amount, na.rm = TRUE), 2),
      .groups = "drop"
    ) |>
    dplyr::transmute(
      conference = .data$conference,
      franchise = .data$FRAN,
      total_given = .data$total_given,
      total_acquired = .data$total_acquired,
      net_given = .data$net_given,
      net_amount = abs(.data$net_given),
      net_direction = dplyr::if_else(.data$net_given >= 0, "given", "acquired")
    )
}

evaluate_cash_trade_limit <- function(saladj_rows, season = get_current_season(), limit = adl_net_cash_trade_limit(season)) {
  summarize_cash_trade_net(saladj_rows) |>
    dplyr::filter(.data$net_amount > .env$limit + 1e-9) |>
    dplyr::mutate(
      season = as.integer(.env$season),
      limit = round(.env$limit, 2),
      overage = round(.data$net_amount - .env$limit, 2)
    )
}
