"""Canonical NFL team identities; provider aliases belong only at I/O boundaries."""
import json
from pathlib import Path

CONTRACT = json.loads((Path(__file__).resolve().parents[1] / "config/nfl_teams.json").read_text())
MFL_TEAMS = frozenset(CONTRACT["teams"])
TEAM_ALIASES = CONTRACT["aliases"]


def mfl_team(value, *, strict=False):
    if value is None:
        return None
    raw = str(value).strip().upper()
    result = TEAM_ALIASES.get(raw, raw)
    if strict and result not in MFL_TEAMS and result not in CONTRACT["sentinels"]:
        raise ValueError("Unknown NFL team code: " + result)
    return result


def provider_team(value, provider):
    result = mfl_team(value, strict=True)
    return CONTRACT["providers"][provider].get(result, result)
