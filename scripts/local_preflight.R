# local_preflight.R
# -----------------
# Lightweight local checks before pushing automation changes.

`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0L || is.na(x)) y else x
}

script_path <- tryCatch(normalizePath(sys.frame(1)$ofile, winslash = "/", mustWork = FALSE), error = function(e) NA_character_)
repo_root <- if (!is.na(script_path)) {
  normalizePath(file.path(dirname(script_path), ".."), winslash = "/", mustWork = FALSE)
} else {
  normalizePath(getwd(), winslash = "/", mustWork = FALSE)
}
if (basename(getwd()) != "ADL-Commissioner-Dashboard" && dir.exists(repo_root)) {
  setwd(repo_root)
}

required_packages <- function(description_path = "DESCRIPTION") {
  if (!file.exists(description_path)) {
    return(character())
  }
  desc <- read.dcf(description_path)
  imports <- desc[1, "Imports"] %||% ""
  pkgs <- unlist(strsplit(imports, ",", fixed = TRUE), use.names = FALSE)
  pkgs <- trimws(gsub("\\s*\\([^)]*\\)", "", pkgs))
  pkgs[nzchar(pkgs)]
}

cat("ADL Commissioner Dashboard local preflight\n")
cat("Working directory: ", normalizePath(getwd(), winslash = "/", mustWork = FALSE), "\n", sep = "")

local_lib <- file.path(getwd(), "_lib")
if (dir.exists(local_lib)) {
  .libPaths(c(local_lib, .libPaths()))
  cat("Using local R library: ", normalizePath(local_lib, winslash = "/", mustWork = FALSE), "\n", sep = "")
}

pkgs <- required_packages()
missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
  cat("Missing R packages: ", paste(missing, collapse = ", "), "\n", sep = "")
  cat("Run: Rscript scripts/setup_local_r_lib.R\n")
} else {
  cat("R packages: ok\n")
}

r_files <- list.files(c("R", "scripts"), pattern = "\\.R$", recursive = TRUE, full.names = TRUE)
parse_failures <- list()
for (path in r_files) {
  ok <- tryCatch({
    parse(path)
    TRUE
  }, error = function(e) {
    parse_failures[[path]] <<- conditionMessage(e)
    FALSE
  })
}

if (length(parse_failures)) {
  cat("Parse failures:\n")
  for (path in names(parse_failures)) {
    cat("- ", path, ": ", parse_failures[[path]], "\n", sep = "")
  }
  quit(status = 1, save = "no")
}
cat("R parse check: ok (", length(r_files), " files)\n", sep = "")

git_probe <- tempfile(tmpdir = ".git", pattern = "codex-write-probe-")
git_writable <- tryCatch({
  writeLines("probe", git_probe)
  unlink(git_probe)
  TRUE
}, error = function(e) FALSE)
if (!git_writable) {
  cat("Local .git write probe: blocked. Use GitHub Actions/API for commits from Codex, or fix Windows ACLs.\n")
} else {
  cat("Local .git write probe: ok\n")
}

cat("Preflight complete.\n")
