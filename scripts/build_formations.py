"""Frozen NFL snap-leader / ADL submitted-lineup aggregates. Sources stay local."""
import collections, csv, gzip, itertools, json, math
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'data/formations'
SOURCE = OUT / 'source'
POSITIONS = {'OFF': ['QB','RB','WR','TE'], 'DEF': ['DT','DE','LB','CB','S']}
LIMIT = {'OFF':7,'DEF':12}

def records(value):
    return value if isinstance(value,list) else [value] if value else []

def read_csv(path):
    opener = gzip.open if path.suffix == '.gz' else open
    with opener(path,'rt',encoding='utf-8-sig',newline='') as f: return list(csv.DictReader(f))

def norm(value): return str(value or '').strip().lower()

def unique_index(pairs):
    candidates=collections.defaultdict(set)
    for key,value in pairs:
        if key and value: candidates[key].add(value)
    return {k:next(iter(v)) for k,v in candidates.items() if len(v)==1}

def selection_candidates(players,side):
    """Combine every positive-snap QB into one entry before ranking seven slots."""
    if side!='OFF': return players
    qbs=[p for p in players if p['position']=='QB']
    if not qbs: raise ValueError('No positive-snap QB in NFL offensive group')
    total=sum(p['snaps'] for p in qbs)
    methods=collections.defaultdict(float)
    for p in qbs: methods[p.get('method','Season ADL/MFL ID match')]+=p['snaps']/total
    qb={'position':'QB','snaps':total,'id':'combined-qb','method_weights':dict(methods)}
    others=[p for p in players if p['position']!='QB']
    return [qb]+others

def distributions(players,side):
    """Uniform combinations at the cutoff: integer formations, fractional frequency."""
    players=selection_candidates(players,side)
    slots=LIMIT[side]; ordered=sorted(players,key=lambda p:-p['snaps'])
    if len(ordered)<slots: raise ValueError(f'Insufficient positive-snap players: {side} {len(ordered)}')
    cutoff=ordered[slots-1]['snaps']
    above=collections.Counter(p['position'] for p in players if p['snaps']>cutoff)
    tied=collections.Counter(p['position'] for p in players if p['snaps']==cutoff)
    remaining=slots-sum(above.values()); denominator=math.comb(sum(tied.values()),remaining)
    positions=POSITIONS[side]; result=[]
    for allocation in itertools.product(*(range(min(tied[p],remaining)+1) for p in positions)):
        if sum(allocation)!=remaining: continue
        ways=math.prod(math.comb(tied[p],n) for p,n in zip(positions,allocation))
        counts=tuple(above[p]+n for p,n in zip(positions,allocation))
        result.append((counts,Fraction(ways,denominator)))
    assert sum(w for _,w in result)==1
    return result, sum(tied.values())>remaining

def write_csv(name,rows):
    if not rows: return
    with (OUT/name).open('w',newline='',encoding='utf-8') as f:
        writer=csv.DictWriter(f,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)

