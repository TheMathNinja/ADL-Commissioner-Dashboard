import unittest,tempfile,hashlib,json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent));sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from prepare_cap_snapshot_overwrite import prepare
from restore_cap_snapshot_backup import restore

class RestoreTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent);self.root=Path(self.tmp.name);self.base=self.root/'data/cap_accounting/2026'
  self.names=['snapshots/2026w8_ADLsalarycapsnapshot.csv','snapshots/2026w8_ADLsalarycapsnapshot.rds','summaries/2026w8_ADLsalarycapsummary.csv','summaries/2026w8_ADLsalarycapsummary.rds','2026w8_ADLsalarycapmetadata.csv','2026w8_ADLsalarycapcomplete.csv']
  for name in self.names:p=self.base/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('original-'+name)
  prepare(self.root,2026,8,'original')
  for name in self.names:(self.base/name).write_text('second-'+name)
 def tearDown(self):self.tmp.cleanup()
 def test_restore_with_verified_backup_of_second_run(self):
  result=restore(self.root,2026,8,'original','late-entries','run1')
  self.assertEqual(result['restored'],6)
  for name in self.names:
   self.assertEqual((self.base/name).read_text(),'original-'+name)
   self.assertEqual((self.base/'manual_overwrites/week-08/before-restore-run1'/name).read_text(),'second-'+name)
 def test_rerun_does_not_erase_already_logged_corrections(self):
  (self.base/'manual_cap_corrections.csv').write_text('season,week,key,franchise,amount\n2026,8,late-entries,DAL,4.79\n')
  result=restore(self.root,2026,8,'original','late-entries','run1');self.assertTrue(result['already_applied']);self.assertTrue((self.base/self.names[2]).read_text().startswith('second'))
 def test_tampering_fails_before_any_replacement(self):
  (self.base/'manual_overwrites/week-08/original'/self.names[0]).write_text('corrupt')
  with self.assertRaises(ValueError):restore(self.root,2026,8,'original','late-entries','run1')
  self.assertTrue((self.base/self.names[0]).read_text().startswith('second'))
 def test_wrong_backup_path_is_rejected(self):
  with self.assertRaises(ValueError):restore(self.root,2026,8,'../original','late-entries','run1')

if __name__=='__main__':unittest.main()
