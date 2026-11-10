import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from check_automation_contracts import personal_sync_contract_errors
import json, subprocess
from unittest.mock import patch
import run_private_preflight as preflight

class PrivateAuditPolling(unittest.TestCase):
 def error(self, code):
  return subprocess.CalledProcessError(1, ['gh'], stderr=f'gh: error (HTTP {code})')
 def test_transient_status_reads(self):
  for code in (404,429,500,502,503,504):
   with self.subTest(code=code), patch.object(preflight.subprocess,'check_output',side_effect=self.error(code)):
    self.assertIsNone(preflight.read_state('123',True))
  with patch.object(preflight.subprocess,'check_output',side_effect=subprocess.TimeoutExpired('gh',30)):
   self.assertIsNone(preflight.read_state('123',False))
 def test_permanent_errors_and_expired_visibility_window_fail(self):
  for code,allow in ((401,True),(403,True),(404,False),(422,True)):
   with self.subTest(code=code), patch.object(preflight.subprocess,'check_output',side_effect=self.error(code)):
    with self.assertRaises(subprocess.CalledProcessError):preflight.read_state('123',allow)
 def test_404_then_success_dispatches_only_once(self):
  url=f'https://github.com/{preflight.REPO}/actions/runs/123'
  with patch.dict(preflight.os.environ,{'GITHUB_RUN_ID':'456'}), patch.object(preflight.subprocess,'check_output',side_effect=[url,self.error(404),json.dumps({'status':'completed','conclusion':'success'})]) as call, patch.object(preflight.time,'sleep'):
   preflight.run('contracts')
   self.assertEqual(sum(args.args[0][1]=='workflow' for args in call.call_args_list),1)
   self.assertEqual(call.call_args_list[1].args,call.call_args_list[2].args)
 def test_failed_child_is_not_hidden(self):
  with patch.dict(preflight.os.environ,{'GITHUB_RUN_ID':'456'}), patch.object(preflight.subprocess,'check_output',return_value=f'https://github.com/{preflight.REPO}/actions/runs/123'), patch.object(preflight,'read_state',return_value={'status':'completed','conclusion':'failure'}):
   with self.assertRaisesRegex(RuntimeError,'ended with failure'):preflight.run('contracts')
 def test_transient_errors_cannot_wait_forever(self):
  with patch.dict(preflight.os.environ,{'GITHUB_RUN_ID':'456'}), patch.object(preflight.subprocess,'check_output',return_value=f'https://github.com/{preflight.REPO}/actions/runs/123'), patch.object(preflight,'read_state',return_value=None), patch.object(preflight.time,'monotonic',side_effect=[0,0,0,421]), patch.object(preflight.time,'sleep'):
   with self.assertRaisesRegex(RuntimeError,'seven minutes'):preflight.run('contracts')
class PrivateContracts(unittest.TestCase):
 def test_private_handoff_and_private_scientific_gating_are_checked(self):
  public='gh workflow run sync_chi_team_tools.yml --repo TheMathNinja/Chicago-Bears-Lineup-Guardian'
  private="Check whether forecast inputs changed\nsteps.forecast.outputs.changed == 'true'\nsteps.forecast.outputs.changed == 'true'"
  self.assertEqual(personal_sync_contract_errors(public,private),[])
  self.assertTrue(personal_sync_contract_errors(public,'missing guard'))
  self.assertTrue(personal_sync_contract_errors('no private handoff',private))
 def test_live_model_publication_must_not_be_vetoed_by_local_cache(self):
  self.assertTrue(personal_sync_contract_errors('--repo TheMathNinja/Chicago-Bears-Lineup-Guardian','forecast-cache.outputs.cache-hit'))
if __name__=='__main__':unittest.main()
