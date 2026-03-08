# dashboard_helpers.R
# -------------------
# Helper functions for dashboard HTML generation.

build_dashboard_html <- function(saladj_summary) {
  paste0(
    "<html>
<head>
  <title>ADL Commissioner Dashboard</title>
</head>
<body>

  <h1>ADL Commissioner Dashboard</h1>

  <h2>Salary Adjustments</h2>

  <p>Season: ", saladj_summary$season[1], "</p>
  <p>Players Adjusted: ", saladj_summary$players_adjusted[1], "</p>
  <p>Total Adjustments: ", saladj_summary$total_adjustments[1], "</p>

</body>
</html>"
  )
}