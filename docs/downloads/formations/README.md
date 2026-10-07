# Formations Report

Compare NFL top 7 offensive and top 12 defensive snap leaders per team-game with ADL submitted starters for league 60206. Offense includes QB/RB/WR/TE and excludes OL. Defense uses DT/DE/LB/CB/S, with DL and DB aggregates appended after S (LB is already listed), plus DL/LB/DB formation frequencies. Group counts overlap individual positions and do not add to lineup totals. These are weekly snap-leader groups, not play-by-play personnel formations.

## Scope and seasons

2021–2025: regular-season weeks 1–17. 2026: weeks 1–4 in the source captured for this release. The report uses every available week within each season. The missing 2021 injury reports that affected Roster Composition do not affect submitted starters and snap counts, so 2021 is included here.

## NFL selection and ties

This extends the user's local `LeagueFeatures/PositionLimits/PositionLimits.R` and its top-N cutoff logic. Rank positive offense or defense snaps within each NFL team-game and eligible ADL side. Side eligibility follows the ADL position; for example, ADL DT Scott Matlock is not included among offensive candidates even when PFR lists him as an NFL FB. This differs from three of the legacy 2024 offensive selections and keeps the seven offensive slots at ADL offensive positions. Players above the cutoff contribute one slot. Players tied at the cutoff split the remaining slots equally. For readable integer formation frequencies, enumerate all possible position-count allocations of the tied slots and weight each by its number of player combinations divided by the total combinations. This produces exactly the same mean position counts as fractional starter weights without arbitrarily selecting a player from a tie. One team-game can therefore contribute fractions to several formations.

Use season-specific ADL positions from that year's MFL `players` export. Match stable PFR IDs to MFL IDs through the fantasy-player crosswalk, supplemented by existing annual ID-map caches and the prior PositionLimits stable-ID matches. Reject ambiguous IDs. For unmatched players, use the modal ADL position among distinct matched players of that NFL position in the season; use an explicit position translation only if no matched examples exist. `position_coverage.csv` records weighted starter equivalents by mapping method. All selected players are classified; three starter-equivalents across 2021–2026 use learned estimates in this snapshot. No selected player uses the final translation fallback.

## ADL decisions

Use MFL `weeklyResults` players explicitly marked `starter`, or its submitted `starters` list. Never use the `shouldStart` flag or rank by fantasy score. Zero-score starters count. Exclude kicker/punter and non-individual positions. Check offense and defense separately: a complete offensive lineup has 7 relevant starters, defense 12. Exclude missing, undersized or oversized sides from means and formation frequencies, and preserve those counts in `coverage.csv`. Franchise bye submissions count if MFL returns a complete lineup. Duplicate franchise responses must agree on their starter IDs; duplicates are counted once. No injury exclusions are applied to submitted lineup decisions.

## Averages and interpretation

Average games/weeks within each team, then average teams equally within each season. Apply the same weighting to formation frequencies, so each league/side sums to 100%. True zero position counts are included. Historical seasons use weeks 1–17; 2026 uses available weeks. The 2026 observations may reflect scoring changes, position changes, roster availability or other decisions; this report does not establish causation.

`weekly_formations.csv` is an aggregate team-week-side formation distribution, with fractional `weight` only for NFL cutoff ties. `coverage.csv` records completeness and cutoff ties. `report.json` contains those aggregates for the static dashboard. Raw NFL player snaps, MFL weekly player results, annual player databases and ID maps stay in the ignored local source directory.

## Rebuild

From the repository root, run `python scripts/fetch_formations.py` to cache public sources, `python scripts/build_formations.py` to rebuild aggregates, then `Rscript scripts/build_nfl_realism.R` to render the full NFL Realism Report. Ordinary dashboard builds reuse the frozen `report.json`. Refresh requires removing only the specific cached source files to be refreshed; the cache is intentionally preserved by default. The current year and week coverage are derived from sources, not from future scheduled games.

Sources: [nflreadr snap counts](https://nflreadr.nflverse.com/reference/load_snap_counts.html), [fantasy ID crosswalk](https://github.com/dynastyprocess/data), MFL `weeklyResults`, `players`, and `league` exports.
