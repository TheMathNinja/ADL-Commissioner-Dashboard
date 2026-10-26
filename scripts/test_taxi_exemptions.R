source("R/cap_accounting_engine.R")
stopifnot(identical(cap_is_taxi_exempt_status(c("S","(S)","Suspended","H","(H)","Holdout","IR","Out",NA)),c(rep(TRUE,6),rep(FALSE,3))))
lookup <- data.frame(franchise_id="0001",FRANCHISE="TEST")
x <- data.frame(franchise_id="0001",roster_status=c(rep("ACTIVE_ROSTER",44),"TAXI_SQUAD","TAXI_SQUAD","INJURED_RESERVE"),inj=c(rep("",44),"Holdout","Suspended","Holdout"),contract_years=2,salary=2)
r <- cap_summarise_roster(x,lookup,1.1)
stopifnot(r$TE==0,r$S==3,r$Yrs==88,r$Paid==45,r$RostSal==90,r[["Vac$"]]==0,r[["Ill?"]]=="")
x <- x[-nrow(x),];r <- cap_summarise_roster(x,lookup,1.1)
stopifnot(r$Paid==44,r$RostSal==88,r[["Vac$"]]==1.1)
# Historical audit: every stored week reconciles for all 32 teams.
for(w in 1:6) {
 base <- "data/cap_accounting/2026"
 old <- readRDS(file.path(base,"summaries",paste0("2026w",w,"_ADLsalarycapsummary.rds")))
 for(j in 1:w) {
  snap <- readRDS(file.path(base,"snapshots",paste0("2026w",j,"_ADLsalarycapsnapshot.rds")))
  r <- cap_summarise_roster(snap,old[,c("franchise_id","FRANCHISE")],1.1)
  r <- r[match(old$franchise_id,r$franchise_id),]
  for(field in c("A","IR","S","TE","Yrs","Ill?","Paid","Vac$","RostSal")) stopifnot(isTRUE(all.equal(as.character(old[[paste0("W",j,"_",field)]]),as.character(round_if_numeric <- if(is.numeric(r[[field]])) round(r[[field]],2) else r[[field]]))))
 }
}
latest <- readRDS("data/cap_accounting/2026/summaries/2026w6_ADLsalarycapsummary.rds")
bal <- latest[latest$FRANCHISE=="BAL",]
stopifnot(bal[["W2_Ill?"]]=="Y",bal[["W5_Ill?"]]=="",bal[["W6_Ill?"]]=="",bal$W6_RostSal==226.33)
cat("PASS: S/H equivalence, paid IR, vacancy reserves, all stored weekly summaries and BAL correction.\n")

# Exercise the Commissioner live-expenditure path without external services.
expr <- parse("R/commissioner_alerts.R")
for(e in expr) if(is.call(e) && identical(e[[1]],as.name("<-")) && as.character(e[[2]]) %in% c("normalize_alert_status","current_cap_accounting_expenditure","commissioner_salary_cap")) eval(e)
rows <- data.frame(conference="AFC",franchise="TEST",franchise_name="Test",roster_status=c("Taxi","Taxi","Active","Injured reserve"),player_status=c("Holdout","Suspended","Holdout","Holdout"),prev_salary=c(2.38,2,3,4),franchise_salary_cap=244)
stopifnot(current_cap_accounting_expenditure(rows)$live_salary==7)
cat("PASS: Commissioner live spending excludes taxi S/H, retains active/IR salaries.\n")
