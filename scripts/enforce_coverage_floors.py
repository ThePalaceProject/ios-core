#!/usr/bin/env python3
"""
Enforce per-module code coverage floors for the Palace iOS CI gate.

Reads coverage-data.json (produced by scripts/coverage-report.py) and compares
per-module/per-file/per-target coverage against scripts/coverage-floors.json.

Exit codes:
  0 — every blocking floor met (advisory rows may still read FAIL)
  1 — a blocking floor violated, or a floor with no data
  2 — input error (missing/empty/invalid coverage data)
  3 — the coverage data is incomplete (`status` is not `complete`); floors are
      not compared, because a partial measurement reads as a coverage drop

Floors:
  overall        app testable coverage (Palace/ outside Palace/Packages)
  modules        a file stem, or several files with that stem, in the app suite
  package_modules  a module whose source moved into a local package
  packages       a local package's Sources, measured by the app suite
  host_packages  a local package's Sources, measured by its own `swift test`

`overall` and `modules` block, failing only below floor - APP_FLOOR_TOLERANCE.
The package scopes are advisory: a row below its floor prints FAIL with an
`advisory` column and does not change the exit code. The coverage floors
README in this directory says why.

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


# Repeated CI runs of one commit measured the same rows up to 1.2 points apart
# (#1601), so an app floor fails only when coverage is more than this fraction
# below it. Floors stay as recorded; the margin lives here, in one place.
APP_FLOOR_TOLERANCE = 0.015

# Floor scopes whose violations are reported but do not fail the gate. Their
# measurements varied between runs of identical code with no slack in the
# floors (#1601). A floor with no data still fails in every scope.
ADVISORY_SCOPES = ("package_modules", "packages", "host_packages")


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


# (floors key, report measurement, row prefix, report key listing what the run
# was required to collect)
PACKAGE_SCOPES = (("packages", "packages_app_suite", "pkg:", "expected_packages"),
                  ("host_packages", "packages_host", "host:", "expected_host_packages"))


def collected(coverage: Dict, expected_key: str) -> bool:
    """Whether the run was required to collect this package measurement. CI
    passes --expect-* to coverage-report.py, so absent data there is already
    INCOMPLETE; a local Xcode run collects none and its package floors are not
    compared."""
    return bool(coverage.get(expected_key))


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
    for floors_key, scope_key, _, _ in PACKAGE_SCOPES:
        measured = coverage.get(scope_key, {})
        if measured:
            baseline[floors_key] = {n: floor_of(find_package_coverage(coverage, scope_key, n))
                                    for n in sorted(measured)}
    return baseline


def app_status(actual: float, floor: float) -> str:
    """PASS at or above the floor, WITHIN up to the tolerance below it, else FAIL."""
    if actual + 1e-9 >= floor:
        return "PASS"
    if actual + 1e-9 >= floor - APP_FLOOR_TOLERANCE:
        return "WITHIN"
    return "FAIL"


def advisory_status(actual: float, floor: float) -> str:
    return "PASS" if actual + 1e-9 >= floor else "FAIL"


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

    overall_status = app_status(overall_actual, overall_floor)
    if overall_status == "FAIL":
        all_pass = False
    rows.append({
        "module": "overall",
        "floor": overall_floor,
        "actual": overall_actual,
        "status": overall_status,
        "missing": False,
        "advisory": False,
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
                "advisory": False,
            })
            all_pass = False
            continue
        effective_floor = actual if baseline_only else float(floor)
        status = app_status(actual, effective_floor)
        if status == "FAIL":
            all_pass = False
        rows.append({
            "module": name,
            "floor": effective_floor,
            "actual": actual,
            "status": status,
            "missing": False,
            "advisory": False,
        })

    # Modules whose source moved into a local package: advisory like the
    # package scopes, compared only when the run collected package source.
    if collected(coverage, "expected_packages"):
        for name, floor in floors.get("package_modules", {}).items():
            actual = find_module_coverage(coverage, name)
            effective_floor = actual if (baseline_only and actual is not None) else float(floor)
            if actual is None:
                status = "MISSING"
                all_pass = False
            else:
                status = advisory_status(actual, effective_floor)
            rows.append({"module": name, "floor": effective_floor, "actual": actual,
                         "status": status, "missing": actual is None, "advisory": actual is not None})

    for floors_key, scope_key, prefix, expected_key in PACKAGE_SCOPES:
        if not collected(coverage, expected_key):
            if floors.get(floors_key):
                log(f"Note: {floors_key} floors not compared; this report did not collect "
                    f"that measurement (CI does: coverage-report.py --expect-local-packages / "
                    f"--expect-host-package).")
            continue
        for name, floor in floors.get(floors_key, {}).items():
            actual = find_package_coverage(coverage, scope_key, name)
            if actual is None:
                rows.append({"module": prefix + name, "floor": float(floor), "actual": None,
                             "status": "MISSING", "missing": True, "advisory": False})
                all_pass = False
                continue
            effective_floor = actual if baseline_only else float(floor)
            rows.append({"module": prefix + name, "floor": effective_floor, "actual": actual,
                         "status": advisory_status(actual, effective_floor), "missing": False,
                         "advisory": True})

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
            status_s = (yellow if r.get("advisory") else red)("FAIL   ")
        elif status == "WITHIN":
            status_s = yellow("WITHIN ")
        else:
            status_s = yellow("MISSING")
        # The fifth column keeps an advisory FAIL out of verify-pr.sh's
        # `NF == 4 && $4 == "FAIL"` count of blocking violations.
        suffix = " advisory" if r.get("advisory") else ""
        print(f"{r['module'].ljust(width)}  {floor_s:>7}  {actual_s:>7}  {status_s}{suffix}".rstrip())


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
        if floors.get("package_modules"):
            baseline["package_modules"] = (
                build_baseline(coverage, floors["package_modules"], args.metric)["modules"]
                if collected(coverage, "expected_packages") else floors["package_modules"])
        # A measurement this report did not collect keeps its recorded floors;
        # a local report would otherwise delete the floors CI compares.
        for floors_key, _, _, expected_key in PACKAGE_SCOPES:
            if not collected(coverage, expected_key) and floors_key in floors:
                baseline[floors_key] = floors[floors_key]
        # Keep the recorded exemptions and their reasons.
        for key in ("unmeasured", "_comment", "_comment_packages"):
            if key in floors:
                baseline[key] = floors[key]
        with open(args.floors, "w") as f:
            json.dump(baseline, f, indent=2, ensure_ascii=False)
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
    try:
        rows, all_pass = evaluate(coverage, floors, args.baseline_only, args.metric)
    except ValueError as e:
        log(f"Error: {e}")
        return 2

    for name, reason in floors.get("unmeasured", {}).items():
        log(f"UNMEASURED  {name}: {reason}")
    print_table(rows)

    missing = [r["module"] for r in rows if r.get("missing")]
    if missing:
        log(f"Warning: {len(missing)} module(s) not found in coverage data: "
            f"{', '.join(missing)}")

    advisory = [r["module"] for r in rows if r.get("advisory") and r["status"] == "FAIL"]
    within = [r["module"] for r in rows if r["status"] == "WITHIN"]
    if within:
        print(f"\nWithin the {APP_FLOOR_TOLERANCE * 100:.1f}-point tolerance: {', '.join(within)}")
    if advisory:
        print(f"Below an advisory floor (not blocking): {', '.join(advisory)}")
    if all_pass:
        note = f" ({len(advisory)} advisory below floor)" if advisory else ""
        print(green(f"\nCoverage gate: PASS{note}"))
        return 0
    print(red("\nCoverage gate: FAIL"))
    return 1


if __name__ == "__main__":
    sys.exit(main())
