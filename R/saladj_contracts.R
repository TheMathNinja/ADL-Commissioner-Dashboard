# Preserve punctuation: ^ is PPE, + is a fifth-year option, * is a toll.
normalize_adl_contract <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  toupper(trimws(gsub("\\s+", " ", x)))
}

adl_rookie_round <- function(x) {
  m <- stringr::str_match(normalize_adl_contract(x),
    "^(?:[0-9]{4} )?([1-6])\\.(?:[0-9]{2}|XX)(?:\\^)?(?:\\+)?(?:\\*)?$")
  suppressWarnings(as.integer(m[, 2]))
}

is_ng_rookie_contract <- function(x) {
  round <- adl_rookie_round(x)
  !is.na(round) & round >= 3L
}

exclude_ng_rookie_drops <- function(rows) {
  if (!nrow(rows)) return(rows)
  marked <- function(name) {
    if (!name %in% names(rows)) return(rep(FALSE, nrow(rows)))
    toupper(trimws(as.character(rows[[name]]))) %in% c("X", "TRUE", "YES", "1")
  }
  # B/R and trade/IB adjustments are distinct events, not rookie release penalties.
  excluded <- is_ng_rookie_contract(rows$CONTRACT) & !marked("B/R") & !marked("TR/IB") &
    toupper(trimws(rows$PLAYER)) != "CASH TRADE"
  rows[!excluded, , drop = FALSE]
}
