"""Head-to-head parity and franchise mobility; no player-level data published."""
import collections, csv, datetime, json, math, statistics
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'data/parity'
ADL=ROOT/'data/formations/source'

def records(x):return x if isinstance(x,list) else [x] if x else []
def mean(x):return statistics.mean(x) if x else None
def sd(x):return statistics.pstdev(x) if x else None
def regression(x,y):
    mx,my=mean(x),mean(y)
    xx=sum((v-mx)**2 for v in x); yy=sum((v-my)**2 for v in y)
    xy=sum((a-mx)*(b-my) for a,b in zip(x,y))
    beta=xy/xx if xx else None
    return {'beta':beta,'regression_to_mean':1-beta if beta is not None else None,'correlation':xy/math.sqrt(xx*yy) if xx and yy else None}

def quantile_weights(values,quartile):
    """Tie-neutral membership: split each tied rank group across quartiles."""
    ordered=sorted(values.items(),key=lambda x:x[1]); n=len(ordered)
    low,high=quartile*n/4,(quartile+1)*n/4
    weights={k:0.0 for k in values}; i=0
    while i<n:
        j=i+1
        while j<n and ordered[j][1]==ordered[i][1]:j+=1
        fraction=max(0,min(j,high)-max(i,low))/(j-i)
        for k,_ in ordered[i:j]:weights[k]=fraction
        i=j
    return weights

def season_summary(games,year,league):
    rows=[r for r in games if r['season']==year and r['league']==league]
    score_mean=mean([g[k] for g in rows for k in ['score_a','score_b']])
    assert score_mean>0
    teams={}
    for g in rows:
        for ident,name,score,against,result in [(g['team_a'],g['name_a'],g['score_a'],g['score_b'],g['outcome']),
                                               (g['team_b'],g['name_b'],g['score_b'],g['score_a'],-g['outcome'])]:
            t=teams.setdefault(ident,{'season':year,'league':league,'team_id':ident,'team':name,'wins':0,'losses':0,'ties':0,'games':0,'points_for':0.0,'points_against':0.0})
            t['games']+=1;t['points_for']+=score;t['points_against']+=against
            t['wins']+=result>0;t['losses']+=result<0;t['ties']+=result==0
    for t in teams.values():
        t['win_pct']=(t['wins']+.5*t['ties'])/t['games']
        t['net_margin']=(t['points_for']-t['points_against'])/t['games']
        t['normalized_net_margin']=t['net_margin']/score_mean
    assert len(teams)==32,(year,league,len(teams))
    win_pcts=[t['win_pct'] for t in teams.values()]
    abs_margins=[abs(g['score_a']-g['score_b']) for g in rows]
    relative=[m/score_mean for m in abs_margins]
    coin_sd=math.sqrt(mean([.25/t['games'] for t in teams.values()]))
    ordered=sorted(win_pcts); quartile=len(ordered)//4
    bins=[(0,.1),(.1,.25),(.25,.5),(.5,1),(1,math.inf)]
    summary={'season':year,'league':league,'games':len(rows),'teams':len(teams),'first_week':min(g['week'] for g in rows),'last_week':max(g['week'] for g in rows),
             'mean_win_pct':mean(win_pcts),'win_pct_sd':sd(win_pcts),'coin_flip_sd':coin_sd,'record_dispersion_ratio':sd(win_pcts)/coin_sd,
             'middle_band_share':sum(.375<=v<=.625 for v in win_pcts)/len(win_pcts),
             'top_bottom_gap':mean(ordered[-quartile:])-mean(ordered[:quartile]),
             'normalized_net_margin_sd':sd([t['normalized_net_margin'] for t in teams.values()]),
             'average_team_score':score_mean,'mean_margin':mean(abs_margins),'median_margin':statistics.median(abs_margins),
             'mean_relative_margin':mean(relative),'close_game_share':sum(v<=.25 for v in relative)/len(relative),
             'blowout_share':sum(v>=.5 for v in relative)/len(relative),
             'margin_histogram':[sum(low<=v<high for v in relative)/len(relative) for low,high in bins],
             'record_histogram':[sum(low<=v<high for v in win_pcts)/len(win_pcts) for low,high in [(0,.25),(.25,.375),(.375,.625000001),(.625000001,.750000001),(.750000001,1.000000001)]]}
    return summary,list(teams.values())

