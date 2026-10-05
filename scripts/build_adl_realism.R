# Offline rebuild from frozen ADL weekly exports and NFL data.
source("R/nfl_realism.R")
source("R/adl_realism.R")
build_adl_realism(nfl_injury_path="data/nfl_realism/source_adl_fallback_injuries.rds")
publish_nfl_realism()
