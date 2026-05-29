#!/usr/bin/env python3
"""
check-sleep-in-tests.py — Wave 2 lint suite.

Flags `Task.sleep`, `Thread.sleep`, `waitForCondition`, and bare `sleep(...)`
calls in PalaceTests/. Sleep-based waits make tests CI-flaky and inflate
test-suite walltime. Use `XCTestExpectation`, `XCTWaiter`, or `withCheckedContinuation`
plus a driven async-await test seam instead.

Allowlist: `// allow-sleep: <reason>` marker on the line OR within 2 lines
above. Reason is mandatory (the colon-suffix); a bare `// allow-sleep` is
not honored.

Source: swarm_f88ae9e3 investigation B. Baseline: 168 sleep sites across
PalaceTests (audit 2026-05-29). Goal of this lint: prevent NEW sites; the
existing baseline is cleared in a separate sweep.

Usage:
  python3 scripts/check-sleep-in-tests.py [--quiet] [--diff <path>]
                                          [--file <path>] [<path> ...]

Exit codes:
  0 — clean
  1 — at least one unmarked sleep site found
  2 — argument / file-read error
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable


# --- Risk patterns ---------------------------------------------------------

# Each entry is a regex against a stripped source line.
RISK_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\bTask\.sleep\s*\("), "Task.sleep(...)"),
    (re.compile(r"\bThread\.sleep\s*\("), "Thread.sleep(...)"),
    (re.compile(r"\bwaitForCondition\s*\("), "waitForCondition(...)"),
    # Bare `sleep(...)` — avoid matching `Thread.sleep(` / `Task.sleep(` already.
    (re.compile(r"(?<![A-Za-z0-9_.])sleep\s*\("), "sleep(...)"),
    # `try? await Task.sleep` variant — the Task.sleep pattern catches it too,
    # but include for the `try await ... .sleep` form on a wrapped Task.
    (re.compile(r"\busleep\s*\("), "usleep(...)"),
)

MARKER_PREFIX = "allow-sleep:"
MARKER_LOOKBACK_LINES = 2


# --- Path-level carveouts --------------------------------------------------

CARVEOUT_BASENAMES = frozenset((
    # Sleep-helper definition sites are legitimate.
    "TestSleep.swift",
    "TestTimingHelpers.swift",
))


def _is_carveout(path: Path) -> bool:
    return path.name in CARVEOUT_BASENAMES


# --- Comment stripping (line-local) ---------------------------------------

def _strip_line_comments_and_strings(line: str) -> str:
    out: list[str] = []
    i, n = 0, len(line)
    in_str = False
    while i < n:
        ch = line[i]
        nxt = line[i + 1] if i + 1 < n else ""
        if not in_str and ch == "/" and nxt == "/":
            out.append(" " * (n - i))
            break
        if ch == '"':
            in_str = not in_str
            out.append(" ")
            i += 1
            continue
        out.append(" " if in_str else ch)
        i += 1
    return "".join(out)


# --- Marker handling ------------------------------------------------------

def _line_has_marker(line: str) -> bool:
    return MARKER_PREFIX in line and f"// {MARKER_PREFIX}" in line


def _lookback_has_marker(lines: list[str], idx: int) -> bool:
    start = max(0, idx - MARKER_LOOKBACK_LINES)
    for j in range(start, idx + 1):
        if _line_has_marker(lines[j]):
            return True
    return False


# --- Scanner --------------------------------------------------------------

def scan_file(path: Path) -> list[str]:
    if _is_carveout(path):
        return []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        print(f"ERROR: cannot read {path}: {e}", file=sys.stderr)
        sys.exit(2)
    lines = text.split("\n")
    findings: list[str] = []
    for idx, raw in enumerate(lines):
        stripped = _strip_line_comments_and_strings(raw)
        for regex, label in RISK_PATTERNS:
            if not regex.search(stripped):
                continue
            if _lookback_has_marker(lines, idx):
                continue
            findings.append(
                f"{path}:{idx + 1}: SLEEP-IN-TEST: {label} — replace with "
                f"`XCTestExpectation` / `XCTWaiter` or add "
                f"`// {MARKER_PREFIX} <reason>` marker."
            )
    return findings


# --- Diff parsing ----------------------------------------------------------

_DIFF_FILE_RE = re.compile(r"^\+\+\+\s+b/(.+)$", re.MULTILINE)


def _files_from_diff(diff_path: Path) -> list[Path]:
    try:
        text = diff_path.read_text(encoding="utf-8")
    except OSError as e:
        print(f"ERROR: cannot read diff {diff_path}: {e}", file=sys.stderr)
        sys.exit(2)
    out: list[Path] = []
    for m in _DIFF_FILE_RE.finditer(text):
        p = Path(m.group(1))
        if p.suffix == ".swift" and "PalaceTests" in p.parts:
            out.append(p)
    return out


# --- CLI -------------------------------------------------------------------

def _iter_targets(args: argparse.Namespace) -> Iterable[Path]:
    seen: set[Path] = set()
    if args.diff:
        for p in _files_from_diff(Path(args.diff)):
            if p not in seen and p.exists():
                seen.add(p)
                yield p
    if args.file:
        for f in args.file:
            p = Path(f)
            if p not in seen:
                seen.add(p)
                yield p
    for f in args.paths:
        p = Path(f)
        if p.is_dir():
            for sub in sorted(p.rglob("*.swift")):
                if sub not in seen:
                    seen.add(sub)
                    yield sub
        elif p not in seen:
            seen.add(p)
            yield p


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-sleep-in-tests.py",
        description=(
            "Flag Task.sleep / Thread.sleep / waitForCondition / sleep(...) "
            "calls in PalaceTests without `// allow-sleep: <reason>` marker."
        ),
    )
    parser.add_argument("paths", nargs="*",
                        help="Swift test files or directories.")
    parser.add_argument("--diff", default=None,
                        help="Unified-diff file; scan only changed PalaceTests.")
    parser.add_argument("--file", action="append", default=[],
                        help="Explicit file to scan (repeatable).")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress success summary on stderr.")
    args = parser.parse_args(argv)

    targets = [p for p in _iter_targets(args)
               if p.exists() and p.suffix == ".swift"]

    failures: list[str] = []
    for p in targets:
        failures.extend(scan_file(p))

    for fail in failures:
        print(fail, file=sys.stderr)

    if not args.quiet:
        if failures:
            print(
                f"\n{len(failures)} sleep-in-test finding(s) across "
                f"{len(targets)} file(s).\n"
                f"Source: swarm_f88ae9e3 investigation B (168 baseline; "
                f"goal: prevent NEW sites).",
                file=sys.stderr,
            )
        else:
            print(
                f"OK: {len(targets)} file(s) checked, 0 sleep findings.",
                file=sys.stderr,
            )

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
