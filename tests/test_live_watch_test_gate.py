from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
from check_live_watch_tests import test_commands


class WatchTestGate(unittest.TestCase):
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
