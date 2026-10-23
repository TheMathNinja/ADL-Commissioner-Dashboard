"""Validate cross-repository league automation contracts without live writes."""
from __future__ import annotations

import argparse
import ast
import re
import sys
from pathlib import Path


def workflow_inputs(path: Path) -> set[str]:
    lines = path.read_text(encoding="utf-8").splitlines()
    in_dispatch = False
    in_inputs = False
    found: set[str] = set()
    for line in lines:
        if re.fullmatch(r"  workflow_dispatch:\s*", line):
            in_dispatch = True
            in_inputs = False
            continue
        if in_dispatch and re.match(r"^  \S", line):
            break
        if in_dispatch and re.fullmatch(r"    inputs:\s*", line):
            in_inputs = True
            continue
        if in_inputs:
            match = re.match(r"^      ([A-Za-z_][\w-]*):\s*", line)
            if match:
                found.add(match.group(1))
            elif re.match(r"^    \S", line):
                in_inputs = False
    return found


def cloud_jobs(path: Path) -> list[tuple[str, str, set[str]]]:
    source = path.read_text(encoding="utf-8")
    jobs = []
    for match in re.finditer(r"\{repo:\s*'([^']+)'[^{}]*workflow:\s*'([^']+)'[^{}]*(?:inputs:\s*\{([^}]*)\})?[^{}]*\}", source):
        inputs = set(re.findall(r"([A-Za-z_][\w-]*)\s*:", match.group(3) or ""))
        jobs.append((match.group(1), match.group(2), inputs))
    return jobs


def shell_dispatches(root: Path, default_repo: str) -> list[tuple[Path, str, str, set[str]]]:
    found = []
    for path in list(root.glob(".github/workflows/*.yml")) + list(root.glob("scripts/*")):
        if not path.is_file():
            continue
        try:
            source = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        source = re.sub(r"\\\r?\n\s*", " ", source)
        for match in re.finditer(r"gh workflow run\s+([^\s]+)([^\n]*(?:\n\s+--[^\n]+)*)", source):
            workflow = match.group(1).strip("'\"")
            if "$" in workflow:
                continue
            tail = match.group(2)
            repo_match = re.search(r"--repo\s+([^\s]+)", tail)
            repo = repo_match.group(1).strip("'\"") if repo_match else default_repo
            inputs = set(re.findall(r"(?:^|\s)-f\s+([A-Za-z_][\w-]*)=", tail))
            found.append((path, repo.split("/")[-1], workflow, inputs))
    return found


def local_python_call_errors(root: Path) -> list[str]:
    errors = []
    for path in list(root.glob("scripts/*.py")) + list(root.glob("tests/*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        definitions = {
            node.name: node
            for node in tree.body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        }
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Name):
                continue
            definition = definitions.get(node.func.id)
            if not definition or definition.args.vararg:
                continue
            positional = len(definition.args.posonlyargs) + len(definition.args.args)
            required = positional - len(definition.args.defaults)
            if any(isinstance(arg, ast.Starred) for arg in node.args):
                continue
            supplied = len(node.args)
            if supplied < required or supplied > positional:
                errors.append(
                    f"{path}:{node.lineno}: {node.func.id} expects {required}..{positional} positional args, got {supplied}"
                )
    return errors


def unittest_module_errors(repo: str, root: Path) -> list[str]:
    errors = []
    for path in root.glob(".github/workflows/*.yml"):
        source = path.read_text(encoding="utf-8")
        for match in re.finditer(r"python(?:3)?\s+-m\s+unittest\s+([^\n]+)", source):
            command = match.group(1).split("#", 1)[0]
            modules = re.findall(r"\b(?:tests|scripts)(?:\.[A-Za-z_][A-Za-z0-9_]*)+\b", command)
            for module in modules:
                target = root.joinpath(*module.split(".")).with_suffix(".py")
                if not target.exists():
                    errors.append(
                        f"{repo}/{path.relative_to(root)} invokes missing unittest module {module}"
                    )
    return errors


