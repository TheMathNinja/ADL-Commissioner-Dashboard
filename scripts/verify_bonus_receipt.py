"""Validate an authoritative MFL readback receipt, never a queue acknowledgement."""
import argparse,json,os,re
from datetime import datetime
from pathlib import Path

def validate_bonus_receipt(ack,league,season,week,run_id=None,source_sha256=None,mode='official'):
    if not isinstance(ack,dict) or (ack.get('status'),ack.get('mode'),ack.get('league'),ack.get('season'),ack.get('week'))!=('success',mode,league,season,week):
        raise ValueError('MFL Bonus Games are not verified for this league/week/mode')
    if run_id is not None and str(ack.get('run_id'))!=str(run_id):raise ValueError('MFL receipt belongs to another run')
    if source_sha256 is not None and ack.get('source_sha256')!=source_sha256:raise ValueError('MFL receipt belongs to another score source')
    if not re.fullmatch('[a-f0-9]{64}',str(ack.get('source_sha256',''))):raise ValueError('MFL receipt lacks a score-source digest')
    if not datetime.fromisoformat(ack.get('verified_at','').replace('Z','+00:00')).tzinfo:raise ValueError('MFL receipt lacks a verification timestamp')
    due=[w for w in (3,6,9,12) if w<=week]
    if ack.get('due_weeks')!=due:raise ValueError('MFL receipt does not cover every due Bonus Game')
    results=ack.get('results',[])
    if len(results)!=len(due) or [x.get('week') for x in results]!=due:raise ValueError('MFL receipt lacks due-week readbacks')
    for result in results:
        rows=result.get('rows',[]);count=2 if result['week']==12 else 1
        if len(rows)!=32 or {x.get('id') for x in rows}!={f'{i:04}' for i in range(1,33)}:raise ValueError('MFL readback must cover all 32 teams')
        for row in rows:
            values=[row.get(k) for k in ('W','L','T')]
            if row.get('week')!=result['week'] or any(type(v)!=int or v<0 for v in values) or sum(values)!=count:raise ValueError('Invalid MFL result in readback')
        if [sum(x[k] for x in rows) for k in ('W','L','T')]!=[15*count,15*count,2*count]:raise ValueError('MFL readback has incorrect league outcome totals')
    return ack

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--league',required=True);a=p.parse_args()
    path=Path(__file__).resolve().parents[1]/'data/bonus_mfl_sync_metadata.json'
    validate_bonus_receipt(json.loads(path.read_text()),a.league,int(os.environ.get('CURRENT_SEASON','2026')),int(os.environ['READY_WEEK']),os.environ['GITHUB_RUN_ID'])
    print(a.league+': authoritative MFL Bonus Games readback verified')
