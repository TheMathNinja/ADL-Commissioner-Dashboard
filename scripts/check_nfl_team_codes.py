"""Offline NFL identity contract: no credentials, live feeds or cloud runners."""
from __future__ import annotations
import argparse
import ast
import json
from pathlib import Path
import re

REPOS = ("ADL-Commissioner-Dashboard", "ADL-GM-Dashboard", "FAFL-GM-Dashboard", "Chicago-Bears-Lineup-Guardian")
SOURCE_DIRS = ("R", "scripts", "src", "scheduler", "www", ".github", "docs/assets")
SUFFIXES = {".R", ".r", ".py", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".gs", ".html"}
QUOTED = re.compile(r"(['\"])([^'\"\n]*?)\1")


def source_files(root):
    paths = set()
    for folder in SOURCE_DIRS:
        directory = root / folder
        if directory.exists():
            paths.update(p for p in directory.rglob("*") if p.is_file() and p.suffix in SUFFIXES
                         and not any(x in p.parts for x in ("node_modules", "__pycache__", "fixtures")))
    paths.update(p for p in root.iterdir() if p.is_file() and p.suffix in SUFFIXES)
    return sorted(paths)


def alias_lines(path, aliases):
    text = path.read_text(encoding="utf-8-sig")
    lines = text.splitlines()
    hits = set()
    if path.suffix == ".py":
        tree = ast.parse(text, filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and node.value in aliases:
                hits.add(node.lineno)
    else:
        for number, line in enumerate(lines, 1):
            if line.lstrip().startswith(("#", "//", "*")):
                continue
            if any(m.group(2) in aliases for m in QUOTED.finditer(line)):
                hits.add(number)
    return [(number, lines[number - 1].strip()) for number in sorted(hits)]


def audit_team_contracts(roots):
    canonical = roots.get(REPOS[0])
    if not canonical:
        return ["MFL team audit requires Commissioner source"]
    errors = []
    contract = json.loads((canonical / "config/nfl_teams.json").read_text())
    teams, aliases = contract["teams"], contract["aliases"]
    if len(teams) != 32 or len(set(teams)) != 32 or any(not re.fullmatch("[A-Z]{3}", t) for t in teams):
        errors.append("MFL dictionary must contain 32 unique three-letter NFL teams")
    if any(a in teams or t not in teams for a, t in aliases.items()):
        errors.append("MFL alias dictionary has invalid targets or ambiguous keys")
    for provider, mapping in contract["providers"].items():
        if len({mapping.get(t, t) for t in teams}) != 32 or set(mapping) - set(teams):
            errors.append("Provider conversion is not a bijection: " + provider)
    for name, root in roots.items():
        manifest = root / "config/nfl_teams.json"
        if not manifest.is_file() or json.loads(manifest.read_text()) != contract:
            errors.append(name + ": MFL dictionary drift; synchronize the reviewed shared contract")
            continue
        helper = root / "scripts/nfl_teams.py"
        if not helper.is_file() or helper.read_text() != (canonical / "scripts/nfl_teams.py").read_text():
            errors.append(name + ": shared Python team normalizer drift")
        allow_path = root / "config/nfl_team_boundaries.json"
        approved = json.loads(allow_path.read_text()) if allow_path.is_file() else []
        seen = set()
        for path in source_files(root):
            relative = path.relative_to(root).as_posix()
            if path.name.startswith(("test_", "test-")) or ".test." in path.name:
                continue
            for number, line in alias_lines(path, aliases):
                match = next((i for i, item in enumerate(approved)
                              if item["file"] == relative and item["line"] == line and item.get("reason")), None)
                if match is None:
                    errors.append(f"{name}/{relative}:{number}: nonstandard NFL literal; use nfl_teams or document an exact boundary: {line}")
                else:
                    seen.add(match)
        for i, item in enumerate(approved):
            if i not in seen:
                errors.append(name + ": obsolete team-code exception: " + item["file"])
    for name in REPOS[:2]:
        if name in roots and (roots[name] / "R/nfl_teams.R").read_text() != (canonical / "R/nfl_teams.R").read_text():
            errors.append(name + ": shared R team normalizer drift")
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", action="append", default=[])
    parser.add_argument("--inventory", action="store_true")
    args = parser.parse_args()
    roots = {name: Path(path).resolve() for name, path in (s.split("=", 1) for s in args.repo)}
    if args.inventory:
        for name, root in roots.items():
            contract = json.loads((root / "config/nfl_teams.json").read_text())
            for path in source_files(root):
                if path.name.startswith(("test_", "test-")) or ".test." in path.name:
                    continue
                for number, line in alias_lines(path, contract["aliases"]):
                    print(json.dumps(dict(repo=name, file=path.relative_to(root).as_posix(), number=number, line=line)))
        return 0
    errors = audit_team_contracts(roots)
    if errors:
        print("\n".join(errors))
        return 1
    print("MFL NFL team identities verified across " + str(len(roots)) + " repositories.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