def build():
    ids=read_csv(SOURCE/'ff_playerids.csv')
    pfr_lookup=unique_index((norm(r.get('pfr_id')),r.get('mfl_id')) for r in ids)
    # Prior local PositionLimits ID matches supplement the shared crosswalk, never names alone.
    legacy=ROOT/'data/formations/source/legacy_game_level.csv'
    if legacy.exists():
        pairs=[(norm(r.get('pfr_id')),r.get('mfl_id')) for r in read_csv(legacy) if r.get('map_method')=='ffpid']
        pfr_lookup=unique_index(list(pfr_lookup.items())+pairs)
    observations=[]; coverage=[]; mapping_audit=[]
    for year in range(2021,2027):
        nfl=read_csv(SOURCE/f'nfl_snaps_{year}.csv.gz')
        nfl=[r for r in nfl if r['game_type']=='REG' and 1<=int(r['week'])<=17]
        weeks=sorted({int(r['week']) for r in nfl})
        mfl=json.loads((SOURCE/f'{year}_players.json').read_text())['players']['player']
        positions={r['id']:r['position'] for r in mfl}
        # Supplemental stable PFR IDs from the saved annual GSIS/ADL maps.
        annual=SOURCE/f'annual_ids_{year}.csv'
        yearly_pfr=unique_index(list(pfr_lookup.items())+([(norm(r['pfr_id']),r['mfl_id']) for r in read_csv(annual)] if annual.exists() else []))
        matched={norm(r['pfr_player_id']):positions.get(yearly_pfr.get(norm(r['pfr_player_id']))) for r in nfl}
        modes=collections.defaultdict(collections.Counter)
        for raw,pid in {(r['position'],norm(r['pfr_player_id'])) for r in nfl}:
            if matched[pid] in sum(POSITIONS.values(),[]):modes[raw][matched[pid]]+=1
        fallback={'HB':'RB','FB':'RB','NT':'DT','ILB':'LB','MLB':'LB','OLB':'LB','SS':'S','FS':'S','DB':'CB','DL':'DT','EDGE':'DE'}
        drop={'OL','C','G','T','OT','OG','LT','LG','RG','RT','LS','K','P','PK','PN'}
        grouped=collections.defaultdict(list)
        for row in nfl:
            raw=row['position']; pid=norm(row['pfr_player_id']); pos=matched[pid]
            if raw in drop: continue
            method='Season ADL/MFL ID match'
            if pos not in sum(POSITIONS.values(),[]):
                method='Estimated: season matched-player mode' if modes[raw] else 'Estimated: NFL position translation'
                pos=sorted(modes[raw],key=lambda p:(-modes[raw][p],p))[0] if modes[raw] else fallback.get(raw,raw)
            if pos not in sum(POSITIONS.values(),[]):raise ValueError(f'Unknown NFL position {year} {raw}')
            side='OFF' if pos in POSITIONS['OFF'] else 'DEF'
            snaps=int(float(row['offense_snaps' if side=='OFF' else 'defense_snaps']))
            if snaps<=0:continue
            key=(int(row['week']),row['game_id'],row['team'],side)
            grouped[key].append({'position':pos,'snaps':snaps,'id':pid,'method':method})
        for (week,game,team,side),players in grouped.items():
            if len({p['id'] for p in players})!=len(players):raise ValueError('Duplicate NFL player/game')
            dist,tie=distributions(players,side)
            for counts,weight in dist:
                observations.append({'season':year,'week':week,'league':'NFL','team':team,'side':side,'counts':list(counts),'weight':float(weight)})
            players=selection_candidates(players,side)
            cutoff=sorted((p['snaps'] for p in players),reverse=True)[LIMIT[side]-1]
            above=sum(p['snaps']>cutoff for p in players); at=sum(p['snaps']==cutoff for p in players)
            for p in players:
                weight=1 if p['snaps']>cutoff else (LIMIT[side]-above)/at if p['snaps']==cutoff else 0
                if weight:
                    methods=p.get('method_weights') or {p['method']:1}
                    for method,share in methods.items():
                        mapping_audit.append({'season':year,'week':week,'side':side,'method':method,'weight':weight*share})
            coverage.append({'season':year,'week':week,'league':'NFL','team':team,'side':side,'slots':LIMIT[side],'included':True,'boundary_tie':tie})
        league=json.loads((SOURCE/f'{year}_league.json').read_text())['league']
        franchises={r['id']:r['name'] for r in records(league['franchises']['franchise']) if r['id']!='0000'}
        for week in weeks:
            result=json.loads((SOURCE/f'{year}_results_w{week:02}.json').read_text())['weeklyResults']
            rows=[r for matchup in records(result.get('matchup')) for r in records(matchup.get('franchise'))]+records(result.get('franchise'))
            lineups={}
            for r in rows:
                if r['id'] not in franchises:continue
                starters={p['id'] for p in records(r.get('player')) if p.get('status')=='starter'}
                if not starters and r.get('starters'):starters=set(filter(None,r['starters'].split(',')))
                if r['id'] in lineups and lineups[r['id']]!=starters:raise ValueError('Conflicting duplicate ADL lineup')
                lineups[r['id']]=starters
            for fid,name in franchises.items():
                starters=lineups.get(fid,set())
                if any(pid not in positions for pid in starters):raise ValueError('Missing annual ADL starter position')
                for side,order in POSITIONS.items():
                    count=collections.Counter(positions[pid] for pid in starters if positions[pid] in order)
                    slots=sum(count.values()); complete=slots==LIMIT[side]
                    coverage.append({'season':year,'week':week,'league':'ADL','team':name,'side':side,'slots':slots,'included':complete,'boundary_tie':False})
                    if complete:observations.append({'season':year,'week':week,'league':'ADL','team':name,'side':side,'counts':[count[p] for p in order],'weight':1.0})
    # Serialize aggregate formations only: no player IDs, scores, ownership or contracts.
    payload={'positions':POSITIONS,'observations':observations,'coverage':coverage,
             'manifest':json.loads((OUT/'retrieval_manifest.json').read_text())}
    (OUT/'report.json').write_text(json.dumps(payload,separators=(',',':')))
    weekly=[{k:v for k,v in r.items() if k!='counts'}|{'formation':' / '.join(f'{n} {p}' for p,n in zip(POSITIONS[r['side']],r['counts']))} for r in observations]
    write_csv('weekly_formations.csv',weekly);write_csv('coverage.csv',coverage)
    summary_rows=[]; frequency_rows=[]
    latest_weeks={r['week'] for r in observations if r['season']==2026 and r['league']=='NFL'}
    for year,league,side,window in itertools.product(range(2021,2027),['NFL','ADL'],POSITIONS,['Available weeks','Same weeks as 2026']):
        rows=[r for r in observations if r['season']==year and r['league']==league and r['side']==side and (window=='Available weeks' or r['week'] in latest_weeks)]
        teams=collections.defaultdict(list)
        for r in rows:teams[r['team']].append(r)
        means=[0.0]*len(POSITIONS[side]);freq=collections.defaultdict(float)
        for group in teams.values():
            denominator=sum(r['weight'] for r in group)
            for r in group:
                weight=r['weight']/denominator/len(teams)
                for i,count in enumerate(r['counts']):means[i]+=count*weight
                freq[tuple(r['counts'])]+=weight
        weeks=sorted({r['week'] for r in rows})
        common={'season':year,'league':league,'side':side,'window':window,'weeks':','.join(map(str,weeks))}
        summary_rows.extend(common|{'position':p,'mean_starters':v,'teams':len(teams),'lineups':round(sum(r['weight'] for r in rows))} for p,v in zip(POSITIONS[side],means))
        frequency_rows.extend(common|{'formation':' / '.join(f'{n} {p}' for p,n in zip(POSITIONS[side],c)),'frequency':v} for c,v in sorted(freq.items(),key=lambda x:-x[1]))
    write_csv('season_averages.csv',summary_rows);write_csv('formation_frequencies.csv',frequency_rows)
    audit=collections.defaultdict(float)
    for r in mapping_audit:audit[(r['season'],r['week'],r['side'],r['method'])]+=r['weight']
    write_csv('position_coverage.csv',[{'season':y,'week':w,'side':s,'method':m,'starter_equivalents':v} for (y,w,s,m),v in sorted(audit.items())])
    print('Built',len(observations),'formation observations;',len(coverage),'team-week-side coverage records.')
    for year in range(2021,2027):
        c=[r for r in coverage if r['season']==year and r['league']=='ADL']
        print(year,'ADL complete:',sum(r['included'] for r in c),'/',len(c),'NFL cutoff ties:',sum(r['boundary_tie'] for r in coverage if r['season']==year and r['league']=='NFL'))

if __name__=='__main__':build()
