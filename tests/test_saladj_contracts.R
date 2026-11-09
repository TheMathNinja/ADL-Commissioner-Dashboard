source("R/saladj_contracts.R")
x <- c("2023 3.18^", "2023 3.18", "2023 6.01^", "3.XX^", " 2023   3.18^ ",
       "2023 2.18^", "2023 1.18+", "2026 UFA", "2026 iEXT", "2026 5YO", "", NA,
       "2023 3.18^ EXT", "2023 3.18^garbage")
stopifnot(identical(is_ng_rookie_contract(x), c(rep(TRUE, 5), rep(FALSE, 9))))
rows <- data.frame(CONTRACT = x, PLAYER = "Player", `B/R` = "", `TR/IB` = "", check.names = FALSE)
stopifnot(nrow(exclude_ng_rookie_drops(rows)) == 9L)
rows$`B/R`[1] <- "x"; rows$`TR/IB`[2] <- "x"
stopifnot(nrow(exclude_ng_rookie_drops(rows)) == 11L)
stopifnot(normalize_adl_contract("2023 3.18^") != normalize_adl_contract("2023 3.18"))
source("R/cap_accounting_engine.R")
stopifnot(is_rvsd_contract("2023 3.18^"), !is_rvsd_contract("2023 2.18^"))
stopifnot(identical(exclude_ng_rookie_drops(rows), exclude_ng_rookie_drops(exclude_ng_rookie_drops(rows))))
cat("Year-prefixed rookie contracts, PPE, options, tolls and event isolation passed.\n")
