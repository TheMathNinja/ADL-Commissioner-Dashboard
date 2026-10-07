"""Explicit refresh of public results; raw player exports remain ignored/local."""
import csv, datetime, io, json, time, urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'data/parity/source';ADL=ROOT/'data/formations/source'
SOURCE.mkdir(parents=True,exist_ok=True);ADL.mkdir(parents=True,exist_ok=True)
def fetch(url,path,refresh=False):
    if path.exists() and not refresh:return path.read_bytes()
    for attempt in range(3):
        time.sleep(1.5)
        try:
            data=urllib.request.urlopen(url,timeout=45).read()
            if path.suffix=='.json' and 'error' in json.loads(data):raise ValueError(str(json.loads(data)))
            path.write_bytes(data);return data
        except Exception:
            if attempt==2:raise
            time.sleep(10*(attempt+1))
nfl=fetch('https://raw.githubusercontent.com/nflverse/nfldata/master/data/games.csv',SOURCE/'nfl_games.csv',True)
rows=list(csv.DictReader(io.StringIO(nfl.decode('utf-8-sig'))))
for year in range(2021,2027):
    league=json.loads(fetch(f'https://api.myfantasyleague.com/{year}/export?TYPE=league&L=60206&JSON=1',ADL/f'{year}_league.json',year==2026))['league']
    last=12
    if year==2026:
        games=[r for r in rows if r['season']==str(year) and r['game_type']=='REG']
        completed=[w for w in range(1,19) if any(int(r['week'])==w for r in games) and all(r['home_score'] and r['away_score'] for r in games if int(r['week'])==w)]
        last=min(12,max(completed))
    for week in range(1,last+1):
        fetch(f"{league['baseURL']}/{year}/export?TYPE=weeklyResults&L=60206&W={week}&JSON=1&MISSING_AS_BYE=1",ADL/f'{year}_results_w{week:02}.json',year==2026)
    print('Cached parity sources',year,'ADL weeks 1–'+str(last),flush=True)
(SOURCE/'retrieval_manifest.json').write_text(json.dumps({'captured_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'nfl_source':'nflverse/nfldata games.csv','adl_source':'MFL weeklyResults, league 60206'}))
