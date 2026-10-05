# ADL Active Roster: only Out/O or a scheduled NFL bye is INA; everything else is ACT.
adl_realism_status <- function(designation, bye) {
  status <- toupper(trimws(ifelse(is.na(designation), "", designation)))
  ifelse(status %in% c("O", "OUT", "BYE") | bye, "INA", "ACT")
}

build_adl_realism <- function(history_dir = "data/nfl_realism/adl_history", nfl_injury_path) {
  library(dplyr)
  out <- "data/nfl_realism"
  positions <- setdiff(nfl_realism_positions(), c("OL", "LS"))
  mfl <- readr::read_csv(file.path(out, "source_mfl_players.csv"), col_types = readr::cols(.default=readr::col_character(),season=readr::col_integer()),show_col_types=FALSE)
  nfl <- readr::read_csv(file.path(out,"player_snapshots.csv.gz"), col_types=readr::cols(.default=readr::col_character(),season=readr::col_integer(),week=readr::col_integer()),show_col_types=FALSE)
  schedule <- readRDS(file.path(out,"source_schedules_2021_2025.rds")) |> filter(game_type=="REG")
  injury <- readRDS(nfl_injury_path) |> filter(game_type=="REG")
  # Stable identity link from the matched NFL player audit plus frozen crosswalk.
  cross <- readRDS(file.path(out,"source_id_crosswalk.rds"))
  id_index <- bind_rows(nfl |> select(mfl_id,gsis_id), cross |> transmute(mfl_id=as.character(mfl_id),gsis_id=as.character(gsis_id))) |>
    filter(!is.na(mfl_id),nzchar(mfl_id),!is.na(gsis_id),nzchar(gsis_id)) |>
    distinct() |> group_by(gsis_id) |> filter(n_distinct(mfl_id)==1) |> ungroup()
  injury <- injury |> left_join(id_index,by="gsis_id",relationship="many-to-many")
  map_team <- function(x) {
    aliases <- c(KCC="KC",GBP="GB",NOS="NO",NEP="NE",SFO="SF",TBB="TB",LAR="LA",LVR="LV",JAC="JAX",ARZ="ARI",OAK="LV",STL="LA",SD="LAC")
    ifelse(x %in% names(aliases),unname(aliases[x]),x)
  }
  # Prefer contemporaneous NFL roster observations, then nearest earlier/next week.
  nfl_team <- nfl |> filter(!is.na(mfl_id),nzchar(mfl_id)) |>
    mutate(priority=match(status,c("ACT","INA","RES","DEV","PUP","SUS","CUT","RET"))) |>
    arrange(season,mfl_id,week,priority) |> distinct(season,mfl_id,week,.keep_all=TRUE)
  all_players <- list(); grids <- list(); coverage <- list()
  for (year in 2021:2025) {
    league <- jsonlite::fromJSON(file.path(history_dir,sprintf("%d_league.json",year)))$league
    weeks <- seq.int(as.integer(league$startWeek),as.integer(league$endWeek))
    franchises <- league$franchises$franchise |> transmute(franchise_id=id,franchise_name=name)
    annual <- mfl |> filter(season==year) |> transmute(player_id=id,player_name=name,adl_position=position,annual_nfl_team=map_team(team))
    for (week in weeks) {
      r <- jsonlite::fromJSON(file.path(history_dir,sprintf("%d_rosters_week%02d.json",year,week)))$rosters$franchise
      rows <- bind_rows(lapply(seq_len(nrow(r)),function(i) {
        p <- r$player[[i]]
        if(is.null(p)||!nrow(p)) return(NULL)
        transmute(p,franchise_id=r$id[i],player_id=as.character(id),roster_status=status)
      })) |> group_by(franchise_id,player_id) |>
        mutate(source_roster_statuses=paste(sort(unique(roster_status)),collapse="|"),
          membership_conflict=n_distinct(roster_status)>1) |> ungroup() |>
        arrange(franchise_id,player_id,match(roster_status,c("ROSTER","INJURED_RESERVE","TAXI_SQUAD"))) |>
        distinct(franchise_id,player_id,.keep_all=TRUE) |>
        left_join(franchises,by="franchise_id") |> left_join(annual,by="player_id")
      if(any(is.na(rows$adl_position))) stop("Missing annual ADL player position: ",year," week ",week)
      snap <- jsonlite::fromJSON(file.path(history_dir,sprintf("%d_injuries_week%02d.json",year,week)))$injuries
      reports <- snap$injury
      has_mfl <- is.data.frame(reports)&&nrow(reports)>0
      if(has_mfl) {
        designations <- reports |> transmute(player_id=as.character(id),designation=status) |>
          mutate(is_out=toupper(designation)%in%c("O","OUT")) |> arrange(desc(is_out)) |> distinct(player_id,.keep_all=TRUE) |> select(-is_out)
        designation_source <- "Archived MFL weekly injuries"
      } else {
        reports <- injury |> filter(season==year,.data$week==.env$week)
        if(!nrow(reports)) stop("No historical designation coverage: ",year," week ",week)
        designations <- reports |> filter(!is.na(mfl_id)) |> transmute(player_id=mfl_id,designation=report_status) |>
          mutate(is_out=designation=="Out") |> arrange(desc(is_out)) |> distinct(player_id,.keep_all=TRUE) |> select(-is_out)
        designation_source <- "Reconstructed O: archived nflreadr injury report"
      }
      observed <- nfl_team |> filter(season==year) |> mutate(distance=abs(.data$week-.env$week),future=.data$week>.env$week) |>
        arrange(mfl_id,distance,future) |> distinct(mfl_id,.keep_all=TRUE) |>
        transmute(player_id=mfl_id,nfl_team=team,team_source=if_else(.data$week==.env$week,"Same-week NFL roster","Nearest-week NFL roster"))
      # A contemporaneous injury report can establish team even during roster-data gaps.
      injury_teams <- injury |> filter(season==year,.data$week==.env$week,!is.na(mfl_id)) |>
        distinct(mfl_id,.keep_all=TRUE) |> transmute(player_id=mfl_id,injury_nfl_team=team)
      games <- schedule |> filter(season==year,.data$week==.env$week)
      playing <- unique(c(games$home_team,games$away_team))
      season_teams <- unique(c(schedule$home_team[schedule$season==year],schedule$away_team[schedule$season==year]))
      rows <- rows |> left_join(designations,by="player_id") |> left_join(observed,by="player_id") |> left_join(injury_teams,by="player_id") |>
        mutate(nfl_team=coalesce(injury_nfl_team,nfl_team,annual_nfl_team),
          team_source=if_else(!is.na(injury_nfl_team),"Same-week NFL injury report",coalesce(team_source,"Annual MFL team fallback")),
          is_bye=nfl_team%in%season_teams & !nfl_team%in%playing,
          season=year,week=week,designation_source=designation_source,
          gameday_status=adl_realism_status(designation,is_bye),
          ina_reason=case_when(toupper(coalesce(designation,""))%in%c("O","OUT") & is_bye ~ "O + Bye",
            toupper(coalesce(designation,""))%in%c("O","OUT") ~ "O",is_bye | toupper(coalesce(designation,""))=="BYE" ~ "Bye",TRUE~""))
      all_players[[length(all_players)+1L]]<-rows
      grids[[length(grids)+1L]] <- expand.grid(season=year,week=week,franchise_id=franchises$franchise_id,gameday_status=c("ACT","INA"),adl_position=positions,stringsAsFactors=FALSE)
      coverage[[length(coverage)+1L]]<-data.frame(season=year,week=week,franchises=nrow(franchises),designation_source=designation_source,
        report_rows=nrow(reports),active_players=sum(rows$roster_status=="ROSTER"),
        annual_team_fallback=sum(rows$roster_status=="ROSTER" & rows$team_source=="Annual MFL team fallback"),
        membership_conflicts=sum(rows$membership_conflict))
    }
  }
  players <- bind_rows(all_players)
  if(any(players$roster_status=="ROSTER" & !players$adl_position %in% positions)) stop("Unexpected active ADL position.")
  weekly <- bind_rows(grids) |> left_join(players |> filter(roster_status=="ROSTER") |> count(season,week,franchise_id,gameday_status,adl_position,name="players"),
    by=c("season","week","franchise_id","gameday_status","adl_position")) |> mutate(players=coalesce(players,0L))
  team_year <- weekly |> group_by(season,franchise_id,gameday_status,adl_position) |>
    summarise(mean_players=mean(players),weeks=n(),.groups="drop")
  year_mean <- team_year |> group_by(season,gameday_status,adl_position) |> summarise(mean_players=mean(mean_players),.groups="drop")
  composite <- year_mean |> group_by(gameday_status,adl_position) |> summarise(mean_players=mean(mean_players),.groups="drop") |> mutate(season="ALL")
  summary <- bind_rows(year_mean |> mutate(season=as.character(season)),composite)
  # Same fantasy-season week window on both sides; NFL means remain per played team-game.
  windows <- bind_rows(coverage) |> select(season,week) |> distinct()
  nw <- readr::read_csv(file.path(out,"weekly.csv"),show_col_types=FALSE) |> semi_join(windows,by=c("season","week"))
  nt <- nw |> group_by(season,team,status,adl_position) |> summarise(mean_players=mean(players),.groups="drop")
  ny <- nt |> group_by(season,status,adl_position) |> summarise(mean_players=mean(mean_players),.groups="drop")
  nc <- ny |> group_by(status,adl_position) |> summarise(mean_players=mean(mean_players),.groups="drop") |> mutate(season="ALL")
  ns <- bind_rows(ny |> mutate(season=as.character(season)),nc)
  comparison <- summary |> rename(adl_mean=mean_players,status=gameday_status) |>
    left_join(ns |> select(season,status,adl_position,nfl_mean=mean_players),by=c("season","status","adl_position"))
  for(name in c("players","weekly","team_year","summary","comparison","coverage")) {
    value<-if(name=="coverage")bind_rows(coverage) else get(name)
    readr::write_csv(value,file.path(out,paste0("adl_",name,if(name=="players") ".csv.gz" else ".csv")))
  }
  readr::write_csv(ns,file.path(out,"nfl_adl_window_summary.csv"))
  readr::write_csv(nt,file.path(out,"nfl_adl_window_team_year.csv"))
  invisible(comparison)
}
