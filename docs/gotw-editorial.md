# Game of the Week Blurb Policy

Applies to both leagues' recurring suggestion email. Display `Blurb:` directly
below each matchup heading, not `Rationale:`. These are proposed banner captions,
not automatically selected games or published artwork. Ranking weights, delivery
schedule, and recipients are unchanged.

## Michael's Style

His approved captions establish the style:

These are writing examples, not hardcoded historical claims to reuse for a new
week. In particular, verify the definition/source of a streak or ranking anew.

- ADL Week 4: "Commissioner Bowl 2026". A verified league relationship can be
  more interesting than standings. Do not infer commissioner/rookie GM identities.
- ADL Week 7: "The Niners seek to snap a 4-game skid against the NFC's new #1".
  Pair a specific recent trend with an imposing opponent. Do not call the Elo
  leader the standings leader or claim "new" without a prior-period comparison.
- FAFL Week 7: "The Eagles' uphill playoff climb runs through a Bayou Buzzsaw".
  Asymmetric stakes and a little local color make a better hook than listing odds.
- ADL Week 8: "Buffalo seeks Week 1 vengeance in the ADL's most heavyweight
  divisional battle". A dated prior defeat plus a high-quality rivalry.
- FAFL Week 8: "The NFC West is up for grabs and these two are fighting for their
  playoff lives". Combine divisional competition with postseason urgency; never
  invent a clinching or elimination scenario.

Pick one strongest story with at most one supporting hook. Aim for one short,
active, banner-ready sentence, usually 10-22 words. Use natural team nicknames,
restrained wordplay, and verbs such as seek, snap, derail, fight, and climb.
No trailing periods. No generic "this is an exciting matchup", metric dumps,
betting language, or stock "must-win" claims. Avoid forcing the same hook onto
every candidate. Keep the numerical ranking explanation in the existing rows.

## Evidence And Runtime

`scripts/gotw_blurbs.py` provides deterministic, evidence-led writing rather than
an external model call. This stores editorial behavior in production code; it
does not claim to retrain model weights. No new API key, forecast simulation,
scheduler, or email recipient is needed.

The existing Elo/swing exports establish quality and conditional postseason
stakes. Two optional MFL reads per league provide actual fantasy divisions and
all-season H2H history (omit W; W=ALL is not supported for this purpose).
Each read times out after 10 seconds, with no retry loop. Failure logs the missing
context and uses only remaining verified facts; it does not block email delivery.
Already-sent suggestions do not perform these extra reads.

Only completed W/L/T pairs with consistent numeric scores through the forecast's
through-week count. Gaps, ties, ambiguous doubleheaders, and missing results break
streaks. Streaks describe H2H games, not Bonus Games or real NFL team streaks.
Revenge refers to the latest verified meeting, never a future fixture or tie.
Fantasy division membership comes from this league's configuration, not inferred
from NFL affiliation. A tight division-race hook requires all four current records,
equal games played, both participants among the top two (including ties), within
one win of the leader, and no completed later-week games in the schedule. This is
not a claim about who wins a tiebreak or can clinch. No unverified claim that a division can be clinched, a team
is eliminated, or a game literally decides a title. Draft movement does not imply
that the franchise owns its pick or wants to lose.

The chosen story and its supporting values are logged with every generated
caption. Unit tests cover missing feeds, future results, ties, ambiguous results,
league separation, and the approved storyline patterns. Review those tests when
adding new hooks; never make up facts to fit a clever phrase.

During each league's four suggestions, mildly downweight already-used story types
when another similarly strong hook exists. If revenge remains the best story,
vary its wording while keeping the same verified winner, loser, and prior week.
