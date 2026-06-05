#!/usr/bin/env python3
"""
check-notification-center-observer-storage.py — detect NotificationCenter
observer registrations that leak by failing to store the returned token
AND lacking a class-level removeObserver cleanup.

Catches PP-4329 wall-class: library selector appears 2-4 times on first
launch because `NotificationCenter.default.addObserver(forName:object:queue:using:)`
was called recursively in a method that re-entered itself on every
`.TPPCatalogDidLoad` post; each call registered a fresh observer whose
returned `NSObjectProtocol` token was never captured, so the recursive
re-entry stacked observers until 8 catalog-load posts fanned out into
2-4 stacked modals.

Predicate (D5-1):

  Within a single Swift class/struct/extension body in a production file
  (under `Palace/`), the following ALL hold:

    1. A closure-API observer registration appears:
         - `NotificationCenter.default.addObserver(forName:`
         - `NotificationCenter.default.addObserver(\n forName:`  (multi-line)
       The closure form returns an `NSObjectProtocol` token; the bug class
       is failing to capture that return value.

    2. The returned token is NOT bound to:
         - a `let token = NotificationCenter.default.addObserver(...)`
         - a `self.<property> = NotificationCenter.default.addObserver(...)`
         - a `<property> = NotificationCenter.default.addObserver(...)`
       and the call is NOT consumed by `.append(...)` / `.insert(...)`
       into a Set/Array on the same line / preceding `=` assignment.

    3. The enclosing type does NOT contain ANY of:
         - `deinit { ... NotificationCenter.default.removeObserver(self) ... }`
         - A `removeObserver(` call inside any function body
         - `applicationWillTerminate` / class-level cleanup with
           `removeObserver(self)`
       In other words: no cleanup mechanism is visible anywhere in the
       same type body.

    4. No `// no-observer-storage: <reason>` annotation appears on the
       addObserver line OR the 3 preceding lines.

Selector-form (`.addObserver(_:selector:name:object:)`) is OUT OF SCOPE per
the architect contract — it is a different shape (no return token, paired
with `removeObserver(self)` typically) and not the observed leak class
from PP-4329.

False-positive escape hatch: `// no-observer-storage: <reason>` on or just
above the addObserver line. Use for AppDelegate-lifetime observers that
intentionally never deregister.

Output (greppable):

    <file>:<line>: D5-1: medium: NotificationCenter observer registered
        without storage/removal — risk of leak / double-fire on re-init
        — Wall: PP-4329

Exit codes:
  0  — no findings at or above the severity floor (default: medium)
  1  — at least one finding at or above the floor
  2  — argument or I/O error

Flags (mirror the sibling pre-commit detectors):

  --diff <file>        Path to unified-diff input. `-` or omit for stdin.
  --scan <repo-root>   Walk `<root>/Palace/**/*.swift` directly instead of
                       a diff. Used for the one-time wipe.
  --severity-floor LVL Block at LVL or higher (low|medium|high). Default
                       medium (D5-1 is a medium finding).
  --no-block           Print findings, always exit 0.
  --quiet              Suppress trailing summary line on stderr.
  --dry-run            Parse only; never exit non-zero on findings.

Lineage / canonical fix pattern: commit `0bbbf2b4a` (PP-4329) — capture
the returned `NSObjectProtocol` in a `firstRunFlowObserver` property,
remove it before re-registering AND once past the deferred state. The
clean reference site is `Palace/AppInfrastructure/DLNavigator.swift:107`
(callOnce helper that captures `token` and self-removes inside the
closure).
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from _checklib import SEVERITY_RANK, at_or_above, read_diff, iter_hunk_lines


# --- Severity ladder (shared with scripts/_checklib.py) --------------------

_SEVERITY_RANK = SEVERITY_RANK
_at_or_above = at_or_above


# --- Detection patterns ----------------------------------------------------

# Closure-form addObserver. The selector form is excluded by requiring
# `forName:` in the same call site (the closure overload is the one that
# returns an NSObjectProtocol token).
#
# Two shapes are handled:
#   - Single-line: `NotificationCenter.default.addObserver(forName: ...`
#   - Multi-line:  `NotificationCenter.default.addObserver(` followed by
#                  a line starting with `forName:` within the next 3 lines.
# Selector form (`addObserver(self,`, `addObserver(_:selector:`) is
# explicitly NOT matched — the next-line `forName:` check excludes it.
_RE_ADD_OBSERVER_SAME_LINE = re.compile(
    r"NotificationCenter\.default\.addObserver\s*\(\s*forName\s*:",
)
# Tolerant opener: matches `NotificationCenter.default.addObserver(` with
# nothing meaningful after `(` on the same line — used together with a
# look-ahead check for `forName:` on a subsequent line.
_RE_ADD_OBSERVER_OPEN = re.compile(
    r"NotificationCenter\.default\.addObserver\s*\(\s*$",
)
_RE_FORNAME_HEAD = re.compile(r"^\s*forName\s*:")

# A line that ALSO carries an assignment of the return value — clean.
# Matches: `let x = `, `var x = `, `self.x = `, `x = ` immediately before
# `NotificationCenter.default.addObserver(`. Also matches `.append(` /
# `.insert(` wrapping the call (Set<NSObjectProtocol> storage pattern).
_RE_TOKEN_BOUND = re.compile(
    r"(?:"
    r"(?:let|var)\s+\w+\s*(?::[^=]+)?=\s*NotificationCenter\.default\.addObserver"
    r"|"
    r"(?:self\.)?\w[\w\.\[\]]*\s*=\s*NotificationCenter\.default\.addObserver"
    r"|"
    r"\.\s*(?:append|insert)\s*\(\s*NotificationCenter\.default\.addObserver"
    r")",
)

# Any removeObserver call within the type body counts as cleanup
# evidence. Includes:
#   NotificationCenter.default.removeObserver(self)
#   NotificationCenter.default.removeObserver(token, ...)
#   NotificationCenter.default.removeObserver(token, name:..., object:...)
_RE_REMOVE_OBSERVER = re.compile(
    r"NotificationCenter\.default\.removeObserver\s*\(",
)

# Annotation escape hatch.
_RE_NO_OBSERVER_STORAGE = re.compile(
    r"//\s*no-observer-storage\s*[:\-—]?\s*",
    re.IGNORECASE,
)

# Type-declaration heuristic. We slice each Swift file into "type bodies"
# (class / struct / extension / actor / enum) and apply the predicate
# within each body. An observer added at file scope (rare) is treated as
# its own pseudo-body.
_RE_TYPE_DECL = re.compile(
    r"^\s*(?:@\w+\s+)*"
    r"(?:public\s+|internal\s+|private\s+|fileprivate\s+|"
    r"open\s+|final\s+)*"
    r"(?:class|struct|extension|actor|enum|protocol)\s+\w+",
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


# --- Type-body parsing -----------------------------------------------------

@dataclass
class _TypeBody:
    file_path: str
    start_line: int      # 1-based, line of the type decl
    end_line: int        # 1-based, closing brace line
    lines: list[str]     # body content, raw

    def joined_text(self) -> str:
        return "\n".join(self.lines)


def _strip_line_comment(raw: str) -> str:
    """Lightweight `//` strip used for brace counting. Same shape as the
    sibling foreign-host detector."""
    idx = raw.find("//")
    if idx < 0:
        return raw
    head = raw[:idx]
    if head.count('"') % 2 == 1:
        return raw
    return head


def _split_types(file_path: str, lines: list[str]) -> list[_TypeBody]:
    """Slice a Swift file into top-level type bodies.

    A "type body" runs from a `class`/`struct`/`extension`/`actor`/`enum`
    /`protocol` declaration at depth 0 through the matching closing brace.
    Anything outside a type body (rare in this codebase — file-scope
    free functions, top-level lets) is dropped: PP-4329 lives inside
    `class TPPAppDelegate`, and the predicate is a per-type one (the
    `removeObserver(self)` cleanup lives in the same class).
    """
    bodies: list[_TypeBody] = []
    depth = 0
    in_type = False
    body_start = 0
    body_lines: list[str] = []
    type_decl_depth = 0

    for idx, raw in enumerate(lines, start=1):
        no_comment = _strip_line_comment(raw)
        opens = no_comment.count("{")
        closes = no_comment.count("}")

        if not in_type and _RE_TYPE_DECL.match(raw):
            in_type = True
            body_start = idx
            body_lines = [raw]
            depth += opens
            depth -= closes
            if depth > 0:
                type_decl_depth = depth
            continue

        if in_type:
            body_lines.append(raw)
            depth += opens
            depth -= closes
            if depth < type_decl_depth:
                bodies.append(_TypeBody(
                    file_path=file_path,
                    start_line=body_start,
                    end_line=idx,
                    lines=body_lines,
                ))
                in_type = False
                body_lines = []
                type_decl_depth = 0
                if depth < 0:
                    depth = 0
            continue

        depth += opens
        depth -= closes
        if depth < 0:
            depth = 0

    # Unterminated type body at EOF.
    if in_type and body_lines:
        bodies.append(_TypeBody(
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


_WALL_REF = "Wall: PP-4329"
_DESCRIPTION = (
    "NotificationCenter observer registered without storage/removal "
    f"— risk of leak / double-fire on re-init — {_WALL_REF}"
)


def _annotated_within(body: _TypeBody, hit_idx: int) -> bool:
    """Check the addObserver line and the 3 preceding lines for the
    `// no-observer-storage:` escape hatch."""
    start = max(0, hit_idx - 3)
    for i in range(start, hit_idx + 1):
        if i >= len(body.lines):
            break
        if _RE_NO_OBSERVER_STORAGE.search(body.lines[i]):
            return True
    return False


def _hit_is_token_bound(body: _TypeBody, hit_idx: int) -> bool:
    """Token-binding scan. Accepts the addObserver line OR the previous
    one line (Swift multi-line call style where the assignment lives on
    the line before `NotificationCenter.default.addObserver(`).

    Pattern variants handled:
        let token = NotificationCenter.default.addObserver(...)
        self.token = NotificationCenter.default.addObserver(...)
        observers.insert(NotificationCenter.default.addObserver(...))
        subscriptions.append(NotificationCenter.default.addObserver(...))
    Plus multi-line form:
        firstRunFlowObserver = NotificationCenter.default.addObserver(
            forName: ...,
    """
    # Same-line bind.
    line = body.lines[hit_idx]
    if _RE_TOKEN_BOUND.search(line):
        return True
    # Previous-line assignment (multi-line addObserver call).
    if hit_idx > 0:
        prev = body.lines[hit_idx - 1].rstrip()
        # Strip trailing `\` or comment.
        prev_no_comment = _strip_line_comment(prev).rstrip()
        # Check whether the previous line ends in `=` (with optional `.append(` etc.).
        if re.search(
            r"(?:"
            r"(?:let|var)\s+\w+\s*(?::[^=]+)?=\s*$"
            r"|"
            r"(?:self\.)?\w[\w\.\[\]]*\s*=\s*$"
            r"|"
            r"\.\s*(?:append|insert)\s*\(\s*$"
            r")",
            prev_no_comment,
        ):
            return True
    return False


def _is_closure_form_addobserver_at(body: _TypeBody, i: int) -> bool:
    """True iff the addObserver call rooted at body.lines[i] is the
    closure form (the one returning NSObjectProtocol).

    Single-line shape:  `... .addObserver(forName: ...`
    Multi-line shape:   `... .addObserver(` on line i, then `forName:`
                        on one of the next 3 lines (ignoring blanks).
    """
    line = body.lines[i]
    if _RE_ADD_OBSERVER_SAME_LINE.search(line):
        return True
    if _RE_ADD_OBSERVER_OPEN.search(line):
        # Look ahead up to 3 lines for a `forName:` head.
        for j in range(i + 1, min(i + 4, len(body.lines))):
            stripped = body.lines[j].strip()
            if not stripped:
                continue
            if _RE_FORNAME_HEAD.match(body.lines[j]):
                return True
            # If the next non-blank line is something else, stop.
            break
    return False


def _scan_file(file_path: str, source: str) -> list[_Finding]:
    findings: list[_Finding] = []
    lines = source.splitlines()
    bodies = _split_types(file_path, lines)
    for body in bodies:
        # Find observer-registration hits inside this type. A "hit" is
        # the line carrying `.addObserver(` — either same-line `forName:`
        # OR `addObserver(` with `forName:` on a subsequent line.
        observer_hits: list[int] = []
        for i in range(len(body.lines)):
            if _is_closure_form_addobserver_at(body, i):
                observer_hits.append(i)
        if not observer_hits:
            continue
        body_text = body.joined_text()
        # Type-level cleanup evidence: any `removeObserver(` call anywhere
        # in the same type body.
        has_cleanup = bool(_RE_REMOVE_OBSERVER.search(body_text))
        for hi in observer_hits:
            if _annotated_within(body, hi):
                continue
            if _hit_is_token_bound(body, hi):
                continue
            if has_cleanup:
                continue
            abs_line = body.start_line + hi
            findings.append(_Finding(
                code="D5-1",
                severity="medium",
                file_path=file_path,
                line_no=abs_line,
                description=_DESCRIPTION,
            ))
    return findings


# --- Diff mode -------------------------------------------------------------

def _files_from_diff(diff_text: str) -> dict[str, set[int]]:
    """Return {post-image file path → set of touched (added/context)
    line numbers}. Touched lines are used to narrow findings so a PR
    that didn't touch a pre-existing leak doesn't get blocked on it."""
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
    if abs_path.is_file():
        return abs_path.read_text(encoding="utf-8", errors="replace")
    alt = Path(rel_path)
    if alt.is_file():
        return alt.read_text(encoding="utf-8", errors="replace")
    return None


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
    touched = _files_from_diff(diff_text)
    out: list[_Finding] = []
    for rel_path, lines in touched.items():
        if _is_non_prod_swift(rel_path):
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
        prog="check-notification-center-observer-storage.py",
        description=(
            "Scan a unified diff (or a repo) for NotificationCenter "
            "observer registrations that leak by failing to store the "
            "returned token AND lacking a class-level removeObserver "
            "cleanup. Catches the PP-4329 wall-failure class."
        ),
    )
    parser.add_argument("--diff", default=None,
                        help="Unified-diff input file. `-` or omit for stdin.")
    parser.add_argument("--scan", default=None,
                        help="Repo root to walk directly instead of a diff.")
    parser.add_argument("--severity-floor", default="medium",
                        choices=("low", "medium", "high"),
                        help="Block at LVL or above (default: medium).")
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
        msg = (f"\n{len(findings)} observer-storage finding(s); "
               f"{len(blocking)} at/above floor={args.severity_floor}")
        print(msg, file=sys.stderr)

    if args.no_block or args.dry_run:
        return 0
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
