"""Read-only snapshot reconciliation; stdout is included in the confirmation email."""
import csv
import io
import os
import sys
from decimal import Decimal
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen


def money(value):
    return Decimal(value.strip().replace("$", "").replace(",", ""))


def column(n):
    return (column((n - 1) // 26) if n > 26 else "") + chr(65 + (n - 1) % 26)


def sheet(tab, cells):
    key = os.getenv("CONTRACT_ADMIN_SHEET_ID", "1Pyw8qVfiBlXNuX0lW0LdjRnBiijfbo2BXHfZMWwLLaw")
    query = urlencode(dict(tqx="out:csv", sheet=tab, range=cells, headers=0))
    with urlopen(f"https://docs.google.com/spreadsheets/d/{key}/gviz/tq?{query}", timeout=15) as r:
        return list(csv.reader(io.StringIO(r.read().decode("utf-8-sig"))))


def review(year, week):
    root = Path("data/cap_accounting") / year
    prefix = f"{year}w{week}_ADLsalary"
    def load(folder, name):
        with (root / folder / (prefix + name + ".csv")).open(encoding="utf-8-sig") as f:
            return list(csv.DictReader(f))
    summary = load("summaries", "capsummary")
    teams = [row["FRANCHISE"] for row in summary]  # engine exports in MFL franchise-ID order
    ids = [r[0] for r in sheet("Cap Rollover", "A3:A34")]
    if len(set(teams)) != 32 or teams != ids:
        raise ValueError("Cap Rollover franchise list differs from snapshot")
    mfl = dict.fromkeys(teams, Decimal(0))
    for row in load("adjustment_snapshots", "adjustments"):
        i = int(row["franchise_id"])
        if not 1 <= i <= 32:
            raise ValueError("unexpected MFL franchise ID")
        mfl[teams[i-1]] += money(row["amount"])
    admin = {}
    for conf in ("NFC", "AFC"):
        tab = conf + " Sal Adj"
        rows = sheet(tab, "U2:V17")
        if sheet(tab, "U1:V1") != [["FRAN", year + " ADJ"]] or len(rows) != 16:
            raise ValueError(conf + " adjustment totals unavailable")
        admin.update((team, money(value)) for team, value in rows)
    start = 2 + 12 * (week - 1) + 8
    block = sheet("Cap Rollover", f"{column(start)}3:{column(start+2)}34")
    if set(admin) != set(teams) or len(block) != 32:
        raise ValueError("incomplete franchise coverage")
    issues = []
    for row, cells in zip(summary, block):
        team = row["FRANCHISE"]
        salary, adj = [money(row[f"W{week}_{field}"]) for field in ("RostSal", "Adj")]
        rs, ra = map(money, cells[:2])
        corr = money(cells[2]) if len(cells) > 2 and cells[2].strip() else Decimal(0)
        if rs != salary or ra != adj or mfl[team] != adj:
            issues.append(f"{team}: snapshot roster/ADJ ${salary:.2f}/${adj:.2f}; rollover ${rs:.2f}/${ra:.2f}; archived MFL ADJ ${mfl[team]:.2f}; Sal Adj tab ${admin[team]:.2f}. Verify source or repair writeback before changing CORR.")
        elif admin[team] != adj:
            delta = admin[team] - adj
            issues.append(f"{team}: snapshot/MFL ADJ ${adj:.2f}; Sal Adj tab ${admin[team]:.2f}. Week {week} adjustment difference: {delta:+.2f}; existing CORR: {corr:+.2f}. " +
                          ("Already covered if this CORR is for these entries; do not add again." if corr == delta else
                           "If the sheet entries applied at capture, use this difference as CORR." if not corr else
                           "Check what existing CORR covers before combining adjustments."))
    return "\n".join(["Salary reconciliation: review needed" if issues else "Salary reconciliation: all 32 adjustment totals and roster-salary writebacks agree.", *issues])


if __name__ == "__main__":
    print(review(sys.argv[1], int(sys.argv[2])))