def function_signatures(path: Path) -> dict[str, tuple]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    signatures = {}
    for node in tree.body:
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        args = node.args
        signatures[node.name] = (
            tuple(arg.arg for arg in args.posonlyargs),
            tuple(arg.arg for arg in args.args),
            len(args.defaults),
            args.vararg.arg if args.vararg else None,
            tuple(arg.arg for arg in args.kwonlyargs),
            tuple(default is not None for default in args.kw_defaults),
            args.kwarg.arg if args.kwarg else None,
        )
    return signatures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", action="append", required=True, metavar="NAME=PATH")
    args = parser.parse_args()
    roots = {}
    for item in args.repo:
        name, raw_path = item.split("=", 1)
        roots[name] = Path(raw_path).resolve()

    required = {"ADL-GM-Dashboard", "FAFL-GM-Dashboard", "ADL-Commissioner-Dashboard", "Chicago-Bears-Lineup-Guardian"}
    errors = []
    if set(roots) != required:
        errors.append(f"Expected repositories {sorted(required)}, got {sorted(roots)}")

    workflows: dict[tuple[str, str], set[str]] = {}
    for repo, root in roots.items():
        for path in root.glob(".github/workflows/*.yml"):
            try:
                path.read_text(encoding="utf-8")
            except UnicodeDecodeError as exc:
                errors.append(f"{repo}/{path.relative_to(root)} is not UTF-8: {exc}")
                continue
            workflows[(repo, path.name)] = workflow_inputs(path)
            if "runs-on: ubuntu-latest" in path.read_text(encoding="utf-8"):
                errors.append(
                    f"{repo}/{path.relative_to(root)} uses moving ubuntu-latest instead of pinned ubuntu-24.04"
                )
        errors.extend(local_python_call_errors(root))
        errors.extend(unittest_module_errors(repo, root))

    commissioner = roots.get("ADL-Commissioner-Dashboard")
    if commissioner:
        r_setup = commissioner / ".github" / "actions" / "setup-adl-r" / "action.yml"
        r_setup_source = r_setup.read_text(encoding="utf-8")
        if "install-r: false" not in r_setup_source:
            errors.append("Shared ADL R setup must reuse the pinned runner's preinstalled R")

        scheduler = commissioner / "scripts" / "CloudPolling.gs"
        source = scheduler.read_text(encoding="utf-8")
        expectations = {
            "five-minute scheduler cadence": "intervalMinutes: 5",
            "6:57 a.m. watchdog": "hour: 6, minute: 57",
            "bounded dispatch retries": "for (let attempt = 0; attempt < 4; attempt++)",
            "polling circuit breaker": "cloudPollingCircuitOpen_",
            "in-flight polling suppression": "cloudWorkflowInFlight_",
            "complete fixed-slot recovery scan": "Search the complete recovery window",
        }
        for label, marker in expectations.items():
            if marker not in source:
                errors.append(f"Canonical CloudPolling.gs is missing {label}")
        for repo, workflow, inputs in cloud_jobs(scheduler):
            declared = workflows.get((repo, workflow))
            if declared is None:
                errors.append(f"Cloud scheduler targets missing workflow {repo}/{workflow}")
            elif not inputs <= declared:
                errors.append(
                    f"Cloud scheduler sends undeclared inputs to {repo}/{workflow}: {sorted(inputs - declared)}"
                )
        for owned in ("email_weekly_completion.py", "email_workflow_failures.py"):
            if not (commissioner / "scripts" / owned).exists():
                errors.append(f"Commissioner-owned script is missing: scripts/{owned}")

    for repo, root in roots.items():
        if repo != "ADL-Commissioner-Dashboard" and (root / "scripts" / "CloudPolling.gs").exists():
            errors.append(f"{repo} contains a second CloudPolling.gs; scheduler ownership must remain singular")
        if repo != "ADL-Commissioner-Dashboard":
            for owned in ("email_weekly_completion.py", "email_workflow_failures.py"):
                if (root / "scripts" / owned).exists():
                    errors.append(f"{repo} contains Commissioner-owned scripts/{owned}")
        for path, target_repo, workflow, inputs in shell_dispatches(root, repo):
            declared = workflows.get((target_repo, workflow))
            if declared is None:
                errors.append(f"{repo}/{path.relative_to(root)} dispatches missing {target_repo}/{workflow}")
            elif not inputs <= declared:
                errors.append(
                    f"{repo}/{path.relative_to(root)} sends undeclared inputs to {target_repo}/{workflow}: "
                    f"{sorted(inputs - declared)}"
                )

    guardian = roots.get("Chicago-Bears-Lineup-Guardian")
    if guardian:
        for workflow in ("guardian.yml", "initial-lineup.yml"):
            source = (guardian / ".github" / "workflows" / workflow).read_text(encoding="utf-8")
            if "Suppress overlapping native backup run" not in source or "--event workflow_dispatch" not in source:
                errors.append(f"Lineup Guardian {workflow} lacks cloud/native scheduler collision suppression")

    adl = roots.get("ADL-GM-Dashboard")
    fafl = roots.get("FAFL-GM-Dashboard")
    if adl and fafl:
        for filename in ("score_readiness.py", "score_corrections.py", "apps_script_bridge.py"):
            left = function_signatures(adl / "scripts" / filename)
            right = function_signatures(fafl / "scripts" / filename)
            for name in sorted(left.keys() & right.keys()):
                if left[name] != right[name]:
                    errors.append(f"ADL/FAFL signature drift in {filename}:{name}")

        self_trigger_guards = {
            adl / ".github/workflows/rebuild_playoff_model.yml": (
                "data/adl_scoring_model.json",
                "data/player_strength/**",
            ),
            fafl / ".github/workflows/rebuild_bonus_games.yml": (
                "data/fafl_scoring_model.json",
                "data/forward_bye_exposure.csv",
            ),
        }
        for path, generated_outputs in self_trigger_guards.items():
            source = path.read_text(encoding="utf-8")
            for output in generated_outputs:
                if re.search(r"^\s*-\s*['\"]?" + re.escape(output) + r"['\"]?\s*$", source, re.MULTILINE):
                    errors.append(
                        f"{path.relative_to(path.parents[2])} watches generated output {output} and can trigger itself"
                    )

        chi_sync = (adl / ".github/workflows/sync_chi_team_tools.yml").read_text(encoding="utf-8")
        if "Check whether forecast inputs changed" not in chi_sync or chi_sync.count(
            "steps.forecast.outputs.changed == 'true' && steps.forecast-cache.outputs.cache-hit != 'true'"
        ) < 2:
            errors.append("CHI sync must skip scientific dependency setup when forecast inputs are unchanged")

    if errors:
        print("Automation contract audit failed:")
        for error in errors:
            print(f"- {error}")
        return 1
    print(f"Automation contracts verified across {len(roots)} repositories and {len(workflows)} workflows.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
