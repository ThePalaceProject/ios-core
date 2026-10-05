#!/usr/bin/env python3
"""
Enforce per-module code coverage floors for the Palace iOS CI gate.

Reads coverage-data.json (produced by scripts/coverage-report.py) and compares
per-module/per-file/per-target coverage against scripts/coverage-floors.json.

Exit codes:
  0 — all floors met
  1 — one or more floors violated
  2 — input error (missing/empty/invalid coverage data)
  3 — the coverage data is incomplete (`status` is not `complete`); floors are
      not compared, because a partial measurement reads as a coverage drop

Floors:
  overall        app testable coverage (Palace/ outside Palace/Packages)
  modules        a file stem, or several files with that stem, in the app suite
  packages       a local package's Sources, measured by the app suite
  host_packages  a local package's Sources, measured by its own `swift test`

Usage:
  python3 scripts/enforce_coverage_floors.py coverage-data.json
  python3 scripts/enforce_coverage_floors.py coverage-data.json --floors scripts/coverage-floors.json
  python3 scripts/enforce_coverage_floors.py coverage-data.json --baseline-only
  python3 scripts/enforce_coverage_floors.py coverage-data.json --write-baseline
"""
import argparse
import json
import math
import os
import sys
from typing import Dict, Any, List, Tuple, Optional


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def use_color() -> bool:
    if os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS"):
        return False
    return sys.stdout.isatty()


def colorize(text: str, code: str) -> str:
    if not use_color():
        return text
    return f"\033[{code}m{text}\033[0m"


def green(s: str) -> str:
    return colorize(s, "32")


def red(s: str) -> str:
    return colorize(s, "31")


def yellow(s: str) -> str:
    return colorize(s, "33")


def load_json(path: str) -> Optional[Any]:
    if not os.path.exists(path):
        log(f"Error: file not found: {path}")
        return None
    try:
        with open(path) as f:
            data = json.load(f)
        if not data:
            log(f"Error: empty JSON in {path}")
            return None
        return data
    except json.JSONDecodeError as e:
        log(f"Error: invalid JSON in {path}: {e}")
        return None


def normalize_fraction(value: float) -> float:
    """coverage-report.py emits percent (0-100); floors are fractions (0-1)."""
    if value > 1.0:
        return value / 100.0
    return value


def get_overall(coverage: Dict, metric: str = "testable") -> float:
    """Return the headline coverage fraction for gating.

    metric="testable" (default) gates on coverage of files that are actually
    unit-testable — i.e. with SwiftUI views, UIKit VCs, and lifecycle code
    removed from the denominator per scripts/coverage-exclude.json. This is
    the honest number: raising it means 'more testable logic is tested',
    not 'we wrote less UI this release'.

    metric="total" gates on every executable line (legacy behavior). Pass
    --metric total to enforce_coverage_floors.py to keep the old semantics.
    """
    if metric == "testable" and "testable_coverage" in coverage:
        return normalize_fraction(float(coverage.get("testable_coverage") or 0.0))
    raw = coverage.get("total_coverage", coverage.get("line_coverage", 0.0))
    return normalize_fraction(float(raw or 0.0))


def find_module_coverage(coverage: Dict, name: str) -> Optional[float]:
    """Search targets first, then files (by stem name) for a matching module.

    Several files with one stem are combined by line counts; a mean of their
    percentages would weight a 10-line file the same as a 1,000-line one."""
    name_lower = name.lower()

    for t in coverage.get("targets", []):
        if t.get("name", "").lower() == name_lower:
            return normalize_fraction(float(t.get("coverage", 0.0)))

    matches = [f for f in coverage.get("files", [])
               if os.path.splitext(os.path.basename(f.get("name", "")))[0].lower() == name_lower]
    if not matches:
        return None
    if all("executable_lines" in f for f in matches):
        executable = sum(int(f["executable_lines"]) for f in matches)
        covered = sum(int(f.get("covered_lines", 0)) for f in matches)
        return covered / executable if executable else 0.0
    if len(matches) == 1:
        return normalize_fraction(float(matches[0].get("coverage", 0.0)))
    raise ValueError(f"{name}: {len(matches)} files match and not all carry line counts")


