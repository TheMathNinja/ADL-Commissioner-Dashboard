# Public, read-only historical MFL exports. Cache every response for reproducibility.
out <- "data/nfl_realism/adl_history"
dir.create(out, recursive = TRUE, showWarnings = FALSE)
fetch <- function(year, type, week = NULL) {
  suffix <- if (is.null(week)) "" else sprintf("_week%02d", week)
  path <- file.path(out, sprintf("%d_%s%s.json", year, type, suffix))
  if (file.exists(path)) return(jsonlite::fromJSON(path))
  base <- if(type=="league") "https://api.myfantasyleague.com" else jsonlite::fromJSON(file.path(out,sprintf("%d_league.json",year)))$league$baseURL
  url <- sprintf("%s/%d/export?TYPE=%s&L=60206&JSON=1%s", base, year, type,
    if (is.null(week)) "" else paste0("&W=", week))
  for (attempt in 1:3) {
    answer <- tryCatch({curl::curl_download(url, path); jsonlite::fromJSON(path)}, error = function(e) NULL)
    if (!is.null(answer) && !"error" %in% names(answer)) break
    if (file.exists(path)) unlink(path)
    Sys.sleep(3)
  }
  if (is.null(answer) || "error" %in% names(answer)) {
    if(type=="injuries" && year<=2024) {
      answer<-list(injuries=list(week=as.character(week),retrieval_error="MFL historical export unavailable; use archived NFL injury report"))
      jsonlite::write_json(answer,path,auto_unbox=TRUE)
    } else stop("Unavailable historical export: ", url)
  }
  Sys.sleep(2)
  answer
}
for (year in 2021:2025) {
  league <- fetch(year, "league")$league
  if (!grepl("Analytics Dynasty", league$name, fixed = TRUE)) stop("Unexpected league identity.")
  weeks <- seq.int(as.integer(league$startWeek), as.integer(league$endWeek))
  for (week in weeks) {
    roster <- fetch(year, "rosters", week)
    injury <- fetch(year, "injuries", week)
    if (is.null(roster$rosters$franchise) || is.null(injury$injuries)) stop("Incomplete weekly payload.")
    message("Cached ADL ", year, " week ", week)
  }
}
jsonlite::write_json(list(captured_at_utc=format(Sys.time(),"%Y-%m-%dT%H:%M:%SZ",tz="UTC"),
  league_id="60206",rosters="MFL rosters W=week",designations="MFL injuries W=week"),
  file.path(out,"retrieval_manifest.json"),auto_unbox=TRUE,pretty=TRUE)
