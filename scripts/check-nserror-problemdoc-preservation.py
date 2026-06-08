#!/usr/bin/env python3
"""
check-nserror-problemdoc-preservation.py — detect NSError(...) constructions
that drop the upstream `TPPProblemDocument` context.

Catches the class of wall-failure surfaced by PP-3956 / PR #935:
TPPNetworkExecutor's token-refresh re-wrap was constructing a fresh NSError
via `localizedDescription`-only and discarding the upstream RFC 7807
problem document. Downstream `userFacingSignInError(...)` then fell back
to the generic "Invalid Credentials" message instead of surfacing the
server-supplied title/detail (e.g. "Expired Card").

Predicate (D4-1):

  Within a single Swift function body in a production file (under `Palace/`),
  the following ALL hold:

    1. The function receives a `TPPProblemDocument` somewhere in scope:
         - parameter declaration: `problemDoc: TPPProblemDocument`,
           `problemDocument: TPPProblemDocument?`, etc.
         - locally bound:       `let problemDoc = ... TPPProblemDocument ...`,
                                `if let problemDoc = (error as NSError).problemDocument`,
                                `TPPProblemDocument.fromProblemResponseData(data)`,
                                `TPPProblemDocument.fromData(data)`.

    2. The function constructs `NSError(...)` (any form — domain:code:userInfo:
       or domain:code: variants).

    3. The NSError userInfo dictionary does NOT reference any of:
         - `problemDocument.title`
         - `problemDocument.detail`
         - `problemDoc.title`
         - `problemDoc.detail`
         - `NSError.problemDocumentKey`           (canonical embed key)
         - `makeFromProblemDocument(`             (helper-routed path)
         - `makeFromHTTPResponse(`                (helper-routed path)

    4. No `// no-problemdoc-preservation: <reason>` annotation appears on
       the NSError construction line OR the 3 preceding lines.

False-positive escape hatch: `// no-problemdoc-preservation: <reason>`
on or just above the NSError construction line.

Output (greppable):

    <file>:<line>: D4-1: high: NSError construction discards problemDocument
        context — Wall: PP-3956

Exit codes:
  0  — no findings at or above the severity floor (default: high)
  1  — at least one finding at or above the floor
  2  — argument or I/O error

Flags (mirror the sibling pre-commit detectors):

  --diff <file>        Path to unified-diff input. `-` or omit for stdin.
  --scan <repo-root>   Walk `<root>/Palace/**/*.swift` directly instead of a
                       diff. Used for the one-time wipe.
  --severity-floor LVL Block at LVL or higher (low|medium|high). Default high.
  --no-block           Print findings, always exit 0.
  --quiet              Suppress trailing summary line on stderr.
  --dry-run            Parse only; never exit non-zero on findings.

Lineage / canonical fix pattern: PP-3956 / PR #935 — adds
`NSError.makeFromHTTPResponse(data:statusCode:domain:userInfo:)` as a single
named entry point for constructing an NSError from a non-2xx HTTP response
that embeds any RFC 7807 problem document found in the body. Either route
NSError construction through `makeFromHTTPResponse` / `makeFromProblemDocument`,
or embed the problemDocument.title / problemDocument.detail in userInfo
directly.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from _checklib import SEVERITY_RANK, at_or_above, iter_hunk_lines, read_diff

# --- Severity ladder (shared with scripts/_checklib.py) --------------------

_SEVERITY_RANK = SEVERITY_RANK
_at_or_above = at_or_above


# --- Detection patterns ----------------------------------------------------

# TPPProblemDocument-in-scope sentinels: parameter decls, local bindings,
# and the two canonical factory entry points that produce one.
_RE_PROBDOC_IN_SCOPE = [
    # Parameter or property declaration with TPPProblemDocument type.
    re.compile(r":\s*TPPProblemDocument\b"),
    # Local binding from `(error as NSError).problemDocument`.
    re.compile(r"\(\s*\w+\s+as\s+NSError\s*\)\.problemDocument\b"),
    # `.problemDocument` accessor on an NSError-typed variable.
    re.compile(r"\bnsError\.problemDocument\b"),
    re.compile(r"\berror\.problemDocument\b"),
    # Factory entry points that PARSE a problem document from response data.
    re.compile(r"\bTPPProblemDocument\.fromProblemResponseData\("),
    re.compile(r"\bTPPProblemDocument\.fromData\("),
]

# NSError construction sentinel — any `NSError(...)` call opening. The
# construction may span multiple lines (e.g. `NSError(\n  domain: ...,\n
# code: ...,\n  userInfo: ...\n)`), so we match the opening token and
# accept either same-line `domain:` OR a multi-line form. The empty
# `NSError()` constructor (an out-of-scope placeholder for a `var` slot)
# is excluded so we don't flag the TPPNetworkResponder:362 var-init.
_RE_NSERROR_CONSTRUCT_INLINE = re.compile(
    r"\bNSError\s*\(\s*domain\s*:"
)
_RE_NSERROR_CONSTRUCT_OPEN = re.compile(
    r"\bNSError\s*\(\s*$"
)

# Evidence that the construction site DOES preserve problem-doc context.
# Presence ANYWHERE in the function body = the function is treated as clean.
_RE_PROBDOC_PRESERVED = [
    re.compile(r"\bproblemDocument\.title\b"),
    re.compile(r"\bproblemDocument\.detail\b"),
    re.compile(r"\bproblemDoc\.title\b"),
    re.compile(r"\bproblemDoc\.detail\b"),
    re.compile(r"\bNSError\.problemDocumentKey\b"),
    re.compile(r"\bmakeFromProblemDocument\("),
    re.compile(r"\bmakeFromHTTPResponse\("),
]

# Annotation escape hatch.
_RE_NO_PROBDOC_PRESERVATION = re.compile(
    r"//\s*no-problemdoc-preservation\s*[:\-—]?\s*",
    re.IGNORECASE,
)

# Function-decl heuristic for function-scope boundary detection.
_RE_FUNC_DECL = re.compile(
    r"^\s*(?:@\w+\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|"
    r"open\s+|final\s+|static\s+|class\s+|override\s+|nonisolated\s+|"
    r"convenience\s+|required\s+|@\w+\s+)*"
    r"(?:func|init|deinit|subscript)\b"
)

_NON_PROD_PATH_SUBSTRINGS = (
    "PalaceTests/",
    "Tests/",
    "TestSupport/",
    "Utilities/Testing/",
    "Preview Content/",
    "Mocks/",
    ".forgeos/",
    "scripts/",
)

# The detector's own scan scope, per architect Module D4 contract.
_IN_SCOPE_PATH_PREFIXES = (
    "Palace/Network/",
    "Palace/SignInLogic/",
)


def _is_swift(path: str) -> bool:
    return path.endswith(".swift")


def _is_non_prod_swift(path: str) -> bool:
    return any(s in path for s in _NON_PROD_PATH_SUBSTRINGS)


def _is_in_scope(path: str) -> bool:
    return any(s in path for s in _IN_SCOPE_PATH_PREFIXES)


# --- Function-body parsing -------------------------------------------------

@dataclass
class _FunctionBody:
    file_path: str
    start_line: int     # 1-based, line of the `func` keyword (or `{` opening)
    end_line: int       # 1-based, last line covered by the body
    lines: list[str]    # body content, as written

    def joined_text(self) -> str:
        return "\n".join(self.lines)


def _strip_line_comment(raw: str) -> str:
    # Lightweight `//` strip. Same heuristic as sibling detectors.
    idx = raw.find("//")
    if idx < 0:
        return raw
    head = raw[:idx]
    if head.count('"') % 2 == 1:
        return raw
    return head


def _split_functions(file_path: str, lines: list[str]) -> list[_FunctionBody]:
    """Slice a Swift file into function bodies via a brace-depth heuristic.
    Same shape as check-foreign-host-401-scoping.py's splitter."""
    bodies: list[_FunctionBody] = []
    depth = 0
    in_func = False
    body_start = 0
    body_lines: list[str] = []
    func_decl_depth = 0

    for idx, raw in enumerate(lines, start=1):
        no_comment = _strip_line_comment(raw)
        opens = no_comment.count("{")
        closes = no_comment.count("}")

        if not in_func and _RE_FUNC_DECL.match(raw):
            in_func = True
            body_start = idx
            body_lines = [raw]
            depth += opens
            depth -= closes
            if depth > 0:
                func_decl_depth = depth
            continue

        if in_func:
            body_lines.append(raw)
            depth += opens
            depth -= closes
            if depth < func_decl_depth:
                bodies.append(_FunctionBody(
                    file_path=file_path,
                    start_line=body_start,
                    end_line=idx,
                    lines=body_lines,
                ))
                in_func = False
                body_lines = []
                func_decl_depth = 0
                if depth < 0:
                    depth = 0
            continue

        depth += opens
        depth -= closes
        if depth < 0:
            depth = 0

    if in_func and body_lines:
        bodies.append(_FunctionBody(
            file_path=file_path,
            start_line=body_start,
            end_line=body_start + len(body_lines) - 1,
            lines=body_lines,
        ))

    return bodies