def find_package_coverage(coverage: Dict, scope_key: str, name: str) -> Optional[float]:
    """Testable coverage of one package in one measurement, from line counts."""
    d = coverage.get(scope_key, {}).get(name)
    if not d:
        return None
    executable = int(d.get("testable_executable_lines", 0))
    return int(d.get("testable_covered_lines", 0)) / executable if executable else 0.0


PACKAGE_SCOPES = (("packages", "packages_app_suite", "pkg:"),
                  ("host_packages", "packages_host", "host:"))


def is_complete(coverage: Dict) -> bool:
    return coverage.get("status") == "complete"


def floor_of(actual: float) -> float:
    """Round down to 4 places so a floor written from a run passes that run."""
    return math.floor(actual * 10000) / 10000


def build_baseline(coverage: Dict, modules: Dict[str, float], metric: str = "testable") -> Dict[str, Any]:
    """Capture current coverage as the new floor (no-regression baseline)."""
    baseline = {
        "overall": floor_of(get_overall(coverage, metric)),
        "modules": {},
        "_comment": "Auto-generated baseline (no regression). Ratchet upward as coverage improves.",
    }
    for name in modules.keys():
        actual = find_module_coverage(coverage, name)
        if actual is not None:
            baseline["modules"][name] = floor_of(actual)
        else:
            baseline["modules"][name] = modules[name]
    for floors_key, scope_key, _ in PACKAGE_SCOPES:
        measured = coverage.get(scope_key, {})
        if measured:
            baseline[floors_key] = {n: floor_of(find_package_coverage(coverage, scope_key, n))
                                    for n in sorted(measured)}
    return baseline


def format_pct(v: Optional[float]) -> str:
    if v is None:
        return "  N/A "
    return f"{v * 100:5.1f}%"


def evaluate(coverage: Dict, floors: Dict, baseline_only: bool, metric: str = "testable") -> Tuple[List[Dict], bool]:
    rows: List[Dict] = []
    all_pass = True

    overall_floor = float(floors.get("overall", 0.0))
    overall_actual = get_overall(coverage, metric)

    if baseline_only:
        overall_floor = overall_actual

    overall_status = "PASS" if overall_actual + 1e-9 >= overall_floor else "FAIL"
    if overall_status == "FAIL":
        all_pass = False
    rows.append({
        "module": "overall",
        "floor": overall_floor,
        "actual": overall_actual,
        "status": overall_status,
        "missing": False,
    })

    unmeasured = floors.get("unmeasured", {})

    for name, floor in floors.get("modules", {}).items():
        actual = find_module_coverage(coverage, name)
        if actual is None:
            # A module that cannot be found in the coverage data is NOT a pass.
            # This used to `continue` without touching `all_pass`, so a module
            # that left the measured surface silently stopped being gated —
            # which is exactly what the decomposition campaign does every time
            # it extracts one into Palace/Packages (coverage reports a single
            # target, Palace.app, so no package source is measured at all).
            # A deliberate exemption goes in `unmeasured` with a reason.
            rows.append({
                "module": name,
                "floor": float(floor),
                "actual": None,
                "status": "MISSING",
                "missing": True,
            })
            all_pass = False
            continue
        effective_floor = actual if baseline_only else float(floor)
        status = "PASS" if actual + 1e-9 >= effective_floor else "FAIL"
        if status == "FAIL":
            all_pass = False
        rows.append({
            "module": name,
            "floor": effective_floor,
            "actual": actual,
            "status": status,
            "missing": False,
        })

    for floors_key, scope_key, prefix in PACKAGE_SCOPES:
        for name, floor in floors.get(floors_key, {}).items():
            actual = find_package_coverage(coverage, scope_key, name)
            if actual is None:
                rows.append({"module": prefix + name, "floor": float(floor), "actual": None,
                             "status": "MISSING", "missing": True})
                all_pass = False
                continue
            effective_floor = actual if baseline_only else float(floor)
            status = "PASS" if actual + 1e-9 >= effective_floor else "FAIL"
            if status == "FAIL":
                all_pass = False
            rows.append({"module": prefix + name, "floor": effective_floor, "actual": actual,
                         "status": status, "missing": False})

    return rows, all_pass


