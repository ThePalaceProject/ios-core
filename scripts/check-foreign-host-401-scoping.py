#!/usr/bin/env python3
"""
check-foreign-host-401-scoping.py — detect 401/credentials-stale dispatch
sites that lack current-account host-scoping.

Catches the class of wall-failure surfaced by PR #1018 / PP-4436 (the Icarus
cross-host logout regression): a 401 from a host outside the current
account's auth surface mis-attributed to the current account, dispatched
through `markCredentialsStale()` / `coordinator.refreshCredentialsIfNeeded`,
and surfacing a sign-in modal for the wrong account every time the foreign
upload retries.

Predicate (FH-1):

  Within a single Swift function body in a production file (under `Palace/`),
  the following ALL hold:

    1. A 401 sentinel appears:
         - `statusCode == 401`       (HTTPURLResponse.statusCode form)
         - `nsError.code == 401`     (NSError bridge form — see PR #1018
                                       architect-revised survivor at
                                       TPPNetworkExecutor.swift:582)
         - `error.code == 401`       (direct error.code form)
         - `(error as NSError).code == 401`

    2. The same function dispatches credential-stale or coordinator flows:
         - `markCredentialsStale()`           (any receiver)
         - `coordinator.refreshCredentialsIfNeeded`
         - `authCoordinator.refreshCredentialsIfNeeded`
         - `AuthCoordinator.refreshCredentialsIfNeeded`
         - `Task { ... await ...coordinator... }` containing
           `refreshCredentialsIfNeeded` or `markCredentialsStale`

    3. The function body does NOT reference any of:
         - `authSurfaceHosts`
         - `currentAccountHostsProvider`

    4. No `// no-host-scoping: <reason>` annotation appears on the
       dispatch line OR the 3 preceding lines.

False-positive escape hatch: `// no-host-scoping: <reason>` on or just
above the dispatch line.

Output (greppable):

    <file>:<line>: FH-1: high: 401 dispatch site has no current-account
        host-scoping reference in function body — Wall: PR #1044 /
        .forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md

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

Lineage / canonical fix pattern: PR #1044 + the two legacy sibling sites
`Palace/MyBooks/TokenRefreshInterceptor.swift:126` and
`Palace/MyBooks/DownloadAuthRetryHandler.swift:234`. Either inline an
`authSurfaceHosts` guard or wire `currentAccountHostsProvider` through
the classifier.
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

# 401 sentinel forms (Phase-1a-revised — covers nsError.code == 401 too).
_RE_401_SENTINELS = [
    re.compile(r"\bstatusCode\s*==\s*401\b"),
    re.compile(r"\bnsError\.code\s*==\s*401\b"),
    re.compile(r"\berror\.code\s*==\s*401\b"),
    re.compile(r"\(\s*\w+\s+as\s+NSError\s*\)\.code\s*==\s*401\b"),
]

# Credential-stale / coordinator dispatch forms.
_RE_DISPATCH = [
    re.compile(r"\bmarkCredentialsStale\s*\("),
    re.compile(r"\.\s*refreshCredentialsIfNeeded\b"),
]

# Host-scoping references (presence anywhere in the function body = clean).
_RE_HOST_SCOPE = [
    re.compile(r"\bauthSurfaceHosts\b"),
    re.compile(r"\bcurrentAccountHostsProvider\b"),
]

# Annotation escape hatch.
_RE_NO_HOST_SCOPING = re.compile(
    r"//\s*no-host-scoping\s*[:\-—]?\s*",
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


def _is_swift(path: str) -> bool:
    return path.endswith(".swift")


def _is_non_prod_swift(path: str) -> bool:
    return any(s in path for s in _NON_PROD_PATH_SUBSTRINGS)


# --- Function-body parsing -------------------------------------------------

@dataclass
class _FunctionBody:
    file_path: str
    start_line: int     # 1-based, line of the `func` keyword (or `{` opening)
    end_line: int       # 1-based, last line covered by the body
    lines: list[str]    # body content, as written

    def joined_text(self) -> str:
        return "\n".join(self.lines)


def _split_functions(file_path: str, lines: list[str]) -> list[_FunctionBody]:
    """Slice a Swift source file into top-level function bodies using a
    simple brace-depth heuristic.

    For every `func`/`init`-style declaration encountered at depth 0, we
    open a new body. We close it when brace depth returns to 0 after entering
    it. Lines that are NOT inside any function are emitted as a single
    file-scoped "function" so 401/dispatch patterns at file scope still
    surface (rare, but possible inside `extension { ... }` blocks).

    This is the same shape as check-blast-radius.py's _AddedLine walker:
    heuristic, deliberately lenient, the `// no-host-scoping:` annotation
    is the escape hatch for false positives.
    """
    bodies: list[_FunctionBody] = []
    depth = 0
    in_func = False
    body_start = 0
    body_lines: list[str] = []
    func_decl_depth = 0

    for idx, raw in enumerate(lines, start=1):
        # Strip line comments BEFORE brace counting so braces inside `//`
        # comments don't confuse the parser. Keep string-literal braces
        # alone; the heuristic accepts the noise.
        no_comment = _strip_line_comment(raw)
        opens = no_comment.count("{")
        closes = no_comment.count("}")

        if not in_func and _RE_FUNC_DECL.match(raw):
            # Look ahead for the opening brace on this line OR a following
            # line; the body starts when depth first goes > 0.
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
            # Body ends when brace depth drops to (func_decl_depth - 1) or
            # below; that means the function's own `}` has closed.
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

        # File-scope content (extension body etc.). We still track depth
        # so braces inside non-func code don't confuse subsequent func
        # detection.
        depth += opens
        depth -= closes
        if depth < 0:
            depth = 0

    # Unterminated function at EOF — flush whatever we have.
    if in_func and body_lines:
        bodies.append(_FunctionBody(
            file_path=file_path,
            start_line=body_start,
            end_line=body_start + len(body_lines) - 1,
            lines=body_lines,
        ))

    return bodies


def _strip_line_comment(raw: str) -> str:
    # Lightweight `//` strip. Does NOT handle URLs/strings — the brace
    # counter only needs approximate accuracy, and the annotation check
    # uses the raw text, not the stripped form.
    idx = raw.find("//")
    if idx < 0:
        return raw
    # Avoid stripping inside string literals containing `//` (rough check).
    head = raw[:idx]
    if head.count('"') % 2 == 1:
        return raw
    return head


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


_WALL_REF = (
    "Wall: PR #1044 / "
    ".forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md"
)


def _annotated_within(body: _FunctionBody, dispatch_line_idx: int) -> bool:
    """Check the dispatch line and the 3 preceding lines for the
    `// no-host-scoping:` escape hatch."""
    start = max(0, dispatch_line_idx - 3)
    for i in range(start, dispatch_line_idx + 1):
        if i >= len(body.lines):
            break
        if _RE_NO_HOST_SCOPING.search(body.lines[i]):
            return True
    return False


def _scan_file(file_path: str, source: str) -> list[_Finding]:
    """Scan a single Swift file's source text for FH-1 findings."""
    findings: list[_Finding] = []
    lines = source.splitlines()
    bodies = _split_functions(file_path, lines)
    for body in bodies:
        body_text = body.joined_text()
        has_401 = any(p.search(body_text) for p in _RE_401_SENTINELS)
        if not has_401:
            continue
        # Find dispatch lines within the body.
        dispatch_hits: list[int] = []
        for i, line in enumerate(body.lines):
            if any(p.search(line) for p in _RE_DISPATCH):
                dispatch_hits.append(i)
        if not dispatch_hits:
            continue
        # If any host-scoping reference appears anywhere in the body, the
        # function is considered properly scoped — skip.
        if any(p.search(body_text) for p in _RE_HOST_SCOPE):
            continue
        # Each remaining dispatch line that isn't individually annotated
        # produces a finding.
        for di in dispatch_hits:
            if _annotated_within(body, di):
                continue
            abs_line = body.start_line + di
            findings.append(_Finding(
                code="FH-1",
                severity="high",
                file_path=file_path,
                line_no=abs_line,
                description=(
                    "401 dispatch site has no current-account host-scoping "
                    f"reference in function body — {_WALL_REF}"
                ),
            ))
    return findings


