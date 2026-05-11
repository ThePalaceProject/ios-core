#!/usr/bin/env python3
"""Import simdrive-regress.sh `regress.json` into a regression `findings.csv`.

For each journey row in regress.json:
- status=fail → emit a finding row with verified=false
- severity HIGH perf delta → severity=major
- struct-check FAIL → severity=major
- crashes>0 → severity=blocker (extreme)
- everything else flagged but lower severity

Usage:
    python3 scripts/regression/import-simdrive.py \
        --regress-json ~/Desktop/regression-PP-XXXX/automated/simdrive/regress.json \
        --findings-csv ~/Desktop/regression-PP-XXXX/findings.csv \
        --pr 921

Re-runnable; existing rows imported by this script (matched on prefix `[simdrive-regress] <journey>`)
are replaced rather than duplicated.
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path

CSV_HEADER = [
    "ID", "Title", "Area", "Test ID", "Classification", "Severity", "Verified",
    "Baseline Behavior", "Candidate Behavior", "Steps",
    "Screenshot Baseline", "Screenshot Candidate", "Notes", "PR", "Jira Ticket",
]
SCRIPT_TAG = "[simdrive-regress]"  # used to identify rows we own


def classify(detail: str) -> tuple[str, str]:
    """Return (severity, classification) from a detail string."""
    if "crashes=" in detail and not detail.split("crashes=")[1].startswith("0"):
        return "blocker", "regression"
    if "perf severity HIGH" in detail or "struct-check=FAIL" in detail:
        return "major", "regression"
    if detail.startswith(("0 steps", "1 steps")):
        return "minor", "pre-existing"
    return "minor", "pending-investigation"


def title_from(journey: str, detail: str) -> str:
    parts = []
    if "perf severity HIGH" in detail:
        m = re.search(r"rss [\d.]+→[\d.]+MB \(Δ([\d.]+)", detail)
        delta = m.group(1) if m else "?"
        parts.append(f"perf RSS Δ{delta}MB")
    if "struct-check=FAIL" in detail:
        parts.append("structural assertion failed")
    if "crashes=" in detail and not detail.split("crashes=")[1].startswith("0"):
        parts.append("crashes")
    if not parts:
        parts.append("journey replay deviated")
    return f"{SCRIPT_TAG} {journey}: " + ", ".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--regress-json", required=True, type=Path)
    ap.add_argument("--findings-csv", required=True, type=Path)
    ap.add_argument("--pr", default="", help="Optional PR number")
    ap.add_argument("--ticket", default="", help="Optional parent Jira ticket (left empty in row by default)")
    args = ap.parse_args()

    if not args.regress_json.exists():
        print(f"regress.json not found at {args.regress_json}", file=sys.stderr)
        return 2

    data = json.loads(args.regress_json.read_text())
    journeys = data.get("journeys") or []
    fails = [j for j in journeys if j.get("status") == "fail"]
    if not fails:
        print("import-simdrive: no failing journeys to import")
        return 0

    # Read existing rows so we don't duplicate
    existing: list[dict] = []
    if args.findings_csv.exists():
        with args.findings_csv.open(newline="") as f:
            r = csv.DictReader(f)
            existing = [row for row in r if not (row.get("Title") or "").startswith(SCRIPT_TAG)]

    # Determine next F-NNN id
    next_n = 1
    for row in existing:
        m = re.match(r"F-(\d+)$", (row.get("ID") or "").strip())
        if m:
            next_n = max(next_n, int(m.group(1)) + 1)

    new_rows: list[dict] = []
    for j in fails:
        journey = j["journey"]
        detail = j["detail"]
        severity, classification = classify(detail)
        new_rows.append({
            "ID": f"F-{next_n:03d}",
            "Title": title_from(journey, detail),
            "Area": "Performance" if "perf" in detail else "Functional",
            "Test ID": f"J-{journey}",
            "Classification": classification,
            "Severity": severity,
            "Verified": "false",
            "Baseline Behavior": "Captured at recording time; needs side-by-side against baseline version to anchor",
            "Candidate Behavior": detail,
            "Steps": f"scripts/simdrive-regress.sh --only {journey}",
            "Screenshot Baseline": "",
            "Screenshot Candidate": "",
            "Notes": f"Auto-imported from simdrive-regress.sh; verify before promoting Classification.",
            "PR": args.pr,
            "Jira Ticket": args.ticket,
        })
        next_n += 1

    # Write back: existing (de-duped) + new rows
    args.findings_csv.parent.mkdir(parents=True, exist_ok=True)
    with args.findings_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_HEADER, quoting=csv.QUOTE_MINIMAL)
        w.writeheader()
        for row in existing + new_rows:
            w.writerow({k: row.get(k, "") for k in CSV_HEADER})

    print(f"import-simdrive: replaced rows starting with '{SCRIPT_TAG}'; wrote {len(new_rows)} new finding(s) -> {args.findings_csv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
