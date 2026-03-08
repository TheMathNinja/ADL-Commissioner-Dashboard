# build_dashboard.R
# -----------------
# This script builds the dashboard website files.

library(tidyverse)

source("R/config_helpers.R")
source("R/dashboard_helpers.R")

current_season <- get_current_season()

# Read the SalAdjCurator output
saladj_summary <- readr::read_csv("data/saladj_summary.csv", show_col_types = FALSE)

# Make sure docs directory exists
dir.create("docs", showWarnings = FALSE)

# Build HTML page
html <- build_dashboard_html(saladj_summary)

writeLines(html, "docs/index.html")

message("Dashboard build complete for season: ", current_season)