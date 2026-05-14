# run_cap_accounting.R
# --------------------
# Runs a salary cap accounting snapshot and summary.

source("R/config_helpers.R")
source("R/cap_accounting_engine.R")

current_season <- get_current_season()
snapshot_week <- as.integer(Sys.getenv("SNAPSHOT_WEEK", unset = "1"))

message("Running salary cap accounting snapshot for season ", current_season, ", week ", snapshot_week)

outputs <- build_cap_accounting_snapshot(
  current_season = current_season,
  snapshot_week = snapshot_week,
  output_dir = "data"
)

print(outputs)
