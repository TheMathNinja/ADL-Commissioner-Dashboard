if (!exists("%||%", mode = "function")) {
  `%||%` <- function(x, y) if (is.null(x) || !length(x) || all(is.na(x))) y else x
}

format_saladj_digest_amount <- function(x) {
  x_chr <- trimws(as.character(x %||% ""))
  if (!nzchar(x_chr)) return("")
  x_num <- suppressWarnings(as.numeric(gsub("[$,]", "", x_chr)))
  if (is.na(x_num)) return(x_chr)
  paste0("$", formatC(x_num, format = "f", digits = 2))
}

saladj_row_value <- function(row, name) {
  if (!name %in% names(row) || !length(row[[name]])) return("")
  as.character(row[[name]][[1]] %||% "")
}

format_saladj_digest_row <- function(row) {
  player <- saladj_row_value(row, "PLAYER")
  team <- saladj_row_value(row, "PLAYER_TEAM")
  pos <- saladj_row_value(row, "PLAYER_POS")
  fran <- saladj_row_value(row, "FRAN")
  date <- saladj_row_value(row, "DATE")
  salary <- format_saladj_digest_amount(saladj_row_value(row, "SALARY"))
  years <- saladj_row_value(row, "YEARS")
  contract <- saladj_row_value(row, "CONTRACT")
  notes <- saladj_row_value(row, "NOTES")
  rvsd <- saladj_row_value(row, "RVSD?")

  player_display <- paste(c(player, team, pos)[nzchar(c(player, team, pos))], collapse = " ")
  contract_details <- c(
    salary,
    if (nzchar(years)) paste0(years, " yr") else NULL,
    if (nzchar(contract)) contract else NULL
  )
  trailing_details <- c(
    if (nzchar(notes)) paste0("Notes: ", notes) else NULL,
    if (nzchar(rvsd)) paste0("RVSD?: ", rvsd) else NULL
  )

  paste0(
    "- Dropped ", date, " ET by ", fran, " | ", player_display,
    if (length(contract_details)) paste0(": ", paste(contract_details, collapse = " / ")) else "",
    if (length(trailing_details)) paste0("\n  ", paste(trailing_details, collapse = "\n  ")) else ""
  )
}

parse_saladj_workflow_time <- function(value, tz = "UTC") {
  if (!nzchar(value)) return(as.POSIXct(NA, tz = tz))
  if (grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", value)) {
    return(suppressWarnings(as.POSIXct(value, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")))
  }
  suppressWarnings(as.POSIXct(value, tz = tz))
}

saladj_public_csv_url <- function(archive_filename) {
  filename <- basename(as.character(archive_filename %||% ""))
  if (!nzchar(filename)) return("")
  paste0(
    "https://themathninja.github.io/ADL-Commissioner-Dashboard/downloads/",
    utils::URLencode(filename, reserved = TRUE)
  )
}

render_saladj_run_audit <- function(run_audit = list()) {
  scheduled <- as.character(run_audit$scheduled_display %||% "")
  started <- as.character(run_audit$started_display %||% "")
  completed <- as.character(run_audit$completed_display %||% "")
  duration <- as.character(run_audit$duration_display %||% "")
  trigger <- as.character(run_audit$trigger %||% "")
  trigger_label <- switch(
    trigger,
    push = "Transaction-triggered refresh",
    schedule = "Scheduled daily refresh",
    workflow_dispatch = "Manually triggered refresh",
    trigger
  )

  if (!nzchar(scheduled) && !nzchar(started) && !nzchar(duration)) return(character())

  c(
    if (nzchar(scheduled)) paste0("SalAdj scraper scheduled: ", scheduled) else NULL,
    if (nzchar(trigger_label)) paste0("Run type: ", trigger_label) else NULL,
    if (nzchar(started)) {
      paste0("Run started: ", started)
    } else {
      NULL
    },
    if (nzchar(completed)) paste0(
      "Run completed / email prepared: ", completed,
      if (nzchar(duration)) paste0(" (runtime: ", duration, ")") else ""
    ) else NULL,
    ""
  )
}

render_saladj_email <- function(new_rows, archive_filename, run_time_display, run_audit = list()) {
  if (!nrow(new_rows)) {
    return("No new SalAdj rows were found.")
  }

  groups <- split(new_rows, new_rows$CONF)
  conference_order <- c("NFC", "AFC")
  groups <- groups[c(intersect(conference_order, names(groups)), setdiff(names(groups), conference_order))]

  lines <- c(
    render_saladj_run_audit(run_audit),
    paste0("SalAdj Curator published ", nrow(new_rows), " new row(s) at ", run_time_display, "."),
    paste0("Dashboard CSV here: ", saladj_public_csv_url(archive_filename)),
    "",
    "Please enter the following new salary adjustments in the Contract Admin sheet.",
    ""
  )

  for (conf in names(groups)) {
    rows <- groups[[conf]]
    lines <- c(lines, conf, strrep("-", nchar(conf)))
    for (i in seq_len(nrow(rows))) {
      lines <- c(lines, format_saladj_digest_row(rows[i, , drop = FALSE]))
    }
    lines <- c(lines, "")
  }

  body <- paste(lines, collapse = "\n")
  gsub(
    "(SalAdj Curator published[^\n]*\\.)\n+Dashboard CSV here:",
    "\\1\nDashboard CSV here:",
    body,
    perl = TRUE
  )
}

saladj_html_escape <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  gsub('"', "&quot;", x, fixed = TRUE)
}

render_saladj_email_html <- function(body, archive_filename) {
  url <- saladj_public_csv_url(archive_filename)
  escaped <- saladj_html_escape(body)
  csv_line <- saladj_html_escape(paste0("Dashboard CSV here: ", url))
  csv_link <- paste0('<a href="', saladj_html_escape(url), '">Dashboard CSV here</a>')
  escaped <- sub(csv_line, csv_link, escaped, fixed = TRUE)
  paste0(
    '<div style="white-space:pre-wrap;font-family:Arial,sans-serif;font-size:14px;line-height:1.45">',
    escaped,
    "</div>"
  )
}
