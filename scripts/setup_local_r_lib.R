# setup_local_r_lib.R
# -------------------
# Installs the repo's declared R dependencies into ./_lib for local checks.

dir.create("_lib", recursive = TRUE, showWarnings = FALSE)
.libPaths(c(normalizePath("_lib", winslash = "/", mustWork = FALSE), .libPaths()))

options(repos = c(
  ffverse = "https://ffverse.r-universe.dev",
  CRAN = "https://cloud.r-project.org"
))

desc <- read.dcf("DESCRIPTION")
imports <- desc[1, "Imports"]
packages <- trimws(gsub("\\s*\\([^)]*\\)", "", unlist(strsplit(imports, ",", fixed = TRUE), use.names = FALSE)))
packages <- packages[nzchar(packages)]

missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
  install.packages(
    missing,
    dependencies = c("Depends", "Imports", "LinkingTo"),
    Ncpus = max(1, parallel::detectCores() - 1)
  )
}

still_missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
if (length(still_missing)) {
  stop("R packages still not installed: ", paste(still_missing, collapse = ", "), call. = FALSE)
}

cat("Local R library ready: ", normalizePath("_lib", winslash = "/", mustWork = FALSE), "\n", sep = "")
