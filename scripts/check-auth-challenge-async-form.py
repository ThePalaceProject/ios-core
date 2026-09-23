#!/usr/bin/env python3
"""
check-auth-challenge-async-form.py — require the ASYNC spelling for
authentication-challenge delegate callbacks in the app target
(`Palace/**/*.swift`).

Catches the PP-4895 regression class, a second sighting of the #1338 Xcode 26.2
ClangImporter defect on a different block shape.

The canonical clang block type
`void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *)` is shared by
two SDK requirements that annotate it differently:

  * `URLSessionTaskDelegate` / `URLSessionDelegate` auth challenge —
    `NS_SWIFT_SENDABLE`
  * `WKNavigationDelegate.webView(_:didReceive:completionHandler:)` —
    `WK_SWIFT_UI_ACTOR`, i.e. `@MainActor`

The ClangImporter caches ONE imported Swift type per canonical block type per
`swift-frontend` process, first use wins. So whichever framework is imported
first in a given compile batch decides whether BOTH requirements carry
`@MainActor`, and the loser's implementation stops matching its requirement. A
method that fails to match an `@objc` optional requirement is not exported to
the ObjC runtime at all — and URLSession/WebKit invoke optional delegate methods
only when the delegate answers `respondsToSelector:` — so the callback silently
never fires. Measured on iOS 26.2 and macOS SDKs, both orders:

    WebKit decl first     -> our URLSession method warns; responds(to:) == false
    Foundation decl first -> WebKit's method warns instead

Annotating the handler to match is NOT a fix: it repairs one import order and
breaks the other, because which side loses depends only on frontend batch
membership. Forcing the selector with an explicit
`@objc(URLSession:task:didReceiveChallenge:completionHandler:)` is a hard
compile error ("provided by method ... conflicts with optional requirement").

The fix is to implement the SDK's ASYNC spelling instead. It carries no block
parameter, so there is nothing for the importer to poison, and it registers
under both orders:

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge)
    async -> (URLSession.AuthChallengeDisposition, URLCredential?)   // APPROVED

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (...) -> Void)      // BANNED

Note the build-log detector (`check-objc-witness-nearly-matches.sh`) cannot
replace this one: it only sees the batch lottery draw that a given build
happened to make. The DRM `Palace` target and the `Palace-noDRM` target compiled
from the SAME source disagreed about whether this warning fires, which is how
the defect reached a release in the first place — CI only ever scanned the DRM
log.

Detection: any `func` whose parameter list mentions `URLAuthenticationChallenge`
AND has a `completionHandler:` parameter. Parameter lists are extracted by
balanced-paren scan (they span lines and contain nested parens from closure
types), over a comment-stripped copy of the source so a prose mention in a doc
comment cannot trip the gate.

Scope: `Palace/**/*.swift` (app target). Test/mock/preview/scripts dirs are
excluded — mirrors `check-addoperation-literal-ban.py`.

False-positive escape hatch: `// no-auth-challenge-async-form: <reason>` on the
violating line or any of the 3 preceding lines.

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

_RE_FUNC = re.compile(r"\bfunc\s+[A-Za-z_]\w*\s*(?:<[^>]*>\s*)?\(")
_RE_CHALLENGE_PARAM = re.compile(r"\bURLAuthenticationChallenge\b")
_RE_COMPLETION_PARAM = re.compile(r"\bcompletionHandler\s*:")

_RE_NO_BAN_ANNOTATION = re.compile(
    r"//\s*no-auth-challenge-async-form\b", re.IGNORECASE
)

# Non-prod path substrings — mirrors check-addoperation-literal-ban.py.
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


def _blank_comments(source: str) -> str:
    """Return `source` with comment bodies replaced by spaces, preserving every
    byte offset and newline so line numbers still map exactly.

    Prose in a doc comment must never trip this gate — the sibling ratchet
    detectors have been tripped by comments before, and the fixed callbacks this
    gate protects carry long explanatory comments that name both the banned
    parameter and the challenge type.
    """
    out = list(source)
    i, n = 0, len(source)
    state = None  # None | 'line' | 'block' | 'string'
    depth = 0
    while i < n:
        ch = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if state is None:
            if ch == '"':
                state = 'string'
            elif ch == "/" and nxt == "/":
                state = 'line'
                out[i] = out[i + 1] = " "
                i += 2
                continue
            elif ch == "/" and nxt == "*":
                state = 'block'
                depth = 1
                out[i] = out[i + 1] = " "
                i += 2
                continue
        elif state == 'string':
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                state = None
        elif state == 'line':
            if ch == "\n":
                state = None
            else:
                out[i] = " "
        elif state == 'block':
            if ch == "/" and nxt == "*":
                depth += 1
                out[i] = out[i + 1] = " "
                i += 2
                continue
            if ch == "*" and nxt == "/":
                depth -= 1
                out[i] = out[i + 1] = " "
                i += 2
                if depth == 0:
                    state = None
                continue
            if ch != "\n":
                out[i] = " "
        i += 1
    return "".join(out)


def _param_list(source: str, open_paren: int) -> tuple[str, int] | None:
    """Return (parameter-list text, offset just past the closing paren) for the
    `(` at `open_paren`, or None when unbalanced."""
    depth = 0
    i = open_paren
    n = len(source)
    while i < n:
        if source[i] == "(":
            depth += 1
        elif source[i] == ")":
            depth -= 1
            if depth == 0:
                return source[open_paren + 1:i], i + 1
        i += 1
    return None


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
    """Find completion-handler-form auth-challenge callbacks. Line-no sorted."""
    if _is_non_prod_swift(rel_path):
        return []
    if not rel_path.endswith(".swift"):
        return []

    code = _blank_comments(source)
    lines = source.splitlines()
    findings: list[_Finding] = []

    for m in _RE_FUNC.finditer(code):
        extracted = _param_list(code, m.end() - 1)
        if extracted is None:
            continue
        params, _ = extracted
        if not _RE_CHALLENGE_PARAM.search(params):
            continue
        if not _RE_COMPLETION_PARAM.search(params):
            continue
        line_no = _line_no_at_offset(code, m.start())
        if _has_annotation(lines, line_no):
            continue
        findings.append(_Finding(
            code="ACF-1",
            severity="high",
            file_path=rel_path,
            line_no=line_no,
            description=(
                "authentication-challenge delegate callback declared in the "
                "completion-handler form — Xcode 26.2 ClangImporter "
                "@MainActor-poisoning risk (PP-4895): a WebKit auth-challenge "
                "declaration anywhere in the same compile batch flips the "
                "requirement to @MainActor, this method stops matching it, and "
                "it is then absent from the ObjC runtime, so URLSession never "
                "calls it and the challenge goes unanswered. Implement the SDK's "
                "async spelling instead: `... didReceive challenge: "
                "URLAuthenticationChallenge) async -> "
                "(URLSession.AuthChallengeDisposition, URLCredential?)`."
            ),
        ))

    findings.sort(key=lambda f: (f.file_path, f.line_no))
    return findings


# --- Diff mode ---------------------------------------------------------------

def _scan_diff(diff_text: str, repo_root: Path) -> list[_Finding]:
    """Scan a unified diff: per touched file, reconstruct or read the post-image
    and emit findings whose line numbers fall on ADDED lines."""
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
            # A multi-line signature counts as touched when ANY of its lines is
            # added — a diff that adds only the `completionHandler:` line to an
            # existing `func` header is exactly the regression to catch.
            if _signature_touches(source, f.line_no, added_lines):
                out.append(f)
    return out


def _signature_touches(source: str, decl_line: int, added: set[int]) -> bool:
    """True when any line of the declaration starting at `decl_line` was added.

    The signature's extent is taken as the declaration line through the line
    holding its closing paren.
    """
    code = _blank_comments(source)
    lines = code.splitlines()
    if decl_line < 1 or decl_line > len(lines):
        return decl_line in added
    offset = sum(len(l) + 1 for l in lines[:decl_line - 1])
    open_paren = code.find("(", offset)
    if open_paren == -1:
        return decl_line in added
    extracted = _param_list(code, open_paren)
    if extracted is None:
        return decl_line in added
    _, end = extracted
    last_line = _line_no_at_offset(code, end - 1)
    return any(ln in added for ln in range(decl_line, last_line + 1))


def _reconstruct_post_image(diff_text: str, target_path: str) -> str | None:
    """Reconstruct a synthetic post-image when the file isn't on disk."""
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
    return "\n".join(rows.get(i, "") for i in range(1, max_line + 1))


# --- Scan mode ---------------------------------------------------------------

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


# --- CLI ---------------------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-auth-challenge-async-form.py",
        description=(
            "Require the async spelling for authentication-challenge delegate "
            "callbacks in Palace/**/*.swift — Xcode 26.2 ClangImporter "
            "@MainActor-poisoning risk (PP-4895)."
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
            findings = _scan_diff(diff_text, Path.cwd())
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
        print(f"\n{len(findings)} auth-challenge-async-form finding(s); "
              f"{len(blocking)} at/above floor={args.severity_floor}",
              file=sys.stderr)

    if args.no_block or args.dry_run:
        return 0
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
