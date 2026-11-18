capture_env <- new.env(parent = globalenv())
sys.source("R/roster_source.R", envir = capture_env)
capture_calls <- 0L
capture_clock <- 1000
capture_env$Sys.time <- function() as.POSIXct(capture_clock, origin = "1970-01-01", tz = "UTC")
capture_env$get_env_or_default <- function(name, default = "") default
capture_env$fetch_live_rosters <- function(...) {
  capture_calls <<- capture_calls + 1L
  data.frame(marker = capture_calls)
}
capture_env$write_roster_cache <- function(...) NULL
capture_env$read_snapshot_rosters <- function(...) data.frame(marker = -1L)
capture_path <- file.path(tempdir(), "coherent-alert-capture", "rosters.csv")
load_capture <- function(...) capture_env$load_current_rosters(
  season = 2026, force_live = TRUE, cache_path = capture_path, ...)
old_capture_option <- getOption("adl_alert_run_rosters")
options(adl_alert_run_rosters = new.env(parent = emptyenv()))
first_capture <- load_capture(source = "live")
stopifnot(identical(first_capture, load_capture(source = "auto")), capture_calls == 1L)
load_capture(source = "live", week = 10L); stopifnot(capture_calls == 2L)
capture_clock <- 1300
stopifnot(!identical(first_capture, load_capture(source = "live")), capture_calls == 3L)
options(adl_alert_run_rosters = new.env(parent = emptyenv()))
load_capture(source = "live"); stopifnot(capture_calls == 4L)
capture_env$fetch_live_rosters <- function(...) stop("simulated MFL failure")
options(adl_alert_run_rosters = new.env(parent = emptyenv()))
stopifnot(inherits(try(load_capture(source = "live"), silent = TRUE), "try-error"))
stopifnot(load_capture(source = "auto")$marker == -1L,
  length(ls(getOption("adl_alert_run_rosters"))) == 0L)
capture_env$fetch_live_rosters <- function(...) {
  capture_calls <<- capture_calls + 1L
  data.frame(marker = capture_calls)
}
stopifnot(load_capture(source = "live")$marker == 5L)
options(adl_alert_run_rosters = NULL)
load_capture(source = "live"); load_capture(source = "live")
stopifnot(capture_calls == 7L)
options(adl_alert_run_rosters = old_capture_option)
cat("PASS: successful same-run roster capture reuse, week isolation, five-minute expiry, new-run freshness, failure visibility and no cached fallback promotion.\n")
