#!/usr/bin/env python3
"""
check-lcp-acquisition-recursive.py — detect non-recursive LCP-acquisition
predicates (the PP-4407 / PP-4454 bug class).

LCP-protected content arrives in three OPDS feed shapes:

  1. `/loans/` XML            — LCP MIME at top of `defaultAcquisition.type`.
  2. `/groups/` JSON (M-place) — top-level type is `application/opds-publication+json`
                                 with the LCP license MIME nested ≥1 level deep
                                 in `indirectAcquisitions`.
  3. OPDS-Catalog wrapping     — sibling acquisitions where `defaultAcquisition`
                                 returns the catalog entry, not the license.

PP-4407 (audiobooks) and PP-4454 (LCP PDFs) both BROKE for the same reason:
the `canOpenBook(_:)` predicate inspected only `defaultAcquisition.type` and
missed shapes 2 and 3. The canonical fix in both cases was a recursive
`hasLCPAcquisition(_:)` walking `indirectAcquisitions` (and, in PR #1008,
the sibling `book.acquisitions` array as well).

This detector finds new occurrences of the bug-class shape:

  D1-1 (high)  A Swift function body references `defaultAcquisition` AND an
               LCP MIME literal (or `expectedAcquisitionType` constant), AND
               does NOT reference any of:
                 - `indirectAcquisitions`
                 - `hasLCPAcquisition`
                 - `indirectChainContainsLCP`
               i.e. it's a top-level acquisition check that will silently
               fail on the Marketplace/Catalog feed shapes.

Annotation escape: place a comment

    // no-lcp-recursive: <reason>

on a line preceding the function declaration. Intentional legacy `canOpenBook`
shims kept for backward source-compatibility are the only legitimate use;
the recursive `hasLCPAcquisition` should be added alongside.

Scan dirs (default): Palace/MyBooks/, Palace/Reader2/, Palace/Audiobooks/,
Palace/OPDS2/. Override with --scan-dir (repeatable) or --scan <root>.

Output (greppable): <file>:<line>: D1-1: high: <description> — Wall: PP-4407 / PP-4454

Exit codes:
  0  — no findings
  1  — at least one finding
  2  — argument or I/O error
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

# LCP MIME literal (exact). Also catch any string literal that mentions `lcp`
# in a `vnd.readium.*` MIME shape — keeps the detector honest if Marketplace
# ever ships a v1.1 variant.
_LCP_MIME_LITERAL_RE = re.compile(
    r'"application/vnd\.readium\.lcp[^"]*"'
)
# Local `expectedAcquisitionType` static constants resolve to the LCP MIME in
# both `LCPAudiobooks` and `LCPPDFs`. Treat the bareword as an LCP-context hint
# when paired with `defaultAcquisition` in the same function.
_LCP_CONST_RE = re.compile(r"\bexpectedAcquisitionType\b")
_LCP_CONTENT_TYPE_RE = re.compile(r"\bContentTypeReadiumLCP\b")

_DEFAULT_ACQ_RE = re.compile(r"\bdefaultAcquisition\b")

# Safe-recursion markers. Presence of ANY ONE of these in the function body
# is sufficient to consider the function clean: the author has either walked
# the indirect chain themselves or delegated to a function that does.
_RECURSIVE_MARKERS_RE = re.compile(
    r"\b(?:indirectAcquisitions|hasLCPAcquisition|indirectChainContainsLCP)\b"
)

# `func` declaration line — captures the function name for the finding text.
# Matches `func`, `static func`, `@objc static func`, `private func`, etc.
_FUNC_DECL_RE = re.compile(
    r"^\s*(?:@\w+\s+)*"
    r"(?:(?:public|internal|private|fileprivate|open)\s+)?"
    r"(?:static\s+|class\s+|final\s+|override\s+)*"
    r"func\s+(\w+)\s*[<(]"
)

# Annotation escape on a comment preceding the func decl.
_NO_LCP_RECURSIVE_RE = re.compile(
    r"//+\s*no-lcp-recursive\s*[:\-—]\s*\S",
    re.IGNORECASE,
)

_DEFAULT_SCAN_DIRS = (
    "Palace/MyBooks",
    "Palace/Reader2",
    "Palace/Audiobooks",
    "Palace/OPDS2",
)


@dataclass
class _Finding:
    file_path: str
    line_no: int
    func_name: str

    def render(self) -> str:
        return (
            f"{self.file_path}:{self.line_no}: D1-1: high: "
            f"LCP acquisition predicate `{self.func_name}` inspects only "
            f"defaultAcquisition.type; missing recursive indirectAcquisitions "
            f"walk — Wall: PP-4407 / PP-4454"
        )


def _extract_function_bodies(text: str) -> list[tuple[int, str, str, str]]:
    """
    Walk the source and return (start_line, func_name, preceding_block, body)
    tuples for every `func` declaration.

    `preceding_block` is the joined comment lines immediately above the decl
    (resets on any blank or non-comment line). Used to honor the annotation
    escape.

    `body` is the brace-balanced text between the opening `{` of the func and
    its matching closing `}`. We use line-by-line scanning with brace-depth
    tracking — Swift string literals and nested braces are handled naively
    (we don't tokenize string interpolation), but that's adequate for the
    detection greps we run on the body (string literals never contain
    `defaultAcquisition` or `indirectAcquisitions` in this codebase).
    """
    lines = text.splitlines()
    results: list[tuple[int, str, str, str]] = []

    preceding_block: list[str] = []

    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.lstrip()

        # Track the rolling preceding-comment block. Reset on blank or
        # non-comment, non-decl line. We DO keep the block across the decl
        # line itself so the annotation match has access to it.
        if stripped.startswith("///") or stripped.startswith("//"):
            preceding_block.append(stripped)
            i += 1
            continue

        m_decl = _FUNC_DECL_RE.match(line)
        if not m_decl:
            if not stripped:
                # blank line - preserve preceding block (Swift allows blank
                # line between docstring and decl)
                pass
            else:
                # non-comment, non-decl, non-blank line resets the block.
                preceding_block = []
            i += 1
            continue

        func_name = m_decl.group(1)
        # Skip funcs declared without a body on the same line (protocol
        # requirements: `func foo() -> Bool`). The opening `{` must appear
        # on the decl line or a subsequent line.
        # Find opening brace `{` — scan forward.
        depth = 0
        body_parts: list[str] = []
        found_open = False
        j = i
        while j < len(lines):
            cur = lines[j]
            for ch in cur:
                if ch == "{":
                    depth += 1
                    found_open = True
                elif ch == "}":
                    depth -= 1
            if found_open:
                body_parts.append(cur)
                if depth == 0:
                    break
            j += 1

        if not found_open or depth != 0:
            # malformed (or protocol-requirement-style declaration); skip.
            preceding_block = []
            i += 1
            continue

        joined_preceding = "\n".join(preceding_block[-8:])
        joined_body = "\n".join(body_parts)
        results.append((i + 1, func_name, joined_preceding, joined_body))

        # Reset state and continue past the function.
        preceding_block = []
        i = j + 1

    return results


def _function_violates(body: str) -> bool:
    """Apply the D1-1 predicate to a function body."""
    if not _DEFAULT_ACQ_RE.search(body):
        return False
    # LCP context: either a literal `vnd.readium.lcp...` MIME, or a reference
    # to a local `expectedAcquisitionType` static, or the SPM-shared
    # `ContentTypeReadiumLCP` constant.
    lcp_context = bool(
        _LCP_MIME_LITERAL_RE.search(body)
        or _LCP_CONST_RE.search(body)
        or _LCP_CONTENT_TYPE_RE.search(body)
    )
    if not lcp_context:
        return False
    # If the body already walks the chain or delegates to a recursive helper,
    # it's clean.
    if _RECURSIVE_MARKERS_RE.search(body):
        return False
    return True


def _scan_file(path: Path) -> list[_Finding]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return []
    findings: list[_Finding] = []
    for start_line, func_name, preceding, body in _extract_function_bodies(text):
        if _NO_LCP_RECURSIVE_RE.search(preceding):
            continue
        if _function_violates(body):
            findings.append(_Finding(
                file_path=str(path),
                line_no=start_line,
                func_name=func_name,
            ))
    return findings


def _iter_swift_files(roots: list[Path]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        if root.is_file() and root.suffix == ".swift":
            files.append(root)
            continue
        for p in root.rglob("*.swift"):
            files.append(p)
    return files


def _resolve_scan_paths(repo_root: Path, args) -> list[Path]:
    if args.scan_dir:
        return [Path(d) for d in args.scan_dir]
    base = Path(args.scan) if args.scan else repo_root
    return [base / d for d in _DEFAULT_SCAN_DIRS]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-lcp-acquisition-recursive.py",
        description=(
            "Scan Swift files for LCP-acquisition predicates that inspect "
            "only `defaultAcquisition.type` and miss `indirectAcquisitions`. "
            "Catches the PP-4407 / PP-4454 bug class."
        ),
    )
    parser.add_argument(
        "--scan",
        default=None,
        help=(
            "Repo root (relative or absolute) under which to apply the four "
            "default scan dirs: Palace/MyBooks, Palace/Reader2, "
            "Palace/Audiobooks, Palace/OPDS2."
        ),
    )
    parser.add_argument(
        "--scan-dir",
        action="append",
        default=[],
        help=(
            "Override scan paths. Repeatable. Each value is a file or dir. "
            "If given, the default scan dirs are not used."
        ),
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress trailing summary on stderr.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print findings; do not exit non-zero.",
    )
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parent.parent
    scan_paths = _resolve_scan_paths(repo_root, args)
    files = _iter_swift_files(scan_paths)

    findings: list[_Finding] = []
    for f in files:
        findings.extend(_scan_file(f))
    findings.sort(key=lambda x: (x.file_path, x.line_no))

    for finding in findings:
        print(finding.render())

    if not args.quiet:
        print(
            f"\n{len(findings)} LCP-acquisition non-recursive finding(s) "
            f"across {len(files)} Swift file(s) in {len(scan_paths)} scan path(s)",
            file=sys.stderr,
        )

    if args.dry_run:
        return 0
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
