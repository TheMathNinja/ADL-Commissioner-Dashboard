salary_thresholds <- tibble::tribble(
  ~season, ~adl_veteran_min,
  2020L, 0.8,
  2021L, 0.9,
  2022L, 0.9,
  2023L, 0.9,
  2024L, 1.0,
  2025L, 1.0,
  2026L, 1.1,
  2027L, 1.1,
  2028L, 1.2,
  2029L, 1.2,
  2030L, 1.3
)

get_cap_veteran_min <- function(current_season) {
  vet_min <- salary_thresholds %>%
    dplyr::filter(.data$season == current_season) %>%
    dplyr::pull(.data$adl_veteran_min)

  if (length(vet_min) != 1 || is.na(vet_min)) {
    stop("No ADL veteran minimum configured for season ", current_season, ".")
  }

  vet_min
}
