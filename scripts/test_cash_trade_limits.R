source("R/config_helpers.R")
source("R/cash_trade_limits.R")

rows <- tibble::tribble(
  ~CONF, ~FRAN, ~PLAYER, ~SALARY,
  "AFC", "KCC", "Cash Trade", "11.20",
  "AFC", "KCC", "Cash Trade", "7.20",
  "AFC", "KCC", "Cash Trade", "-6.20",
  "NFC", "WAS", "Cash Trade", "-3.65",
  "NFC", "WAS", "Cash Trade", "-8.60",
  "NFC", "ATL", "Cash Trade", "8.55",
  "NFC", "ATL", "Cash Trade", "3.65",
  "NFC", "ATL", "Not Cash", "99.00"
)

summary <- summarize_cash_trade_net(rows)
kcc <- summary[summary$franchise == "KCC", , drop = FALSE]
was <- summary[summary$franchise == "WAS", , drop = FALSE]
stopifnot(kcc$total_given[[1]] == 18.40, kcc$total_acquired[[1]] == 6.20, kcc$net_amount[[1]] == 12.20)
stopifnot(was$net_direction[[1]] == "acquired", was$net_amount[[1]] == 12.25)

violations <- evaluate_cash_trade_limit(rows, season = 2026)
stopifnot(identical(violations$franchise, "WAS"))
stopifnot(violations$overage[[1]] == 0.05)

cat("Cash trade limit checks passed.\n")
