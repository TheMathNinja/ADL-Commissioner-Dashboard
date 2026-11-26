# ADL MFL pregame designation evidence

The existing public Commissioner reporter archives MFL's weekly injury export
at the 120-, 90-, 60-, and 30-minute marks before each distinct kickoff. It
uses the verified MFL kickoff schedule from the Guardian coverage assessment.
Identical kickoff times share a slot. A capture more than 15 minutes after its
slot is not recorded or backfilled, and the file carries the actual observation
time. The four existing daily roster snapshots remain the independent baseline.

Append-only records live in GitHub under
`data/commissioner_alerts/mfl_pregame_designations/<season>/week<NN>/`. The
archive stores only public MFL player IDs and injury designations, without
rosters, franchise details, injury descriptions, or personal projections.
The production job does not require a local device. A regular local Git pull
will fetch these files along with the rest of the repository.

The lineup review resolves each observed player to their unambiguous archived
weekly MFL team identity and keeps observation times separate from announcement
times. A missing player, feed, or archive slot cannot prove an inactive
designation. This does not change the inactivity rules or add NFL announcement
evidence. No additional scheduled runner or separate failure email is created.
