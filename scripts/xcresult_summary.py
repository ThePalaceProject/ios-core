#!/usr/bin/env python3
"""Authoritative pass/fail tallies and failing class names from an .xcresult.

WHY THIS EXISTS. `verify-pr.sh` derived its unit-test tally by scraping
xcodebuild's stdout for `Test Suite 'All tests' passed` followed by
`Executed N tests`. Under parallel-clone execution — which is how both CI and
the local optimized script run — xcodebuild emits per-test-case lines
(`Test case 'X.y()' passed on 'Clone 1 of iPhone 16 Pro'`) and those top-level
rollups are absent or partial. The scrape then reports a number with no
relationship to what ran.

Observed on one branch, same tree, three consecutive runs: the gate reported
`2815 tests, 1 failures`, then `4786 tests, 1 failures`, then `0 tests, 0
failures`, while the corresponding xcresults held 8246/7, 8250/5, and a full
green. A gate that under-reports failures is worse than no gate, because it is
believed. The xcresult is the artifact Xcode itself writes and is the only
tally worth quoting.

Pure functions take already-parsed JSON so they can be tested without a real
xcresult bundle; the CLI shells out to `xcrun xcresulttool`.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

# An XCTest class name. Used to pick the class out of a test-node path like
# "Palace > PalaceTests > MyTests > testThing()".
_CLASS_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*Tests?$")


def tally(summary: dict) -> tuple[int, int]:
    """(passed, failed) from `xcresulttool get test-results summary` JSON."""
    return int(summary.get("passedTests") or 0), int(summary.get("failedTests") or 0)


def failing_test_names(summary: dict) -> list[str]:
    """Test names from the summary's `testFailures`, in the order reported."""
    return [f.get("testName", "") for f in (summary.get("testFailures") or []) if f.get("testName")]


def failing_classes(tests: dict) -> list[str]:
    """Sorted XCTest class names owning at least one failed test case.

    Walks `xcresulttool get test-results tests` JSON, keyed on `nodeType`:
    a test is `"Test Case"`, its owning class is the nearest enclosing
    `"Test Suite"`.

    A FAILED TEST CASE IS NOT A LEAF. Its children are `"Failure Message"`
    nodes carrying the assertion text, so the obvious "leaf nodes are the
    tests" rule excludes precisely the failures being looked for and returns
    an empty list on a run that failed. That was the first implementation
    here, and it passed a full suite of hand-written fixtures before a real
    xcresult showed the shape was invented — the same class of error as
    `--diff-baseline`'s own extractor, which this replaces.

    Tolerant of both `children` and `testNodes`: the root uses `testNodes`
    and every level below it uses `children`. Falls back to matching a
    class-shaped name in the path when `nodeType` is absent, so an older or
    future bundle degrades to a guess rather than to silence.
    """
    found: set[str] = set()

    def walk(node: dict, suite: str | None, path: list[str]) -> None:
        name = node.get("name", "")
        kind = node.get("nodeType")
        here = path + [name] if name else path

        if kind == "Test Suite" and name:
            suite = name
        if kind == "Test Case" and node.get("result") == "Failed":
            owner = suite
            if owner is None:  # no nodeType information — recover from the path
                owner = next((p for p in reversed(here[:-1]) if _CLASS_RE.match(p)), None)
            if owner:
                found.add(owner)

        for kid in (node.get("children") or []) + (node.get("testNodes") or []):
            walk(kid, suite, here)

    walk(tests, None, [])
    return sorted(found)


def _xcresulttool(kind: str, path: str) -> dict:
    out = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", kind, "--path", path, "--format", "json"],
        capture_output=True, text=True,
    )
    if out.returncode != 0 or not out.stdout.strip():
        raise SystemExit(f"xcresulttool {kind} failed for {path}: {out.stderr.strip()[:200]}")
    return json.loads(out.stdout)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--path", required=True, help="Path to the .xcresult bundle")
    ap.add_argument("--mode", choices=["tally", "classes", "names"], default="tally")
    args = ap.parse_args()

    if args.mode == "classes":
        print("\n".join(failing_classes(_xcresulttool("tests", args.path))))
        return 0

    summary = _xcresulttool("summary", args.path)
    if args.mode == "names":
        print("\n".join(failing_test_names(summary)))
        return 0

    passed, failed = tally(summary)
    print(f"{passed} {failed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
