#!/usr/bin/env python3
"""
test_coverage_classifier.py — turn raw line coverage into a systematic test plan.

Reads `xcrun xccov` output and classifies every uncovered (or under-covered)
file as one of:

  unit         — pure logic, models, view models, services, parsers
  integration  — multi-component (registry+downloader, network+queue)
  snapshot     — SwiftUI views, UIKit cells, view controllers
  e2e          — flows requiring real navigation / simulator
  none         — generated code, framework conformance, app lifecycle hooks

Outputs a prioritized to-do list per category, sorted by uncovered LOC,
plus a JSON manifest for downstream tooling (test-writing agents).

Usage:
    xcrun xccov view --report --files-for-target Palace.app TestResults.xcresult \\
      | scripts/test_coverage_classifier.py --plan-out test-plan.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, asdict, field
from typing import Any

REPO_ROOT = "/Users/mauricework/PalaceProject/ios-core"

# Coverage threshold below which we consider a file "needs more tests"
DEFAULT_COVERAGE_THRESHOLD = 60.0  # percent
# Minimum lines for a file to be worth attention (skip tiny files)
MIN_LINES = 50


@dataclass
class FileCoverage:
    path: str           # repo-relative
    coverage_pct: float
    covered_lines: int
    total_lines: int
    func_count: int
    category: str = "unknown"
    reason: str = ""

    @property
    def uncovered_lines(self) -> int:
        return self.total_lines - self.covered_lines


# ---------------------------------------------------------------------------
# Classification rules
# ---------------------------------------------------------------------------

# Rules are tried in order. First match wins.
# Each rule: (predicate, category, reason)

NONE_PATTERNS = [
    (r".*/AppDelegate.*\.swift$", "none", "AppDelegate hooks — exercised at runtime, not unit-testable"),
    (r".*/SceneDelegate.*\.swift$", "none", "SceneDelegate hooks"),
    (r".*\.generated\.swift$", "none", "Generated code"),
    (r".*/R\.generated\.swift$", "none", "Generated resources"),
    (r".*/Strings\.swift$", "none", "Localization key constants"),
    (r".*/Bundle\+.*\.swift$", "none", "Bundle convenience"),
    (r".*Stub\.swift$", "none", "Test stub file"),
    (r".*/Generated/.*\.swift$", "none", "Generated directory"),
    (r".*/Mocks/.*\.swift$", "none", "Mock used by tests, not production"),
]

E2E_PATTERNS = [
    (r".*/CarPlay/.*\.swift$", "e2e", "CarPlay templates need a connected car / external display — simdrive"),
    (r".*/AppInfrastructure/.*Coordinator\.swift$", "e2e", "Navigation coordinator drives flows — simdrive"),
]

SNAPSHOT_PATTERNS = [
    (r".*/Views/.*View\.swift$", "snapshot", "SwiftUI view — snapshot test"),
    (r".*View\.swift$", "snapshot", "SwiftUI/UIKit view — snapshot test"),
    (r".*Cell\.swift$", "snapshot", "Cell — snapshot test"),
    (r".*ViewController\.swift$", "snapshot", "View controller — snapshot the rendered states"),
    (r".*/UI/.*\.swift$", "snapshot", "UI layer — snapshot test"),
    (r".*Sheet\.swift$", "snapshot", "Bottom sheet view — snapshot test"),
    (r".*/Typography/.*Picker.*\.swift$", "snapshot", "Picker UI — snapshot test"),
    (r".*/Typography/.*View.*\.swift$", "snapshot", "Typography view — snapshot test"),
]

INTEGRATION_PATTERNS = [
    (r".*DownloadCenter\.swift$", "integration", "Download orchestration — multi-service integration tests"),
    (r".*Registry\.swift$", "integration", "Registry coordinates state across components"),
    (r".*Service\.swift$", "integration", "Service often coordinates multiple components"),
    (r".*BusinessLogic\.swift$", "integration", "Business logic often spans services"),
    (r".*\+Async\.swift$", "integration", "Async extension typically wraps multi-step flows"),
    (r".*/Migrations/.*\.swift$", "integration", "Migrations need before/after state assertions"),
]

UNIT_PATTERNS = [
    (r".*ViewModel\.swift$", "unit", "ViewModel — pure unit test with injected deps"),
    (r".*Model\.swift$", "unit", "Model — unit test"),
    (r".*/Models/.*\.swift$", "unit", "Model — unit test"),
    (r".*Mapper\.swift$", "unit", "Mapper — pure function unit test"),
    (r".*Parser\.swift$", "unit", "Parser — unit test with fixture inputs"),
    (r".*Validator\.swift$", "unit", "Validator — unit test"),
    (r".*Helper\.swift$", "unit", "Helper — unit test"),
    (r".*/Utilities/.*\.swift$", "unit", "Utility — unit test"),
    (r".*\+.*\.swift$", "unit", "Type extension — unit test"),
    (r".*Provider\.swift$", "unit", "Provider — unit test with mock dependencies"),
    (r".*/Protocols?/.*\.swift$", "none", "Protocol declaration — no logic"),
]


def classify(path: str) -> tuple[str, str]:
    """Return (category, reason) for a file path. Order matters.

    Priority order:
      1. NONE — generated/lifecycle files we won't unit-test
      2. NAME-based UNIT/INTEGRATION rules (Service, ViewModel, Logic, Mapper, …)
         These run BEFORE path-based UI rules so that BookService.swift living
         in /UI/ still gets correctly classified as integration.
      3. E2E — CarPlay, navigation coordinator
      4. SNAPSHOT — path-based UI fallback
      5. Default to unit
    """
    # 1. NONE rules first
    for pat, cat, reason in NONE_PATTERNS:
        if re.match(pat, path):
            return (cat, reason)

    # 2. Name-based content rules (split out from the path-based UI rules)
    name_rules = [
        (r".*ViewModel\.swift$", "unit", "ViewModel — unit test with injected deps"),
        (r".*BusinessLogic\.swift$", "integration", "Business logic — integration test"),
        (r".*Service\.swift$", "integration", "Service coordinates components — integration test"),
        (r".*\+Async\.swift$", "integration", "Async extension wraps multi-step flows"),
        (r".*Mapper\.swift$", "unit", "Mapper — pure function unit test"),
        (r".*Parser\.swift$", "unit", "Parser — unit test with fixture inputs"),
        (r".*Validator\.swift$", "unit", "Validator — unit test"),
        (r".*Helper\.swift$", "unit", "Helper — unit test"),
        (r".*Provider\.swift$", "unit", "Provider — unit test with mock dependencies"),
        (r".*Mocker\.swift$", "none", "Mock factory used by tests"),
        (r".*DownloadCenter\.swift$", "integration", "Download orchestration — integration test"),
        (r".*Registry\.swift$", "integration", "Registry coordinates state — integration test"),
        (r".*Manager\.swift$", "integration", "Manager coordinates components — integration test"),
        (r".*Tracker\.swift$", "unit", "Tracker — unit test with stubs"),
        (r".*Bootstrapper\.swift$", "integration", "Bootstrap path — integration test"),
        (r".*Interceptor\.swift$", "integration", "Interceptor — integration test"),
    ]
    for pat, cat, reason in name_rules:
        if re.match(pat, path):
            return (cat, reason)

    # 3. E2E
    for pat, cat, reason in E2E_PATTERNS:
        if re.match(pat, path):
            return (cat, reason)

    # 4. Snapshot (path-based UI) — fires only if name rules above didn't match
    for pat, cat, reason in SNAPSHOT_PATTERNS:
        if re.match(pat, path):
            return (cat, reason)

    # 5. Remaining unit rules (extensions, models, utilities)
    leftover_unit = [
        (r".*Model\.swift$", "unit", "Model — unit test"),
        (r".*/Models/.*\.swift$", "unit", "Model — unit test"),
        (r".*/Utilities/.*\.swift$", "unit", "Utility — unit test"),
        (r".*\+.*\.swift$", "unit", "Type extension — unit test"),
        (r".*/Protocols?/.*\.swift$", "none", "Protocol declaration — no logic"),
        (r".*/Migrations/.*\.swift$", "integration", "Migration — before/after assertions"),
    ]
    for pat, cat, reason in leftover_unit:
        if re.match(pat, path):
            return (cat, reason)

    # 6. Default
    return ("unit", "Default — assume unit-testable until proven otherwise")


# ---------------------------------------------------------------------------
# xccov parsing
# ---------------------------------------------------------------------------

XCCOV_LINE = re.compile(r"\s*\d+\s+(\S+)\s+(\d+)\s+([\d.]+)%\s+\((\d+)/(\d+)\)")


def parse_xccov(stream) -> list[FileCoverage]:
    """Parse `xcrun xccov view --report --files-for-target X` output."""
    out = []
    for ln in stream:
        m = XCCOV_LINE.match(ln)
        if not m:
            continue
        path, funcs, pct, covered, total = m.groups()
        rel = path.replace(REPO_ROOT + "/", "")
        out.append(FileCoverage(
            path=rel,
            coverage_pct=float(pct),
            covered_lines=int(covered),
            total_lines=int(total),
            func_count=int(funcs),
        ))
    return out


# ---------------------------------------------------------------------------
# Plan emission
# ---------------------------------------------------------------------------

def emit_plan(files: list[FileCoverage], threshold: float, min_lines: int) -> dict[str, Any]:
    """Build a structured plan dict bucketed by category and prioritized."""
    # Filter to substantive files needing attention
    needs_work = [f for f in files if f.coverage_pct < threshold and f.total_lines >= min_lines]

    # Classify each
    for f in needs_work:
        cat, reason = classify(f.path)
        f.category = cat
        f.reason = reason

    # Bucket by category, sort within bucket by uncovered LOC desc
    buckets: dict[str, list[FileCoverage]] = {}
    for f in needs_work:
        buckets.setdefault(f.category, []).append(f)
    for cat in buckets:
        buckets[cat].sort(key=lambda x: -x.uncovered_lines)

    # Aggregate stats
    totals = {
        "files_total": len(files),
        "files_needing_work": len(needs_work),
        "files_meeting_threshold": len(files) - len(needs_work),
        "uncovered_lines_total": sum(f.uncovered_lines for f in needs_work),
        "covered_lines_total": sum(f.covered_lines for f in files),
        "all_lines_total": sum(f.total_lines for f in files),
    }
    totals["overall_coverage_pct"] = round(
        totals["covered_lines_total"] / totals["all_lines_total"] * 100, 1
    ) if totals["all_lines_total"] else 0.0

    by_category_summary = {}
    for cat, items in buckets.items():
        by_category_summary[cat] = {
            "file_count": len(items),
            "uncovered_lines": sum(i.uncovered_lines for i in items),
            "files": [
                {
                    "path": f.path,
                    "coverage_pct": f.coverage_pct,
                    "uncovered_lines": f.uncovered_lines,
                    "total_lines": f.total_lines,
                    "func_count": f.func_count,
                    "reason": f.reason,
                }
                for f in items
            ],
        }

    return {
        "thresholds": {"coverage_pct": threshold, "min_lines": min_lines},
        "totals": totals,
        "categories": by_category_summary,
    }


# ---------------------------------------------------------------------------
# Pretty printing
# ---------------------------------------------------------------------------

CATEGORY_ORDER = ["unit", "integration", "snapshot", "e2e", "none"]


def print_plan(plan: dict[str, Any], top_n: int = 15) -> None:
    t = plan["totals"]
    print()
    print("=" * 78)
    print(f"Test coverage classification — Palace iOS")
    print("=" * 78)
    print(f"Overall line coverage:      {t['overall_coverage_pct']}%")
    print(f"Files measured:             {t['files_total']}")
    print(f"Files meeting threshold:    {t['files_meeting_threshold']}")
    print(f"Files needing work:         {t['files_needing_work']}")
    print(f"Uncovered lines (in scope): {t['uncovered_lines_total']:,}")
    print()

    for cat in CATEGORY_ORDER:
        if cat not in plan["categories"]:
            continue
        info = plan["categories"][cat]
        print(f"--- {cat.upper():<12} {info['file_count']:>3} files  {info['uncovered_lines']:>7,} uncovered lines")
        for f in info["files"][:top_n]:
            cov = f["coverage_pct"]
            print(f"  {cov:>5.1f}%  {f['uncovered_lines']:>5}/{f['total_lines']:<5}  {f['path']}")
        if len(info["files"]) > top_n:
            print(f"  ... and {len(info['files']) - top_n} more")
        print()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description="Classify uncovered Palace iOS files by test approach")
    p.add_argument("--xccov-input", help="Path to xccov output file (default: stdin)")
    p.add_argument("--threshold", type=float, default=DEFAULT_COVERAGE_THRESHOLD,
                   help="Files at or above this coverage are considered done")
    p.add_argument("--min-lines", type=int, default=MIN_LINES,
                   help="Skip files with fewer than this many lines")
    p.add_argument("--plan-out", help="Write JSON plan manifest to this path")
    p.add_argument("--top-n", type=int, default=15, help="Show top N files per category")
    p.add_argument("--category", help="Print only this category (unit/integration/snapshot/e2e/none)")
    args = p.parse_args()

    if args.xccov_input:
        with open(args.xccov_input) as f:
            files = parse_xccov(f)
    else:
        files = parse_xccov(sys.stdin)

    if not files:
        print("error: no files parsed from xccov input", file=sys.stderr)
        return 2

    plan = emit_plan(files, args.threshold, args.min_lines)

    if args.category:
        # Trim categories to just the requested one
        plan["categories"] = {k: v for k, v in plan["categories"].items() if k == args.category}

    print_plan(plan, top_n=args.top_n)

    if args.plan_out:
        with open(args.plan_out, "w") as f:
            json.dump(plan, f, indent=2)
        print(f"plan manifest: {args.plan_out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
