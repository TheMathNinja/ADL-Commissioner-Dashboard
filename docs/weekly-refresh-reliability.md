# Weekly refresh reliability evidence

The Commissioner weekly completion digest checks ADL and FAFL publications against the existing live-site marker, publication receipt, payout receipt and MFL score baseline. Completion establishes that the site is live. The digest separately reports reliability issues from the run that produced it.

- Published component status and clinch certificates are read at the commit that wrote the matching league, season, week, process and run ID. A later maintenance rebuild cannot erase warnings from the weekly refresh.
- Unknown clinch queries remain unresolved. A timeout or cancellation reason is counted explicitly. The certificate applies through Week 12 when the refresh is in the postseason.
- The digest checks GitHub job and step outcomes, production log signals, the matching MFL Bonus Games verification child, earlier attempts of the same run and recent failed refreshes for the same week and process.
- Test steps, command echoes and unrelated release deprecations are excluded. Email reports the affected step and category, without copying raw log messages. Normal preliminary Bonus Games and correction-only cap exclusions do not generate warnings.
- Missing, unreadable or run-mismatched evidence appears as unverified. A completed publisher can still have a reliability notice. A failed publisher remains covered by the incident reporter; the completion digest retains its existing live-publication gate.

This checks observable evidence. A component must emit a status, certificate, log warning or failure for the digest to identify a problem inside it. Entirely silent bad results and external activity with no matching evidence are outside this check.
