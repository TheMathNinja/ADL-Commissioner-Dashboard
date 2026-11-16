from pathlib import Path
import sys
import unittest
import json
import tempfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
from check_live_watch_tests import test_commands
from sync_live_display_contract import synchronize, read_contract, generated_policy


class WatchTestGate(unittest.TestCase):
    def test_reviewed_contract_propagates_settings_and_examples_together(self):
        contract=read_contract()
        with tempfile.TemporaryDirectory() as directory:
            repo=Path(directory)
            asset=repo/'docs/assets/bonus-live-watch.js';asset.parent.mkdir(parents=True)
            asset.write_text('before\n // BEGIN GENERATED LIVE DISPLAY POLICY\nstale\n // END GENERATED LIVE DISPLAY POLICY\nafter',encoding='utf-8')
            with self.assertRaisesRegex(ValueError,'drift'):synchronize(repo,contract)
            synchronize(repo,contract,write=True)
            synchronize(repo,contract)
            self.assertTrue(asset.read_text().startswith('before\n'))
            self.assertTrue(asset.read_text().endswith('\nafter'))
            self.assertIn(generated_policy(contract),asset.read_text())
            fixture=repo/'tests/fixtures/live_display_contract.json'
            self.assertEqual(json.loads(fixture.read_text()),contract)
            changed=json.loads(json.dumps(contract));changed['policyVersion']='test-next'
            changed['policy']['lowLabel']='reviewed-new-label'
            changed['probabilities'][3]['expected']='reviewed-new-label'
            with self.assertRaisesRegex(ValueError,'drift'):synchronize(repo,changed)
            synchronize(repo,changed,write=True)
            synchronize(repo,changed)
            self.assertIn('reviewed-new-label',asset.read_text())
            self.assertEqual(json.loads(fixture.read_text()),changed)
            changed['policy']['tieMinimumExclusive']=0.02
            with self.assertRaisesRegex(ValueError,'version|Version'):
                synchronize(repo,changed,write=True)

    def test_missing_or_ambiguous_generated_region_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            repo=Path(directory);asset=repo/'docs/assets/bonus-live-watch.js';asset.parent.mkdir(parents=True)
            for source in ['no markers',' // BEGIN GENERATED LIVE DISPLAY POLICY\n // BEGIN GENERATED LIVE DISPLAY POLICY\n // END GENERATED LIVE DISPLAY POLICY']:
                asset.write_text(source,encoding='utf-8')
                with self.assertRaisesRegex(ValueError,'ambiguous'):synchronize(repo,read_contract(),write=True)
                self.assertEqual(asset.read_text(),source)

    def commands(self, script):
        with patch('check_live_watch_tests.yaml.safe_load', return_value={
                'jobs': {'watch': {'steps': [{'run': script}]}}}), patch.object(Path, 'read_text', return_value=''):
            return test_commands(Path('repo'))

    def test_only_tests_are_executed_in_declared_order(self):
        commands = self.commands('python3 -m unittest discover -s tests -p test_live_bonus.py -v\n'
                                 'node tests/test_live_windows.cjs\n'
                                 'python3 scripts/collect_live_bonus.py --league ADL\n'
                                 'git push origin main')
        self.assertEqual(len(commands), 2)
        self.assertEqual(commands[0][0], sys.executable)
        self.assertEqual(commands[1], ['node', 'tests/test_live_windows.cjs'])

    def test_invalid_or_empty_test_list_fails_closed(self):
        for script in ('echo no tests', 'node tests/../../publish.cjs',
                       'node tests/test_live.cjs && git push',
                       'python3 -m unittest discover -s tests -p ../other.py'):
            with self.subTest(script=script), self.assertRaises(ValueError):
                self.commands(script)
