"""Keep runtime dependency validation wired into every shared R setup."""
from email.parser import Parser
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]


class RDependencyContract(unittest.TestCase):
    def test_shared_email_dependency_is_installed(self):
        description = Parser().parsestr((ROOT / 'DESCRIPTION').read_text())
        imports = {value.strip() for value in description['Imports'].split(',')}
        self.assertIn('digest', imports)

    def test_runtime_and_release_guard_stay_wired(self):
        action = yaml.safe_load((ROOT / '.github/actions/setup-adl-r/action.yml').read_text())
        steps = action['runs']['steps']
        install = next(i for i, step in enumerate(steps) if step['name'] == 'Install and verify R packages')
        guard = next(i for i, step in enumerate(steps) if step.get('run', '').strip() == 'Rscript tests/test_r_dependencies.R')
        self.assertGreater(guard, install)
        self.assertTrue((ROOT / 'tests/test_r_dependencies.R').is_file())
        release = (ROOT / 'scripts/check_email_delivery.py').read_text()
        self.assertIn("'test_r_dependency_contract.py'", release)


if __name__ == '__main__':
    unittest.main()
