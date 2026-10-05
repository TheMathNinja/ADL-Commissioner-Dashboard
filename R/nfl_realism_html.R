build_nfl_realism_html <- function(summary, totals, manifest, adl_summary = NULL, adl_team_year = NULL) {
  template <- paste(readLines("R/nfl_realism_template.html", warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  payload <- jsonlite::toJSON(list(summary = summary, totals = totals, manifest = manifest,
    adl_summary = adl_summary, adl_team_year = adl_team_year),
    dataframe = "rows", auto_unbox = TRUE, na = "null", digits = 8)
  payload <- gsub("<", "\\u003c", payload, fixed = TRUE)
  template <- sub("REPORT_DATA", payload, template, fixed = TRUE)
  script <- paste(readLines("R/nfl_realism_comparison.js",warn=FALSE,encoding="UTF-8"),collapse="\n")
  template <- sub("REPORT_SCRIPT",script,template,fixed=TRUE)
  dashboard_page("NFL Realism Report", paste0(back_link(), template))
}
