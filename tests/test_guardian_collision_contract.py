import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("contracts", Path(__file__).resolve().parents[1] / "scripts/check_automation_contracts.py")
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)


class GuardianCollisionContractTests(unittest.TestCase):
    def test_shared_non_cancelling_queue_is_accepted(self):
        source = "concurrency:\n  group: lineup-guardian-writes\n  cancel-in-progress: false\n\npermissions:\n  contents: write\n"
        self.assertEqual(contracts.guardian_collision_errors({"guardian.yml": source, "initial-lineup.yml": source}), [])

    def test_separate_groups_and_cancellation_are_rejected(self):
        source = "concurrency:\n  group: lineup-guardian-initial\n  cancel-in-progress: true\n"
        self.assertEqual(len(contracts.guardian_collision_errors({"initial-lineup.yml": source})), 2)

    def test_obsolete_step_names_do_not_satisfy_contract(self):
        source = "# Suppress overlapping native backup run --event workflow_dispatch\n"
        self.assertEqual(len(contracts.guardian_collision_errors({"guardian.yml": source})), 2)


if __name__ == "__main__":
    unittest.main()
