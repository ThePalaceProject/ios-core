#!/usr/bin/env python3
"""
check-completion-nil-error-suppression.py — detect `(Error?, String?, String?)`
completion calls that pass `nil` for the error while supplying a title/message,
silently suppressing the consumer's `if let error, let title, let message`
alert path.

Catches the PP-4419 / HelpSpot 17870 wall-failure class: SAML sign-in silently
failed because `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift` invoked
`completion(nil, title, message)` from 3 failure exits. The consumer
`TPPSAMLHelper` guards with `if let error, let errorTitle, let errorMessage` —
a nil error blocks the alert path even when title/message are set. The canonical
fix is to synthesize `NSError(domain: "OAuth.SignIn", code: 0, userInfo: [...])`
and pass that as the first arg (see commit 547e185aa).

Predicate (D3-1, Phase-1a-revised):

  A completion-style call where ALL of the following hold:

    1. The call shape is `<recv>?(...)` or `<recv>(...)` where `<recv>` ends in
       `completion` (e.g. `completion`, `self.completion`, `self?.completion`).

    2. The first positional argument is exactly `nil` (after stripping
       whitespace and an optional trailing comma).

    3. Among the remaining positional arguments (positions 2..N), at least ONE
       is either:
         a. A string literal — `"..."`           (the PP-4419 shape directly), or
         b. A variable identifier whose name matches `title` / `message` /
            `errorTitle` / `errorMessage` AND was bound to a string literal in
            the same function body via `let <name> = "..."` (or
            `let <name> = NSLocalizedString(...)`).

    4. The all-nil shape `completion?(nil, nil, nil)` is EXPLICITLY EXCLUDED —
       that is the OAuth success path at
       `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift:244` (verified)
       and is correct semantics, not the bug class.

    5. The failure-passthrough shape `completion?(nil, response, error)` is
       EXCLUDED because the error position is non-nil through `error`. (Note:
       the spec predicate above ONLY fires when arg-1 is literally `nil` and a
       LATER arg is a string-literal/title-bound variable; `response, error`
       are neither, so this falls out naturally.)

  False-positive escape hatch: `// no-nil-error-suppression: <reason>` on the
  call line or any of the 3 preceding lines.

Output (greppable):

    <file>:<line>: D3-1: high: completion with nil error + non-nil title/message
        suppresses consumer alert path — Wall: PP-4419

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

Lineage / canonical fix pattern: commit 547e185aa — synthesize an NSError
with `domain: "OAuth.SignIn", code: 0, userInfo: [NSLocalizedDescriptionKey: ...]`
and pass it as the first arg. The consumer's `if let error` guard then succeeds
and the alert path runs.
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

# Completion-call recognition. We look for any identifier ending in
# "completion" that is being CALLED — either `completion(` or `completion?(`.
# Receivers like `self.completion` and `self?.completion` are supported.
# The identifier must be a WORD-BOUNDARY match so `var completion: ...` (which
# is followed by `:` not `(`) and decl-style hits don't match, and so
# unrelated identifiers ending in something other than "completion" don't
# accidentally hit.
_RE_COMPLETION_CALL = re.compile(
    r"(?<![A-Za-z_0-9])"
    r"(?P<prefix>(?:[A-Za-z_][\w]*(?:\?)?\.)*"
    r"[A-Za-z_]*[Cc]ompletion)"
    r"(?P<opt>\??)\s*\("
)

# Function-decl heuristic — same convention as check-foreign-host-401-scoping.
_RE_FUNC_DECL = re.compile(
    r"^\s*(?:@\w+\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|"
    r"open\s+)*"
    r"(?:static\s+|class\s+|final\s+|override\s+|mutating\s+)*"
    r"(?:func|init)\b"
)

# `let <name> = "<literal>"` or `let <name> = NSLocalizedString(...)` or
# `let <name> = Strings.<...>` — anything that resolves to a string.
_RE_LET_STRING = re.compile(
    r"^\s*let\s+(?P<name>title|message|errorTitle|errorMessage)\s*"
    r"(?::\s*String\s*)?=\s*(?P<rhs>.+)$"
)
_RE_STRING_LITERAL = re.compile(r'^"[^"]*"$')
_RE_STRING_RHS_HINT = re.compile(
    r'"[^"]*"|NSLocalizedString\s*\(|Strings\.|Localized\b'
)

_RE_NO_NIL_ERROR_SUPPRESSION = re.compile(
    r"//\s*no-nil-error-suppression\b",
    re.IGNORECASE,
)

# Identifiers we accept as "looks like a title/message" when used in args 2-3.
# Direct names only; partial matches (e.g. "errorMessage" -> "Message") happen
# via the canonical bindings table built per-function.
_TITLE_MESSAGE_NAMES = {"title", "message", "errorTitle", "errorMessage"}

# Non-prod path substrings — mirror check-blast-radius.py.
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


# --- Helpers ---------------------------------------------------------------

def _is_non_prod_swift(path: str) -> bool:
    return any(s in path for s in _NON_PROD_PATH_SUBSTRINGS)


def _split_top_level_args(arg_text: str) -> list[str]:
    """Split a comma-separated argument list at top-level commas only.

    Honors nesting in `()`, `[]`, `{}` and string literals (`"..."`). Returns
    the trimmed argument expressions, including any leading `label:` token.
    """
    parts: list[str] = []
    depth_paren = 0
    depth_brack = 0
    depth_brace = 0
    in_string = False
    string_quote = ""
    escape = False
    buf: list[str] = []
    for ch in arg_text:
        if in_string:
            buf.append(ch)
            if escape:
                escape = False
                continue
            if ch == "\\":
                escape = True
                continue
            if ch == string_quote:
                in_string = False
            continue
        if ch == '"':
            in_string = True
            string_quote = ch
            buf.append(ch)
            continue
        if ch == "(":
            depth_paren += 1
        elif ch == ")":
            depth_paren -= 1
        elif ch == "[":
            depth_brack += 1
        elif ch == "]":
            depth_brack -= 1
        elif ch == "{":
            depth_brace += 1
        elif ch == "}":
            depth_brace -= 1
        elif (ch == "," and depth_paren == 0 and depth_brack == 0
              and depth_brace == 0):
            parts.append("".join(buf).strip())
            buf = []
            continue
        buf.append(ch)
    tail = "".join(buf).strip()
    if tail:
        parts.append(tail)
    return [_strip_label(p) for p in parts]


def _strip_label(arg: str) -> str:
    """`error: nil` -> `nil`. Leaves un-labeled args alone."""
    m = re.match(r"^\s*[A-Za-z_]\w*\s*:\s*(?P<v>.+)$", arg)
    return m.group("v").strip() if m else arg.strip()


# Whole-arg shapes that represent a STRING-TYPED value. We deliberately reject
# anything that looks like `NSError(...)`, `XError.case(...)`,
# `Foo(domain: ..., userInfo: [... : "literal"])` etc. — those are Error-typed
# even if a string literal lives nested inside.
_RE_BARE_STRING_LITERAL = re.compile(r'^"(?:[^"\\]|\\.)*"$')
# Interpolated string literal — single-line `"...\(...)..."` shape.
_RE_INTERPOLATED_STRING = re.compile(r'^"(?:[^"\\]|\\.|\\\([^)]*\))*"$')
_RE_NSLOCALIZED = re.compile(r"^NSLocalizedString\s*\(")
# Palace convention: localized constants live under `Strings.<...>` and
# resolve to `String`. Tightened to a *chain that ends* at an identifier
# (no trailing `(`) so `Strings.Foo.bar()` (a method call) doesn't pass.
_RE_STRINGS_DOT_CHAIN = re.compile(
    r"^Strings(?:\.[A-Za-z_]\w*)+\s*$"
)


def _is_string_typed_arg(arg: str) -> bool:
    """Return True if `arg` is a TOP-LEVEL String-typed expression.

    Accepts bare string literals (`"..."`), interpolated strings, bare
    `NSLocalizedString(...)` whole-arg calls, and `Strings.<...>` constants
    (Palace localized-strings ns). Rejects `NSError(...)`, `*.case(...)`,
    `XError.foo(message: "...")` etc. — those are Error-typed even when a
    string literal lives nested inside.
    """
    s = arg.strip()
    if not s:
        return False
    if _RE_BARE_STRING_LITERAL.match(s):
        return True
    if _RE_INTERPOLATED_STRING.match(s):
        return True
    # `NSLocalizedString("...", ...)` as a whole-arg expression — must START
    # with the call. The presence of a top-level paren means the function-call
    # is the whole expression.
    if _RE_NSLOCALIZED.match(s) and s.endswith(")"):
        return True
    if _RE_STRINGS_DOT_CHAIN.match(s):
        return True
    return False


def _slice_call_args(source: str, call_open_pos: int) -> tuple[str, int] | None:
    """Given a position at the opening `(` of a call, return the inner-arg text
    and the position just past the matching `)`. Returns None if unbalanced.
    """
    if call_open_pos >= len(source) or source[call_open_pos] != "(":
        return None
    depth = 0
    in_string = False
    string_quote = ""
    escape = False
    i = call_open_pos
    n = len(source)
    while i < n:
        ch = source[i]
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == string_quote:
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            string_quote = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                inner = source[call_open_pos + 1:i]
                return inner, i + 1
        i += 1
    return None


# --- Per-function scan -----------------------------------------------------

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


def _function_bounds(source_lines: list[str]) -> list[tuple[int, int]]:
    """Return [(start_line, end_line)] (1-based, inclusive) for each function.

    Naive but matches the sibling detector's approach: a function starts on a
    line matching _RE_FUNC_DECL and ends at the matching closing brace tracked
    by curly-brace depth from the FIRST `{` after the decl. End-of-file closes
    the last open function.
    """
    bounds: list[tuple[int, int]] = []
    n = len(source_lines)
    i = 0
    in_block_comment = False
    while i < n:
        line = source_lines[i]
        # Strip block-comment regions (very rough; good enough for func-decl).
        if in_block_comment:
            end = line.find("*/")
            if end != -1:
                in_block_comment = False
            i += 1
            continue
        start_bc = line.find("/*")
        if start_bc != -1 and line.find("*/", start_bc) == -1:
            in_block_comment = True
            i += 1
            continue
        if _RE_FUNC_DECL.match(line):
            # Walk forward to find first `{` (could be on same line or later).
            depth = 0
            opened = False
            j = i
            while j < n:
                # Skip // comments on the line for brace counting.
                seg = re.sub(r"//.*$", "", source_lines[j])
                # Strip strings (cheap heuristic).
                seg = re.sub(r'"[^"]*"', "", seg)
                for ch in seg:
                    if ch == "{":
                        depth += 1
                        opened = True
                    elif ch == "}":
                        depth -= 1
                if opened and depth == 0:
                    bounds.append((i + 1, j + 1))
                    i = j
                    break
                j += 1
            else:
                # Didn't close — treat as open to EOF.
                bounds.append((i + 1, n))
                break
        i += 1
    return bounds


def _bindings_in_range(
    source_lines: list[str], start_line: int, end_line: int
) -> dict[str, bool]:
    """Return name -> True if `let <name> = <string-like>` was bound anywhere in
    [start_line..end_line] (1-based, inclusive). Names limited to
    _TITLE_MESSAGE_NAMES.
    """
    out: dict[str, bool] = {}
    for ln in range(start_line, end_line + 1):
        if ln < 1 or ln > len(source_lines):
            continue
        line = source_lines[ln - 1]
        m = _RE_LET_STRING.match(line)
        if not m:
            continue
        name = m.group("name")
        rhs = m.group("rhs").strip()
        if rhs.endswith(","):
            rhs = rhs[:-1].strip()
        if (_RE_STRING_LITERAL.match(rhs)
                or _RE_STRING_RHS_HINT.search(rhs)):
            out[name] = True
    return out


def _scan_file(rel_path: str, source: str) -> list[_Finding]:
    """Find all D3-1 violations in `source`. Returns line-no-sorted findings."""
    if _is_non_prod_swift(rel_path):
        return []
    if not rel_path.endswith(".swift"):
        return []

    findings: list[_Finding] = []
    lines = source.splitlines()
    func_bounds = _function_bounds(lines)

    # Build a map of (call_line) -> the function it lives in, so we can scope
    # let-bindings to the same function body.
    def find_func(line_no: int) -> tuple[int, int] | None:
        for s, e in func_bounds:
            if s <= line_no <= e:
                return (s, e)
        return None

    # Scan for `<...>completion(` and `<...>completion?(` occurrences.
    for m in _RE_COMPLETION_CALL.finditer(source):
        opt = m.group("opt")
        # The opening paren is right after the match end.
        paren_pos = m.end() - 1
        sliced = _slice_call_args(source, paren_pos)
        if sliced is None:
            continue
        inner, _ = sliced
        args = _split_top_level_args(inner)
        if len(args) < 2:
            # Single-arg or zero-arg completion can't be the (Error?, String?,
            # String?) shape.
            continue

        # ARG-1 must be exactly `nil`.
        first = args[0].strip()
        if first != "nil":
            continue

        # FALSE-POSITIVE GUARD: all-nil success-path shape (e.g.
        # `completion?(nil, nil, nil)` at OAuth+244).
        if all(a.strip() == "nil" for a in args):
            continue

        # Check args 2..N for: (a) string literal OR (b) recently-bound
        # title/message variable.
        call_line = _line_no_at_offset(source, m.start())
        fb = find_func(call_line)
        bindings: dict[str, bool] = {}
        if fb is not None:
            bindings = _bindings_in_range(lines, fb[0], call_line - 1)

        # The PP-4419 shape REQUIRES the (Error?, String?, String?) call
        # signature. Therefore args 2-3 must be string-typed — directly. We
        # accept:
        #
        #   - bare string literal:           `"Sign In Failed"`
        #   - bare interpolated string:      `"\(thing) failed"`
        #   - localized-strings constant:    `Strings.Error.loginErrorTitle`
        #     or `Strings.Error.loginErrorDescription` (Palace convention)
        #   - bare `NSLocalizedString(...)`  (whole-arg form)
        #   - a bare identifier `title` / `message` / `errorTitle` /
        #     `errorMessage` that was let-bound to a string in the same
        #     function body.
        #
        # We deliberately REJECT args that are NSError(...) / XError.case(...)
        # constructors — those are Error-typed even if they contain a string
        # literal nested inside their userInfo. The DPLA/LCP false positives
        # surfaced this: `completion(nil, nil, DPLAError.requestError("..."))`
        # is the failure-passthrough shape with the error in position 3 of an
        # (X?, Y?, Error?) signature — NOT the PP-4419 shape.
        triggers_string_literal = False
        triggers_bound_var = False
        for arg in args[1:]:
            stripped = arg.strip()
            if stripped == "nil":
                continue
            if _is_string_typed_arg(stripped):
                triggers_string_literal = True
                continue
            # Bare-identifier check — recently bound to a string in scope.
            ident_m = re.match(r"^([A-Za-z_]\w*)$", stripped)
            if ident_m and ident_m.group(1) in bindings:
                triggers_bound_var = True
                continue

        if not (triggers_string_literal or triggers_bound_var):
            continue

        # Annotation escape: `// no-nil-error-suppression:` on the call line or
        # any of the 3 preceding lines (mirror sibling detectors).
        if _has_annotation(lines, call_line):
            continue

        findings.append(_Finding(
            code="D3-1",
            severity="high",
            file_path=rel_path,
            line_no=call_line,
            description=(
                "completion with nil error + non-nil title/message "
                "suppresses consumer alert path — Wall: PP-4419"
            ),
        ))

    findings.sort(key=lambda f: (f.file_path, f.line_no))
    return findings


def _has_annotation(lines: list[str], call_line: int) -> bool:
    start = max(1, call_line - 3)
    for ln in range(start, call_line + 1):
        if ln < 1 or ln > len(lines):
            continue
        if _RE_NO_NIL_ERROR_SUPPRESSION.search(lines[ln - 1]):
            return True
    return False


# --- Diff mode -------------------------------------------------------------

def _scan_diff(diff_text: str, repo_root: Path) -> list[_Finding]:
    """Scan a unified diff: per touched file, reconstruct or read the post-image
    and emit findings whose line numbers fall on TOUCHED lines (added or
    context within a hunk that contained additions).
    """
    # Group added-line numbers per file.
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
    for rel_path, lines in touched.items():
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
        # Narrow to findings whose call line is in the touched set — same
        # convention as the sibling detectors.
        for f in file_findings:
            if f.line_no in lines:
                out.append(f)
    return out


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
    out_lines = [rows.get(i, "") for i in range(1, max_line + 1)]
    return "\n".join(out_lines)


# --- Scan mode -------------------------------------------------------------

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


# --- CLI -------------------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-completion-nil-error-suppression.py",
        description=(
            "Scan a unified diff (or repo) for `completion(nil, title, message)`"
            " call sites that suppress the consumer's `if let error` alert "
            "guard. Catches the PP-4419 / HelpSpot 17870 wall-failure class."
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
        msg = (f"\n{len(findings)} completion-nil-error finding(s); "
               f"{len(blocking)} at/above floor={args.severity_floor}")
        print(msg, file=sys.stderr)

    if args.no_block or args.dry_run:
        return 0
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
