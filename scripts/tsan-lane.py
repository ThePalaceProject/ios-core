#!/usr/bin/env python3
"""Helpers for the ThreadSanitizer CI job (.github/workflows/tsan.yml).

    tsan-lane.py suites    [--manifest scripts/tsan-suites.txt] [--root .]
        Print the test classes the manifest selects, one per line.
        Exit 2 if a glob matches no file, a named class is not declared in
        PalaceTests, or the selection is empty.

    tsan-lane.py check-log LOG
        Exit 1 if LOG holds any ThreadSanitizer report, printing each one's
        SUMMARY line. Exit 2 if LOG is missing or empty, so a step that never
        wrote its log cannot read as clean.

    tsan-lane.py check-ran TESTS_JSON CLASS [CLASS ...]
        TESTS_JSON is `xcrun xcresulttool get test-results tests` output.
        Exit 1 if any CLASS has no test suite in it: -only-testing ignores a
        name that matches nothing, so a missing suite would otherwise pass.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

TEST_BASES = ("XCTestCase", "PalaceTestCase", "PalaceWiringTestCase")
CLASS_DECL = re.compile(
    r"^[ \t]*(?:@MainActor[ \t]+)?(?:(?:final|private|fileprivate|internal|public|open)[ \t]+)*"
    r"class[ \t]+([A-Za-z0-9_]+)[ \t]*:[ \t]*(?:" + "|".join(TEST_BASES) + r")\b",
    re.MULTILINE,
)
# TSan writes "WARNING: ThreadSanitizer: <kind>" at the start of a report and
# "SUMMARY: ThreadSanitizer: <kind> <location>" at the end. Matching the bare
# token also catches runtime failures such as "ThreadSanitizer: failed to ...".
TSAN_TOKEN = "ThreadSanitizer:"


def test_classes(path: Path) -> list[str]:
    return CLASS_DECL.findall(path.read_text(errors="replace"))


def resolve_suites(manifest: Path, root: Path) -> tuple[list[str], list[str]]:
    """Return (classes, errors)."""
    classes: set[str] = set()
    errors: list[str] = []
    declared: set[str] | None = None
    for lineno, raw in enumerate(manifest.read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        kind, _, value = line.partition(":")
        kind, value = kind.strip(), value.strip()
        if kind == "glob" and value:
            files = sorted(p for p in root.glob(value) if p.is_file())
            if not files:
                errors.append(f"{manifest}:{lineno}: glob matches no file: {value}")
            for f in files:
                classes.update(test_classes(f))
        elif kind == "class" and value:
            if declared is None:
                declared = {name for f in (root / "PalaceTests").rglob("*.swift") for name in test_classes(f)}
            if value not in declared:
                errors.append(f"{manifest}:{lineno}: no PalaceTests file declares test class {value}")
            classes.add(value)
        else:
            errors.append(f"{manifest}:{lineno}: expected 'glob: <pattern>' or 'class: <Name>', got: {raw}")
    if not classes and not errors:
        errors.append(f"{manifest}: selects no test classes")
    return sorted(classes), errors


ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m")


def tsan_reports(text: str) -> list[str]:
    """Return one line per TSan report found in text (empty if none)."""
    hits = [ANSI_ESCAPE.sub("", ln).strip() for ln in text.splitlines() if TSAN_TOKEN in ln]
    summaries = [h for h in hits if h.startswith("SUMMARY:")]
    # A report cut off before its SUMMARY line still counts.
    return summaries or hits


def suites_in_results(tests_json: dict) -> set[str]:
    found: set[str] = set()

    def walk(node: dict) -> None:
        if node.get("nodeType") == "Test Suite":
            found.add(node.get("name", ""))
        for child in node.get("children", []):
            walk(child)

    for node in tests_json.get("testNodes", []):
        walk(node)
    return found


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_suites = sub.add_parser("suites")
    p_suites.add_argument("--manifest", default="scripts/tsan-suites.txt")
    p_suites.add_argument("--root", default=".")
    p_log = sub.add_parser("check-log")
    p_log.add_argument("log")
    p_ran = sub.add_parser("check-ran")
    p_ran.add_argument("tests_json")
    p_ran.add_argument("classes", nargs="+")
    args = parser.parse_args(argv)

    if args.cmd == "suites":
        classes, errors = resolve_suites(Path(args.manifest), Path(args.root))
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        if errors:
            return 2
        print("\n".join(classes))
        return 0

    if args.cmd == "check-log":
        log = Path(args.log)
        if not log.is_file() or log.stat().st_size == 0:
            print(f"error: {log} is missing or empty; nothing was checked", file=sys.stderr)
            return 2
        reports = tsan_reports(log.read_text(errors="replace"))
        if reports:
            print(f"ThreadSanitizer reported {len(reports)} issue(s):")
            for r in reports:
                print(f"  {r}")
            return 1
        print("No ThreadSanitizer reports.")
        return 0

    found = suites_in_results(json.loads(Path(args.tests_json).read_text()))
    missing = sorted(set(args.classes) - found)
    if missing:
        print(f"error: these suites did not run: {', '.join(missing)}", file=sys.stderr)
        return 1
    print(f"All {len(set(args.classes))} suites ran.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
