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
  
  paste0(
    "<html>
<head>
  <title>ADL Commissioner Dashboard - SalAdjCurator</title>
</head>
<body>
  <h1>SalAdjCurator</h1>

  <p><a href='index.html'>Back to Commissioner Dashboard</a></p>

  <p><strong>Script last run:</strong> ", run_meta$run_time_display[1], "</p>

  <p><strong>Latest CSV:</strong> <a href='downloads/", run_meta$latest_archive_filename[1], "'>", run_meta$latest_archive_filename[1], "</a> (script generated: ", run_meta$run_time_display[1], ")</p>

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