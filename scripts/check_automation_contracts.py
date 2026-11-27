"""Validate cross-repository league automation contracts without live writes."""
from __future__ import annotations

import argparse
import ast
import json
import re
import subprocess
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


def payout_publication_errors(adl: Path, fafl: Path) -> list[str]:
    """Require the shared payout builder and a native publication in both leagues."""
    errors = []
    builder = "scripts/build_payouts.py"
    if not all((root / builder).is_file() for root in (adl, fafl)):
        return ["Both GM dashboards must include the native payout builder"]
    if (adl / builder).read_bytes() != (fafl / builder).read_bytes():
        errors.append("ADL and FAFL must use the same native payout calculations")
    for league, root, workflow in (
        ("ADL", adl, "refresh_extension_calculator.yml"),
        ("FAFL", fafl, "refresh.yml"),
    ):
        source = (root / ".github/workflows" / workflow).read_text(encoding="utf-8")
        if f"{builder} --league {league}" not in source or "scripts/sync_payouts.py" in source:
            errors.append(f"{league} official refresh must build payouts without writing to Google Sheets")
        for path in ("config/payouts.json", "docs/payouts/index.html", "docs/payouts/payouts-data.json",
                     "tests/test_native_payouts.py"):
            if not (root / path).is_file():
                errors.append(f"{league} is missing {path}")
        result = subprocess.run(
            [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_native_payouts.py"],
            cwd=root, capture_output=True, text=True,
        )
        if result.returncode:
            errors.append(f"{league} payout contract tests failed:\n{result.stderr}")
    return errors


def playoff_browser_errors(adl: Path, fafl: Path) -> list[str]:
    dependency = 'requirements-playoff-browser.txt'
    locks = [root / dependency for root in (adl, fafl)]
    if not all(lock.is_file() for lock in locks):
        return ['Both weekly refreshes must have a Playoff Picture browser dependency lock']
    pins = [lock.read_text(encoding='utf-8').strip() for lock in locks]
    errors = []
    if pins[0] != pins[1] or not re.fullmatch(r'playwright==\d+\.\d+\.\d+', pins[0]):
        errors.append('ADL and FAFL must use the same exact Playwright pin')
    setup = 'scripts/prepare_playoff_browser.py'
    installers = [root / setup for root in (adl, fafl)]
    if not all(path.is_file() for path in installers) or len({path.read_text(encoding='utf-8') for path in installers}) != 1:
        errors.append('ADL and FAFL must use the same launch-tested headless Chromium installer')
    for root, workflow in ((adl, 'refresh_extension_calculator.yml'), (fafl, 'refresh.yml')):
        source = (root / '.github/workflows' / workflow).read_text(encoding='utf-8')
        steps = re.split(r'^      - ', source, flags=re.MULTILINE)
        browser = next((i for i, step in enumerate(steps) if 'id: playoff_browser' in step), -1)
        elo = next((i for i, step in enumerate(steps) if 'id: elo' in step), -1)
        local = 'run: python scripts/check_playoff_picture_browser.py'
        generated = next((i for i, step in enumerate(steps) if local + '\n' in step), -1)
        published = next((i for i, step in enumerate(steps) if local + ' --live-url ' in step), -1)
        if (not 0 < browser < elo < generated < published
                or ('pip install -r ' + dependency) not in steps[browser]
                or ('python ' + setup) not in steps[browser]):
            errors.append(f'{workflow} must install the shared browser before live Elo writes and verify generated and published pages')
    result = subprocess.run(
        [sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-p', 'test_prepare_playoff_browser.py'],
        cwd=adl, capture_output=True, text=True)
    if result.returncode or 'Ran 0 tests' in result.stderr:
        errors.append('Headless browser setup regression suite did not pass:\n' + result.stderr)
    return errors


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
        try:
            source = path.read_text(encoding="utf-8")
        except UnicodeDecodeError as error:
            errors.append(f"{repo}/{path.relative_to(root).as_posix()} is not UTF-8 at byte {error.start}")
            continue
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


def guardian_diagnostic_steps_guarded(source: str) -> bool:
    """Only the explicitly read-only path may bypass live-write serialization."""
    jobs = source.split('\njobs:', 1)[-1]
    if re.findall(r'^  ([\w-]+):\s*$', jobs, re.MULTILINE) != ['guardian']:
        return False
    steps = re.split(r'(?=^      - )', jobs, flags=re.MULTILINE)[1:]
    configured = False
    for step in steps:
        if re.search(r'^      - name: Check configuration\s*$', step, re.MULTILINE):
            first_branch = step.split('elif', 1)[0]
            configured = ('if [[ "${{ inputs.verify_test_cache }}" == "true" ]]; then' in first_branch
                          and 'echo "ready=false"' in first_branch)
            continue
        if re.search(r'uses: (?:actions/(?:checkout|setup-node)@|\./\.github/actions/verified-guardian-tests\s*$)', step, re.MULTILINE):
            continue
        guard = re.search(r'^(?:        |      - )if: (.+)$', step, re.MULTILINE)
        if not guard or guard[1] not in ("steps.configured.outputs.ready == 'true'",
                "always() && steps.configured.outputs.ready == 'true'", 'always() && !inputs.verify_test_cache'):
            return False
    return configured


def guardian_collision_errors(sources: dict[str, str]) -> list[str]:
    errors = []
    for workflow, source in sources.items():
        block = re.search(r"^concurrency:\s*\n((?:[ \t]+[^\n]*\n|\n)+)", source, re.MULTILINE)
        settings = block.group(1) if block else ""
        retired_group = "  group: ${{ vars.GUARDIAN_PRECISION_OWNER == 'public-scheduler-v2' && startsWith(inputs.dispatch_id, 'gas-') && format('retired-gas-{0}', github.run_id) || 'lineup-guardian-writes' }}"
        retired_guard = "!(vars.GUARDIAN_PRECISION_OWNER == 'public-scheduler-v2' && startsWith(inputs.dispatch_id, 'gas-'))"
        safe_retired_wakeup = (workflow == 'guardian.yml' and retired_group in settings.splitlines()
                               and retired_guard in source)
        diagnostic_group = retired_group.replace('${{ ', "${{ inputs.verify_test_cache && format('guardian-readonly-{0}', github.run_id) || ", 1)
        safe_diagnostic = (workflow == 'guardian.yml' and diagnostic_group in settings.splitlines()
                           and retired_guard in source and guardian_diagnostic_steps_guarded(source))
        if not safe_retired_wakeup and not safe_diagnostic and not re.search(r"^  group: lineup-guardian-writes\s*$", settings, re.MULTILINE):
            errors.append(f"Lineup Guardian {workflow} must share the lineup-guardian-writes concurrency group")
        if not re.search(r"^  cancel-in-progress: false\s*$", settings, re.MULTILINE):
            errors.append(f"Lineup Guardian {workflow} must not cancel an in-progress roster/lineup write")
    return errors


def publication_is_manual_only(source: str) -> bool:
    steps=re.split(r'(?=^      - (?:name:|uses:))',source,flags=re.MULTILINE)
    writers=[step for step in steps if re.search(r'^\s+git push\b',step,re.MULTILINE)]
    return bool(writers) and all(re.search(r"^        if: github.event_name == 'workflow_dispatch'\s*$",step,re.MULTILINE) for step in writers)


def personal_sync_contract_errors(public_source: str, private_source: str) -> list[str]:
    errors=[]
    if '--repo TheMathNinja/Chicago-Bears-Lineup-Guardian' not in public_source:
        errors.append('Public CHI sync must hand off to the private repository')
    if 'Check whether forecast inputs changed' not in private_source or private_source.count("steps.forecast.outputs.changed == 'true'")<2:
        errors.append('Private CHI sync must skip scientific dependency setup when forecast inputs are unchanged')
    if 'forecast-cache.outputs.cache-hit' in private_source:
        errors.append('CHI model publication must not be vetoed by a local cache after the live Site requires an update')
    if (re.findall(r"^\s+- cron:\s*['\"]([^'\"]+)['\"]", private_source, re.M) != ['0 6 * * *']
            or 'timezone: America/New_York' not in private_source):
        errors.append('Private CHI sync must run daily at 6 a.m. Eastern, including DST')
    if re.search(r'^  schedule:', public_source, re.M):
        errors.append('Public CHI sync wrapper must remain manual-only')
    if 'request_id:' not in private_source or 'scripts/chi_sync_completion.py' not in private_source:
        errors.append('Private CHI sync must acknowledge coalesced owner refresh requests')
    return errors

def main() -> int:
    from check_nfl_team_codes import audit_team_contracts
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
    elif all((root / 'config/nfl_teams.json').is_file() for root in roots.values()):
        errors.extend(audit_team_contracts(roots))
    else:
        errors.append('Every league repository must install the shared MFL NFL team contract')

    if set(roots) == required:
        cap_money = [roots[repo] / "R" / "cap_money.R" for repo in
                     ("ADL-Commissioner-Dashboard", "ADL-GM-Dashboard")]
        if not all(path.is_file() for path in cap_money) or len({
            path.read_text(encoding="utf-8") for path in cap_money
        }) != 1:
            errors.append("ADL salary-cap rounding helper must match in Commissioner and GM repositories")

    # Reject encoding damage before any helper attempts to parse the same file.
    for repo, root in roots.items():
        for path in root.glob('.github/workflows/*.yml'):
            try:
                path.read_text(encoding='utf-8')
            except UnicodeDecodeError as error:
                errors.append(f'{repo}/{path.relative_to(root).as_posix()} is not UTF-8 at byte {error.start}')
    if errors:
        print('Automation contract audit failed:')
        for error in errors:
            print('- ' + error)
        return 1

    workflows: dict[tuple[str, str], set[str]] = {}
    for repo, root in roots.items():
        for path in root.glob(".github/workflows/*.yml"):
            try:
                path.read_text(encoding="utf-8")
            except UnicodeDecodeError as exc:
                errors.append(f"{repo}/{path.relative_to(root)} is not UTF-8: {exc}")
                continue
            source = path.read_text(encoding="utf-8")
            workflows[(repo, path.name)] = workflow_inputs(path)
            if "runs-on: ubuntu-latest" in source:
                errors.append(
                    f"{repo}/{path.relative_to(root)} uses moving ubuntu-latest instead of pinned ubuntu-24.04"
                )
            for obsolete_action in (
                "actions/checkout@v4",
                "actions/cache@v4",
                "actions/upload-artifact@v4",
            ):
                if obsolete_action in source:
                    errors.append(
                        f"{repo}/{path.relative_to(root)} uses obsolete {obsolete_action}"
                    )
        errors.extend(local_python_call_errors(root))
        errors.extend(unittest_module_errors(repo, root))

    commissioner = roots.get("ADL-Commissioner-Dashboard")
    if commissioner:
        r_setup = commissioner / ".github" / "actions" / "setup-adl-r" / "action.yml"
        r_setup_source = r_setup.read_text(encoding="utf-8")
        required_r_setup = {
            "pinned R package": "r-4.5.1_1_amd64.deb",
            "minimal R install": "--no-install-recommends",
            "Ubuntu-only apt source file": "/etc/apt/sources.list.d/ubuntu.sources",
            "no unrelated apt sources": "Dir::Etc::sourceparts=-",
            "bounded apt download retries": "Acquire::Retries=2",
            "current cache action": "actions/cache@v5",
        }
        for label, marker in required_r_setup.items():
            if marker not in r_setup_source:
                errors.append(f"Shared ADL R setup is missing {label}")

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

        watchdog = commissioner / ".github" / "workflows" / "dashboard_watchdog.yml"
        watchdog_source = watchdog.read_text(encoding="utf-8")
        current_roster_job = "Refresh rosters, EXT and Salary Cap Manager / refresh"
        if current_roster_job not in watchdog_source:
            errors.append("Dashboard watchdog does not require the current roster/EXT/cap-manager job")
        if "Refresh rosters and Extension Calculator / refresh" in watchdog_source:
            errors.append("Dashboard watchdog still requires the retired roster/Extension job name")

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
        errors.extend(guardian_collision_errors({
            workflow: (guardian / ".github" / "workflows" / workflow).read_text(encoding="utf-8")
            for workflow in ("guardian.yml", "initial-lineup.yml")
        }))

    adl = roots.get("ADL-GM-Dashboard")
    if adl and commissioner:
        contract = json.loads((commissioner/'contracts/mfl_potential_warning.json').read_text())
        producer = (adl/'scripts/weekly_pairs.py').read_text()
        consumer = (commissioner/'scripts/mfl_potential_warning.py').read_text()
        reporter = (commissioner/'scripts/email_workflow_failures.py').read_text()
        if (contract['policy'] not in producer or contract['policy'] not in consumer
                or "allow_reported_potential_below_pf=league=='ADL'" not in producer
                or 'report_warning(state, args.dry_run' not in reporter
                or "MFL_POTENTIAL_WARNING: 'true'" not in (commissioner/'.github/workflows/email_workflow_failures.yml').read_text()):
            errors.append('MFL potential warning producer and owner-email consumer must match the reviewed contract')
    fafl = roots.get("FAFL-GM-Dashboard")
    if adl and fafl:
        errors.extend(payout_publication_errors(adl, fafl))
        errors.extend(playoff_browser_errors(adl, fafl))
        corrections=(adl/'scripts/score_corrections.py').read_text(encoding='utf-8')
        if corrections != (fafl/'scripts/score_corrections.py').read_text(encoding='utf-8'):
            errors.append('ADL/FAFL Thursday correction readiness policies must match, not just their signatures')
        if commissioner and "clock >= '04:15'" not in (commissioner/'scripts/CloudPolling.gs').read_text(encoding='utf-8'):
            errors.append('Cloud scheduler must not start Thursday corrections before 04:15 Eastern')
        if '"04:15"' not in (adl/'R/score_finalization_guard.R').read_text(encoding='utf-8'):
            errors.append('ADL score-finality eligibility must agree with the 04:15 Thursday correction boundary')
        for root,parent in [(adl,'refresh_extension_calculator.yml'),(fafl,'refresh.yml')]:
            poll=(root/'.github/workflows/poll_score_corrections.yml').read_text(encoding='utf-8')
            if not all(marker in poll for marker in ('actions/cache/restore@v5','actions/cache/save@v5','.score_correction_observation.json')):
                errors.append(f'{root.name}: Thursday settling observations must survive between polling runs')
            source=(root/'.github/workflows'/parent).read_text(encoding='utf-8')
            if 'Archive timestamped player-score input' not in source or 'include-hidden-files: true' not in source:
                errors.append(f'{root.name}: weekly runs must preserve their timestamped input evidence')
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
            if publication_is_manual_only(source):
                continue
            for output in generated_outputs:
                if re.search(r"^\s*-\s*['\"]?" + re.escape(output) + r"['\"]?\s*$", source, re.MULTILINE):
                    errors.append(
                        f"{path.relative_to(path.parents[2])} watches generated output {output} and can trigger itself"
                    )

        if guardian:
            policy = (commissioner / 'scripts/guardian_check_policy.py').read_text(encoding='utf-8')
            if policy != (guardian / 'scripts/guardian_check_policy.py').read_text(encoding='utf-8'):
                errors.append('Guardian dispatch and deadline policies must be identical across repositories')
            scheduler = (guardian / 'scheduler/Code.gs').read_text(encoding='utf-8')
            if ('CHECK_OFFSETS_MINUTES = (75, 45, 15)' not in policy or
                    'monitorIntervalMinutes: 30' not in scheduler or 'lookaheadMinutes: 75' not in scheduler):
                errors.append('Guardian precision scheduler must match the shared 75/45/15-minute check policy')
            for name in ('guardian.yml', 'initial-lineup.yml'):
                worker = (guardian / '.github/workflows' / name).read_text(encoding='utf-8')
                if 'uses: ./.github/actions/verified-guardian-tests' not in worker:
                    errors.append('Guardian live workers must verify exact-input passing test evidence')
            plan = json.loads((commissioner / 'contracts/actions_budget_plan.json').read_text())
            if plan['checkpointOffsetsMinutes'] != [75, 45, 15]:
                errors.append('The budget forecast must use the deployed Guardian checkpoints')
            cloud_audit = (commissioner / '.github/workflows/automation-preflight.yml').read_text()
            if '30 8 * * 3' not in cloud_audit or '30 8 * * *' in cloud_audit:
                errors.append('Cloud audit cadence must be weekly plus relevant releases, not daily')
            if re.search(r'^  schedule:', (guardian / '.github/workflows/preflight.yml').read_text(), re.MULTILINE):
                errors.append('Guardian preflight must not duplicate the independent weekly cross-repository audit')
            for filename in ('guardian_fallback.yml', 'email_workflow_failures.yml'):
                if 'GUARDIAN_PRECISION_OWNER: ${{ vars.GUARDIAN_PRECISION_OWNER }}' not in (commissioner / '.github/workflows' / filename).read_text(encoding='utf-8'):
                    errors.append('Both public scheduling clocks must honor precision ownership')
            worker_source = (guardian / '.github/workflows/guardian.yml').read_text(encoding='utf-8')
            if 'PRIVATE_DISCRETIONARY_ACTIONS' in worker_source or 'PRIVATE_DISCRETIONARY_ACTIONS' in (guardian / '.github/workflows/initial-lineup.yml').read_text():
                errors.append('Budget conservation must never gate required Guardian workers')
            for name in ('sync_chi_team_tools.yml', 'league-audit.yml', 'preflight.yml', 'model_contract_preflight.yml'):
                if "vars.PRIVATE_DISCRETIONARY_ACTIONS != 'paused'" not in (guardian / '.github/workflows' / name).read_text():
                    errors.append('Discretionary private jobs must enforce conservation before runner allocation: ' + name)
            for name in ('guardian_fallback.py', 'guardian_health_monitor.py'):
                if 'private_actions_policy' in (commissioner / 'scripts' / name).read_text():
                    errors.append('Budget conservation must not disable backup or missed-check coverage')
            if "!(vars.GUARDIAN_PRECISION_OWNER == 'public-scheduler-v2' && startsWith(inputs.dispatch_id, 'gas-'))" not in worker_source:
                errors.append('Retired precision wakeups must allocate no private runner after verified handoff')
            errors.extend(personal_sync_contract_errors(
                (adl / '.github/workflows/sync_chi_team_tools.yml').read_text(encoding='utf-8'),
                (guardian / '.github/workflows/sync_chi_team_tools.yml').read_text(encoding='utf-8')))

    if errors:
        print("Automation contract audit failed:")
        for error in errors:
            print(f"- {error}")
        return 1
    print(f"Automation contracts verified across {len(roots)} repositories and {len(workflows)} workflows.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