def mobility(prior,current,league,start,end,provisional):
    a={t['team_id']:t for t in prior};b={t['team_id']:t for t in current}; ids=sorted(a.keys()&b.keys())
    x=[a[k]['win_pct'] for k in ids];y=[b[k]['win_pct'] for k in ids]
    mx,my=mean(x),mean(y)
    margin_x=mean([a[k]['normalized_net_margin'] for k in ids]);margin_y=mean([b[k]['normalized_net_margin'] for k in ids])
    cohort_a=[quantile_weights({k:a[k]['win_pct'] for k in ids},q) for q in range(4)]
    cohort_b=[quantile_weights({k:b[k]['win_pct'] for k in ids},q) for q in range(4)]
    bottom,top=cohort_a[0],cohort_a[3];den=sum(bottom.values())
    movements=[{'league':league,'from_season':start,'to_season':end,'provisional':provisional,'team_id':k,'team':b[k]['team'],
                'prior_win_pct':a[k]['win_pct'],'next_win_pct':b[k]['win_pct'],'change':b[k]['win_pct']-a[k]['win_pct'],
                'prior_centered':a[k]['win_pct']-mx,'next_centered':b[k]['win_pct']-my,
                'prior_margin':a[k]['normalized_net_margin'],'next_margin':b[k]['normalized_net_margin'],
                'prior_margin_centered':a[k]['normalized_net_margin']-margin_x,'next_margin_centered':b[k]['normalized_net_margin']-margin_y,
                'bottom_weight':bottom[k],'top_weight':top[k],'next_bottom_weight':cohort_b[0][k],'next_top_weight':cohort_b[3][k]} for k in ids]
    matrix=[[sum(cohort_a[i][k]*cohort_b[j][k] for k in ids)/sum(cohort_a[i].values()) for j in range(4)] for i in range(4)]
    result={'league':league,'from_season':start,'to_season':end,'provisional':provisional,'teams':len(ids),**regression(x,y),
            'margin_beta':regression([a[k]['normalized_net_margin'] for k in ids],[b[k]['normalized_net_margin'] for k in ids])['beta'],
            'mean_absolute_change':mean([abs(v-u) for u,v in zip(x,y)]),
            'bottom_next_win_pct':sum(bottom[k]*b[k]['win_pct'] for k in ids)/den,
            'bottom_improvement':sum(bottom[k]*(b[k]['win_pct']-a[k]['win_pct']) for k in ids)/den,
            'bottom_to_winning':sum(bottom[k]*(b[k]['win_pct']>.5) for k in ids)/den,
            'bottom_to_top':sum(bottom[k]*cohort_b[3][k] for k in ids)/den,
            'top_to_losing':sum(top[k]*(b[k]['win_pct']<.5) for k in ids)/sum(top.values()),
            'top_to_bottom':sum(top[k]*cohort_b[0][k] for k in ids)/sum(top.values()),'transition_matrix':matrix}
    return result,movements

def write_csv(name,rows):
    with (OUT/name).open('w',newline='',encoding='utf-8') as f:
        writer=csv.DictWriter(f,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)

