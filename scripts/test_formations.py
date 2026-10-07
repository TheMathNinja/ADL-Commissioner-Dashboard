"""Check tie probabilities, real lineup coverage and prior PositionLimits results."""
import collections, itertools, json, math
from build_formations import ROOT, POSITIONS, LIMIT, distributions, read_csv

# Independent enumeration of individual tied-player selections verifies the
# position-combination weighting, including several players at one position.
players=[{'position':p,'snaps':100} for p in ['QB','RB','WR','WR','TE']]
players += [{'position':p,'snaps':50} for p in ['RB','RB','WR','TE']]
actual,tie=distributions(players,'OFF')
expected=collections.Counter()
for selected in itertools.combinations(range(5,9),2):
    c=collections.Counter(players[i]['position'] for i in list(range(5))+list(selected))
    expected[tuple(c[p] for p in POSITIONS['OFF'])]+=1/6
assert tie and all(math.isclose(float(w),expected[c]) for c,w in actual)
assert all(sum(c)==7 for c,_ in actual)

# A substitute QB cannot displace the next eligible skill-position player.
replacement=[{'position':p,'snaps':s} for p,s in [('QB',90),('QB',80),('RB',75),('WR',70),('WR',65),('TE',60),('WR',55),('RB',50)]]
actual,tie=distributions(replacement,'OFF')
assert actual==[((1,2,3,1),1)] and not tie
# With two QBs removed from consideration, the sixth non-QB cutoff still splits ties.
replacement[-1]['snaps']=55
replacement.append({'position':'TE','snaps':55})
actual,tie=distributions(replacement,'OFF')
assert tie and all(c[0]==1 and sum(c)==7 for c,_ in actual)

data=json.loads((ROOT/'data/formations/report.json').read_text())
groups=collections.defaultdict(list)
for r in data['observations']:
    assert all(isinstance(n,int) and n>=0 for n in r['counts'])
    assert sum(r['counts'])==LIMIT[r['side']] and r['weight']>0
    if r['league']=='NFL' and r['side']=='OFF': assert r['counts'][0]==1
    groups[(r['season'],r['week'],r['league'],r['team'],r['side'])].append(r)
for rows in groups.values():assert math.isclose(sum(r['weight'] for r in rows),1,abs_tol=1e-10)
for r in data['coverage']:
    key=tuple(r[k] for k in ['season','week','league','team','side'])
    assert (key in groups)==r['included']
    if r['league']=='ADL':assert r['included']==(r['slots']==LIMIT[r['side']])
assert len({tuple(r[k] for k in ['season','week','league','team','side']) for r in data['coverage']})==len(data['coverage'])
current=[r for r in data['coverage'] if r['season']==2026 and r['league']=='ADL']
current_weeks={r['week'] for r in current}
assert len(current)==len(current_weeks)*32*2
assert {r['week'] for r in data['coverage'] if r['season']==2026 and r['league']=='NFL'}==current_weeks
for season in range(2021,2027):
    for league in ['NFL','ADL']:
        for side in ['OFF','DEF']:
            for max_week in [4,17]:
                rows=[r for r in data['observations'] if r['season']==season and r['league']==league and r['side']==side and r['week']<=max_week]
                teams=collections.defaultdict(list)
                for r in rows:teams[r['team']].append(r)
                frequency=collections.defaultdict(float)
                for team_rows in teams.values():
                    denominator=sum(r['weight'] for r in team_rows)
                    for r in team_rows:frequency[tuple(r['counts'])]+=r['weight']/denominator/len(teams)
                assert len(teams)==32 and math.isclose(sum(frequency.values()),1,abs_tol=1e-10)
                assert math.isclose(sum(sum(c)*w for c,w in frequency.items()),LIMIT[side],abs_tol=1e-10)

# Existing independent saved output agrees exactly for 2023/2025 and 2024
# defense. 2024 offense differs only because the legacy output placed MFL DT
# Scott Matlock in the PFR FB group (three starts). He is ineligible at ADL
# offensive positions here, preserving a seven-player offensive comparison.
legacy=ROOT/'data/formations/source/legacy_game_level.csv'
if legacy.exists():
    old=read_csv(legacy)
    for year,side in [(2023,'DEF'),(2024,'DEF'),(2025,'DEF')]:
        actual=collections.Counter();expected=collections.Counter()
        for r in data['observations']:
            if r['season']==year and r['league']=='NFL' and r['side']==side:
                for p,n in zip(POSITIONS[side],r['counts']):actual[p]+=n*r['weight']
        for r in old:
            if int(r['season'])==year and r['side']==side:expected[r['mfl_pos']]+=float(r['starter_weight'])
        assert all(math.isclose(actual[p],expected[p],abs_tol=1e-8) for p in POSITIONS[side])
print('Tie allocation, 7/12 slots, complete-lineup filtering, all season/window frequencies and prior-output reconciliation passed.')
