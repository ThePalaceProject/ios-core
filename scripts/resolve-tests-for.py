#!/usr/bin/env python3
"""
resolve-tests-for.py — given a production Swift file, print the list of
`PalaceTests/<XCTestCaseSubclass>` selectors for `-only-testing:` (one per
line).

Why this exists:
    `xcodebuild -only-testing:` takes either `<bundle>/<class>` or
    `<bundle>/<class>/<method>`. Passing a directory path silently matches
    no class and runs zero tests, but xcodebuild still prints
    `** TEST SUCCEEDED **`. The old verify-pr.sh logic passed
    `PalaceTests/Book` (a directory) — that broke `palace_mutate.py`'s
    baseline run for every changed file, causing the mutation gate to
    silently produce empty reports for months.

How resolution works:
    1. Compute the production file's basename (e.g. `BorrowReducer`).
    2. Find every `*Tests*.swift` under `PalaceTests/` whose filename
       contains the production basename (case-insensitive, with an
       optional `TPP` prefix stripped — so `TPPLCPClient` matches
       `LCPClientTests.swift`).
    3. Grep each match for `class <Name>: XCTestCase` declarations,
       skipping mocks/helpers.
    4. Emit `PalaceTests/<Name>` selectors on stdout.

Exit codes:
    0 — at least one selector printed
    1 — no matching tests found (caller should skip / warn)

Usage:
    scripts/resolve-tests-for.py Palace/Book/UI/BookDetail/BorrowReducer.swift
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_ROOT = REPO_ROOT / "PalaceTests"
CLASS_DECL_RE = re.compile(
    r"^\s*(?:final\s+|public\s+|internal\s+|@MainActor\s+)*class\s+"
    r"([A-Za-z0-9_]+)\s*:\s*[^{]*XCTestCase",
    re.MULTILINE,
)


def candidate_basenames(prod_path: Path) -> list[str]:
    """Production-basename variants to search test filenames against.

    Some production files use the `TPP` prefix that the test files drop
    (`TPPLCPClient.swift` → `LCPClientTests.swift`). Yield both.
    """
    raw = prod_path.stem  # e.g. "TPPLCPClient"
    variants = [raw]
    if raw.startswith("TPP"):
        variants.append(raw[3:])
    return variants


def find_test_files(prod_path: Path) -> list[Path]:
    """All test files whose filename contains any candidate basename."""
    bases = [b.lower() for b in candidate_basenames(prod_path)]
    matches: list[Path] = []
    for swift in TESTS_ROOT.rglob("*Tests*.swift"):
        name_lower = swift.name.lower()
        if any(b.lower() in name_lower for b in bases):
            matches.append(swift)
    # Deterministic order for stable cache keys downstream.
    matches.sort()
    return matches


def extract_classes(test_file: Path) -> list[str]:
    """All XCTestCase subclass names declared in a test file."""
    text = test_file.read_text(encoding="utf-8")
    return CLASS_DECL_RE.findall(text)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: resolve-tests-for.py <production-swift-file>", file=sys.stderr)
        return 2

    prod_path = Path(argv[1])
    if not prod_path.is_absolute():
        prod_path = REPO_ROOT / prod_path

    test_files = find_test_files(prod_path)
    selectors: list[str] = []
    for tf in test_files:
        for cls in extract_classes(tf):
            selectors.append(f"PalaceTests/{cls}")

    # De-dup while preserving order.
    seen: set[str] = set()
    unique: list[str] = []
    for s in selectors:
        if s not in seen:
            seen.add(s)
            unique.append(s)

    if not unique:
        return 1

    for s in unique:
        print(s)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
