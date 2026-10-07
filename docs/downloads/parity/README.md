# Parity

Compare ADL head-to-head records and winning margins with the NFL, plus franchise mobility from one year to the next. Seasons: 2021–2026. Completed seasons use ADL weeks 1–12 and NFL weeks 1–17 (usually 16 games per NFL team after its bye). NFL week 18 is excluded. 2026 uses fully completed weeks only and is explicitly provisional. It does not enter completed-season mobility.

ADL regular-season scope follows the existing `get_adl_playoff_picture.R` definition of 12 weeks. Historical MFL `lastRegularSeasonWeek` and `regularSeason` flags incorrectly include later playoff/consolation contests; the explicit week-12 cutoff overrides those labels. Byes, unknown pseudo-franchises, all-play/bonus standings points, and postseason results are excluded. Only genuine pairs of league franchises count. Identical duplicates count once; disagreement stops the build. Outcomes follow scores, with supplied W/L resolving a scored tie if MFL applies a tiebreaker. NFL canceled or unfinished games do not count. Each scheduled game counts once; franchise-seasons are equally weighted in record statistics.

## Within-season measures

- Winning percentage = (wins + 0.5 × ties) / games.
- Record spread = population SD of team winning percentages; report as percentage points.
- Coin-flip baseline = sqrt(mean(0.25 / team games)); dispersion ratio = observed record SD / this baseline. It is a conventional independent-game approximation, not an exact schedule simulation. It adjusts the baseline for the shorter ADL season but does not remove all uncertainty or schedule effects. The baseline retains .25 despite ties.
- Middle-band share = fraction of teams between .375 and .625 inclusive.
- Top–bottom gap = mean win percentage of the highest eight records minus that of the lowest eight.
- Normalized net margin = each team's average signed margin / the league-season average team-game score. Net-margin spread is its population SD.
- Relative game margin = absolute game margin / average league-season team-game score. The report shows its mean and distribution, along with raw margins as context. Ties contribute a zero margin. Close = at most 25% of typical team scoring; lopsided = at least 50%. These are descriptive thresholds, not possession rules.

Scale normalization makes NFL points and fantasy points dimensionless; it does not make fantasy scoring mechanically identical to football scoring.

## Year-to-year measures

Pair the same ADL franchise IDs / NFL team codes across consecutive seasons. Fit an OLS regression with intercept of next win percentage on prior win percentage. The slope β measures persistence. Gap reduction, 1 − β, measures fitted regression of prior separation toward the mean; it is not a percent of teams improving. β can be negative or greater than one. Record correlation and average absolute win-percentage movement give complementary views.

Pooled completed-season results contain four transitions (2021→2022 through 2024→2025), 128 franchise-transitions per league. Center both prior and next results at their league-season team averages before pooling. Apply the same seasonal centering to normalized net-margin persistence. Current-season transitions are displayed separately, never pooled. A secondary 12-week record-persistence calculation restricts the NFL to weeks 1–12 and retains the full ADL regular season; NFL byes still make game counts slightly different. This is a sensitivity check, while ADL weeks 1–12 and NFL weeks 1–17 remain the primary comparison.

Bottom/top quartiles contain eight team-equivalents. At tied-record cutoffs, split membership evenly over all tied franchises. Count rebounds to winning records (> .500), jumps from bottom to top, falls to losing records (< .500), and top-to-bottom falls. A quartile transition cell uses prior membership × next membership divided by prior group weight. Every row sums to one. These are descriptive tie-neutral allocations, not additional games or literal fractional franchises.

Regression includes record luck as well as changes in underlying quality, schedules, rosters and management. ADL has fewer games than the NFL, which increases record noise and can reduce apparent persistence. Normalized margin β supplies an alternative based on scoring performance, but is also noisy. The report does not infer causation or isolate the 2026 scoring changes or ownership changes.

The recovery-speed table follows the fixed 2021 bottom/top cohorts through 2025 and reports the share ever crossing strictly above/below .500 within one to four subsequent seasons. Using the same cohort at every horizon keeps cumulative rates comparable. Each group contains only eight team-equivalents; this is a descriptive small-cohort measure, not an estimate of sustained recovery.

## Files and rebuild

`season_metrics.csv`: within-year metrics; `team_records.csv`: aggregate W/L/T and margins; `yearly_mobility.csv`: yearly regressions and cohort outcomes; `pooled_mobility.csv`: completed-season pool; `team_movement.csv`: aggregate franchise changes; `recovery_speed.csv`: cumulative recovery/decline of the 2021 cohorts; `coverage.csv`: excluded byes/duplicates and source coverage. `report.json` also carries histograms and transition matrices for the static report. Raw MFL player exports and source files remain local in ignored source directories.

Run `python scripts/fetch_parity.py`, `python scripts/build_parity.py`, `python scripts/test_parity.py`, then `Rscript scripts/build_nfl_realism.R` from the repository root. Ordinary dashboard builds reuse the frozen aggregates. A research rebuild with `--matched-weeks` uses weeks 1–12 in both leagues; the published report uses ADL weeks 1–12 and NFL weeks 1–17.

Sources: public MFL weeklyResults, [nflreadr schedules](https://nflreadr.nflverse.com/reference/load_schedules.html), [NFL game-data definitions](https://nflreadr.nflverse.com/articles/dictionary_schedules.html).
