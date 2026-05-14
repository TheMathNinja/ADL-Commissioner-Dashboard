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

build_dashboard_index_html <- function() {
  paste0(
    "<html>
<head>
  <title>ADL Commissioner Dashboard</title>
</head>
<body>
  <h1>ADL Commissioner Dashboard</h1>

  <ul>
    <li><a href='saladjcurator.html'>SalAdjCurator</a></li>
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