def build(matched_weeks=False):
    OUT.mkdir(parents=True,exist_ok=True)
    with (OUT/'source/nfl_games.csv').open(encoding='utf-8-sig') as f:nfl=list(csv.DictReader(f))
    games=[];audit=[];scopes=[]
    for year in range(2021,2027):
        league=json.loads((ADL/f'{year}_league.json').read_text())['league']
        # The local ADL playoff script defines a 12-week regular season.
        # Historical MFL metadata incorrectly marks postseason as regular.
        adl_max=12
        nfl_max=12 if matched_weeks else 17
        nfl_year=[r for r in nfl if int(r['season'])==year and r['game_type']=='REG' and int(r['week'])<=nfl_max]
        if year==2026:
            complete_weeks=[w for w in range(1,nfl_max+1) if any(int(r['week'])==w for r in nfl_year) and all(r['home_score'] and r['away_score'] for r in nfl_year if int(r['week'])==w)]
            nfl_max=max(complete_weeks);adl_max=min(adl_max,nfl_max)
        franchises={r['id']:r['name'] for r in records(league['franchises']['franchise'])}
        seen={}
        for week in range(1,adl_max+1):
            source=ADL/f'{year}_results_w{week:02}.json'
            if not source.exists():raise ValueError(f'Missing frozen ADL results: {source}')
            payload=json.loads(source.read_text())['weeklyResults'];byes=post=duplicates=0
            for m in records(payload.get('matchup')):
                if str(m.get('regularSeason'))!='1':post+=1;continue
                pair=records(m.get('franchise'))
                if len(pair)!=2 or any(r['id'] not in franchises for r in pair):byes+=1;continue
                a,b=pair;key=(week,*sorted([a['id'],b['id']]))
                fingerprint=sorted((r['id'],r['score'],r.get('result')) for r in pair)
                if key in seen:
                    if seen[key]!=fingerprint:raise ValueError('Conflicting duplicate ADL matchup')
                    duplicates+=1;continue
                seen[key]=fingerprint
                sa,sb=float(a['score']),float(b['score']);outcome=(sa>sb)-(sa<sb)
                if sa==sb and a.get('result') in ['W','L']:outcome=1 if a['result']=='W' else -1
                if a.get('result') in ['W','L','T']:
                    supplied={'W':1,'L':-1,'T':0}[a['result']]
                    if supplied!=outcome:raise ValueError(f'ADL result/score disagreement: {year} {week} {key}')
                games.append({'season':year,'week':week,'league':'ADL','team_a':a['id'],'team_b':b['id'],'name_a':franchises[a['id']],
                              'name_b':franchises[b['id']],'score_a':sa,'score_b':sb,'outcome':outcome})
            audit.append({'season':year,'week':week,'adl_bye_entries_excluded':byes,'adl_postseason_entries_excluded':post,'duplicate_matchups_excluded':duplicates})
        nfl_missing=0
        for r in nfl_year:
            if int(r['week'])>nfl_max:continue
            if not r['home_score'] or not r['away_score']:nfl_missing+=1;continue
            a,b=float(r['home_score']),float(r['away_score'])
            games.append({'season':year,'week':int(r['week']),'league':'NFL','team_a':r['home_team'],'team_b':r['away_team'],
                          'name_a':r['home_team'],'name_b':r['away_team'],'score_a':a,'score_b':b,'outcome':(a>b)-(a<b)})
        scopes.append({'season':year,'adl_max_week':adl_max,'nfl_max_week':nfl_max,'adl_regular_season_end':12,'mfl_reported_regular_season_end':int(league['lastRegularSeasonWeek']),'provisional':year==2026,'nfl_unscored_games_excluded':nfl_missing})
    summaries=[];teams=[]
    for year in range(2021,2027):
        for league in ['NFL','ADL']:
            s,t=season_summary(games,year,league);summaries.append(s);teams.extend(t)
    transitions=[];movements=[]
    for end in range(2022,2027):
        for league in ['NFL','ADL']:
            a=[t for t in teams if t['season']==end-1 and t['league']==league];b=[t for t in teams if t['season']==end and t['league']==league]
            result,rows=mobility(a,b,league,end-1,end,league=='ADL' and scopes[end-2021]['provisional'] or league=='NFL' and end==2026)
            transitions.append(result);movements.extend(rows)
    pooled=[];recovery=[]
    for league in ['NFL','ADL']:
        rows=[r for r in movements if r['league']==league and not r['provisional']]
        den=sum(r['bottom_weight'] for r in rows);topden=sum(r['top_weight'] for r in rows)
        pooled.append({'league':league,'first_season':2021,'last_season':2025,'team_transitions':len(rows),'season_transitions':4,
                       **regression([r['prior_centered'] for r in rows],[r['next_centered'] for r in rows]),
                       'margin_beta':regression([r['prior_margin_centered'] for r in rows],[r['next_margin_centered'] for r in rows])['beta'],
                       'mean_absolute_change':mean([abs(r['change']) for r in rows]),
                       'bottom_next_win_pct':sum(r['bottom_weight']*r['next_win_pct'] for r in rows)/den,
                       'bottom_improvement':sum(r['bottom_weight']*r['change'] for r in rows)/den,
                       'bottom_to_winning':sum(r['bottom_weight']*(r['next_win_pct']>.5) for r in rows)/den,
                       'bottom_to_top':sum(r['bottom_weight']*r['next_top_weight'] for r in rows)/den,
                       'top_to_losing':sum(r['top_weight']*(r['next_win_pct']<.5) for r in rows)/topden,
                       'top_to_bottom':sum(r['top_weight']*r['next_bottom_weight'] for r in rows)/topden})
        baseline={t['team_id']:t['win_pct'] for t in teams if t['season']==2021 and t['league']==league}
        bottom=quantile_weights(baseline,0);top=quantile_weights(baseline,3)
        history={(t['season'],t['team_id']):t['win_pct'] for t in teams if t['league']==league}
        for horizon in range(1,5):
            recovery.append({'league':league,'baseline_season':2021,'through_season':2021+horizon,'seasons_elapsed':horizon,
                             'cohort_team_equivalents':sum(bottom.values()),
                             'bottom_ever_winning':sum(bottom[k]*any(history[(y,k)]>.5 for y in range(2022,2022+horizon)) for k in baseline)/sum(bottom.values()),
                             'top_ever_losing':sum(top[k]*any(history[(y,k)]<.5 for y in range(2022,2022+horizon)) for k in baseline)/sum(top.values())})
    # Common-window sensitivity check: roughly similar record sample sizes,
    # retaining the full-season metrics as the primary requested comparison.
    matched_nfl=[]
    for year in range(2021,2026):matched_nfl.extend(season_summary([g for g in games if g['week']<=12],year,'NFL')[1])
    matched_moves=[]
    for end in range(2022,2026):
        matched_moves.extend(mobility([t for t in matched_nfl if t['season']==end-1],[t for t in matched_nfl if t['season']==end],'NFL',end-1,end,False)[1])
    nfl_check=regression([r['prior_centered'] for r in matched_moves],[r['next_centered'] for r in matched_moves])
    for p in pooled:
        p['twelve_week_beta']=nfl_check['beta'] if p['league']=='NFL' else p['beta']
        p['twelve_week_regression_to_mean']=1-p['twelve_week_beta']
    report={'seasons':summaries,'teams':teams,'transitions':transitions,'movements':movements,'pooled':pooled,'recovery':recovery,'scopes':scopes,'matched_weeks':matched_weeks,
            'captured_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    (OUT/'report.json').write_text(json.dumps(report,separators=(',',':')))
    write_csv('season_metrics.csv',[{k:v for k,v in r.items() if not isinstance(v,list)} for r in summaries])
    write_csv('team_records.csv',teams);write_csv('yearly_mobility.csv',[{k:v for k,v in r.items() if k!='transition_matrix'} for r in transitions])
    write_csv('team_movement.csv',movements);write_csv('pooled_mobility.csv',pooled);write_csv('coverage.csv',audit)
    write_csv('recovery_speed.csv',recovery)
    print('Built parity:',len(games),'head-to-head games;',len(teams),'team-seasons;',len(movements),'team-year transitions.')
    print('Completed-season persistence / bounce-back:',[(r['league'],round(r['beta'],3),round(r['bottom_to_winning'],3)) for r in pooled])

if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('--matched-weeks',action='store_true')
    build(parser.parse_args().matched_weeks)
