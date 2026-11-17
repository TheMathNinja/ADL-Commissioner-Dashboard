import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("contracts", Path(__file__).resolve().parents[1] / "scripts/check_automation_contracts.py")
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)


class GuardianCollisionContractTests(unittest.TestCase):
    def diagnostic_source(self):
        return '''concurrency:
  group: ${{ inputs.verify_test_cache && format('guardian-readonly-{0}', github.run_id) || vars.GUARDIAN_PRECISION_OWNER == 'public-scheduler-v2' && startsWith(inputs.dispatch_id, 'gas-') && format('retired-gas-{0}', github.run_id) || 'lineup-guardian-writes' }}
  cancel-in-progress: false
jobs:
  guardian:
    if: !(vars.GUARDIAN_PRECISION_OWNER == 'public-scheduler-v2' && startsWith(inputs.dispatch_id, 'gas-'))
    steps:
      - uses: actions/checkout@v5
      - name: Check configuration
        run: |
          if [[ "${{ inputs.verify_test_cache }}" == "true" ]]; then
            echo "ready=false" >> "$GITHUB_OUTPUT"
          elif [[ -n "$MFL_USERNAME" ]]; then
            echo "ready=true" >> "$GITHUB_OUTPUT"
          fi
      - if: steps.configured.outputs.ready == 'true'
        run: npm run check
      - name: Archive exact roster checks
        if: always() && !inputs.verify_test_cache
        uses: actions/upload-artifact@v6
'''

    def test_only_verified_readonly_steps_can_use_an_isolated_queue(self):
        source = self.diagnostic_source()
        self.assertEqual(contracts.guardian_collision_errors({'guardian.yml': source}), [])
        for changed in (source.replace('echo "ready=false"', 'echo "ready=true"'),
                        source.replace("        if: always() && !inputs.verify_test_cache\n", ''),
                        source + '      - name: Accidental ungated writer\n        run: send-email\n',
                        source.replace("|| 'lineup-guardian-writes'", "|| 'different-group'")):
            self.assertTrue(contracts.guardian_collision_errors({'guardian.yml': changed}))
        self.assertTrue(contracts.guardian_collision_errors({'initial-lineup.yml': source}))

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