def print_table(rows: List[Dict]) -> None:
    width = max((len(r["module"]) for r in rows), default=10)
    width = max(width, 30)
    header = f"{'MODULE'.ljust(width)}  {'FLOOR':>7}  {'ACTUAL':>7}  STATUS"
    print(header)
    print("-" * len(header))
    for r in rows:
        floor_s = f"{r['floor'] * 100:5.1f}%"
        actual_s = format_pct(r["actual"])
        status = r["status"]
        if status == "PASS":
            status_s = green("PASS   ")
        elif status == "FAIL":
            status_s = red("FAIL   ")
        else:
            status_s = yellow("MISSING")
        print(f"{r['module'].ljust(width)}  {floor_s:>7}  {actual_s:>7}  {status_s}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Enforce per-module coverage floors.")
    parser.add_argument("coverage_json", help="Path to coverage-data.json")
    parser.add_argument("--floors", default="scripts/coverage-floors.json",
                        help="Path to coverage-floors.json (default: scripts/coverage-floors.json)")
    parser.add_argument("--baseline-only", action="store_true",
                        help="Use current actual as floor (no-regression mode).")
    parser.add_argument("--write-baseline", action="store_true",
                        help="Write current coverage to the floors file and exit 0.")
    parser.add_argument("--metric", choices=["testable", "total"], default="testable",
                        help="Which headline metric to gate on. 'testable' (default) "
                             "excludes UI/lifecycle files per coverage-exclude.json. "
                             "'total' gates on every executable line (legacy).")
    args = parser.parse_args()

    coverage = load_json(args.coverage_json)
    if coverage is None:
        return 2

    if not isinstance(coverage, dict):
        log("Error: coverage data is not a JSON object")
        return 2

    if not is_complete(coverage):
        reasons = coverage.get("incomplete_reasons") or [
            "the coverage data does not declare itself complete (no `status: complete`)"]
        print("Coverage gate: INCOMPLETE — floors not compared")
        for r in reasons:
            print(f"  - {r}")
        return 3

    floors = load_json(args.floors)
    if floors is None:
        log(f"Note: floors file missing — using empty defaults.")
        floors = {"overall": 0.0, "modules": {}}

    if args.write_baseline:
        baseline = build_baseline(coverage, floors.get("modules", {}), args.metric)
        with open(args.floors, "w") as f:
            json.dump(baseline, f, indent=2)
            f.write("\n")
        log(f"Wrote baseline floors to {args.floors} (metric={args.metric})")
        print_table(evaluate(coverage, baseline, baseline_only=False, metric=args.metric)[0])
        return 0

    has_modules = bool(coverage.get("targets")) or bool(coverage.get("files"))
    if not has_modules:
        log("Notice: coverage-data.json has no per-target/per-file breakdown — "
            "falling back to overall project coverage only.")
        floors = {"overall": floors.get("overall", 0.0), "modules": {},
                  "packages": floors.get("packages", {}),
                  "host_packages": floors.get("host_packages", {})}

    log(f"Gating on '{args.metric}' coverage metric.")
    rows, all_pass = evaluate(coverage, floors, args.baseline_only, args.metric)

    for name, reason in floors.get("unmeasured", {}).items():
        log(f"UNMEASURED  {name}: {reason}")
    print_table(rows)

    missing = [r["module"] for r in rows if r.get("missing")]
    if missing:
        log(f"Warning: {len(missing)} module(s) not found in coverage data: "
            f"{', '.join(missing)}")

    if all_pass:
        print(green("\nCoverage gate: PASS"))
        return 0
    print(red("\nCoverage gate: FAIL"))
    return 1


if __name__ == "__main__":
    sys.exit(main())
