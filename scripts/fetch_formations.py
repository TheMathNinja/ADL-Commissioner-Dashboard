import concurrent.futures, csv, datetime, gzip, io, json, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / 'data/formations/source'
ROOT.mkdir(parents=True, exist_ok=True)

def fetch(url, path):
    if path.exists():
        return path.read_bytes()
    time.sleep(1.5)
    for attempt in range(3):
        try:
            data = urllib.request.urlopen(url, timeout=60).read()
            if path.suffix == '.json' and 'error' in json.loads(data):
                raise ValueError(str(json.loads(data)))
            path.write_bytes(data)
            return data
        except Exception:
            if attempt == 2: raise
            time.sleep(10 * (attempt+1))

tasks=[]
for year in range(2021,2027):
    raw=fetch(f'https://github.com/nflverse/nflverse-data/releases/download/snap_counts/snap_counts_{year}.csv.gz',ROOT/f'nfl_snaps_{year}.csv.gz')
    rows=list(csv.DictReader(io.StringIO(gzip.decompress(raw).decode())))
    weeks=sorted({int(r['week']) for r in rows if r.get('game_type')=='REG' and int(r['week'])<=17})
    print(year, 'NFL weeks', weeks, flush=True)
    league=json.loads(fetch(f'https://api.myfantasyleague.com/{year}/export?TYPE=league&L=60206&JSON=1',ROOT/f'{year}_league.json'))['league']
    base=league['baseURL']
    tasks.append((f'{base}/{year}/export?TYPE=players&L=60206&DETAILS=1&JSON=1',ROOT/f'{year}_players.json'))
    for week in (range(1,18) if year<2026 else weeks):
        tasks.append((f'{base}/{year}/export?TYPE=weeklyResults&L=60206&W={week}&JSON=1&MISSING_AS_BYE=1',ROOT/f'{year}_results_w{week:02}.json'))
with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
    futures={pool.submit(fetch,u,p):p for u,p in tasks}
    for future in concurrent.futures.as_completed(futures):
        path=futures[future]
        future.result()
        print('Cached',path.name,flush=True)
fetch('https://raw.githubusercontent.com/dynastyprocess/data/master/files/db_playerids.csv',ROOT/'ff_playerids.csv')
(ROOT.parent/'retrieval_manifest.json').write_text(json.dumps({'captured_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'league_id':'60206','seasons':list(range(2021,2027))},indent=2))
