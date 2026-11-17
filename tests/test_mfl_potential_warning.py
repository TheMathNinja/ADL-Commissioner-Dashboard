import sys
import unittest
from pathlib import Path
from unittest.mock import Mock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from mfl_potential_warning import report_warning

class WarningEmailTests(unittest.TestCase):
    def test_sends_once_per_changed_observation_and_dry_run_does_not_send(self):
        report=dict(policy='mfl-potential-warning-v1',league='ADL',season=2026,through_week=10,status='warning',observations=[dict(week=10,franchise_id='0001',points=200,potential=190)])
        state={'sent':{}};send=Mock();save=Mock()
        deliver=lambda state,key,action,persist: action()
        args=(state,False,lambda *a:report,deliver,save,send)
        report_warning(*args);report_warning(*args)
        self.assertEqual(send.call_count,1)
        report['observations'][0]['potential']=191
        report_warning(state,True,args[2],deliver,save,send)
        self.assertEqual(send.call_count,1)
        report_warning(*args)
        self.assertEqual(send.call_count,2)
        report['status']='clear';report_warning(*args)
        self.assertEqual(send.call_count,2)
