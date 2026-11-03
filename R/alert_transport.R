deliver_alert <- function(subject, body, to, cc = character(), html_body = NULL) {
  path <- tempfile(fileext = ".json")
  on.exit(unlink(path), add = TRUE)
  jsonlite::write_json(list(subject = subject, body = body, to = as.list(to),
                            cc = as.list(cc), html = html_body), path,
                       auto_unbox = TRUE, null = "null")
  result <- system2("python3", c("scripts/send_plain_email.py", "--payload", shQuote(path)))
  if (result != 0L) stop("Mail delivery not confirmed; review before retrying.", call. = FALSE)
}
