#!/usr/bin/env python3
"""
check-blast-radius.py — detect new API/visibility/test-seam exposure in a diff.

Universal pre-commit floor for the gap classes wave 1-4 manual review exposed.
Operates on a unified-diff file (defaults to `git diff --staged` if omitted).

Categories detected (severity in parentheses):

  BR-1 (high)   New `public` / `open` symbols on non-test Swift files.
  BR-2 (high)   New `#if DEBUG` / `#if !DEBUG` blocks on non-test Swift files.
                Demoted to medium when the block also references an XCTest
                env-var gate (e.g. `XCTestConfigurationFilePath`) — that
                shape is structurally test-only.
  BR-3 (high)   `public private(set)` declaration whose docstring contains
                test/verify/spy/observable wording.
  BR-4 (high)   New init parameters added to `AppContainer.swift` or any
                `*Container.swift` file (composition-root churn).
  BR-5 (medium) `let _ = fn(...)` discard without `// TODO(ticket):`
                justification on the same or preceding line.

Output (greppable): `<file>:<line>: <code>: <severity>: <description>`

Exit codes:
  0  — no findings at or above the severity floor
  1  — at least one finding at or above the severity floor (default floor: high)
  2  — argument or I/O error

Flags:
  --diff <file>          Path to unified-diff input. Defaults to stdin.
  --severity-floor LVL   Block at LVL or higher (low|medium|high). Default high.
  --no-block             Print findings, always exit 0.
  --quiet                Suppress the trailing summary line.
  --dry-run              Parse only; do not exit non-zero on findings.

Catches the gap class that wave 1-4 manual adversarial review surfaced:
  - `authenticateCallCount` shipped as `public private(set)` (test-only seam
    leaking onto Palace framework public surface).
  - `_testContainerOverride` gated on `#if DEBUG` (sim/dev/TestFlight covered).
  - Hidden composition-root churn via new `*Container.swift` init params.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

# --- Severity ladder -------------------------------------------------------

_SEVERITY_RANK = {"low": 0, "medium": 1, "high": 2}


def _at_or_above(level: str, floor: str) -> bool:
    return _SEVERITY_RANK.get(level, 0) >= _SEVERITY_RANK.get(floor, 2)


# --- Diff parsing ----------------------------------------------------------

@dataclass
class _AddedLine:
    file_path: str           # post-image path (b/...)
    line_no: int             # line number in the post-image file
    text: str                # added line content (no leading "+")
    docstring_block: str     # preceding /// or // comment block, joined

# Regex anchors
_FILE_HDR_RE = re.compile(r"^\+\+\+ b/(.+)$")
_HUNK_HDR_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")

# Detection patterns
_PUBLIC_DECL_RE = re.compile(
    r"^\s*(?:@\w+\s+)*"
    r"(?:public|open)\s+"
    r"(?:final\s+|static\s+|class\s+|struct\s+|enum\s+|protocol\s+|"
    r"actor\s+|extension\s+|func\s+|var\s+|let\s+|typealias\s+|init|"
    r"private\(set\)\s+(?:var|let)|"
    r"override\s+)"
)
_PUBLIC_PRIVATE_SET_RE = re.compile(
    r"^\s*(?:@\w+\s+)*public\s+private\(set\)\s+(?:var|let)\s+(\w+)"
)
_IF_DEBUG_RE = re.compile(r"^\s*#if\s+(?:!\s*)?DEBUG\b")
_XCTEST_ENV_RE = re.compile(r"XCTestConfigurationFilePath|isRunningUnderXCTest")
_DISCARD_RE = re.compile(r"^\s*let\s+_\s*=\s*(\w[\w\.]*)\s*\(")
_TODO_TICKET_RE = re.compile(r"//\s*TODO\([A-Z]+-\d+\)")
_CONTAINER_FILE_RE = re.compile(r"(?:^|/)[A-Z]\w*Container\.swift$")
_INIT_RE = re.compile(r"^\s*(?:public\s+|internal\s+)?(?:convenience\s+)?init\s*\(")

# Test/sample/preview-style files that don't ship to production:
_NON_PROD_PATH_SUBSTRINGS = (
    "PalaceTests/",
    "Tests/",
    "TestSupport/",
    "Preview Content/",
    "Mocks/",
    ".forgeos/",
    "scripts/_fixtures/",
)


def _is_swift(path: str) -> bool:
    return path.endswith(".swift")


def _is_non_prod_swift(path: str) -> bool:
    return any(s in path for s in _NON_PROD_PATH_SUBSTRINGS)


def _parse_diff(diff_text: str) -> list[_AddedLine]:
    """Yield post-image added Swift lines with line numbers + preceding doc block."""
    lines = diff_text.splitlines()
    added: list[_AddedLine] = []
    current_path: str | None = None
    current_line_no: int = 0
    last_doc_block: list[str] = []

    for raw in lines:
        m_file = _FILE_HDR_RE.match(raw)
        if m_file:
            current_path = m_file.group(1)
            current_line_no = 0
            last_doc_block = []
            continue
        if current_path is None:
            continue
        m_hunk = _HUNK_HDR_RE.match(raw)
        if m_hunk:
            current_line_no = int(m_hunk.group(1)) - 1
            last_doc_block = []
            continue
        if raw.startswith("+++") or raw.startswith("---"):
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            current_line_no += 1
            text = raw[1:]
            doc_join = "\n".join(last_doc_block[-12:])
            added.append(_AddedLine(
                file_path=current_path,
                line_no=current_line_no,
                text=text,
                docstring_block=doc_join,
            ))
            stripped = text.lstrip()
            if stripped.startswith("///") or stripped.startswith("//"):
                last_doc_block.append(stripped)
            elif stripped:
                last_doc_block = []
            continue
        if raw.startswith(" "):
            current_line_no += 1
            stripped = raw[1:].lstrip()
            if stripped.startswith("///") or stripped.startswith("//"):
                last_doc_block.append(stripped)
            elif stripped:
                last_doc_block = []
        # Removed lines ("-...") don't advance post-image line numbers.
    return added


# --- Detection -------------------------------------------------------------

@dataclass
class _Finding:
    code: str                # BR-1..BR-5
    severity: str            # low|medium|high
    file_path: str
    line_no: int
    description: str

    def render(self) -> str:
        return (f"{self.file_path}:{self.line_no}: "
                f"{self.code}: {self.severity}: {self.description}")


def _scan(added: list[_AddedLine]) -> list[_Finding]:
    findings: list[_Finding] = []
    # Track per-file hunk context for BR-2 demotion (XCTest env-gate detection).
    if_debug_open: dict[str, list[int]] = {}

    for entry in added:
        path = entry.file_path
        if not _is_swift(path):
            # BR-5 + BR-4 only apply to Swift files; skip non-Swift entirely.
            continue
        if _is_non_prod_swift(path):
            continue
        text = entry.text

        # BR-3 — public private(set) test-only declaration.
        m_pps = _PUBLIC_PRIVATE_SET_RE.match(text)
        if m_pps:
            name = m_pps.group(1)
            doc = entry.docstring_block.lower()
            test_hints = ("test", "verify", "spy", "observable",
                          "observable from", "not used for any production")
            if any(hint in doc for hint in test_hints):
                findings.append(_Finding(
                    code="BR-3",
                    severity="high",
                    file_path=path,
                    line_no=entry.line_no,
                    description=(f"`public private(set)` var `{name}` "
                                 f"has test/verify/spy wording in docstring "
                                 f"— prefer `internal private(set)`"),
                ))
                # Don't double-flag as BR-1.
                continue

        # BR-1 — new public/open declaration.
        if _PUBLIC_DECL_RE.match(text):
            findings.append(_Finding(
                code="BR-1",
                severity="high",
                file_path=path,
                line_no=entry.line_no,
                description=(f"new `public`/`open` declaration on prod file "
                             f"— justify or downgrade to `internal`"),
            ))

        # BR-2 — #if DEBUG block on prod file. Demoted to medium if the
        # following few added lines (or the block itself) carry an XCTest env-var
        # marker. We can only see additions; treat presence of the env-marker
        # anywhere in the same file's added lines as a hint.
        if _IF_DEBUG_RE.match(text):
            if_debug_open.setdefault(path, []).append(entry.line_no)

        # BR-4 — new init parameter on *Container.swift.
        # Heuristic: an added line that is an init signature OR an added
        # parameter token-list inside an init.
        if _CONTAINER_FILE_RE.search(path):
            if _INIT_RE.match(text):
                findings.append(_Finding(
                    code="BR-4",
                    severity="high",
                    file_path=path,
                    line_no=entry.line_no,
                    description=("new `init(...)` on a `*Container.swift` "
                                 "file — composition-root churn"),
                ))

        # BR-5 — discarded function result.
        m_dis = _DISCARD_RE.match(text)
        if m_dis:
            fn = m_dis.group(1)
            doc = entry.docstring_block
            has_todo = bool(_TODO_TICKET_RE.search(text)) or bool(
                _TODO_TICKET_RE.search(doc))
            if not has_todo:
                findings.append(_Finding(
                    code="BR-5",
                    severity="medium",
                    file_path=path,
                    line_no=entry.line_no,
                    description=(f"`let _ = {fn}(...)` discards result "
                                 f"without `// TODO(TICKET-XXX): ...` "
                                 f"justification"),
                ))

    # Post-pass: emit BR-2 findings with severity demotion.
    file_to_env_hint: dict[str, bool] = {}
    for entry in added:
        if not _is_swift(entry.file_path) or _is_non_prod_swift(entry.file_path):
            continue
        if _XCTEST_ENV_RE.search(entry.text):
            file_to_env_hint[entry.file_path] = True
    for path, line_nos in if_debug_open.items():
        demoted = file_to_env_hint.get(path, False)
        for ln in line_nos:
            findings.append(_Finding(
                code="BR-2",
                severity=("medium" if demoted else "high"),
                file_path=path,
                line_no=ln,
                description=(
                    "`#if DEBUG` on prod file"
                    + (" (demoted: XCTest env-gate present in same diff)"
                       if demoted else
                       " — covers sim/dev/TestFlight; prefer XCTest env-var gate")
                ),
            ))

    findings.sort(key=lambda f: (f.file_path, f.line_no, f.code))
    return findings


# --- CLI -------------------------------------------------------------------

def _read_diff(path: str | None) -> str:
    if path is None or path == "-":
        return sys.stdin.read()
    p = Path(path)
    if not p.is_file():
        print(f"ERROR: diff file not found: {path}", file=sys.stderr)
        sys.exit(2)
    return p.read_text(encoding="utf-8", errors="replace")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-blast-radius.py",
        description=(
            "Scan a unified diff for new public/open symbols, #if DEBUG blocks, "
            "test-only public(private(set)) counters, container-init churn, "
            "and discarded function results without justification."
        ),
    )
    parser.add_argument("--diff", default=None,
                        help="Unified-diff input file. `-` or omit for stdin.")
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

    diff_text = _read_diff(args.diff)
    added = _parse_diff(diff_text)
    findings = _scan(added)

    blocking: list[_Finding] = []
    for f in findings:
        if _at_or_above(f.severity, args.severity_floor):
            blocking.append(f)
        print(f.render())

    if not args.quiet:
        msg = (f"\n{len(findings)} blast-radius finding(s); "
               f"{len(blocking)} at/above floor={args.severity_floor}")
        print(msg, file=sys.stderr)

    if args.no_block or args.dry_run:
        return 0
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
