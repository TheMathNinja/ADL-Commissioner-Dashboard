source("R/inseason_inactivity_monitor.R")
source("R/official_july1_snapshot.R")
source("R/emergency_salary_preflight.R")
run_emergency_salary_preflight(get_current_season(), as.integer(Sys.getenv("SNAPSHOT_WEEK")))
