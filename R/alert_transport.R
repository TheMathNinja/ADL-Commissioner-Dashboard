deliver_alert <- function(subject, body, to, cc = character(), html_body = NULL, delivery_key = NULL, lineup_payload = NULL) {
  path <- tempfile(fileext = ".json")
  on.exit(unlink(path), add = TRUE)
  payload <- list(subject = subject, body = body, to = as.list(to), cc = as.list(cc), html = html_body)
  if (!is.null(delivery_key)) payload$delivery_key <- delivery_key
  if (!is.null(lineup_payload)) payload <- c(payload, lineup_payload)
  jsonlite::write_json(payload, path,
                       auto_unbox = TRUE, null = "null")
  result <- system2("python3", c("scripts/send_plain_email.py", "--payload", shQuote(path)))
  if (result != 0L) stop("Mail delivery not confirmed; review before retrying.", call. = FALSE)
}
