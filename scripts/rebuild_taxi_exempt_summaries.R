# Rebuild derived history from stored, immutable weekly roster snapshots.
# Does not recapture MFL, change SalAdj transactions, or send notifications.
source("R/cap_accounting_engine.R")
season <- get_current_season()
base <- file.path("data","cap_accounting",season)
files <- list.files(file.path(base,"summaries"),pattern="salarycapsummary[.]rds$",full.names=TRUE)
stopifnot(length(files)>0)
changes <- list()
for(file in files) {
  summary_week <- as.integer(sub(".*w([0-9]+)_.*","\\1",basename(file)))
  original <- readRDS(file)
  out <- original
  lookup <- original[,c("franchise_id","FRANCHISE")]
  for(week in seq_len(summary_week)) {
    snapshot <- readRDS(file.path(base,"snapshots",paste0(season,"w",week,"_ADLsalarycapsnapshot.rds")))
    rebuilt <- cap_summarise_roster(snapshot,lookup,get_cap_veteran_min(season))
    rebuilt <- rebuilt[match(out$franchise_id,rebuilt$franchise_id),]
    stopifnot(nrow(rebuilt)==32,!anyNA(rebuilt$franchise_id))
    for(field in c("A","IR","S","TE","Yrs","Ill?","Paid","Vac$","RostSal")) {
      col <- paste0("W",week,"_",field)
      old <- out[[col]];new <- rebuilt[[field]]
      if(is.numeric(new)) new <- round(new,2)
      changed <- which(ifelse(is.na(old),!is.na(new),ifelse(is.na(new),TRUE,as.character(old)!=as.character(new))))
      if(length(changed)) changes[[length(changes)+1]] <- data.frame(summary_week,week,franchise=out$FRANCHISE[changed],field,old=as.character(old[changed]),new=as.character(new[changed]))
      out[[col]] <- new
    }
    # Preserve stored corrections; recompute a stored Final only when it exists.
    final_col <- paste0("W",week,"_Final")
    populated <- !is.na(out[[final_col]])
    if(any(populated)) out[[final_col]][populated] <- round(rowSums(out[populated,paste0("W",week,"_",c("Vac$","RostSal","Adj","Corr"))],na.rm=TRUE),2)
  }
  # Monetary corrections and official adjustment ledgers must remain unchanged.
  preserved <- grep("_(Adj|Corr)$",names(out),value=TRUE)
  stopifnot(identical(original[preserved],out[preserved]))
  if(!identical(original,out)) {
    saveRDS(out,file)
    csv <- out |> select(-franchise_id)
    money <- grep("_(Vac[$]|RostSal|Adj|Corr|Final)$",names(csv),value=TRUE)
    csv <- csv |> mutate(across(all_of(money),format_summary_dollars))
    readr::write_csv(csv,sub("[.]rds$",".csv",file),na="")
    dest <- file.path("docs","downloads","salary-cap-accounting","summaries",basename(sub("[.]rds$",".csv",file)))
    dir.create(dirname(dest),recursive=TRUE,showWarnings=FALSE)
    file.copy(sub("[.]rds$",".csv",file),dest,overwrite=TRUE)
  }
}
audit <- bind_rows(changes)
dir.create(file.path(base,"corrections"),showWarnings=FALSE)
if(nrow(audit)) {
 readr::write_csv(audit,file.path(base,"corrections","taxi_holdout_recalculation.csv"),na="")
 print(audit |> filter(summary_week==max(summary_week)))
} else message("All derived summaries already match stored snapshots.")
