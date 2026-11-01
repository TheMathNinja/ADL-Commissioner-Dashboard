import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from check_automation_contracts import personal_sync_contract_errors
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
