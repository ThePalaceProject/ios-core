#!/usr/bin/env python3
"""
check-addoperation-literal-ban.py — ban raw `NSOperation`-family closure
LITERALS in the app target (`Palace/**/*.swift`).

Catches the #1338 regression class: an Xcode 26.2 / Swift 6.2 ClangImporter
bug caches the imported Swift type of the canonical clang block type
`void (^)(void)` the FIRST time any WebKit block declaration is type-checked
in a given `swift-frontend` process. WebKit's headers annotate blocks with
`NS_SWIFT_UI_ACTOR` (`@MainActor`) while Foundation's `-addOperationWithBlock:`
/ `-addExecutionBlock:` / `completionBlock` use `NS_SWIFT_SENDABLE` — both are
`swift_attr` sugar over the SAME canonical block type. Once the ClangImporter
has cached `@MainActor @Sendable () -> Void` for that type, every LATER
structurally-identical block parameter in the same process (batch or WMO)
surfaces as `@MainActor` too — including Foundation's operation-queue APIs. A
`@MainActor`-typed closure LITERAL passed directly to one of those APIs gets a
`dispatch_assert_queue(main)` prologue and SIGTRAPs
(`swift_task_checkIsolated` -> `dispatch_assert_queue_fail`) the instant the
queue runs it off-main. Which files are affected depends only on
frontend-batch membership, so an unrelated file-set change can flip a
previously-fine file. See `Palace/Utilities/ImageCache/ImageCache.swift`'s
class-header comment for the full forensic (the #1338 bootstrap crash).

The fix is NOT to avoid these APIs — it is to hoist the closure into an
explicitly-typed `let` binding BEFORE handing it to the API. The closure's
type then comes from the `let` ANNOTATION (e.g. `@Sendable () -> Void`), not
the poisonable imported parameter type; passing that typed value to even a
poisoned parameter is a safe conversion with no runtime isolation assertion.

    let work: @Sendable () -> Void = { ... }
    queue.addOperation(work)                     // APPROVED — named value

    queue.addOperation { ... }                    // BANNED — literal
    operation.addExecutionBlock { ... }           // BANNED — literal
    BlockOperation { ... }                        // BANNED — literal
    BlockOperation(block: { ... })                // BANNED — literal
    operation.completionBlock = { ... }           // BANNED — literal assign

Scope: diff-ADDED lines only, `Palace/**/*.swift` (app target). Test/mock/
preview/scripts dirs are excluded — mirrors
`check-completion-nil-error-suppression.py`'s `_NON_PROD_PATH_SUBSTRINGS`.

False-positive escape hatch: `// no-addoperation-literal-ban: <reason>` on the
violating line or any of the 3 preceding lines (mirrors the sibling
detectors' `// no-nil-error-suppression:` convention).

Flags (mirror the sibling pre-commit detectors):
  --diff <file>        Unified-diff input. `-` or omit for stdin.
  --scan <repo-root>   Walk `<root>/Palace/**/*.swift` directly instead of a
                       diff (whole-tree dry run / bootstrap).
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

# --- Detection patterns ------------------------------------------------------
#
# Each pattern matches a closure LITERAL (`{`) passed/assigned directly to one
# of the banned NSOperation-family APIs. A NAMED value (identifier, no `{`
# immediately following) never matches — that is the approved hoisted form.
# `(?!s)` on addOperation keeps `.addOperations(` (plural, array API — out of
# scope) from matching. Patterns are matched against the whole reconstructed
# source (not line-by-line) so a literal whose opening `{` sits just after a
# line break (e.g. `.addOperation(\n    {`) is still caught — `\s` matches
# newlines too.

_RE_ADD_OPERATION = re.compile(r"\.addOperation(?!s)\s*\(?\s*\{")
_RE_ADD_EXECUTION_BLOCK = re.compile(r"\.addExecutionBlock\s*\(?\s*\{")
_RE_BLOCK_OPERATION = re.compile(r"\bBlockOperation\s*(?:\(\s*block\s*:\s*)?\{")
_RE_COMPLETION_BLOCK_ASSIGN = re.compile(r"\.completionBlock\s*=\s*\{")

_PATTERNS: tuple[tuple[str, re.Pattern, str], ...] = (
    ("addOperation", _RE_ADD_OPERATION,
     "`.addOperation { ... }` trailing-closure LITERAL"),
    ("addExecutionBlock", _RE_ADD_EXECUTION_BLOCK,
     "`.addExecutionBlock { ... }` closure LITERAL"),
    ("BlockOperation", _RE_BLOCK_OPERATION,
     "`BlockOperation { ... }` / `BlockOperation(block: { ... })` closure LITERAL"),
    ("completionBlock", _RE_COMPLETION_BLOCK_ASSIGN,
     "`.completionBlock = { ... }` closure LITERAL assignment"),
)

_RE_NO_BAN_ANNOTATION = re.compile(
    r"//\s*no-addoperation-literal-ban\b", re.IGNORECASE
)

# Non-prod path substrings — mirrors check-blast-radius.py /
# check-completion-nil-error-suppression.py.
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


# --- Findings ----------------------------------------------------------------

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


def _has_annotation(lines: list[str], call_line: int) -> bool:
    start = max(1, call_line - 3)
    for ln in range(start, call_line + 1):
        if ln < 1 or ln > len(lines):
            continue
        if _RE_NO_BAN_ANNOTATION.search(lines[ln - 1]):
            return True
    return False


def _scan_file(rel_path: str, source: str) -> list[_Finding]:
    """Find all banned-literal call sites in `source`. Line-no sorted."""
    if _is_non_prod_swift(rel_path):
        return []
    if not rel_path.endswith(".swift"):
        return []

    lines = source.splitlines()
    findings: list[_Finding] = []
    for _name, rx, desc in _PATTERNS:
        for m in rx.finditer(source):
            line_no = _line_no_at_offset(source, m.start())
            if _has_annotation(lines, line_no):
                continue
            findings.append(_Finding(
                code="AOB-1",
                severity="high",
                file_path=rel_path,
                line_no=line_no,
                description=(
                    f"{desc} — Xcode 26.2 ClangImporter @MainActor-poisoning "
                    "risk (#1338: a WebKit block declaration anywhere in the "
                    "same compile batch flips this literal's inferred type to "
                    "@MainActor, and it SIGTRAPs off-main). Hoist into "
                    "`let work: @Sendable () -> Void = { ... }` and pass "
                    "`work` instead."
                ),
            ))

    findings.sort(key=lambda f: (f.file_path, f.line_no))
    return findings


# --- Diff mode ---------------------------------------------------------------

def _scan_diff(diff_text: str, repo_root: Path) -> list[_Finding]:
    """Scan a unified diff: per touched file, reconstruct or read the
    post-image and emit findings whose line numbers fall on ADDED lines.
    """
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
        file_findings = _scan_file(rel_path, source)
        for f in file_findings:
            if f.line_no in added_lines:
                out.append(f)
    return out


def _reconstruct_post_image(diff_text: str, target_path: str) -> str | None:
    """Reconstruct a synthetic post-image when the file isn't on disk (e.g.
    scanning a standalone diff file against a throwaway/no-checkout root)."""
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
    max_line = max(rows)
    out_lines = [rows.get(i, "") for i in range(1, max_line + 1)]
    return "\n".join(out_lines)


# --- Scan mode ----------------------------------------------------------------

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


# --- CLI -----------------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-addoperation-literal-ban.py",
        description=(
            "Ban raw NSOperation-family closure LITERALS "
            "(.addOperation {, .addExecutionBlock {, BlockOperation {, "
            ".completionBlock = {) in Palace/**/*.swift — Xcode 26.2 "
            "ClangImporter @MainActor-poisoning risk (#1338)."
        ),
    )
    parser.add_argument("--diff", default=None,
                        help="Unified-diff input file. `-` or omit for stdin.")
    parser.add_argument("--scan", default=None,
                        help="Repo root to walk directly instead of a diff.")
    parser.add_argument("--severity-floor", default="high",
                        choices=("low", "medium", "high"),
                        help="Block at LVL or above (default: high).")
    parser.add_argument("--no-block", action="store_true",
                        help="Print findings, always exit 0.")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress summary line on stderr.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print findings; do not exit non-zero.")
    args = parser.parse_args(argv)

    try:
        if args.scan:
            findings = _scan_repo(Path(args.scan).resolve())
        else:
            diff_text = read_diff(args.diff)
            repo_root = Path.cwd()
            findings = _scan_diff(diff_text, repo_root)
    except SystemExit:
        raise
    except Exception as exc:  # pragma: no cover - safety net
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    blocking: list[_Finding] = []
    for f in sorted(findings, key=lambda x: (x.file_path, x.line_no, x.code)):
        if _at_or_above(f.severity, args.severity_floor):
            blocking.append(f)
        print(f.render())

    if not args.quiet:
        msg = (f"\n{len(findings)} addOperation-literal-ban finding(s); "
               f"{len(blocking)} at/above floor={args.severity_floor}")
        print(msg, file=sys.stderr)

    if args.no_block or args.dry_run:
        return 0
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
