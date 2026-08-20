#!/usr/bin/env python3
"""
check-raising-unarchiver.py — ban the RAISING `NSKeyedUnarchiver` reads in the
app target (`Palace/**/*.swift`).

`NSKeyedUnarchiver.unarchiveObject(with:)` and `unarchiveObject(withFile:)`
signal a corrupt archive by RAISING an ObjC exception
(`NSInvalidUnarchiveOperationException` /
`NSArchiverArchiveInconsistency`), which cannot be caught from Swift — `try?`
does not help, and the process aborts.

This is measured, not assumed. Bit-flipping each byte of a valid archive in
turn and counting process aborts:

    archived [String: String] (277 bytes)   legacy 63 aborts   modern 0
    archived String           (156 bytes)   legacy  2 aborts   modern 0

Garbage bytes and truncated archives both return nil, so a casual probe finds
nothing — real on-disk corruption is bit-level, and that is the shape that
kills these calls. Two live examples of why it matters:

  - `TPPNetworkQueue` read persisted request headers this way on the launch
    path (offline-queue purge) and on the drain path (PP-4987).
  - `TPPKeychainManager.validateKeychain()` is called from
    `TPPAppDelegate.performBackgroundStartupTasks()` on EVERY launch, and read
    keychain blobs this way. A corrupt item there is an unrecoverable launch
    crash loop — the patron cannot get past it without reinstalling, which
    costs them their downloaded books.

Approved replacements:

    NSKeyedUnarchiver.unarchivedObject(ofClasses:from:)     // typed, throws
    NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(_:)   // untyped, throws

Both return nil / throw on corruption instead of aborting. Prefer the first
when the expected classes are known; the second preserves "any archived type"
semantics where the value is genuinely untyped.

Scope: `Palace/**/*.swift` (app target). Tests, mocks, previews and scripts are
excluded — a test may legitimately construct the legacy call to prove it aborts.

False-positive escape hatch: `// no-raising-unarchiver: <reason>` on the
violating line or any of the 3 preceding lines.

Flags (mirror the sibling pre-commit detectors):
  --diff <file>        Unified-diff input. `-` or omit for stdin.
  --scan <repo-root>   Walk `<root>/Palace/**/*.swift` directly instead of a diff.
  --severity-floor LVL Block at LVL or higher (low|medium|high). Default high.
  --no-block           Print findings, always exit 0.
  --quiet              Suppress trailing summary line on stderr.
  --dry-run            Parse only; never exit non-zero on findings.

Exit codes:
  0  — no findings at or above the severity floor (default: high)
  1  — at least one finding at or above the floor
  2  — argument or I/O error
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from _checklib import at_or_above, iter_hunk_lines, read_diff

_at_or_above = at_or_above

# `unarchiveObject(with:)` / `unarchiveObject(withFile:)` — the raising forms.
# `unarchiveTopLevelObjectWithData` and `unarchivedObject(ofClasses:` are the
# approved throwing forms and must NOT match; the `(?!TopLevel)` guard and the
# explicit `with(?:File)?:` argument label keep them out.
_RE_RAISING_UNARCHIVE = re.compile(
    r"NSKeyedUnarchiver\s*\.\s*unarchiveObject\s*\(\s*with(?:File)?\s*:"
)

_PATTERNS: tuple[tuple[str, re.Pattern, str], ...] = (
    ("unarchiveObject", _RE_RAISING_UNARCHIVE,
     "`NSKeyedUnarchiver.unarchiveObject(with:)` RAISES an uncatchable ObjC "
     "exception on a corrupt archive (measured: 63 of 277 bit-flips abort)"),
)

_RE_NO_BAN_ANNOTATION = re.compile(r"//\s*no-raising-unarchiver\b", re.IGNORECASE)

_NON_PROD_PATH_SUBSTRINGS = (
    "PalaceTests/",
    "Tests/",
    "TestSupport/",
    "Utilities/Testing/",
    "Preview Content/",
    "Mocks/",
    ".forgeos/",
    "scripts/_fixtures/",
    "scripts/tests/",
)


def _is_non_prod_swift(path: str) -> bool:
    return any(s in path for s in _NON_PROD_PATH_SUBSTRINGS)


@dataclass
class _Finding:
    code: str
    severity: str
    file_path: str
    line_no: int
    description: str

    def render(self) -> str:
        return (f"{self.file_path}:{self.line_no}: "
                f"{self.code}: {self.severity}: {self.description}")


def _line_no_at_offset(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def _is_in_comment(source: str, offset: int) -> bool:
    """True when `offset` sits inside a comment rather than in code.

    Naming a banned API in prose is how you DOCUMENT the ban — this detector's
    own header does it, and so does the fix's explanatory comment. A detector
    that fires on its own documentation trains people to ignore it, which is
    the failure mode these checks exist to prevent.

    Handles `//` line comments (including trailing) and `/* */` blocks. A `//`
    inside a string literal is not treated as a comment start, which keeps a
    URL like "https://…" from masking real code after it.
    """
    line_start = source.rfind("\n", 0, offset) + 1
    prefix = source[line_start:offset]
    in_string = False
    i = 0
    while i < len(prefix):
        ch = prefix[i]
        if ch == "\\":
            i += 2
            continue
        if ch == '"':
            in_string = not in_string
        elif not in_string and prefix.startswith("//", i):
            return True
        i += 1

    # Block comment: an unclosed `/*` anywhere before the match.
    opened = source.rfind("/*", 0, offset)
    if opened != -1 and source.rfind("*/", 0, offset) < opened:
        return True
    # A `*`-aligned continuation line inside a block comment.
    return prefix.lstrip().startswith("*")


def _has_annotation(lines: list[str], call_line: int) -> bool:
    start = max(1, call_line - 3)
    for ln in range(start, call_line + 1):
        if ln < 1 or ln > len(lines):
            continue
        if _RE_NO_BAN_ANNOTATION.search(lines[ln - 1]):
            return True
    return False


def _scan_file(rel_path: str, source: str) -> list[_Finding]:
    if _is_non_prod_swift(rel_path) or not rel_path.endswith(".swift"):
        return []
    lines = source.splitlines()
    findings: list[_Finding] = []
    for _name, rx, desc in _PATTERNS:
        for m in rx.finditer(source):
            if _is_in_comment(source, m.start()):
                continue
            line_no = _line_no_at_offset(source, m.start())
            if _has_annotation(lines, line_no):
                continue
            findings.append(_Finding(
                code="RUA-1",
                severity="high",
                file_path=rel_path,
                line_no=line_no,
                description=(
                    f"{desc}. Use `unarchivedObject(ofClasses:from:)` when the "
                    "expected classes are known, or "
                    "`unarchiveTopLevelObjectWithData(_:)` when the value is "
                    "genuinely untyped — both throw instead of aborting."
                ),
            ))
    findings.sort(key=lambda f: (f.file_path, f.line_no))
    return findings


def _scan_diff(diff_text: str, repo_root: Path) -> list[_Finding]:
    touched: dict[str, set[int]] = {}
    for dl in iter_hunk_lines(diff_text):
        if dl.kind != "+":
            continue
        if not dl.file_path.endswith(".swift"):
            continue
        if _is_non_prod_swift(dl.file_path):
            continue
        touched.setdefault(dl.file_path, set()).add(dl.line_no)

    out: list[_Finding] = []
    for rel_path, added_lines in touched.items():
        on_disk = repo_root / rel_path
        if on_disk.is_file():
            try:
                source = on_disk.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
        else:
            source = _reconstruct_post_image(diff_text, rel_path)
            if source is None:
                continue
        for f in _scan_file(rel_path, source):
            if f.line_no in added_lines:
                out.append(f)
    return out


def _reconstruct_post_image(diff_text: str, target_path: str) -> str | None:
    rows: dict[int, str] = {}
    found = False
    for dl in iter_hunk_lines(diff_text):
        if dl.file_path != target_path:
            continue
        if dl.kind not in ("+", " "):
            continue
        rows[dl.line_no] = dl.text
        found = True
    if not found:
        return None
    if not rows:
        return ""
    return "\n".join(rows.get(i, "") for i in range(1, max(rows) + 1))


def _scan_repo(repo_root: Path) -> list[_Finding]:
    out: list[_Finding] = []
    palace_dir = repo_root / "Palace"
    if not palace_dir.is_dir():
        palace_dir = repo_root
    for root, _dirs, files in os.walk(palace_dir):
        for name in files:
            if not name.endswith(".swift"):
                continue
            full = Path(root) / name
            try:
                rel = str(full.relative_to(repo_root))
            except ValueError:
                rel = str(full)
            if _is_non_prod_swift(rel):
                continue
            try:
                source = full.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            out.extend(_scan_file(rel, source))
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-raising-unarchiver.py",
        description=("Ban the raising NSKeyedUnarchiver reads "
                     "(unarchiveObject(with:)/(withFile:)) in Palace/**/*.swift."),
    )
    parser.add_argument("--diff", default=None)
    parser.add_argument("--scan", default=None)
    parser.add_argument("--severity-floor", default="high",
                        choices=("low", "medium", "high"))
    parser.add_argument("--no-block", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    try:
        if args.scan:
            findings = _scan_repo(Path(args.scan).resolve())
        else:
            findings = _scan_diff(read_diff(args.diff), Path.cwd())
    except SystemExit:
        raise
    except Exception as exc:  # pragma: no cover - safety net
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    blocking = []
    for f in sorted(findings, key=lambda x: (x.file_path, x.line_no, x.code)):
        if _at_or_above(f.severity, args.severity_floor):
            blocking.append(f)
        print(f.render())

    if not args.quiet:
        print(f"\n{len(findings)} raising-unarchiver finding(s); "
              f"{len(blocking)} at/above floor={args.severity_floor}",
              file=sys.stderr)

    if args.no_block or args.dry_run:
        return 0
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
