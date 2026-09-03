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

Commissioner Alerts:

R/commissioner\_alerts.R checks roster cap, contract years, salary cap, and illegal lineup rules. The daily alert workflow runs at 6:15 a.m. Eastern during daylight saving time and sends emails when alerts are found. It also runs roster cutdown reports near Noon Eastern on August 31 and September 7 with backup runs to reduce the chance of GitHub schedule drops.

Salary cap alerts use the offseason/preseason Top 43 rule until the Final Roster Cutdown datetime. After Final Cutdown, daily checks read this repo's salary-cap accounting summaries and warn teams whose current live accounting salary would push their cumulative average over the franchise cap at the next weekly salary snapshot.

Public alert summaries are written under data/commissioner\_alert\_reports/ and published to docs/commissioner-alerts.html.

Offseason Inactivity Monitor:

R/offseason\_inactivity\_monitor.R checks offseason inactivity policies and reuses the commissioner-alert email plumbing. Season-specific date windows live in data/source/offseason\_inactivity\_windows\_<season>.csv and should be updated each offseason before running retroactive auction-window checks.

Annual Season Rollover Checklist:

At the start of each ADL season, update CURRENT\_SEASON in the GitHub Actions workflows and create/update data/source/offseason\_inactivity\_windows\_<season>.csv. Codex should explicitly prompt for every date/value below before enabling the new season's daily checks.

Required annual date fields:

- rookie\_draft, Rookie Draft: end\_at. Once this passes, rookie draft clock-expiration checks stop for the season.
- pre\_ufa\_auction, R/F: start\_at and end\_at.
- pre\_ufa\_auction, FT: start\_at and end\_at.
- pre\_ufa\_auction, RFA: start\_at and end\_at.
- pre\_ufa\_auction, B/R: start\_at and end\_at.
- pre\_ufa\_auction, UDFA: start\_at and end\_at. Salary-below-UDFA adjustment checks begin after this window ends.
- ufa\_auction, UFA Auction: start\_at. Bid-adjustment checks begin at 12:00:01 a.m. ET on the eighth day of this auction.
- ufa\_auction\_first\_three\_days, UFA: start\_at and end\_at. Used for the 24-hour no-bid inactivity rule during the first three UFA days.
- roster\_deadline, UFA signing deadline: deadline\_at.
- roster\_deadline, Rookie signing deadline: deadline\_at.
- roster\_cutdown\_1: date/time, configured in R/commissioner\_alerts.R defaults or ADL\_ROSTER\_CUTDOWN\_1\_AT.
- final\_roster\_cutdown: date/time, configured in R/commissioner\_alerts.R defaults or ADL\_FINAL\_ROSTER\_CUTDOWN\_AT. The late-offseason NG bid-adjustment rule stops at this deadline, and in-season salary accounting begins after this deadline.
- ADL\_WEEK\_ONE\_START: first date used to infer the active in-season fantasy week for lineup checks.

Required annual values:

- ADL salary cap baseline and individual franchise salary caps from MFL.
- ADL SD minimum, via ADL\_SD\_MIN\_<season> or the fallback table in R/commissioner\_alerts.R.
- NFL bye weeks, if the dashboard's fallback table is not current.
- Commissioner digest franchises and optional extra recipients/CCs if roles changed.

One-time checks:

- Deadline-based checks should be scheduled/run once at the deadline and then treated as complete.
- Draft-clock checks should not continue after the rookie draft end date.
- Issued inactivity violations are tracked in data/offseason\_inactivity/issued\_violations\_<season>.csv and data/inseason\_inactivity/issued\_violations\_<season>.csv so daily monitors only email newly confirmed violations.

Additional GitHub Actions secrets needed for commissioner alert emails:

- ADL_ALERT_EMAIL_FROM
- ADL_SMTP_SERVER
- ADL_SMTP_USERNAME
- ADL_SMTP_PASSWORD
- ADL_SMTP_SSL
- ADL_ALERT_DIGEST_FRANCHISES, defaults to CHI,KCC,IND,SEA in the workflow
- ADL_ALERT_DIGEST_EXTRA_EMAILS, optional
- ADL_ALERT_NFC_CC, optional
- ADL_ALERT_AFC_CC, optional
