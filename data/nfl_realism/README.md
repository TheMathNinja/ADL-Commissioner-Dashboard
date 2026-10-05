# NFL Realism Report — Roster Composition

Frozen 2021–2025 regular-season NFL roster benchmark, covering 2,718 completed team-games.

The displayed comparison uses ADL seasons 2021–2025, weeks 1–17, and the same NFL week window. The original full NFL season files below retain week 18. ADL appears only in the top position table; the bottom team table is NFL-only, with a five-year mean followed by five annual means.

## ADL historical comparison

Use MFL weekly `rosters` exports for league 60206 and count only players whose roster status is `ROSTER`. ADL injured reserve and taxi squad membership are excluded. Among Active Roster players, only O/Out or Bye is INA; all others are ACT, including Questionable, IR, and other tags. Both columns add to the Active Roster total. This implements the requested ADL definition rather than reconstructing actual NFL gameday eligibility.

Historical weekly MFL `injuries` exports supply Out. Empty or unavailable exports use archived `nflreadr::load_injuries(2021:2024)` report_status Out via GSIS-to-MFL IDs. These are reconstructed designations, not exact archived ADL display labels. Bye uses the scheduled NFL team's off week; same-week or nearest-week NFL roster observations supply team, with annual MFL team fallback explicitly audited. A missing Out label defaults to ACT under the requested rule.

ADL means include all 32 franchise-weeks; NFL means include played team-games. Consequently ADL bye players count INA while NFL bye teams have no gameday snapshot. Average weeks within franchise, then franchises within season, then seasons equally. Every position/status cell includes zero weeks.

`adl_comparison.csv` is the readable side-by-side comparison. `adl_players.csv.gz` records membership, designation source, inferred team source, and INA reason. `adl_weekly.csv`, `adl_team_year.csv`, `adl_summary.csv`, and `adl_coverage.csv` provide aggregation and coverage audits. `nfl_adl_window_summary.csv` and `nfl_adl_window_team_year.csv` contain the displayed NFL window. Detailed ADL player archives and cached MFL responses remain local and are excluded from the public repository. An offline ADL rebuild requires those local `adl_history/` responses; use the explicit fetch script to obtain them. Public ADL downloads contain aggregate counts only; fallback NFL injuries are in `source_adl_fallback_injuries.rds`.

Run `Rscript scripts/build_adl_realism.R` for an offline historical comparison rebuild and `Rscript scripts/test_adl_realism.R` for validation. Historical downloads are explicit via `scripts/fetch_adl_realism_history.R` and cached. Large player audits use gzip compression without changing their CSV contents.

The primary measures are observed `ACT + INA` and `ACT + INA - OL - LS`. No roster total is forced to 53. The composite averages games within each team-season, then equally weights teams within seasons and the five seasons. The canceled 2022 Bills–Bengals game is excluded; those teams have 16 completed games.

## Position authority

The player's position in that year's ADL/MFL league 60206 player export is authoritative. Use stable GSIS/ESPN/Sportradar/PFR/Rotowire ID crosswalks and direct IDs from the annual export to establish MFL identity. Current crosswalk positions are never used. Annual exports are historical season databases retrieved now, not weekly MFL position snapshots. NFL OL and LS remain excluded even if a player has an MFL listing at another position.

Unmatched players use the modal MFL classification of matched player classifications in the same season and NFL position/depth-position group. The schema includes support and agreement share; this is descriptive agreement, not a calibrated probability of correctness. When no examples exist, explicit NFL depth-position translation applies. Conflicting IDs are refused. Every estimated record carries its method and reason.

## Files

| File | Grain / purpose |
| --- | --- |
| `team_year.csv` | Season × team × ACT/INA × ADL position, with mean/min/max and game denominator |
| `league_year.csv` | Season × ACT/INA × ADL position, mean NFL team |
| `composite.csv` | Equal-season five-year NFL mean by status and position (`ALL` season key) |
| `totals.csv` | Team-season/NFL roster totals, OL, LS and remaining positions |
| `weekly.csv` | Team-game × status × position, including zero counts |
| `player_snapshots.csv.gz` | All source statuses at completed regular-season games; MFL identity, position and fallback audit |
| `position_coverage.csv` | ACT/INA player-game counts by position assignment method |
| `fallback_schema.csv` | Season-specific estimates learned from unique matched player classifications |
| `audit.csv` | Team-game totals and review flags (not assertions of rule violations) |
| `status_codes.csv` | Counts for all original statuses and secondary status codes |
| `source_mfl_players.csv` | Original player fields from five annual ADL exports |
| `source_weekly_rosters_2021_2025.rds` | Entire original nflreadr snapshot, including postseason |
| `source_schedules_2021_2025.rds` | Original schedules used to establish completed games |
| `source_id_crosswalk.rds` | ID crosswalk captured for reproducible linkage |
| `manifest.json` | Retrieval time, source/version, scope and snapshot checksum |

## Build and verify

From repository root, run `Rscript scripts/build_nfl_realism.R` to render the frozen report. Only `Rscript scripts/build_nfl_realism.R --refresh` downloads replacement source data. The ordinary dashboard builder republishes the frozen page without fetching historical data. Run `Rscript scripts/test_nfl_realism.R` to verify historical positions, fallback logic, zero counts and roster arithmetic.

Sources: [weekly rosters](https://nflreadr.nflverse.com/reference/load_rosters_weekly.html), [ID crosswalk](https://nflreadr.nflverse.com/reference/load_ff_playerids.html), annual MFL players exports with `L=60206`, and [NFL roster rules](https://operations.nfl.com/calendar-events/nfl-free-agency/contract-language).

Duplicate MFL player/franchise/week records are counted once. If both ROSTER and reserve/taxi records appear, explicit ROSTER membership takes precedence. Source status combinations and membership_conflict flags remain in the player and coverage audits.

Public deployment includes aggregate summary files only. Player snapshots, annual MFL player records, ID crosswalks, source RDS files, and detailed ADL history are local build inputs and are excluded from the public repository and site downloads. The frozen report renderer uses aggregate CSVs; source rebuilds and player-level validation require local inputs or explicit source retrieval.
