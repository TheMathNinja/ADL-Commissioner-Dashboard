# build_dashboard.R
# -----------------
# This script builds the dashboard website files.

library(tidyverse)

# Read the SalAdjCurator output
saladj_summary <- read_csv("data/saladj_summary.csv")

# Make sure docs directory exists
dir.create("docs", showWarnings = FALSE)

# Build simple HTML page
html <- paste0(
  "<html>
<head>
<title>ADL Commissioner Dashboard</title>
</head>
<body>

<h1>ADL Commissioner Dashboard</h1>

<h2>Salary Adjustments</h2>

<p>Season: ", saladj_summary$season, "</p>
<p>Players Adjusted: ", saladj_summary$players_adjusted, "</p>
<p>Total Adjustments: ", saladj_summary$total_adjustments, "</p>

</body>
</html>"
)

writeLines(html, "docs/index.html")

print("Dashboard build complete")