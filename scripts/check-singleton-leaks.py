#!/usr/bin/env python3
"""
check-singleton-leaks.py — Wave 2 lint suite.

Scans PalaceTests/*.swift for tests that touch real singleton-backed
production state without an opt-in marker. Three risk patterns are flagged:

  1. `AccountsManager(` — constructing a real AccountsManager (not a mock).
     Allow with `// allow-real-accounts-manager:` marker on the same line
     OR within 2 lines above.

  2. `TPPUserAccount.sharedAccount(libraryUUID:` — touching the real
     keychain-backed user-account singleton. Allow with
     `// allow-real-tppuser-account:` marker (same rule).

  3. `NotificationCenter.default.post(name: .TPP...)` — broadcasting a
     `.TPP*` notification on the default center (which every test class
     subscribes to). Allow with `// allow-default-center-broadcast:` marker.

Carveouts (no marker required):
  - The base test class file itself (`TPPTestCase.swift`,
    `BaseTestCase.swift`, `KeychainBackedTestCase.swift`, etc.) is allowed
    to construct real singletons in shared setup; classes that INHERIT
    still need markers on their own bodies because the rule is per-line.
  - Mock files under `PalaceTests/Mocks/` (their job is to wrap real types).

Source: swarm_f88ae9e3 investigation A (singleton-leak audit).

Usage:
  python3 scripts/check-singleton-leaks.py [--quiet] [--diff <path>]
                                           [--file <path>] [<path> ...]

Exit codes:
  0 — clean
  1 — at least one unmarked singleton-touch site found
  2 — argument / file-read error
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable


# --- Risk patterns ---------------------------------------------------------

# (regex, marker_token, human_label) for each risk pattern.
RISK_PATTERNS = (
    (
        re.compile(r"(?<![A-Za-z0-9_])AccountsManager\("),
        "allow-real-accounts-manager",
        "real AccountsManager construction",
    ),
    (
        re.compile(r"TPPUserAccount\.sharedAccount\s*\(\s*libraryUUID\s*:"),
        "allow-real-tppuser-account",
        "TPPUserAccount.sharedAccount(libraryUUID:)",
    ),
    (
        re.compile(r"NotificationCenter\.default\.post\s*\(\s*name\s*:\s*\.TPP"),
        "allow-default-center-broadcast",
        "NotificationCenter.default.post(name: .TPP…)",
    ),
)

MARKER_LOOKBACK_LINES = 2


# --- Carveouts -------------------------------------------------------------

# File basenames that are allowed to touch real singletons without markers.
CARVEOUT_BASENAMES = frozenset((
    "TPPTestCase.swift",
    "BaseTestCase.swift",
    "KeychainBackedTestCase.swift",
    "KeychainAvailability.swift",  # the gating helper itself
))

# Path-segment carveouts (any path component matching → skipped).
CARVEOUT_PATH_SEGMENTS = ("Mocks",)


def _is_carveout(path: Path) -> bool:
    if path.name in CARVEOUT_BASENAMES:
        return True
    for part in path.parts:
        if part in CARVEOUT_PATH_SEGMENTS:
            return True
    return False


# --- Comment / string stripping -------------------------------------------

def _strip_line_comments_and_strings(line: str) -> str:
    """
    Replace `// ...`, `/* ... */` (single-line), and string literals with
    spaces. Multi-line strings would need a parser; for lint purposes the
    line-local strip is sufficient since the risky tokens are code idioms,
    not string content.
    """
    out: list[str] = []
    i, n = 0, len(line)
    in_str = False
    while i < n:
        ch = line[i]
        nxt = line[i + 1] if i + 1 < n else ""
        if not in_str and ch == "/" and nxt == "/":
            # Rest of line is a comment.
            out.append(" " * (n - i))
            break
        if not in_str and ch == "/" and nxt == "*":
            # Find closing */ on the same line; if none, drop rest.
            end = line.find("*/", i + 2)
            if end < 0:
                out.append(" " * (n - i))
                break
            out.append(" " * (end + 2 - i))
            i = end + 2
            continue
        if ch == '"':
            in_str = not in_str
            out.append(" ")
            i += 1
            continue
        if in_str:
            out.append(" ")
        else:
            out.append(ch)
        i += 1
    return "".join(out)


# --- Marker detection ------------------------------------------------------

def _line_has_marker(line: str, marker: str) -> bool:
    """A marker is `// <marker>:` anywhere in the source line (not stripped)."""
    return f"// {marker}:" in line


def _lookback_has_marker(lines: list[str], idx: int, marker: str) -> bool:
    start = max(0, idx - MARKER_LOOKBACK_LINES)
    for j in range(start, idx + 1):
        if _line_has_marker(lines[j], marker):
            return True
    return False


# --- Scanning --------------------------------------------------------------

def scan_file(path: Path) -> list[str]:
    """Return a list of greppable failure lines for this file."""
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
        for regex, marker, label in RISK_PATTERNS:
            if not regex.search(stripped):
                continue
            if _lookback_has_marker(lines, idx, marker):
                continue
            findings.append(
                f"{path}:{idx + 1}: SINGLETON-LEAK: {label} — "
                f"add `// {marker}: <reason>` marker on this line or "
                f"within {MARKER_LOOKBACK_LINES} lines above, or replace "
                f"with a mock."
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
        prog="check-singleton-leaks.py",
        description=(
            "Detect PalaceTests files that touch real singleton-backed "
            "state (AccountsManager, TPPUserAccount.sharedAccount, "
            "NotificationCenter.default broadcast of .TPP*) without an "
            "opt-in `// allow-...:` marker."
        ),
    )
    parser.add_argument("paths", nargs="*",
                        help="Swift test files or directories to scan.")
    parser.add_argument("--diff", default=None,
                        help="Unified-diff file; scan only added/modified "
                             "PalaceTests Swift files.")
    parser.add_argument("--file", action="append", default=[],
                        help="Explicit file to scan (repeatable).")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress success summary on stderr.")
    args = parser.parse_args(argv)

    targets: list[Path] = []
    for p in _iter_targets(args):
        if not p.exists():
            continue
        if p.suffix != ".swift":
            continue
        targets.append(p)

    failures: list[str] = []
    for p in targets:
        failures.extend(scan_file(p))

    for fail in failures:
        print(fail, file=sys.stderr)

    if not args.quiet:
        if failures:
            print(
                f"\n{len(failures)} singleton-leak finding(s) across "
                f"{len(targets)} file(s).\n"
                f"Source: swarm_f88ae9e3 investigation A.",
                file=sys.stderr,
            )
        else:
            print(
                f"OK: {len(targets)} file(s) checked, 0 singleton leaks.",
                file=sys.stderr,
            )

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
