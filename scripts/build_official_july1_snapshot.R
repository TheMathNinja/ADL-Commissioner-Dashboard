library(readr)

source("R/config_helpers.R")
source("R/official_july1_snapshot.R")

season <- get_current_season()
today <- as.Date(Sys.getenv("ADL_TODAY", unset = as.character(Sys.Date())))

if (format(today, "%m-%d") < "07-01" && !identical(Sys.getenv("ADL_ALLOW_PRE_JULY1_OFFICIAL_BUILD", unset = "FALSE"), "TRUE")) {
  message("Skipping official July 1 salary snapshot before July 1.")
  quit(save = "no", status = 0)
}

status <- build_official_july1_salary_snapshot(season = season, output_dir = "data")
print(status)
