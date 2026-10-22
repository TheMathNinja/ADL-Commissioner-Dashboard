import copy,importlib.util,json,os,sys,tempfile,types,unittest
from pathlib import Path
from unittest.mock import patch,MagicMock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from verify_bonus_receipt import validate_bonus_receipt
def bonus_receipt(week=3,run_id='123',league='ADL'):
    due=[w for w in (3,6,9,12) if w<=week]
    rows=lambda w:[dict(id=f'{i:04}',week=w,W=(1 if i<=15 else 0)*(2 if w==12 else 1),L=(1 if i>=18 else 0)*(2 if w==12 else 1),T=(1 if 16<=i<=17 else 0)*(2 if w==12 else 1)) for i in range(1,33)]
    return dict(status='success',mode='official',league=league,season=2026,week=week,run_id=run_id,source_sha256='a'*64,verified_at='2026-10-22T18:00:00Z',due_weeks=due,results=[dict(week=w,rows=rows(w)) for w in due])

class ReceiptTests(unittest.TestCase):
 def test_every_due_period(self):
  for week in [1,3,6,9,12,17]:validate_bonus_receipt(bonus_receipt(week),'ADL',2026,week,'123')
 def test_reject_unverified_or_wrong_context(self):
  for key,value in [('status','queued'),('status','failure'),('mode','preview'),('league','FAFL'),('week',2),('run_id','old'),('due_weeks',[]),('verified_at',''),('source_sha256','bad'),('results',[])]:
   with self.subTest(key=key,value=value),self.assertRaises((ValueError,TypeError)):validate_bonus_receipt({**bonus_receipt(),key:value},'ADL',2026,3,'123')
 def test_all_teams_and_totals(self):
  for kind in ['missing','duplicate','invalid']:
   ack=bonus_receipt()
   if kind=='missing':ack['results'][0]['rows'].pop()
   if kind=='duplicate':ack['results'][0]['rows'][-1]['id']='0001'
   if kind=='invalid':ack['results'][0]['rows'][0].update(W=0,L=1)
   with self.assertRaises(ValueError):validate_bonus_receipt(ack,'ADL',2026,3,'123')
