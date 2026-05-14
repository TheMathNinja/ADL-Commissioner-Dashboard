# dashboard_helpers.R
# -------------------
# Helper functions for dashboard HTML generation.

build_archive_links_html <- function(archive_files_public) {
  if (length(archive_files_public) == 0) {
    return("<p>No archived CSV files yet.</p>")
  }
  
  links <- paste0(
    "<li><a href='", archive_files_public, "'>", basename(archive_files_public), "</a></li>",
    collapse = "\n"
  )
  
  paste0("<ul>\n", links, "\n</ul>")
}

build_dashboard_index_html <- function(latest_daily_salary_snapshot_public = NA_character_) {
  daily_snapshot_text <- if (!is.na(latest_daily_salary_snapshot_public) && nzchar(latest_daily_salary_snapshot_public)) {
    paste0(
      "<li><a href='daily-salary-snapshots.html'>Daily salary snapshots</a> ",
      "(latest: <a href='", latest_daily_salary_snapshot_public, "'>",
      basename(latest_daily_salary_snapshot_public),
      "</a>)</li>"
    )
  } else {
    "<li><a href='daily-salary-snapshots.html'>Daily salary snapshots</a></li>"
  }

  paste0(
    "<html>
<head>
  <title>ADL Commissioner Dashboard</title>
</head>
<body>
  <h1>ADL Commissioner Dashboard</h1>

  <ul>
    <li><a href='saladjcurator.html'>SalAdjCurator</a></li>
    ", daily_snapshot_text, "
  </ul>
</body>
</html>"
  )
}

build_saladjcurator_html <- function(run_meta, archive_files_public) {
  archive_links_html <- build_archive_links_html(archive_files_public)
  last_checked <- if ("last_checked_display" %in% names(run_meta)) run_meta$last_checked_display[1] else run_meta$run_time_display[1]
  last_changed <- if ("last_changed_display" %in% names(run_meta)) run_meta$last_changed_display[1] else run_meta$run_time_display[1]
  changed_text <- if ("latest_csv_changed" %in% names(run_meta) && !is.na(run_meta$latest_csv_changed[1]) && isFALSE(run_meta$latest_csv_changed[1])) {
    "No new actionable CSV was archived on the most recent check."
  } else {
    "A new actionable CSV was archived on the most recent check."
  }
  qualifying_rows <- if ("qualifying_rows" %in% names(run_meta)) run_meta$qualifying_rows[1] else NA_integer_
  
  paste0(
    "<html>
<head>
  <title>ADL Commissioner Dashboard - SalAdjCurator</title>
</head>
<body>
  <h1>SalAdjCurator</h1>

  <p><a href='index.html'>Back to Commissioner Dashboard</a></p>

  <p><strong>Last checked:</strong> ", last_checked, "</p>

  <p><strong>Latest change:</strong> ", last_changed, "</p>

  <p><strong>Current qualifying rows:</strong> ", qualifying_rows, "</p>

  <p><strong>Status:</strong> ", changed_text, "</p>

  <p><strong>Latest CSV:</strong> <a href='downloads/", run_meta$latest_archive_filename[1], "'>", run_meta$latest_archive_filename[1], "</a></p>

  <h2>SalAdjCurator Archive</h2>
  ", archive_links_html, "

  <h2>Instructions</h2>
  <p>
  This script scrapes ADL transactions after the NFL draft to avoid complications from early offseason auctions.
  Enter cap adjustments manually before that time.
  Copy and paste DATE through CONTRACT columns and TR/IB through NOTES columns into ADL Contract Admin sheet for each conference.
  This sheet does not track Suspended status ((S) column) or July 1 Tenders (JT column).
  Enter that data manually.
  </p>
</body>
</html>"
  )
}

build_daily_salary_snapshots_html <- function(snapshot_files_public, latest_snapshot_public = NA_character_) {
  snapshot_links_html <- build_archive_links_html(snapshot_files_public)
  latest_link_html <- if (!is.na(latest_snapshot_public) && nzchar(latest_snapshot_public)) {
    paste0("<p><strong>Latest CSV:</strong> <a href='", latest_snapshot_public, "'>", basename(latest_snapshot_public), "</a></p>")
  } else {
    "<p><strong>Latest CSV:</strong> Not available yet.</p>"
  }

  paste0(
    "<html>
<head>
  <title>ADL Commissioner Dashboard - Daily Salary Snapshots</title>
</head>
<body>
  <h1>Daily Salary Snapshots</h1>

  <p><a href='index.html'>Back to Commissioner Dashboard</a></p>

  ", latest_link_html, "

  <h2>Snapshot Archive</h2>
  ", snapshot_links_html, "

  <h2>Notes</h2>
  <p>
  These CSVs are roster salary snapshots captured by the SalAdjCurator run and published using Eastern time.
  The archive shows the latest capture for each Eastern calendar day.
  They preserve player salary, years, contract info, franchise, conference, and roster status at the time of capture.
  They are intended as supporting salary evidence for commissioner review and are separate from the SalAdj transaction CSVs.
  </p>
</body>
</html>"
  )
}
