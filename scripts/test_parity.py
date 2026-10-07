"""Verify actual records, scope, accounting, regression and tied cohorts."""
import json, math
from build_parity import ROOT, quantile_weights, regression

assert math.isclose(regression([.25,.5,.75],[.375,.5,.625])['beta'],.5)
assert math.isclose(regression([.25,.5,.75],[.75,.5,.25])['regression_to_mean'],2)
values={str(i):.5 for i in range(32)}
quartiles=[quantile_weights(values,q) for q in range(4)]
assert all(math.isclose(sum(q.values()),8) for q in quartiles)
assert all(math.isclose(sum(q[k] for q in quartiles),1) for k in values)
assert all(math.isclose(q[k],.25) for q in quartiles for k in values)

d=json.loads((ROOT/'data/parity/report.json').read_text())
assert not d['matched_weeks']
assert len(d['teams'])==6*32*2 and len(d['movements'])==5*32*2
for s in d['seasons']:
    teams=[t for t in d['teams'] if t['season']==s['season'] and t['league']==s['league']]
    assert len(teams)==32
    assert sum(t['games'] for t in teams)==2*s['games']
    assert sum(t['wins'] for t in teams)==sum(t['losses'] for t in teams)
    assert all(t['wins']+t['losses']+t['ties']==t['games'] for t in teams)
    assert all(math.isclose((t['wins']+.5*t['ties'])/t['games'],t['win_pct']) for t in teams)
    assert math.isclose(sum(t['points_for'] for t in teams),sum(t['points_against'] for t in teams),abs_tol=1e-8)
    assert math.isclose(sum(t['points_for'] for t in teams)/sum(t['games'] for t in teams),s['average_team_score'])
    assert math.isclose(sum(s['record_histogram']),1) and math.isclose(sum(s['margin_histogram']),1)
    if s['league']=='ADL' and s['season']<2026:
        assert s['games']==192 and s['last_week']==12 and all(t['games']==12 for t in teams)
    if s['league']=='NFL' and s['season']<2026:
        assert s['last_week']==18 and s['games']==(271 if s['season']==2022 else 272)

def team(y,code):return next(t for t in d['teams'] if t['season']==y and t['league']=='NFL' and t['team_id']==code)
assert [team(2024,'KC')[k] for k in ['wins','losses','ties']]==[15,2,0]
assert [team(2023,'CAR')[k] for k in ['wins','losses','ties']]==[2,15,0]
assert [team(2022,'BUF')[k] for k in ['wins','losses','games']]==[13,3,16]
for t in d['transitions']:
    assert t['teams']==32 and t['provisional']==(t['to_season']==2026)
    assert all(math.isclose(sum(row),1) for row in t['transition_matrix'])
    for k in ['bottom_to_winning','bottom_to_top','top_to_losing','top_to_bottom']:assert 0<=t[k]<=1
for p in d['pooled']:
    rows=[r for r in d['movements'] if r['league']==p['league'] and not r['provisional']]
    assert len(rows)==128 and max(r['to_season'] for r in rows)==2025
    beta=sum(r['prior_centered']*r['next_centered'] for r in rows)/sum(r['prior_centered']**2 for r in rows)
    assert math.isclose(beta,p['beta']) and math.isclose(1-beta,p['regression_to_mean'])
    for y in range(2022,2026):
        pair=[r for r in rows if r['to_season']==y]
        assert math.isclose(sum(r['bottom_weight'] for r in pair),8)
        assert math.isclose(sum(r['top_weight'] for r in pair),8)
        assert abs(sum(r['prior_margin_centered'] for r in pair))<1e-8
        assert abs(sum(r['next_margin_centered'] for r in pair))<1e-8
for league in ['NFL','ADL']:
    rows=sorted([r for r in d['recovery'] if r['league']==league],key=lambda r:r['seasons_elapsed'])
    for k in ['bottom_ever_winning','top_ever_losing']:
        assert all(0<=r[k]<=1 for r in rows)
        assert all(a[k]<=b[k] for a,b in zip(rows,rows[1:]))
    transition=next(t for t in d['transitions'] if t['league']==league and t['to_season']==2022)
    assert math.isclose(rows[0]['bottom_ever_winning'],transition['bottom_to_winning'])
    assert math.isclose(rows[0]['top_ever_losing'],transition['top_to_losing'])
print('Parity verified: 12/18-week scope, known NFL records, game accounting, tied quartiles, regression pooling, recovery and 2026 exclusion.')
