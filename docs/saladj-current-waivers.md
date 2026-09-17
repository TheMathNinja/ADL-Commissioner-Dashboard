# Current MFL waiver verification

Policy: `20260916-mfl-drop-event-check-v1`.

Each Curator run reads MFL's public league metadata and Locked Players report once. Both ADL conferences are checked. This is an HTML report, not an undocumented JSON API endpoint. The parser verifies league, season, conference ownership, player IDs, dropping franchise and the complete report structure.

For a recent unresolved drop, the current individual lock must match player ID, conference, dropping franchise and the original drop's exact Eastern timestamp. A matching lock keeps the adjustment pending even after the calculated deadline. The output says `PENDING WAIVER - STILL LISTED BY MFL`. A later re-drop or a system-added player cannot reopen an older adjustment.

The existing 24/48-hour and next-5-a.m. calculation remains the historical timing rule. The live check covers each player's latest drop in each conference within seven days, all clock-pending drops, and any older drop with an exact current lock. An absent lock after the estimated deadline only clears pending status; it never proves a waiver claim or independently reverses a penalty. Existing transaction/contract claim evidence and salary snapshots still determine those outcomes. Already-supported claims survive temporary lookup failures.

Unverified, conflicting, stale or failed live evidence makes recent unresolved status unknown, with `WAIVER STATUS UNVERIFIED` and the expected 5 a.m. Eastern waiver run date. It is not silently treated as cleared. A blanket league lock also prevents interpreting individual absence as clearance. Unknown status does not trigger an automatic claim reversal. A verified matching lock is labeled `ON WAIVERS CURRENTLY`; a verified absence after the expected run is labeled `NOT LISTED ON MFL WAIVERS AT LAST CHECK`. Salary, contract and manual-review notes remain intact. Changes in waiver status update the archive but do not resend an email for the same adjustment.

Raw public responses, request timestamps and hashes, parsed locks, the verification receipt, and per-drop decisions are saved under `data/waiver_snapshots/`. These files support later investigation. The check performs two public read requests and does not submit league transactions or salary adjustments. Existing scheduled Curator publication and notification behavior is unchanged.

Run `Rscript scripts/test_saladj_waivers.R` for deterministic tests. ADL Automation Preflight runs these checks and can also run the full Curator in its existing no-email mode.
