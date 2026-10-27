"""Short, evidence-led GoTW copy. Editorial policy: docs/gotw-editorial.md."""
import json
import math
import urllib.parse
import urllib.request


def rows(value):
    return value if isinstance(value, list) else [value] if isinstance(value, dict) else []


def mapping(value):
    return value if isinstance(value, dict) else {}


def number(value):
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (ValueError, TypeError):
        return None


def fetch_context(season, league_id):
    """Optional enrichment, two bounded reads; never start forecasts or writes."""
    context = {}
    for kind in ('league', 'schedule'):
        # Omit W: W=ALL does not return historical matchups on MFL.
        url = f'https://api.myfantasyleague.com/{season}/export?' + urllib.parse.urlencode(
            {'TYPE': kind, 'L': league_id, 'JSON': '1'})
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Analytics-Fantasy-Labs-GoTW'})
            with urllib.request.urlopen(req, timeout=10) as response:
                payload = json.load(response)
            if not isinstance(mapping(payload).get(kind), dict):
                raise ValueError(f'MFL {kind} missing')
            context[kind] = payload[kind]
        except (OSError, ValueError) as exc:
            print(f'GoTW blurb context {league_id}/{kind} unavailable; using verified remaining inputs: {exc}')
    return context


def history_games(schedule, through):
    """Accept only completed, internally consistent fantasy H2H results."""
    indexed = {}
    for week in rows(mapping(schedule).get('weeklySchedule')):
        if not isinstance(week, dict):
            continue
        w = number(week.get('week'))
        if w is None or not w.is_integer() or not 1 <= w <= through:
            continue
        for matchup in rows(week.get('matchup')):
            if not isinstance(matchup, dict):
                continue
            teams = rows(matchup.get('franchise'))
            if len(teams) != 2 or not all(isinstance(t, dict) for t in teams):
                continue
            a, b = teams
            ids = [str(t.get('id', '')).zfill(4) for t in teams]
            scores = [number(t.get('score')) for t in teams]
            if any(not i.isdigit() or i == '0000' for i in ids) or ids[0] == ids[1] or None in scores:
                continue
            expected = ('W', 'L') if scores[0] > scores[1] else ('L', 'W') if scores[0] < scores[1] else ('T', 'T')
            if (a.get('result'), b.get('result')) != expected:
                continue
            for i in (0, 1):
                key = (int(w), ids[i])
                game = dict(week=int(w), opponent=ids[1-i], result=expected[i])
                # Multiple different games for a team/week cannot establish a weekly streak.
                if key not in indexed:
                    indexed[key] = game
                elif indexed[key] != game:
                    indexed[key] = None
    return indexed


def streak(games, team, through):
    recent = games.get((through, team))
    if not recent or recent['result'] == 'T':
        return None, 0
    result = recent['result']
    count = 0
    for week in range(through, 0, -1):
        game = games.get((week, team))
        if not game or game['result'] != result:
            break
        count += 1
    return result, count


def division_race(context, franchises, division, ids, through):
    """Describe a close race, not an unverified tiebreak/clinching scenario."""
    members = {i for i, f in franchises.items() if f.get('division') == division}
    records = {}
    for f in rows(mapping(context.get('standings')).get('franchise')):
        if not isinstance(f, dict):
            continue
        team = str(f.get('id', '')).zfill(4)
        if team not in members:
            continue
        values = [number(f.get(k)) for k in ('h2hw', 'h2hl', 'h2ht')]
        if any(v is None or v < 0 or not v.is_integer() for v in values):
            return None
        records[team] = (values[0] + values[2]/2, sum(values))
    if len(members) != 4 or set(records) != members or not set(ids) <= members:
        return None
    counts = {value[1] for value in records.values()}
    if len(counts) != 1 or not through <= next(iter(counts)) <= through + 5:
        return None
    # leagueStandings is live, not an as-of-week endpoint. Avoid using future results.
    schedule = context.get('schedule', {})
    if not schedule or any(w > through for w, _ in history_games(schedule, 30)):
        return None
    wins = sorted((value[0] for value in records.values()), reverse=True)
    if all(records[i][0] >= wins[1] and wins[0]-records[i][0] <= 1 for i in ids):
        return {i: {'win_credit': credit, 'games': games} for i, (credit, games) in records.items()}
    return None


