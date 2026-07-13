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

run\_saladjcurator.R Ã¢â€ â€™ data/\*.csv Ã¢â€ â€™ build\_dashboard.R Ã¢â€ â€™ docs/index.html Ã¢â€ â€™ GitHub Pages



Current module:

SalAdjCurator Ã¢â‚¬â€œ filters ADL transactions for those requiring team salary adjustments in copy-pasteable format for Contract Admin sheet.



Season control:

CURRENT\_SEASON env variable in the workflow (currently 2026).

R reads this via get\_current\_season().



Caching:

Raw league data cached using read\_or\_build\_rds() in cache/raw\_league\_data.



Local run:

Rscript scripts/run\_saladjcurator.R

SNAPSHOT\_WEEK=1 Rscript scripts/run\_cap\_accounting.R

Rscript scripts/build\_dashboard.R


GitHub Actions secrets needed for live MFL scraping:

- ADL_LEAGUE_ID, default 60206 if omitted locally
- MFL_USERNAME
- MFL_PASSWORD
- MFL_USER_AGENT, default ADLCommissionerDashboard if omitted locally

SalAdjCurator outputs:

- data/SalAdjCurator_latest.csv
- data/SalAdjCurator_<season>.csv
- data/archive/<run_date>_ADLSalAdjCurator.csv
- docs/saladjcurator.html links to archived CSV downloads

Roster snapshots:

SalAdjCurator now writes dated roster snapshots to data/roster_snapshots. Drop transactions are matched against the most recent prior snapshot for the same franchise/player. If no prior franchise snapshot exists, recent drops can still be surfaced as CHECK SALARY rows when the player currently appears elsewhere with salary-risk evidence.

Salary cap accounting:

scripts/run\_cap\_accounting.R writes weekly roster snapshots and rolling summary files under data/cap\_accounting/<season>/. The dashboard builder publishes those CSVs to docs/downloads/salary-cap-accounting/ and updates docs/salary-cap-accounting.html. The weekly GitHub Action runs Tuesday at 3:30 a.m. Toronto time during the regular season; manual workflow runs can provide SNAPSHOT\_WEEK, or omit it to infer the latest completed regular-season week from nflreadr.
