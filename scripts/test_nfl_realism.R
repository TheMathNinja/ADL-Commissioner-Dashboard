library(dplyr)
source("R/nfl_realism.R")
source("R/nfl_realism_ids.R")
# Same NFL player must get the ADL position of the requested year, not current position.
r <- data.frame(season=c(2021,2022,2022,2022,2022), gsis_id=c("a","a","missing","ol","conflict"),
  espn_id=c("1","1",NA,"4","1"), position=c("LB","LB","LB","OL","LB"), depth_chart_position=c("OLB","OLB","OLB","T","OLB"))
ids <- data.frame(gsis_id=c("a","ol","conflict"), espn_id=c("1","4","5"), mfl_id=c("10","20","30"))
m <- data.frame(season=c(2021,2022,2022,2022),id=c("10","10","20","30"),position=c("LB","DE","TE","LB"),
  name=c("Player A","Player A","Player OL","Player Conflict"),espn_id=c("1","1","4","5"),rotowire_id=NA_character_)
resolved <- resolve_nfl_realism_positions(r, ids, m)$rosters
stopifnot(resolved$adl_position[1]=="LB",resolved$adl_position[2]=="DE",
  grepl("Estimated",resolved$position_method[3]),resolved$adl_position[3]=="DE",
  resolved$adl_position[4]=="OL",resolved$mfl_candidates[5]==2,
  grepl("Estimated",resolved$position_method[5]))
# Frozen historical integration: zeros, game coverage, status totals and no 53 normalization.
w <- readr::read_csv("data/nfl_realism/weekly.csv",show_col_types=FALSE)
a <- readr::read_csv("data/nfl_realism/audit.csv",show_col_types=FALSE)
t <- readr::read_csv("data/nfl_realism/totals.csv",col_types=readr::cols(season=readr::col_character()),show_col_types=FALSE)
s <- readr::read_csv("data/nfl_realism/summary.csv",col_types=readr::cols(season=readr::col_character()),guess_max=Inf,show_col_types=FALSE)
stopifnot(nrow(a)==2718,nrow(w)==2718*2*length(nfl_realism_positions()),
  all(w$players >= 0), any(w$players==0), all(abs(t$observed_non_ol_ls-(t$act+t$ina-t$ol-t$ls))<1e-10),
  all(!is.na(s$season)),nrow(readr::problems(s))==0,
  abs(t$observed_roster[t$season=="ALL"&t$team=="NFL"]-54.19115349264706)<1e-10)
counts <- w |> group_by(season,team,week,status) |> summarise(n=sum(players),.groups="drop")
check <- counts |> left_join(a,by=c("season","team","week"))
stopifnot(all(check$n[check$status=="ACT"]==check$act[check$status=="ACT"]),
  all(check$n[check$status=="INA"]==check$ina[check$status=="INA"]))
message("Historical positions, ambiguous IDs, fallback, non-ADL exclusions and 2,718 team-game counts passed.")
