build_nfl_realism_html <- function(summary, totals, manifest, adl_summary = NULL, adl_team_year = NULL) {
  template <- paste(readLines("R/nfl_realism_template.html", warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  payload <- jsonlite::toJSON(list(summary = summary, totals = totals, manifest = manifest,
    adl_summary = adl_summary, adl_team_year = adl_team_year),
    dataframe = "rows", auto_unbox = TRUE, na = "null", digits = 8)
  payload <- gsub("<", "\\u003c", payload, fixed = TRUE)
  template <- sub("REPORT_DATA", payload, template, fixed = TRUE)
  script <- paste(readLines("R/nfl_realism_comparison.js",warn=FALSE,encoding="UTF-8"),collapse="\n")
  template <- sub("REPORT_SCRIPT",script,template,fixed=TRUE)
  if (file.exists("data/formations/report.json")) {
    formations <- paste(readLines("R/formations_template.html",warn=FALSE,encoding="UTF-8"),collapse="\n")
    formation_data <- paste(readLines("data/formations/report.json",warn=FALSE,encoding="UTF-8"),collapse="\n")
    formation_data <- gsub("<", "\\u003c", formation_data, fixed=TRUE)
    formation_script <- paste(readLines("R/formations_report.js",warn=FALSE,encoding="UTF-8"),collapse="\n")
    formations <- sub("FORMATIONS_DATA",formation_data,formations,fixed=TRUE)
    formations <- sub("FORMATIONS_SCRIPT",formation_script,formations,fixed=TRUE)
    template <- paste0(template, formations)
  }
  dashboard_page("NFL Realism Report", paste0(back_link(), template))
}
