# dashboard_helpers.R
# -------------------
# Helper functions for dashboard HTML generation.

dashboard_css <- function() {
  "
  <style>
    :root {
      --ink: #1f2937;
      --muted: #667085;
      --line: #d0d5dd;
      --panel: #ffffff;
      --page: #f3f5f7;
      --red: #c83a3f;
      --blue: #174ea6;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      color: var(--ink);
      background: var(--page);
    }
    header {
      display: flex;
      align-items: center;
      gap: 1.9rem;
      min-height: 6.4rem;
      padding: 0.65rem 1.5rem;
      background: linear-gradient(90deg, #8b8b8b 0%, #a3a9ae 10%, #c9ced3 28%, #d8dde2 44%, #d8dde2 100%);
      border-bottom: 2px solid var(--red);
      box-shadow: 0 1px 8px rgba(15, 23, 42, 0.06);
    }
    header img {
      width: 5.15rem;
      height: 6.1rem;
      object-fit: contain;
    }
    header h1 {
      margin: 0;
      font-size: clamp(2rem, 4vw, 3rem);
      line-height: 1;
      font-weight: 800;
      letter-spacing: 0;
    }
    main {
      max-width: 1040px;
      margin: 0 auto;
      padding: 2rem 1.25rem;
    }
    .tool-grid {
      display: grid;
      gap: 1rem;
    }
    .tool-card,
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      box-shadow: 0 1px 4px rgba(15, 23, 42, 0.05);
    }
    .tool-card {
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 1rem;
      align-items: center;
      padding: 1.2rem 1.25rem;
    }
    .panel {
      padding: 1.2rem 1.25rem;
      margin-bottom: 1rem;
    }
    h2 {
      margin: 0 0 0.35rem;
      font-size: 1.25rem;
      line-height: 1.2;
    }
    h3 {
      margin: 1rem 0 0.35rem;
      font-size: 1rem;
      line-height: 1.2;
      color: var(--muted);
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    p {
      margin: 0 0 0.75rem;
      color: var(--muted);
      line-height: 1.45;
    }
    p:last-child { margin-bottom: 0; }
    ul {
      margin: 0.35rem 0 0;
      padding-left: 1.25rem;
      color: var(--ink);
      line-height: 1.55;
    }
    a {
      color: var(--blue);
      font-weight: 700;
    }
    .button {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 2.5rem;
      padding: 0 1rem;
      border-radius: 6px;
      background: var(--blue);
      color: #fff;
      text-decoration: none;
      font-weight: 700;
      white-space: nowrap;
    }
    .back-link {
      display: inline-flex;
      margin-bottom: 1rem;
      color: var(--blue);
      text-decoration: none;
      font-weight: 700;
    }
    .stat-row {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 0.8rem;
      margin-bottom: 1rem;
    }
    .stat {
      background: #f8fafc;
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 0.85rem 0.95rem;
    }
    .stat-label {
      display: block;
      color: var(--muted);
      font-size: 0.75rem;
      font-weight: 800;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      margin-bottom: 0.25rem;
    }
    .stat-value {
      color: var(--ink);
      font-size: 1rem;
      font-weight: 700;
    }
    .generated-at {
      color: var(--muted);
      font-weight: 500;
    }
    @media (max-width: 720px) {
      header { gap: 1.25rem; padding: 0.65rem 1rem; }
      header img { width: 4.4rem; height: 5.2rem; }
      .tool-card,
      .stat-row {
        grid-template-columns: 1fr;
      }
      .button {
        width: 100%;
      }
    }
  </style>"
}

dashboard_page <- function(title, body_html) {
  paste0(
    "<!DOCTYPE html>
<html lang='en'>
<head>
  <meta charset='utf-8' />
  <meta name='viewport' content='width=device-width,initial-scale=1' />
  <title>", title, "</title>
  ", dashboard_css(), "
</head>
<body>
  <header>
    <img src='adl-shield.png' alt='ADL shield' />
    <h1>", title, "</h1>
  </header>
  <main>
    ", body_html, "
  </main>
</body>
</html>"
  )
}

tool_card <- function(title, description, href, button = "Open") {
  paste0(
    "<section class='tool-card'>
      <div>
        <h2>", title, "</h2>
        <p>", description, "</p>
      </div>
      <a class='button' href='", href, "'>", button, "</a>
    </section>"
  )
}

back_link <- function() {
  "<a class='back-link' href='index.html'>Back to Commissioner Dashboard</a>"
}

build_archive_links_html <- function(archive_files_public) {
  if (length(archive_files_public) == 0) {
    return("<p>No archived CSV files yet.</p>")
  }

  archive_file_labels <- basename(sub("\\?.*$", "", archive_files_public))
  
  links <- paste0(
    "<li><a href='", archive_files_public, "'>", archive_file_labels, "</a></li>",
    collapse = "\n"
  )
  
  paste0("<ul>\n", links, "\n</ul>")
}

build_archive_links_with_warnings_html <- function(archive_files_public, warnings_by_file = list()) {
  if (length(archive_files_public) == 0) {
    return("<p>No archived CSV files yet.</p>")
  }

  archive_file_labels <- basename(sub("\\?.*$", "", archive_files_public))

  links <- paste0(
    "<li><a href='", archive_files_public, "'>", archive_file_labels, "</a>",
    vapply(archive_file_labels, function(label) {
      warnings <- warnings_by_file[[label]]
      if (is.null(warnings) || length(warnings) == 0) return("")
      paste0(" (Warnings: ", paste(warnings, collapse = "; "), ")")
    }, character(1), USE.NAMES = FALSE),
    "</li>",
    collapse = "\n"
  )

  paste0("<ul>\n", links, "\n</ul>")
}

format_generated_at <- function(generated_at) {
  if (is.null(generated_at) || length(generated_at) == 0 || is.na(generated_at) || !nzchar(generated_at)) {
    return("")
  }

  paste0(" <span class='generated-at'>(generated ", generated_at, ")</span>")
}

build_cap_links_html <- function(archive_files_public, generated_at_by_file = list(), warnings_by_file = list()) {
  if (length(archive_files_public) == 0) {
    return("<p>No archived CSV files yet.</p>")
  }

  archive_file_labels <- basename(sub("\\?.*$", "", archive_files_public))

  links <- paste0(
    "<li><a href='", archive_files_public, "'>", archive_file_labels, "</a>",
    vapply(archive_file_labels, function(label) {
      format_generated_at(generated_at_by_file[[label]])
    }, character(1), USE.NAMES = FALSE),
    vapply(archive_file_labels, function(label) {
      warnings <- warnings_by_file[[label]]
      if (is.null(warnings) || length(warnings) == 0) return("")
      paste0(" (Warnings: ", paste(warnings, collapse = "; "), ")")
    }, character(1), USE.NAMES = FALSE),
    "</li>",
    collapse = "\n"
  )

  paste0("<ul>\n", links, "\n</ul>")
}

build_dashboard_index_html <- function(
  latest_daily_roster_snapshot_public = NA_character_,
  latest_cap_summary_public = NA_character_
) {
  daily_snapshot_text <- if (!is.na(latest_daily_roster_snapshot_public) && nzchar(latest_daily_roster_snapshot_public)) {
    latest_daily_roster_snapshot_label <- basename(sub("\\?.*$", "", latest_daily_roster_snapshot_public))
    paste0(
      "<li><a href='daily-roster-snapshots.html'>Daily roster snapshots</a> ",
      "(latest: <a href='", latest_daily_roster_snapshot_public, "'>",
      latest_daily_roster_snapshot_label,
      "</a>)</li>"
    )
  } else {
    "<li><a href='daily-roster-snapshots.html'>Daily roster snapshots</a></li>"
  }

  cap_accounting_text <- if (!is.na(latest_cap_summary_public) && nzchar(latest_cap_summary_public)) {
    latest_cap_summary_label <- basename(sub("\\?.*$", "", latest_cap_summary_public))
    paste0(
      "<li><a href='salary-cap-accounting.html'>Salary Cap Accounting & Rollover</a> ",
      "(current summary: <a href='", latest_cap_summary_public, "'>",
      latest_cap_summary_label,
      "</a>)</li>"
    )
  } else {
    "<li><a href='salary-cap-accounting.html'>Salary Cap Accounting & Rollover</a></li>"
  }

  dashboard_page(
    "ADL Commissioner Dashboard",
    paste0(
      "<div class='tool-grid'>",
      tool_card(
        "SalAdjCurator",
        "Transaction review output for salary adjustments that need league-office handling.",
        "saladjcurator.html"
      ),
      tool_card(
        "Daily Roster Snapshots",
        if (!is.na(latest_daily_roster_snapshot_public) && nzchar(latest_daily_roster_snapshot_public)) {
          paste0("Roster snapshots with latest capture: ", latest_daily_roster_snapshot_label, ".")
        } else {
          "Roster snapshots captured by dashboard runs."
        },
        "daily-roster-snapshots.html"
      ),
      tool_card(
        "Salary Cap Accounting & Rollover",
        if (!is.na(latest_cap_summary_public) && nzchar(latest_cap_summary_public)) {
          paste0("Current cap summary: ", latest_cap_summary_label, ".")
        } else {
          "Weekly salary-cap summaries and full accounting snapshots."
        },
        "salary-cap-accounting.html"
      ),
      tool_card(
        "GM Dashboard",
        "Player-facing ADL tools, including the live Contract Extension Calculator.",
        "https://themathninja.github.io/ADL-GM-Dashboard/"
      ),
      "</div>"
    )
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
  
  dashboard_page(
    "SalAdjCurator",
    paste0(
      back_link(),
      "<section class='panel'>
        <div class='stat-row'>
          <div class='stat'><span class='stat-label'>Last checked</span><span class='stat-value'>", last_checked, "</span></div>
          <div class='stat'><span class='stat-label'>Latest change</span><span class='stat-value'>", last_changed, "</span></div>
          <div class='stat'><span class='stat-label'>Current qualifying rows</span><span class='stat-value'>", qualifying_rows, "</span></div>
          <div class='stat'><span class='stat-label'>Latest CSV</span><span class='stat-value'><a href='downloads/", run_meta$latest_archive_filename[1], "'>", run_meta$latest_archive_filename[1], "</a></span></div>
        </div>
        <p><strong>Status:</strong> ", changed_text, "</p>
      </section>
      <section class='panel'>
        <h2>SalAdjCurator Archive</h2>
        ", archive_links_html, "
      </section>
      <section class='panel'>
        <h2>Instructions</h2>
        <p>
        For 2026, SalAdjCurator uses manually seeded Contract Admin rows for all present-season entries before May 1, 2026.
        Starting with May 1, 2026 transactions, this dashboard uses the automated ADL transaction scrape.
        </p>
        <p>
        The manual seed is intentional.
        Through the NFL Draft date, April 23, 2026, offseason auction activity such as FT and B/R can create drops that should not be counted as ordinary salary-adjustment drops by the scraper.
        April 24-30, 2026 entries are also seeded from Contract Admin because they occurred before the scrape feed was running reliably.
        </p>
        <p>
        Copy and paste DATE through CONTRACT columns and TR/IB through NOTES columns into the ADL Contract Admin sheet for each conference.
        This dashboard does not track Suspended status ((S) column) or July 1 Tenders (JT column); enter those manually when needed.
        </p>
      </section>"
    )
  )
}

build_cap_accounting_html <- function(
  current_summary_public = NA_character_,
  summary_files_public = character(),
  snapshot_files_public = character(),
  warnings_by_file = list(),
  generated_at_by_file = list()
) {
  current_summary_html <- if (!is.na(current_summary_public) && nzchar(current_summary_public)) {
    current_summary_label <- basename(sub("\\?.*$", "", current_summary_public))
    current_warnings <- warnings_by_file[[current_summary_label]]
    current_warning_html <- if (is.null(current_warnings) || length(current_warnings) == 0) {
      ""
    } else {
      paste0(" (Warnings: ", paste(current_warnings, collapse = "; "), ")")
    }
    paste0(
      "<p><strong>Current Summary:</strong> <a href='", current_summary_public, "'>",
      current_summary_label,
      "</a>",
      format_generated_at(generated_at_by_file[[current_summary_label]]),
      current_warning_html,
      "</p>"
    )
  } else {
    "<p><strong>Current Summary:</strong> Not available yet.</p>"
  }

  summary_links_html <- build_cap_links_html(summary_files_public, generated_at_by_file, warnings_by_file)
  snapshot_links_html <- build_cap_links_html(snapshot_files_public, generated_at_by_file)

  dashboard_page(
    "Salary Cap Accounting & Rollover",
    paste0(
      back_link(),
      "<section class='panel'>", current_summary_html, "</section>
      <section class='panel'>
        <h2>Weekly Snapshots and Summaries Archive</h2>
        <h3>Summaries</h3>
        ", summary_links_html, "
        <h3>Full Snapshots</h3>
        ", snapshot_links_html, "
      </section>"
    )
  )
}

build_daily_roster_snapshots_html <- function(
  snapshot_files_public,
  latest_snapshot_public = NA_character_,
  no_change_check_text = character()
) {
  snapshot_links_html <- build_archive_links_html(snapshot_files_public)
  latest_link_html <- if (!is.na(latest_snapshot_public) && nzchar(latest_snapshot_public)) {
    latest_snapshot_label <- basename(sub("\\?.*$", "", latest_snapshot_public))
    paste0("<p><strong>Latest CSV:</strong> <a href='", latest_snapshot_public, "'>", latest_snapshot_label, "</a></p>")
  } else {
    "<p><strong>Latest CSV:</strong> Not available yet.</p>"
  }

  no_change_html <- if (length(no_change_check_text) == 0) {
    "<p><strong>No-change checks since latest snapshot:</strong> None.</p>"
  } else {
    paste0(
      "<p><strong>No-change checks since latest snapshot:</strong></p>\n<ul>\n",
      paste0("<li>", no_change_check_text, "</li>", collapse = "\n"),
      "\n</ul>"
    )
  }

  dashboard_page(
    "Daily Roster Snapshots",
    paste0(
      back_link(),
      "<section class='panel'>
        <h2>Purpose</h2>
        <p>
        These CSVs are roster snapshots captured by the SalAdjCurator run and published using Eastern time.
        The archive shows the latest capture for each Eastern calendar day.
        They preserve player salary, years, contract info, franchise, conference, and roster status at the time of capture.
        They are intended as supporting salary evidence for commissioner review and are separate from the SalAdj transaction CSVs.
        </p>
      </section>
      <section class='panel'>
        ", latest_link_html, "
        ", no_change_html, "
      </section>
      <section class='panel'>
        <h2>Snapshot Archive</h2>
        ", snapshot_links_html, "
      </section>"
    )
  )
}
