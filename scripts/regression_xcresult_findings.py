#!/usr/bin/env python3
"""regression_xcresult_findings.py — turn an xcresult's test failures into
findings.csv rows for a headless XCTest regression cell (e.g. C-carplay).

The C-carplay cell (per the CarPlay feasibility verdict) is NOT a simdrive
journey cell — CarPlay can't be interactively driven on a sim. Its regression
signal is the headless `PalaceTests/CarPlay` XCTest suite. This module reads the
result bundle that suite produces and emits one finding per failed test into the
cell's own shard, conforming to the pinned regression_findings schema.

Source of truth: `xcrun xcresulttool get test-results summary --format json`,
whose `testFailures[]` array gives, per failure:
    { failureText, targetName, testIdentifierString ("Suite/testMethod()"),
      testName }
`failureText` discriminates a crash ("Test crashed with signal trap.") from an
assertion ("XCTAssertNotNil failed") — so a CarPlay regression that *crashes*
(the high-severity case) is classified `crash`; an assertion failure is `other`.
(Cross-cell `device-divergence` is assigned later by Fable-triage when the same
failure reproduces across cells — a single cell does not self-assign it.)

Usage:
  regression_xcresult_findings.py --xcresult <bundle> \
      --device-cell C-carplay --area carplay \
      --run-dir .regression-runs/<id> [--first-seen-commit <sha>] [--json]
  # or feed a pre-extracted summary JSON (testing / offline):
  regression_xcresult_findings.py --summary-json <file> ...

Exit code:
  0  — parsed; no test failures (cell PASS)
  1  — at least one failure (findings emitted; cell FAIL)
  2  — config error (no xcresult / xcresulttool error)
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# failureText markers that mean the test CRASHED (vs. a plain assertion).
_CRASH_MARKERS = re.compile(
    r"crash|signal|trap|fatal error|EXC_|SIGABRT|SIGSEGV|SIGTRAP|"
    r"terminating with uncaught", re.I,
)

_COLUMNS = [
    "id", "area", "device_cell", "severity", "classification", "verified",
    "evidence_paths", "screenshot_pair", "first_seen_commit", "dedup_cluster",
    "disposition",
]


def classify_failure(failure_text: str) -> str:
    """A crashed test → 'crash'; any other failure → 'other'."""
    return "crash" if _CRASH_MARKERS.search(failure_text or "") else "other"


def parse_failures(summary: dict) -> list[dict]:
    """Extract normalized failures from a `test-results summary` JSON object."""
    out = []
    for f in summary.get("testFailures", []) or []:
        ident = f.get("testIdentifierString", "") or ""
        suite, _, method = ident.partition("/")
        text = f.get("failureText", "") or ""
        out.append({
            "suite": suite,
            "test": method or f.get("testName", ""),
            "identifier": ident,
            "failure_text": text,
            "target": f.get("targetName", ""),
            "classification": classify_failure(text),
        })
    return out


def build_rows(failures: list[dict], device_cell: str, area: str,
               evidence: str, first_seen_commit: str) -> list[dict]:
    rows = []
    for i, f in enumerate(failures):
        is_crash = f["classification"] == "crash"
        rows.append({
            "id": f"{device_cell}-{area}-{i+1}",
            "area": area,
            "device_cell": device_cell,
            # a crashing CarPlay test is a blocker; an assertion failure major.
            "severity": "blocker" if is_crash else "major",
            "classification": f["classification"],
            "verified": "false",
            "evidence_paths": evidence,
            "screenshot_pair": "",
            "first_seen_commit": first_seen_commit,
            "dedup_cluster": "",
            "disposition": "",
            # not schema columns, but handy in --json output:
            "_identifier": f["identifier"],
            "_failure_text": f["failure_text"],
        })
    return rows


def emit_findings(run_dir: str, device_cell: str, area: str,
                  rows: list[dict]) -> str | None:
    if not rows:
        return None
    shard = Path(run_dir) / "findings" / f"{device_cell}__{area}.csv"
    schema_rows = [{c: r.get(c, "") for c in _COLUMNS} for r in rows]
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import regression_findings as rf  # type: ignore
        rf.append_findings(str(shard), schema_rows)
    except Exception:
        _inline_append(shard, schema_rows)
    return str(shard)


def _inline_append(shard: Path, rows: list[dict]) -> None:
    import csv
    shard.parent.mkdir(parents=True, exist_ok=True)
    new = not shard.exists() or shard.stat().st_size == 0
    with shard.open("a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=_COLUMNS)
        if new:
            w.writeheader()
        for row in rows:
            w.writerow({c: row.get(c, "") for c in _COLUMNS})


def _summary_from_xcresult(xcresult: str) -> dict:
    res = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary",
         "--path", xcresult, "--format", "json"],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        print(f"ERROR: xcresulttool failed: {res.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    return json.loads(res.stdout)


def main() -> int:
    ap = argparse.ArgumentParser(description="xcresult failures → findings")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--xcresult", help="path to the .xcresult bundle")
    src.add_argument("--summary-json", help="pre-extracted summary JSON (offline/testing)")
    ap.add_argument("--device-cell", default="C-carplay")
    ap.add_argument("--area", default="carplay")
    ap.add_argument("--run-dir", default=".regression-runs/adhoc")
    ap.add_argument("--first-seen-commit", default="")
    ap.add_argument("--evidence", default="", help="evidence path override (default: the xcresult)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    if args.summary_json:
        summary = json.loads(Path(args.summary_json).read_text())
        evidence = args.evidence or args.summary_json
    else:
        summary = _summary_from_xcresult(args.xcresult)
        evidence = args.evidence or args.xcresult

    failures = parse_failures(summary)
    rows = build_rows(failures, args.device_cell, args.area, evidence,
                      args.first_seen_commit)
    shard = emit_findings(args.run_dir, args.device_cell, args.area, rows)

    result = {
        "device_cell": args.device_cell,
        "area": args.area,
        "total_tests": summary.get("totalTestCount"),
        "failed": len(failures),
        "crashes": sum(1 for f in failures if f["classification"] == "crash"),
        "verdict": "FAIL" if failures else "PASS",
        "findings_shard": shard,
        "failures": [
            {"identifier": f["identifier"], "classification": f["classification"],
             "failure_text": f["failure_text"]} for f in failures
        ],
    }

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"=== {args.device_cell} headless XCTest cell ===")
        print(f"tests={summary.get('totalTestCount')}  failed={len(failures)}  "
              f"crashes={result['crashes']}")
        for f in failures:
            print(f"  [{f['classification']}] {f['identifier']} — {f['failure_text'][:70]}")
        print(f"\nVERDICT: {result['verdict']}"
              + (f"  (findings → {shard})" if shard else ""))

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
