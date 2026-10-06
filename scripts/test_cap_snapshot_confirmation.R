metadata_path <- tempfile(fileext = ".csv")
preview_path <- tempfile(fileext = ".txt")
readr::write_csv(
  tibble::tibble(
    season = 2026L,
    week = 3L,
    snapshot_taken_at_utc = "2026-09-29 09:49:55",
    snapshot_taken_at_et = "2026-09-29 05:49:55 EDT",
    completed_at_utc = "2026-09-29 09:50:08",
    workflow_run_url = "https://github.com/example/actions/runs/123"
  ),
  metadata_path
)
Sys.setenv(
  CURRENT_SEASON = "2026",
  SNAPSHOT_WEEK = "3",
  ADL_CAP_SNAPSHOT_METADATA_PATH = metadata_path,
  ADL_CAP_SNAPSHOT_PREVIEW_PATH = preview_path,
  ADL_CAP_SNAPSHOT_SEND_EMAIL = "false",
  ADL_CAP_SNAPSHOT_SHEET_STATUS = "updated successfully",
  ADL_WEEKLY_UPDATE_URL = "https://github.com/example/adl/actions/runs/456"
)
source("scripts/send_cap_snapshot_confirmation.R")
body <- paste(readLines(preview_path, warn = FALSE), collapse = "\n")
stopifnot(
  grepl("official Week 3 salary cap snapshot completed successfully", body, fixed = TRUE),
  grepl("Tuesday, Sep 29, 2026 at 05:49:55 AM ET", body, fixed = TRUE),
  grepl("Contract Admin Cap Rollover tab: updated successfully", body, fixed = TRUE),
  grepl(
    "View the Week 3 weekly update process here: https://github.com/example/adl/actions/runs/456",
    body,
    fixed = TRUE
  )
)
cat("Cap snapshot confirmation email checks passed.\n")
