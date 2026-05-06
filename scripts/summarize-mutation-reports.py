#!/usr/bin/env python3
"""Aggregate per-file palace_mutate JSON reports into a kill-rate summary.

Usage: summarize-mutation-reports.py <reports-dir>

If the directory contains no JSON files, emits a note that mutation was run in
dry-run mode (palace_mutate.py doesn't write a --report in dry-run).
"""
import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: summarize-mutation-reports.py <reports-dir>", file=sys.stderr)
        return 2

    reports_dir = Path(sys.argv[1])
    if not reports_dir.is_dir():
        print(f"no reports dir at {reports_dir}")
        return 0

    files = sorted(reports_dir.glob("*.json"))
    if not files:
        print("No per-file JSON reports found — mutation ran in dry-run mode.")
        print("Re-run with --mutation-run to get kill/survive data.")
        return 0

    per_file = []
    total_killed = total_survived = total_errored = 0

    for path in files:
        try:
            with path.open() as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            print(f"  skip {path.name}: {e}", file=sys.stderr)
            continue

        summary = data.get("summary", {})
        killed = int(summary.get("killed", 0))
        survived = int(summary.get("survived", 0))
        errored = int(summary.get("errored", 0))
        total = killed + survived
        rate = (killed / total * 100) if total else None

        per_file.append({
            "file": data.get("file", path.stem),
            "killed": killed,
            "survived": survived,
            "errored": errored,
            "rate": rate,
        })
        total_killed += killed
        total_survived += survived
        total_errored += errored

    overall_total = total_killed + total_survived
    overall_rate = (total_killed / overall_total * 100) if overall_total else 0.0

    print("=" * 64)
    print(f"Mutation aggregate — {len(per_file)} files")
    print(f"  killed:    {total_killed}")
    print(f"  survived:  {total_survived}")
    print(f"  errored:   {total_errored}")
    print(f"  kill rate: {overall_rate:.1f}%")
    print("=" * 64)

    # Bottom-5 kill rates (likely weakest test coverage)
    rated = [f for f in per_file if f["rate"] is not None]
    if rated:
        print()
        print("Weakest kill rates (bottom 5):")
        for f in sorted(rated, key=lambda x: x["rate"])[:5]:
            print(f"  {f['rate']:5.1f}%  {f['killed']:>3}k/{f['survived']:>3}s  {f['file']}")

    # Exit non-zero if overall kill rate is concerning
    return 1 if overall_total > 0 and overall_rate < 50 else 0


if __name__ == "__main__":
    sys.exit(main())