# --- Diff mode -------------------------------------------------------------

def _files_from_diff(diff_text: str) -> dict[str, set[int]]:
    """Return {post-image file path → set of touched (added/context) line
    numbers}. We re-read the FULL file when a path is touched; the touched
    line set is used only to narrow findings to lines actually present
    in the diff.
    """
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
        # Diff fixture mode: try `rel_path` as-is.
        alt = Path(rel_path)
        if alt.is_file():
            return alt.read_text(encoding="utf-8", errors="replace")
        return None
    return abs_path.read_text(encoding="utf-8", errors="replace")


def _scan_diff(diff_text: str, repo_root: Path) -> list[_Finding]:
    """Diff mode: re-read each touched file and scan it; narrow the
    findings to lines whose line number is within the touched set
    (so unrelated pre-existing dispatch sites don't false-block a PR
    that didn't touch them)."""
    touched = _files_from_diff(diff_text)
    out: list[_Finding] = []
    for rel_path, lines in touched.items():
        if _is_non_prod_swift(rel_path):
            continue
        source = _read_swift_source(repo_root, rel_path)
        if source is None:
            # Fall back to reconstructing the post-image from the diff —
            # rarely needed in CI but matters for fixture-only diffs.
            source = _reconstruct_post_image(diff_text, rel_path)
            if source is None:
                continue
        file_findings = _scan_file(rel_path, source)
        # Narrow to dispatch lines that are in the touched set. This is
        # the same convention as the other detectors: a diff that doesn't
        # touch a pre-existing finding doesn't get blocked on it.
        for f in file_findings:
            if f.line_no in lines:
                out.append(f)
    return out


def _reconstruct_post_image(diff_text: str, target_path: str) -> str | None:
    """When a diff fixture supplies just `+` lines and no on-disk file,
    reconstruct a synthetic post-image from the added/context lines so
    the scanner has something to slice."""
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


# --- Scan mode -------------------------------------------------------------

def _scan_repo(repo_root: Path) -> list[_Finding]:
    out: list[_Finding] = []
    palace_dir = repo_root / "Palace"
    if not palace_dir.is_dir():
        # Be permissive — scan whatever Swift files exist under root.
        palace_dir = repo_root
    for root, _dirs, files in os.walk(palace_dir):
        for name in files:
            if not name.endswith(".swift"):
                continue
            full = Path(root) / name
            rel = str(full.relative_to(repo_root))
            if _is_non_prod_swift(rel):
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
        prog="check-foreign-host-401-scoping.py",
        description=(
            "Scan a unified diff (or repo) for 401-dispatch sites that "
            "lack current-account host-scoping. Catches the PR #1018 / "
            "PR #1044 wall-failure class."
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
        msg = (f"\n{len(findings)} foreign-host-401 finding(s); "
               f"{len(blocking)} at/above floor={args.severity_floor}")
        print(msg, file=sys.stderr)

    if args.no_block or args.dry_run:
        return 0
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
