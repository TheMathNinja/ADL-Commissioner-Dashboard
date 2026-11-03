"""Restore a verified original cap package before separately logging late corrections."""
from pathlib import Path
import argparse,csv,hashlib,json,os,re,shutil
from prepare_cap_snapshot_overwrite import prepare

def restore(root,season,week,backup_id,correction_key,run_id):
 root=Path(root).resolve();season=int(season);week=int(week)
 if not 2000<=season<=2100 or not 1<=week<=17:raise ValueError('Invalid season/week')
 if not re.fullmatch(r'[A-Za-z0-9_-]+',backup_id) or not re.fullmatch(r'[A-Za-z0-9._-]+',correction_key):raise ValueError('Invalid backup or correction identity')
 if not re.fullmatch(r'[A-Za-z0-9_-]+',run_id):raise ValueError('Invalid run identity')
 base=root/'data/cap_accounting'/str(season);ledger=base/'manual_cap_corrections.csv'
 if ledger.exists():
  with ledger.open(encoding='utf-8-sig') as f:logged=list(csv.DictReader(f))
  if any(r['key']==correction_key and int(r['season'])==season and int(r['week'])==week for r in logged):return dict(already_applied=True,restored=0)
 source=base/'manual_overwrites'/f'week-{week:02}'/backup_id
 manifest=json.loads((source/'manifest.json').read_text())
 if manifest['season']!=season or manifest['week']!=week:raise ValueError('Backup has wrong season/week')
 files=manifest['files'];seen=set()
 for row in files:
  path=Path(row['path']);target=(base/path).resolve();saved=(source/path).resolve()
  if path.is_absolute() or not target.is_relative_to(base.resolve()) or not saved.is_relative_to(source.resolve()) or not re.fullmatch(fr'{season}w{week}_ADL.*\.(csv|rds)',path.name):raise ValueError('Backup contains an out-of-scope path')
  if row['path'] in seen:raise ValueError('Duplicate backup path')
  seen.add(row['path'])
  if hashlib.sha256(saved.read_bytes()).hexdigest()!=row['sha256']:raise ValueError('Backup checksum failed')
 for required in [f'snapshots/{season}w{week}_ADLsalarycapsnapshot.csv',f'snapshots/{season}w{week}_ADLsalarycapsnapshot.rds',f'summaries/{season}w{week}_ADLsalarycapsummary.csv',f'summaries/{season}w{week}_ADLsalarycapsummary.rds',f'{season}w{week}_ADLsalarycapmetadata.csv']:
  if required not in seen:raise ValueError('Incomplete original package')
 prepare(root,season,week,'before-restore-'+run_id)
 for row in files:
  target=base/row['path'];target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source/row['path'],target)
  if hashlib.sha256(target.read_bytes()).hexdigest()!=row['sha256']:raise AssertionError('Restore verification failed')
 return dict(already_applied=False,restored=len(files))

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--root',default='.');p.add_argument('--season',required=True,type=int);p.add_argument('--week',required=True,type=int);p.add_argument('--backup-id',required=True);p.add_argument('--key',required=True);a=p.parse_args();print(restore(a.root,a.season,a.week,a.backup_id,a.key,os.getenv('GITHUB_RUN_ID','manual')+'-'+os.getenv('GITHUB_RUN_ATTEMPT','1')))
