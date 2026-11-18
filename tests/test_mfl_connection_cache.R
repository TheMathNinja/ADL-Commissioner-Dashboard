connection_env <- new.env(parent = globalenv())
sys.source("R/mfl_helpers.R", envir = connection_env)
calls <- 0L
create <- function(...) { calls <<- calls + 1L; list(marker = calls) }
clock <- 1000
now <- function() clock
args <- list(season = 2026, league_id = 60206, user_agent = "offline-test",
  rate_limit_number = 1, rate_limit_seconds = 6, user_name = "fixture", password = "fixture")
get_connection <- function(config = args, factory = create) connection_env$cached_adl_mfl_connection(config, create = factory, now = now)
first <- get_connection()
stopifnot(identical(first, get_connection()), calls == 1L)
sys.source("R/mfl_helpers.R", envir = connection_env)
sys.source("R/roster_source.R", envir = connection_env)
stopifnot(identical(first, get_connection()), calls == 1L)
clock <- 2799
stopifnot(identical(first, get_connection()), calls == 1L)
clock <- 2800
stopifnot(!identical(first, get_connection()), calls == 2L)
clock <- 999
get_connection(); stopifnot(calls == 3L)
for (field in c("season", "league_id", "user_agent", "user_name", "password", "rate_limit_seconds")) {
  changed <- args
  changed[[field]] <- if (is.numeric(changed[[field]])) changed[[field]] + 1 else paste0(changed[[field]], "-changed")
  before <- calls
  get_connection(changed); get_connection(changed)
  stopifnot(calls == before + 1L)
}
failed <- args; failed$league_id <- 99999
stopifnot(inherits(try(get_connection(failed, function(...) stop("simulated login error")), silent = TRUE), "try-error"))
before <- calls
get_connection(failed); stopifnot(calls == before + 1L)
stopifnot(all(grepl("^[a-f0-9]{64}$", ls(connection_env$.adl_mfl_connection_cache))))
connection_env$get_env_or_default <- function(name, default = "") default
connection_env$cached_adl_mfl_connection <- function(args) { production_args <<- args; list(marker = 0L) }
connection_env$connect_adl_mfl(2026L)
stopifnot(production_args$rate_limit_number == 1, production_args$rate_limit_seconds == 6)
cat("PASS: one connection/limiter per config across callers, bounded cookie lifetime, credential/season isolation, failed-login recovery and opaque in-memory cache keys.\n")
