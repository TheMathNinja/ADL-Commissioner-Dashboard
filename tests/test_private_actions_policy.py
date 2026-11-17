from pathlib import Path
import sys
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from private_actions_policy import paused, VARIABLE


class PolicyTests(unittest.TestCase):
    def test_absent_enabled_and_paused(self):
        for value, expected in (([], False), ([{'name': VARIABLE, 'value': 'enabled'}], False),
                                ([{'name': VARIABLE, 'value': 'paused'}], True)):
            self.assertEqual(paused(Mock(return_value={'variables': value})), expected)

    def test_incomplete_or_failed_policy_read_cannot_authorize_spending(self):
        with self.assertRaises(RuntimeError):
            paused(Mock(return_value={'total_count': 101, 'variables': []}))
        with self.assertRaises(OSError):
            paused(Mock(side_effect=OSError('unavailable')))

    def test_policy_does_not_gate_required_check_or_independent_monitors(self):
        root = Path(__file__).resolve().parents[1]
        for name in ('guardian_fallback.py', 'guardian_health_monitor.py'):
            self.assertNotIn('private_actions_policy', (root / 'scripts' / name).read_text())
        for name in ('guardian_fallback.yml',):
            self.assertNotIn('PRIVATE_DISCRETIONARY_ACTIONS', (root / '.github/workflows' / name).read_text())
        reporter = (root / '.github/workflows/email_workflow_failures.yml').read_text()
        self.assertIn('PRIVATE_DISCRETIONARY_ACTIONS: ${{ vars.PRIVATE_DISCRETIONARY_ACTIONS }}', reporter)
        self.assertNotIn("if: vars.PRIVATE_DISCRETIONARY_ACTIONS", reporter)


if __name__ == '__main__':
    unittest.main()
