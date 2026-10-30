source("R/commissioner_alerts.R")

old_digest <- Sys.getenv("ADL_ALERT_DIGEST_FRANCHISES", unset = NA_character_)
old_extra <- Sys.getenv("ADL_ALERT_DIGEST_EXTRA_EMAILS", unset = NA_character_)
on.exit({
  if (is.na(old_digest)) Sys.unsetenv("ADL_ALERT_DIGEST_FRANCHISES") else Sys.setenv(ADL_ALERT_DIGEST_FRANCHISES = old_digest)
  if (is.na(old_extra)) Sys.unsetenv("ADL_ALERT_DIGEST_EXTRA_EMAILS") else Sys.setenv(ADL_ALERT_DIGEST_EXTRA_EMAILS = old_extra)
}, add = TRUE)

Sys.setenv(
  ADL_ALERT_DIGEST_FRANCHISES = "CHI,KCC,IND,SEA",
  ADL_ALERT_DIGEST_EXTRA_EMAILS = ""
)

directory <- tibble::tibble(
  franchise = c("CHI", "KCC", "IND", "SEA", "LAR"),
  franchise_name = c("Chicago", "Kansas City", "Indianapolis", "Seattle", "Los Angeles"),
  email = paste0(tolower(c("CHI", "KCC", "IND", "SEA", "LAR")), "@example.com"),
  source = "fixture"
)

digest <- resolve_commissioner_alert_recipients(2026, mfl_recipients = directory)
stopifnot(nrow(digest) == 4L)
stopifnot(setequal(digest$franchise, c("CHI", "KCC", "IND", "SEA")))

send_body <- paste(deparse(body(send_commissioner_alert_email)), collapse = "\n")
fetch_calls <- gregexpr("fetch_mfl_franchise_recipients\\(", send_body, perl = TRUE)[[1]]
stopifnot(sum(fetch_calls > 0) == 1L)

shared <- normalize_mfl_franchise_email_rows(tibble::tibble(
  id = c("0005", "0030", "0030"),
  name = c("Chicago Bears", "Kansas City Chiefs", "Kansas City Chiefs"),
  abbrev = c("CHI", "KCC", "KCC"),
  email = rep("shared@example.com", 3)
))
stopifnot(nrow(shared) == 2L, setequal(shared$franchise, c("CHI", "KCC")))
stopifnot(nrow(dplyr::filter(shared, .data$franchise == "KCC")) == 1L)

cat("Commissioner recipient-directory regression test passed.\n")
