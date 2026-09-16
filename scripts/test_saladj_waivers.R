# Deterministic checks; no network, emails or production data writes.
source("R/saladj_waivers.R")
work <- tempfile("saladj-waiver-tests-"); dir.create(work)
league <- list(id = "60206", name = "ADL Test", baseURL = "https://www46.myfantasyleague.com",
  playerLimitUnit = "CONFERENCE", rostersPerPlayer = "1",
  conferences = list(conference = list(list(id="00", name="NFC"), list(id="01", name="AFC"))),
  divisions = list(division = list(list(id="00", conference="00"), list(id="01", conference="01"))),
  franchises = list(franchise = lapply(1:32, function(i) list(id=sprintf("%04d",i), division=if(i<=16) "00" else "01"))))
row <- function(id, fid, time="Tue Sep 15 11:00:16 a.m. ET 2026") sprintf(
  "<tr><td><a href=\"javascript:launch_player_modal('60206','%s');\">Player</a></td><td>%s</td><td>Waivers After Wed Sep 16 11:00:16 a.m. ET 2026</td><td>%s</td></tr>",
  id, time, if(is.na(fid)) "Added To System" else sprintf('<a class="franchise_%s ">Team</a>',fid))
html <- paste0('<html><title>Fantasy Football: ADL Test Locked Players</title><a href="/2026/home/60206">Home</a><table>',
  '<tr><th><h4>Players With Individual Locks</h4></th></tr><tr><th colspan="5">Locked players in NFC</th></tr>',
  row("14778","0011"), row("15937",NA), '<tr><th colspan="5">Locked players in AFC</th></tr>',
  row("14778","0021"), '</table><footer>Page Generated</footer></html>')
fetch <- function(url,path) {
  if(grepl("TYPE=league",url,fixed=TRUE)) jsonlite::write_json(list(league=league),path,auto_unbox=TRUE) else writeLines(html,path)
  list(url=url,status=200L,captured_at=as.numeric(Sys.time()),md5=unname(tools::md5sum(path)))
}
snap <- saladj_collect_current_waivers(list(league_id="60206"),2026L,work,fetch)
stopifnot(snap$ok, nrow(snap$locks)==3L, !snap$global_lock)
now <- as.POSIXct("2026-09-16 12:00:00",tz="UTC"); snap$checked_at <- as.numeric(now)
drop <- function(id="14778",fid="0011",conf="NFC", time="2026-09-15 15:00:16",pending=FALSE,claim=FALSE) {
  data.frame(row_key=paste(id,fid,time),player_id=id,franchise_id=fid,CONF=conf,
    DATE_raw=as.POSIXct(time,tz="UTC"),waiver_matures_at=now+if(pending) 3600 else -3600,
    waiver_pending=pending,waiver_claim_evidence=claim,SALARY=12.5,CONTRACT="2.XX")
}
run <- function(d,s=snap,t=now) suppressMessages(saladj_apply_current_waivers(d,s,t,2026L))
expect <- function(d,status,s=snap,t=now) {
  z<-run(d,s,t); stopifnot(identical(z$waiver_check_status,status),identical(z$SALARY,d$SALARY),identical(z$CONTRACT,d$CONTRACT)); z
}
# Exact current drop overrides an expired clock, independently for each copy.
z<-expect(rbind(drop(),drop(fid="0021",conf="AFC")),c("pending","pending")); stopifnot(all(z$waiver_pending))
z<-expect(drop("99999"),"not_listed"); stopifnot(!z$waiver_pending, !z$waiver_claim_evidence)
expect(drop("99999",pending=TRUE),"unknown")
expect(drop(fid="0002"),"unknown")
expect(drop(time="2026-09-15 15:00:17"),"unknown")
expect(drop("15937"),"unknown") # A system addition is not a matching drop.
z<-expect(rbind(drop(time="2026-09-01 15:00:16"),drop()),c("historical","pending")); stopifnot(!z$waiver_pending[1])
expect(drop(time="2026-09-14 15:00:16"),"historical") # Later re-drop cannot reopen an earlier event.
failed<-snap; failed$ok<-FALSE
z<-expect(rbind(drop(),drop("99999",claim=TRUE),drop(time="2026-08-01 15:00:16")),c("unknown","historical","historical"),failed)
stopifnot(is.na(z$waiver_pending[1]),!z$waiver_pending[2],!z$waiver_pending[3])
stale<-snap; stale$checked_at<-as.numeric(now)-601; expect(drop(),"unknown",stale)
wrong<-snap; wrong$season<-2025L; expect(drop(),"unknown",wrong)
wrong<-snap; wrong$league_id<-"12345"; expect(drop(),"unknown",wrong)
broken<-snap; broken$receipts<-list(); expect(drop(),"unknown",broken)
global<-snap; global$global_lock<-TRUE; expect(drop("99999"),"unknown",global)
global<-snap; global$global_lock<-TRUE; expect(drop(),"pending",global)
# Repeated Eastern wall time at the DST fall-back must remain ambiguous.
dst<-snap; dst$locks<-dst$locks[1,,drop=FALSE]; dst$locks$drop_time_key<-"2026-11-01 01:30:00"
later<-as.POSIXct("2026-11-02 12:00:00",tz="UTC"); dst$checked_at<-as.numeric(later)
expect(rbind(drop(time="2026-11-01 05:30:00"),drop(time="2026-11-01 06:30:00")),c("unknown","unknown"),dst,later)
# No silent handling of malformed, truncated, wrong-conference or duplicate reports.
parse_bad <- function(text) {
  file<-file.path(work,"bad.html"); writeLines(text,file)
  stopifnot(inherits(try(saladj_parse_individual_locks(file,league,2026,"60206"),silent=TRUE),"try-error"))
}
parse_bad(sub("Page Generated","",html,fixed=TRUE))
parse_bad(sub("/2026/home/60206","/2025/home/60206",html,fixed=TRUE))
parse_bad(sub("franchise_0011","franchise_0021",html,fixed=TRUE))
parse_bad(sub(row("14778","0011"),paste0(row("14778","0011"),row("14778","0011")),html,fixed=TRUE))
parse_bad(sub("Players With Individual Locks","Unexpected Report",html,fixed=TRUE))
stopifnot(inherits(try(saladj_lock_time_key("Yesterday"),silent=TRUE),"try-error"))
stopifnot(saladj_lock_time_key("Tue Sep 15 12:00:00 a.m. ET 2026")=="2026-09-15 00:00:00")
stopifnot(saladj_lock_time_key("Tue Sep 15 12:00:00 p.m. ET 2026")=="2026-09-15 12:00:00")
old<-paste0("Manual; PENDING WAIVER UNTIL ",format(lubridate::with_tz(now,"America/Toronto"),"%m/%d/%Y %I:%M %p %Z"),"; CHECK SALARY")
stopifnot(saladj_waiver_note(old,"pending",now)=="Manual; PENDING WAIVER - STILL LISTED BY MFL; CHECK SALARY")
stopifnot(saladj_waiver_note("CHECK SALARY","unknown",now)=="WAIVER STATUS UNKNOWN - CHECK MFL; CHECK SALARY")
cat("tamper",file=file.path(snap$directory,"locked_players.html"),append=TRUE); expect(drop(),"unknown")
failed_collect<-suppressWarnings(saladj_collect_current_waivers(list(league_id="60206"),2026L,work,function(...) stop("Fixture HTTP failure")))
stopifnot(!failed_collect$ok,file.exists(file.path(failed_collect$directory,"receipt.json")))
cat("SalAdj waiver event, conference, clock, claim-preservation, failure, parser and note checks passed.\n")
