# cache_helpers.R
# ---------------
# Helpers for reading/writing cached raw league data.

library(tidyverse)

get_raw_cache_dir <- function() {
  raw_cache_dir <- Sys.getenv("RAW_CACHE_DIR", unset = "cache/raw_league_data")
  dir.create(raw_cache_dir, recursive = TRUE, showWarnings = FALSE)
  raw_cache_dir
}

build_raw_cache_file <- function(filename) {
  file.path(get_raw_cache_dir(), filename)
}

read_or_build_rds <- function(filename, builder_fun, refresh = FALSE, verbose = TRUE) {
  cache_file <- build_raw_cache_file(filename)
  
  if (file.exists(cache_file) && !refresh) {
    if (verbose) message("Loading cached file: ", cache_file)
    return(readRDS(cache_file))
  }
  
  if (verbose) message("Building fresh file: ", cache_file)
  obj <- builder_fun()
  
  saveRDS(obj, cache_file)
  obj
}