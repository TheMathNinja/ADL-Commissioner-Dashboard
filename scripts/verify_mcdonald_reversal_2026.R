# Read-only verification of the historical repair; no external service writes.
source("R/saladj_contracts.R")
for (path in c("data/SalAdjCurator_2026.csv", "data/SalAdjCurator_latest.csv",
               "docs/downloads/2026_11_09_ADLSalAdjCurator.csv")) {
  rows <- read.csv(path, check.names = FALSE)
  stopifnot(!any(rows$FRAN == "PHI" & rows$PLAYER == "Will McDonald" &
    rows$CONTRACT == "2023 3.18^"))
}
cache <- readRDS("data/saladj_qualified_2026.rds")
stopifnot(nrow(cache) == nrow(exclude_ng_rookie_drops(cache)))
for (path in c("data/cap_accounting/2026/summaries/2026w8_ADLsalarycapsummary.csv",
               "docs/downloads/salary-cap-accounting/summaries/2026w8_ADLsalarycapsummary.csv")) {
  rows <- read.csv(path, check.names = FALSE)
  stopifnot(rows$W8_Corr[rows$FRANCHISE == "PHI"] == 0)
}
ledger <- read.csv("data/cap_accounting/2026/manual_cap_corrections.csv")
stopifnot(sum(ledger$amount[ledger$week == 8 & ledger$franchise == "PHI"]) == 0)
cat("PHI Week 8 CORR net zero; current CSV, public CSV and reusable cache exclude NG McDonald drop.\n")