# --- Scan ------------------------------------------------------------------

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


_WALL_REF = "Wall: PP-3956"


def _annotated_within(body: _FunctionBody, construct_line_idx: int) -> bool:
    """Check the construction line and the 3 preceding lines for the
    `// no-problemdoc-preservation:` escape hatch."""
    start = max(0, construct_line_idx - 3)
    for i in range(start, construct_line_idx + 1):
        if i >= len(body.lines):
            break
        if _RE_NO_PROBDOC_PRESERVATION.search(body.lines[i]):
            return True
    return False


def _scan_file(file_path: str, source: str) -> list[_Finding]:
    """Scan a single Swift file's source text for D4-1 findings."""
    findings: list[_Finding] = []
    lines = source.splitlines()
    bodies = _split_functions(file_path, lines)
    for body in bodies:
        body_text = body.joined_text()
        # Step 1: must have a TPPProblemDocument in scope.
        has_probdoc = any(p.search(body_text) for p in _RE_PROBDOC_IN_SCOPE)
        if not has_probdoc:
            continue
        # Step 2: find NSError construction lines within the body. Accepts
        # both inline (`NSError(domain: ..., code: ..., userInfo: ...)` on
        # one line) and multi-line (`NSError(\n  domain: ...\n)`) forms.
        # The multi-line form is detected by an `NSError(` opening followed
        # within 3 lines by a `domain:` argument.
        nserror_hits: list[int] = []
        for i, line in enumerate(body.lines):
            if _RE_NSERROR_CONSTRUCT_INLINE.search(line):
                nserror_hits.append(i)
                continue
            if _RE_NSERROR_CONSTRUCT_OPEN.search(line):
                # Confirm `domain:` appears in the next 3 lines.
                lookahead = body.lines[i + 1: i + 4]
                if any("domain:" in la for la in lookahead):
                    nserror_hits.append(i)
        if not nserror_hits:
            continue
        # Step 3: if any preservation evidence appears anywhere in the body,
        # the function is treated as clean. The bug is "drops" — any single
        # surviving reference proves the path is wired.
        if any(p.search(body_text) for p in _RE_PROBDOC_PRESERVED):
            continue
        # Step 4: each remaining NSError-construction line that isn't
        # individually annotated produces a finding.
        for ni in nserror_hits:
            if _annotated_within(body, ni):
                continue
            abs_line = body.start_line + ni
            findings.append(_Finding(
                code="D4-1",
                severity="high",
                file_path=file_path,
                line_no=abs_line,
                description=(
                    "NSError construction discards problemDocument context "
                    f"— {_WALL_REF}"
                ),
            ))
    return findings


