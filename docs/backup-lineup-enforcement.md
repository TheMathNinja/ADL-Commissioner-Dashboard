# ADL backup-lineup enforcement

ADL V-A and XV-B require an active lineup. The commissioner's November 17,
2026 interpretation includes failing to pursue a starting free agent earlier
in the week after the need is known. An unsuccessful acquisition attempt is
not inactivity. This check conservatively exempts every recorded attempt;
it does not judge maximum bids or demand spending beyond available cap.

`data/source/backup_lineup_opportunities_YEAR.csv` records reviewed role and
availability evidence. It is not a depth-chart feed. Add candidates only after
verifying that the backup was not expected to play, the starter was available
to that conference, and the need/opportunity was known before the auction
closed. Zero points, zero snaps and being listed as a backup alone are not
proof. Unreviewed cases are not automatically discovered by this evaluator.

At execution, the checker verifies the opening and winning auction records
against MFL's full transaction export, checks direct bids and proxy-bid
annotations, and rechecks the final weekly lineup. Missing auction boundaries,
missing final lineups or wrong-conference evidence cannot confirm a violation.
Ambiguous bid annotations mentioning the franchise are conservatively exempt.

Only completed prior weeks enter the existing inactivity pipeline. The key is
`illegal_lineup|YEAR|FRANCHISE|WEEK`, shared with the other lineup checks, so
multiple symptoms/opportunities do not produce multiple weekly violations.
Existing delivery and issued records own notifications; there is no new mailer,
schedule, paid job, automatic penalty, emergency add or lineup rewrite.

## MIN, Week 10, 2026

- Richardson was the Colts' announced backup, not an NFL-inactive player.
- Willis went on IR November 10 at 3:59 p.m. Eastern (Dolphins announcement).
- NOS opened McCord's NFC auction November 10 at 4:17:10 p.m. Eastern and
  won November 11 at 4:41:33 p.m. Eastern. TBB forced a proxy-bid increase.
- The full public transaction export showed no MIN attempt on this auction.
- MIN's submitted lineup timestamp was November 14 at 12:04:34 p.m. Eastern;
  its final Week 10 starters included Richardson (MFL player 16152).
- The commissioner explicitly confirmed that no attempt in this circumstance
  is inactivity, while an unsuccessful bid is exempt.

Sources: [ADL bylaws](https://docs.google.com/document/d/12l8eriNPrC1aY9LRgPlXQHJtNxSfOzmnfv0zJBUY1jU/edit),
[Colts backup announcement](https://www.colts.com/news/anthony-richardson-sr-named-colts-backup-quarterback),
[Willis IR announcement](https://www.miamidolphins.com/news/dolphins-make-roster-moves-x8063),
[McCord Week 10 press conference](https://www.miamidolphins.com/video/qb-kyle-mccord-nov-11-press-conference),
[MFL transactions](https://api.myfantasyleague.com/2026/export?TYPE=transactions&L=60206&JSON=1).
