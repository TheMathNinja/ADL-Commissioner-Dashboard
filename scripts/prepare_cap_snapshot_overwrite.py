"""Back up exactly one official cap week before an explicitly authorized recapture."""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil
from datetime import datetime,timezone

def prepare(root,season,week,backup_id):
 root=Path(root).resolve();season=int(season);week=int(week)
 if not 2000<=season<=2100 or not 1<=week<=17:raise ValueError('Invalid cap season/week')
 if not re.fullmatch(r'[A-Za-z0-9_-]+',backup_id):raise ValueError('Invalid backup identity')
 base=(root/'data/cap_accounting'/str(season)).resolve()
 if not base.is_relative_to(root):raise ValueError('Cap directory escapes workspace')
 prefix=f'{season}w{week}_ADL';snapshot=base/'snapshots'/f'{prefix}salarycapsnapshot.csv'
 if not snapshot.is_file():raise ValueError('An existing official snapshot is required for overwrite')
 for p in base.glob(f'{season}w*_ADLsalarycapmetadata.csv'):
  m=re.fullmatch(fr'{season}w(\d+)_ADLsalarycapmetadata.csv',p.name)
  if m and int(m[1])>week:raise ValueError('Later official snapshots exist; a prior-week rewrite needs a propagation plan')
 archive=base/'manual_overwrites';destination=archive/f'week-{week:02}'/backup_id
 if destination.exists():raise ValueError('Backup identity already exists; refusing replacement')
 files=[p for p in base.rglob('*') if p.is_file() and not p.is_relative_to(archive) and re.fullmatch(re.escape(prefix)+r'.*\.(csv|rds)',p.name)]
 if any(not p.resolve().is_relative_to(base) for p in files):raise ValueError('Snapshot source escapes cap directory')
 records=[]
 for source in files:
  relative=source.relative_to(base);target=destination/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
  digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
  if digest(source)!=digest(target):raise AssertionError('Backup verification failed')
  records.append(dict(path=relative.as_posix(),sha256=digest(source),bytes=source.stat().st_size))
 manifest=dict(season=season,week=week,backup_id=backup_id,created_at_utc=datetime.now(timezone.utc).isoformat(),actor=os.getenv('GITHUB_ACTOR','manual'),source_commit=os.getenv('GITHUB_SHA',''),workflow_run_id=os.getenv('GITHUB_RUN_ID',''),files=records)
 (destination/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf8')
 # Retire only this checkout's old completion receipt. The verified backup and
 # old remote package survive until the replacement capture commits successfully.
 receipt=base/f'{prefix}salarycapcomplete.csv'
 if receipt.exists():receipt.unlink()
 return manifest

if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--root',default='.');parser.add_argument('--season',required=True,type=int);parser.add_argument('--week',required=True,type=int);parser.add_argument('--backup-id',required=True);a=parser.parse_args();result=prepare(a.root,a.season,a.week,a.backup_id);print(f"Verified backup of {len(result['files'])} Week {a.week} files; ready for explicit recapture.")
