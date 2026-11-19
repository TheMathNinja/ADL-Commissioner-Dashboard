"""Regression guard for the cross-provider Raiders kickoff failure."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from nfl_teams import CONTRACT, MFL_TEAMS, mfl_team, provider_team
from check_nfl_team_codes import alias_lines, audit_team_contracts, REPOS


class TeamIdentityTests(unittest.TestCase):
    def test_all_32_and_every_alias(self):
        self.assertEqual(len(MFL_TEAMS), 32)
        for team in MFL_TEAMS:
            self.assertEqual(len(team), 3)
            self.assertEqual(mfl_team(team, strict=True), team)
            for provider in CONTRACT['providers']:
                self.assertEqual(mfl_team(provider_team(team, provider), strict=True), team)
        for alias, team in CONTRACT['aliases'].items():
            self.assertEqual(mfl_team(' ' + alias.lower() + ' ', strict=True), team)
        self.assertEqual(mfl_team('JAX'), 'JAC')
        self.assertEqual(mfl_team('LV'), 'LVR')

    def test_missing_and_unknown_are_not_invented(self):
        self.assertIsNone(mfl_team(None))
        self.assertEqual(mfl_team('FA', strict=True), 'FA')
        with self.assertRaises(ValueError):
            mfl_team('XYZ', strict=True)

    def test_new_nonstandard_literals_are_detected(self):
        with tempfile.TemporaryDirectory() as folder:
            for suffix, code in [('.py', 'player_team = "LV"'), ('.R', 'player_team <- "GB"'),
                                 ('.js', 'const playerTeam = "JAX";')]:
                path = Path(folder) / ('new_tool' + suffix)
                path.write_text(code)
                self.assertEqual(len(alias_lines(path, CONTRACT['aliases'])), 1)

    def test_dictionary_drift_and_new_tool_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            roots = {name: Path(folder) / str(i) for i, name in enumerate(REPOS)}
            for name, root in roots.items():
                for relative in ('config/nfl_teams.json', 'scripts/nfl_teams.py', 'R/nfl_teams.R'):
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text((ROOT / relative).read_text())
            self.assertEqual(audit_team_contracts(roots), [])
            target = roots[REPOS[2]]
            (target / 'scripts/new_tool.py').write_text('team = "LV"')
            self.assertTrue(any('new_tool.py' in x for x in audit_team_contracts(roots)))
            (target / 'scripts/new_tool.py').unlink()
            contract = dict(CONTRACT, version=99)
            (target / 'config/nfl_teams.json').write_text(json.dumps(contract))
            self.assertTrue(any('dictionary drift' in x for x in audit_team_contracts(roots)))

    def test_release_gate_includes_identity_guard(self):
        self.assertIn('errors.extend(audit_team_contracts(roots))',
                      (ROOT / 'scripts/check_automation_contracts.py').read_text())
        self.assertIn('test_nfl_team_codes.py', (ROOT / 'scripts/check_email_delivery.py').read_text())

    def test_hosted_r_app_includes_team_dictionary(self):
        guardian = Path(__import__('os').environ.get('GUARDIAN_TEST_ROOT', str(ROOT.parent / 'guardian')))
        adl = guardian.parent / 'adl'
        self.assertIn('"config/nfl_teams.json"', (adl / 'scripts/deploy_shinyapps.R').read_text())


if __name__ == '__main__':
    unittest.main()
