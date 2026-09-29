from pathlib import Path


workflow = Path(".github/workflows/weekly_salary_cap_accounting.yml").read_text(encoding="utf-8")

required = {
    "bounded job": "timeout-minutes: 30",
    "completion receipt": "_ADLsalarycapcomplete.csv",
    "resumable capture": "capture_needed=false",
    "snapshot retries": "Salary cap accounting attempt ${attempt} failed.",
    "sheet retries": "Cap Rollover writeback attempt ${attempt} failed.",
    "missing credentials are fatal": "Cap Rollover cannot be certified complete.",
    "email is isolated": "Email official snapshot confirmation\n        if: steps.localtime.outputs.should_run == 'true'\n        continue-on-error: true",
}

missing = [name for name, marker in required.items() if marker not in workflow]
if missing:
    raise SystemExit("Cap workflow safety checks failed: " + ", ".join(missing))

print("Cap workflow transaction and retry checks passed.")
