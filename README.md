ADL Commissioner Dashboard project



Repo: https://github.com/TheMathNinja/ADL-Commissioner-Dashboard

Site: https://themathninja.github.io/ADL-Commissioner-Dashboard/



Purpose:

Automate ADL league commissioner tools and publish a static dashboard using GitHub Actions + GitHub Pages.



Development workflow:

New scripts are developed locally in:

Documents/R/LeagueFeatures/



Once a script is stable, it is copied into this repo under:

scripts/ or R/



This repo is primarily the automation + publishing layer.



Architecture:

\- GitHub Action (.github/workflows/update\_dashboard.yml) runs daily.

\- Workflow runs R scripts, builds datasets, generates HTML dashboard, commits results.

\- GitHub Pages serves docs/index.html.



Repo structure:

ADL-Commissioner-Dashboard/

&nbsp; scripts/

&nbsp;   run\_saladjcurator.R

&nbsp;   build\_dashboard.R

&nbsp; R/

&nbsp;   cache\_helpers.R

&nbsp;   config\_helpers.R

&nbsp;   saladj\_helpers.R

&nbsp;   dashboard\_helpers.R

&nbsp; cache/raw\_league\_data/   (raw data cache, not committed)

&nbsp; data/                    (generated CSV outputs for dashboard)

&nbsp; docs/                    (published GitHub Pages dashboard)



Pipeline:

run\_saladjcurator.R → data/\*.csv → build\_dashboard.R → docs/index.html → GitHub Pages



Current module:

SalAdjCurator – filters ADL transactions for those requiring team salary adjustments in copy-pasteable format for Contract Admin sheet.



Season control:

CURRENT\_SEASON env variable in the workflow (currently 2026).

R reads this via get\_current\_season().



Caching:

Raw league data cached using read\_or\_build\_rds() in cache/raw\_league\_data.



Local run:

Rscript scripts/run\_saladjcurator.R

Rscript scripts/build\_dashboard.R

