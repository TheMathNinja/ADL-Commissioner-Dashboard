# ADL cap amounts are in millions. Keep this helper identical in both ADL repositories.
round_cap_money <- function(x, digits = 2L) {
  value <- as.numeric(x)
  scale <- 10^digits
  scaled <- abs(value) * scale
  whole <- floor(scaled)
  # Match Sheets ROUND at decimal ties despite binary arithmetic noise.
  slack <- 2 * .Machine$double.eps * pmax(1, scaled)
  sign(value) * (whole + (scaled - whole >= 0.5 - slack)) / scale
}
