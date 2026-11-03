import tempfile,unittest,json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from prepare_cap_snapshot_overwrite import prepare

class OverwriteTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent);self.root=Path(self.temp.name);self.base=self.root/'data/cap_accounting/2026'
  for name in ['snapshots/2026w8_ADLsalarycapsnapshot.csv','snapshots/2026w8_ADLsalarycapsnapshot.rds','summaries/2026w8_ADLsalarycapsummary.csv','2026w8_ADLsalarycapmetadata.csv','2026w8_ADLsalarycapcomplete.csv','snapshots/2026w7_ADLsalarycapsnapshot.csv','manual_cap_corrections.csv']:
   p=self.base/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(name.encode())
 def tearDown(self):self.temp.cleanup()
 def test_backup_verified_and_other_weeks_untouched(self):
  before={p.relative_to(self.base).as_posix():p.read_bytes() for p in self.base.rglob('*') if p.is_file()};result=prepare(self.root,2026,8,'run-1')
  self.assertEqual(len(result['files']),5)
  for row in result['files']:self.assertEqual((self.base/'manual_overwrites/week-08/run-1'/row['path']).read_bytes(),before[row['path']])
  self.assertFalse((self.base/'2026w8_ADLsalarycapcomplete.csv').exists());self.assertEqual((self.base/'snapshots/2026w7_ADLsalarycapsnapshot.csv').read_bytes(),before['snapshots/2026w7_ADLsalarycapsnapshot.csv']);self.assertEqual((self.base/'manual_cap_corrections.csv').read_bytes(),before['manual_cap_corrections.csv'])
 def test_rejects_reusing_backup(self):
  prepare(self.root,2026,8,'run-1')
  with self.assertRaises(ValueError):prepare(self.root,2026,8,'run-1')
 def test_rejects_path_escape(self):
  with self.assertRaises(ValueError):prepare(self.root,2026,8,'../escape')
 def test_rejects_overwriting_earlier_week_without_propagation(self):
  (self.base/'2026w9_ADLsalarycapmetadata.csv').write_text('later')
  with self.assertRaises(ValueError):prepare(self.root,2026,8,'run-1')
 def test_missing_snapshot_leaves_existing_files_untouched(self):
  with self.assertRaises(ValueError):prepare(self.root,2026,6,'run-1')
  self.assertTrue((self.base/'2026w8_ADLsalarycapcomplete.csv').exists())

if __name__=='__main__':unittest.main()