# --- Diff mode -------------------------------------------------------------

def _files_from_diff(diff_text: str) -> dict[str, set[int]]:
    touched: dict[str, set[int]] = {}
    for dl in iter_hunk_lines(diff_text):
        if dl.kind not in ("+", " "):
            continue
        if not _is_swift(dl.file_path):
            continue
        touched.setdefault(dl.file_path, set()).add(dl.line_no)
    return touched


def _read_swift_source(repo_root: Path, rel_path: str) -> str | None:
    abs_path = repo_root / rel_path
    if not abs_path.is_file():
        alt = Path(rel_path)
        if alt.is_file():
            return alt.read_text(encoding="utf-8", errors="replace")
        return None
    return abs_path.read_text(encoding="utf-8", errors="replace")


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
    max_line = max(rows)
    out_lines = [rows.get(i, "") for i in range(1, max_line + 1)]
    return "\n".join(out_lines)


def _scan_diff(diff_text: str, repo_root: Path) -> list[_Finding]:
    """Diff mode: scan only files in the in-scope prefixes; narrow findings
    to touched line numbers so an unrelated PR doesn't false-block on a
    pre-existing pattern."""
    touched = _files_from_diff(diff_text)
    out: list[_Finding] = []
    for rel_path, lines in touched.items():
        if _is_non_prod_swift(rel_path):
            continue
        if not _is_in_scope(rel_path):
            continue
        source = _read_swift_source(repo_root, rel_path)
        if source is None:
            source = _reconstruct_post_image(diff_text, rel_path)
            if source is None:
                continue
        file_findings = _scan_file(rel_path, source)
        for f in file_findings:
            if f.line_no in lines:
                out.append(f)
    return out


# --- Scan mode -------------------------------------------------------------

def _scan_repo(repo_root: Path) -> list[_Finding]:
    out: list[_Finding] = []
    palace_dir = repo_root / "Palace"
    walk_root = palace_dir if palace_dir.is_dir() else repo_root
    for root, _dirs, files in os.walk(walk_root):
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
            # In repo-walk mode, allow the in-scope prefix filter to apply
            # only when the repo actually has the canonical Palace/ layout.
            # For fixture-based tests the file may live at
            # `<tmp>/Palace/Network/foo.swift`, which `_is_in_scope` matches.
            if palace_dir.is_dir() and not _is_in_scope(rel):
                continue
            try:
                source = full.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            out.extend(_scan_file(rel, source))
    return out


# --- CLI -------------------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-nserror-problemdoc-preservation.py",
        description=(
            "Scan a unified diff (or repo) for NSError(...) constructions "
            "that drop the upstream TPPProblemDocument context. Catches "
            "the PP-3956 / PR #935 wall-failure class."
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
        msg = (f"\n{len(findings)} nserror-problemdoc-preservation "
               f"finding(s); {len(blocking)} at/above "
               f"floor={args.severity_floor}")
        print(msg, file=sys.stderr)

    if args.no_block or args.dry_run:
        return 0
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