def make_blurb(league, matchup, context=None, used_kinds=()):
    """Choose one main story, at most one supporting hook, and retain its evidence."""
    r = matchup
    context = context or {}
    through = int(r['through_week'])
    names = [r['team_a'], r['team_b']]
    # Nicknames work naturally in the user's short, banner-ready sentences.
    short = ['the Niners' if n == 'San Francisco 49ers' else 'the ' + n.split()[-1] for n in names]
    ids = [str(r[f'team_{s}_id']).zfill(4) for s in ('a', 'b')]
    ranks = [int(r[f'{s}_elo_rank']) for s in ('a', 'b')]
    odds_win = [float(r[f'team_{s}_playoff_if_win']) for s in ('a', 'b')]
    odds_loss = [float(r[f'team_{s}_playoff_if_loss']) for s in ('a', 'b')]
    swings = [float(r[f'team_{s}_swing']) for s in ('a', 'b')]
    config = mapping(context.get('league'))
    franchises = {str(f.get('id', '')).zfill(4): f for f in rows(mapping(config.get('franchises')).get('franchise'))
                  if isinstance(f, dict)}
    divisions = {d['id']: d for d in rows(mapping(config.get('divisions')).get('division'))
                 if isinstance(d, dict) and d.get('id')}
    conferences = {c['id']: c.get('name', '') for c in rows(mapping(config.get('conferences')).get('conference'))
                   if isinstance(c, dict) and c.get('id')}
    divs = [franchises.get(i, {}).get('division') for i in ids]
    same_division = divs[0] is not None and divs[0] == divs[1] and divs[0] in divisions
    division = divisions.get(divs[0], {})
    division_name = ' '.join(filter(None, [conferences.get(division.get('conference')), division.get('name')]))
    games = history_games(context.get('schedule', {}), through)
    streaks = [streak(games, i, through) for i in ids]
    meetings = [g for (week, team), g in games.items()
                if team == ids[0] and g and g['opponent'] == ids[1]
                and games.get((week, ids[1])) and games[(week, ids[1])]['opponent'] == ids[0]]
    last = max(meetings, key=lambda g: g['week']) if meetings else None
    hooks = []

    def add(priority, kind, text, evidence):
        hooks.append(dict(priority=priority, kind=kind, text=text[0].upper()+text[1:], evidence=evidence))

    if last and last['result'] != 'T':
        loser = 0 if last['result'] == 'L' else 1
        winner = 1-loser
        ending = (' in a divisional heavyweight rematch' if same_division and max(ranks) <= 8
                  else ' with a playoff foothold at stake' if swings[loser] >= 15
                  else ' in their divisional rematch' if same_division else '')
        revenge = [f"{short[loser]} seek Week {last['week']} vengeance against {short[winner]}{ending}",
                   f"{short[winner]} won the last meeting; {short[loser]} come looking to settle the score",
                   f"{short[loser]} get another shot at {short[winner]} after their Week {last['week']} defeat"]
        add(85 + (10 if ending.startswith(' in a divisional heavyweight') else 0), 'revenge',
            revenge[list(used_kinds).count('revenge') % len(revenge)],
            dict(prior_week=last['week'], loser=ids[loser], winner=ids[winner], elo_ranks=ranks, same_division=same_division))
    for i, (result, count) in enumerate(streaks):
        other = 1-i
        if count >= 3 and result == 'L':
            obstacle = (f"{league}'s Elo leader" if ranks[other] == 1 else short[other])
            add(91 + min(count, 6), 'losing_streak',
                f'{short[i]} seek to snap a {count}-game skid against {obstacle}',
                dict(team=ids[i], through_week=through, consecutive_h2h_losses=count, opponent_elo_rank=ranks[other]))
        if count >= 3 and result == 'W':
            add(78 + min(count, 6), 'winning_streak',
                f"{short[other]} try to derail {short[i]}' {count}-game surge",
                dict(team=ids[i], through_week=through, consecutive_h2h_wins=count))
        if 5 <= odds_loss[i] <= 40 and swings[i] >= 10 and min(odds_win[other], odds_loss[other]) >= 75:
            obstacle = 'a Bayou buzzsaw' if names[other] == 'New Orleans Saints' and ranks[other] <= 8 else short[other]
            add(87, 'uphill_path', f"{short[i]}' uphill playoff climb runs through {obstacle}",
                dict(team=ids[i], playoff_if_loss=odds_loss[i], playoff_if_win=odds_win[i], opponent_playoff_if_loss=odds_loss[other], opponent_elo_rank=ranks[other]))

    if same_division:
        race = division_race(context, franchises, divs[0], ids, through)
        if race:
            race_text = (f"{short[0]} and {short[1]} bring a tight {division_name} race head-to-head"
                         if 'division_race' in used_kinds else
                         f"{short[0]} and {short[1]} collide at the front of a tight {division_name} race")
            add(92, 'division_race', race_text,
                dict(division=division_name, records=race))
            for i, (result, count) in enumerate(streaks):
                if result == 'W' and count >= 3:
                    add(96, 'streak_in_division_race',
                        f"{short[1-i]} try to halt {short[i]}' {count}-game surge at the front of the {division_name} race",
                        dict(division=division_name, records=race, streak_team=ids[i], consecutive_h2h_wins=count))
        if min(swings) >= 10 and max(odds_loss) <= 50 and min(odds_win) >= 15:
            add(90, 'division_bubble', f"{short[0]} and {short[1]} fight for playoff breathing room in the {division_name}",
                dict(division=division_name, playoff_if_win=odds_win, playoff_if_loss=odds_loss))
        if max(ranks) <= 8:
            add(82, 'division_heavyweights', f"{short[0]} and {short[1]} bring heavyweight stakes to the {division_name}",
                dict(division=division_name, elo_ranks=ranks))
        add(55, 'division_rivalry', f"{short[0]} and {short[1]} renew their {division_name} rivalry",
            dict(division=division_name))
    if min(swings) >= 10:
        add(70, 'playoff_crossroads', f"{short[0]} and {short[1]} meet at a playoff crossroads",
            dict(playoff_if_win=odds_win, playoff_if_loss=odds_loss))
    if min(odds_loss) >= 85 and float(r['combined_seed_swing']) >= 1:
        add(75, 'seed_stakes', f"{short[0]} and {short[1]} jockey for the postseason's upper hand",
            dict(playoff_if_loss=odds_loss, combined_seed_swing=float(r['combined_seed_swing'])))
    i = 0 if swings[0] >= swings[1] else 1
    if swings[i] >= 10:
        add(60, 'one_sided_stakes', f"{short[i]}' playoff push has to go through {short[1-i]}",
            dict(team=ids[i], playoff_if_win=odds_win[i], playoff_if_loss=odds_loss[i]))
    if max(ranks) <= 8:
        add(65, 'heavyweights', f"{short[0]} and {short[1]} collide near the top of {league}'s pecking order",
            dict(elo_ranks=ranks))
    add(0, 'elo_matchup', f"{short[0]} test {short[1]} in a battle of near-equals" if abs(float(r['a_elo'])-float(r['b_elo'])) <= 35
        else f"{short[0 if ranks[0] > ranks[1] else 1]} take aim at the higher-rated {names[1 if ranks[0] > ranks[1] else 0].split()[-1]}",
        dict(elo=[r['a_elo'], r['b_elo']]))
    # Prefer a different, similarly strong story to four copies of one template.
    chosen = max(hooks, key=lambda h: h['priority'] - min(12, 12*list(used_kinds).count(h['kind'])))
    chosen['text'] = chosen['text'].rstrip(' .!')
    return chosen
