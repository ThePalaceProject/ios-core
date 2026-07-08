#!/usr/bin/env python3
"""
check-swiftui-placeholder-a11y.py — detect SwiftUI placeholder/label sites that
read as disabled UI to VoiceOver + sighted patrons.

Per PP-4421 / HelpSpot 17923: SwiftUI's default `.placeholderText` rendering
(~30% gray) on bare-string TextField / SecureField first-arg labels and on
`Button { } label: { Text("short") }` patterns reads as a disabled control
to sighted users AND VoiceOver hears the placeholder as the accessibility
label. The canonical fix is either:

  - explicit `prompt: Text(label).foregroundColor(.secondary)` on the
    TextField/SecureField (overrides the placeholder rendering); OR
  - explicit `.accessibilityLabel(<localized-string>)` modifier on the
    surrounding view.

Detector trigger predicates:

  D2-1 (medium)   `TextField(<short-literal-or-identifier>, text: ...)` or
                  `SecureField(<short-literal-or-identifier>, ...)` where:
                    - the label position is a string literal `"..."` OR a
                      simple identifier (e.g. `label`, `pinLabel`, `Strings.X.y`)
                      — i.e. it looks like a localized short placeholder, NOT
                      a long sentence (>30 chars literal); AND
                    - no `prompt:` argument is present in the call; AND
                    - no `.accessibilityLabel(` appears within a small window
                      of following lines on the same chained view expression.

  D2-2 (medium)   `Button(...) { ... } label: { Text("short-literal") }` or
                  `Button { ... } label: { Text("short-literal") }` where the
                  label Text is a literal string ≤30 chars AND no
                  `.accessibilityLabel(` appears within a small window of
                  following lines.

Annotation escape: a comment `// no-a11y-label: <reason>` on the line above
the call (or anywhere in the preceding 3-line window) suppresses the finding.

Output (greppable): `<file>:<line>: D2-1: medium: <description>`

Exit codes:
  0  — no findings at or above the severity floor.
  1  — at least one finding at or above the severity floor (default: medium).
  2  — argument / I/O error.

Modes:
  --scan <dir>   Walk `*.swift` files under <dir> (recursive). Default mode.
  --diff <file>  Parse a unified diff; scan only added (`+`) lines.

Flags:
  --severity-floor LVL   Block at LVL or above (low|medium|high). Default medium.
  --no-block             Print findings, always exit 0.
  --quiet                Suppress trailing summary line on stderr.

Lineage:
  - PP-4421 / HelpSpot 17923 (commit e761a6ed3): canonical fix wraps each
    TextField/SecureField call with `prompt: Text(label).foregroundColor(.secondary)`.
  - Wall-failure entry: `.forgeos/wall-failures/2026-06-05-pp4421-swiftui-placeholder-a11y.md`.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from _checklib import SEVERITY_RANK, at_or_above, iter_hunk_lines, read_diff

# Reasonable cap below which a string is "placeholder-ish" (short label) rather
# than user-facing body copy. Above the cap → very likely a main UI string and
# the call site is exempt from the detector (lots of false positives otherwise).
_PLACEHOLDER_LITERAL_MAX = 30

# Window (in lines) we scan downward from a flagged call to look for either
# `.accessibilityLabel(` or a chained `prompt:` modifier that retroactively
# cures the call. Kept small so we don't drift across unrelated views.
_DOWNSTREAM_WINDOW = 8

# Window (in lines) we scan upward for the `// no-a11y-label:` annotation.
_ANNOTATION_WINDOW = 3

# --- Triggers --------------------------------------------------------------

# TextField first-arg shapes — supports two patterns the canonical fix lives
# in. We deliberately do NOT require a `text:` arg label match in the line
# itself because TextField calls often wrap across lines; the SwiftUI-call
# detector matches the head and then inspects the same expression's downstream
# lines.
_TEXTFIELD_HEAD_RE = re.compile(
    r"""^\s*
        (?:return\s+)?
        (?P<kind>TextField|SecureField)
        \s*\(
        \s*
        (?P<label>
            "(?P<literal>[^"\\]*(?:\\.[^"\\]*)*)"  |   # string literal
            (?P<ident>[A-Za-z_][\w\.]*)               # identifier / dotted path
        )
        \s*,
    """,
    re.VERBOSE,
)

# Button label-trailing-closure pattern. Two common forms:
#   Button(action: { ... }, label: { Text("Foo") })       (multiline)
#   Button { ... } label: { Text("Foo") }                  (trailing closure)
# We anchor on the `label: { Text("short")` token so we don't trip on every
# Button. Multi-line bodies need separate matching of the Text("...") line; we
# scan upward to confirm a preceding `Button` head.
_BUTTON_TEXT_LABEL_RE = re.compile(
    r"""label\s*:\s*\{\s*
        Text\(\s*"(?P<literal>[^"\\]*(?:\\.[^"\\]*)*)"\s*\)
    """,
    re.VERBOSE,
)

# Simple Button trailing-closure form with bare `Text("...")` as the only
# content of the trailing closure. Matches:
#     Button(action: ...) { Text("Foo") }
# In Swift these are equivalent in label-position semantics.
_BUTTON_TRAILING_TEXT_RE = re.compile(
    r"""Button\s*(?:\([^)]*\))?\s*\{\s*
        Text\(\s*"(?P<literal>[^"\\]*(?:\\.[^"\\]*)*)"\s*\)
        \s*\}\s*$
    """,
    re.VERBOSE,
)

# Multi-line Button label-closure opener — `..., label: {` followed on a later
# line by a bare `Text("short")`. Used in tandem with _BARE_TEXT_LINE_RE
# scanned over the next _BUTTON_LABEL_BODY_WINDOW lines.
#
# We require the opener line to ALSO contain `Button(` (or `Button ` followed
# by `{`) so we don't flag `NavigationLink { } label: { Text(...) }` or
# `Link(...) { Text(...) }` — those labels are semantically the navigation
# destination name and ARE the right VoiceOver announcement; the PP-4421 bug
# class is specifically the gray-as-disabled placeholder rendering, which
# doesn't apply to NavigationLink / Link / Menu chrome.
_BUTTON_LABEL_OPENER_RE = re.compile(
    r"""(?:^|\s)Button\s*\(.*\blabel\s*:\s*\{\s*$""",
)
_BARE_TEXT_LINE_RE = re.compile(
    r"""^\s*Text\(\s*"(?P<literal>[^"\\]*(?:\\.[^"\\]*)*)"\s*\)\s*$
    """,
    re.VERBOSE,
)
_BUTTON_LABEL_BODY_WINDOW = 3

_ACCESSIBILITY_LABEL_RE = re.compile(r"\.accessibilityLabel\s*\(")
_PROMPT_KW_RE = re.compile(r"\bprompt\s*:")
_NO_A11Y_ANNOTATION_RE = re.compile(
    r"//+\s*no-a11y-label\s*[:\-—]\s*\S",
    re.IGNORECASE,
)

# --- Data classes ----------------------------------------------------------

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


# --- Core predicate --------------------------------------------------------

def _label_is_short(match: re.Match) -> bool:
    """Is the matched first-arg label short (placeholder-ish)?

    String literals: must be ≤ _PLACEHOLDER_LITERAL_MAX chars.
    Identifiers (e.g. `label`, `Strings.SignIn.barcode`): always treated as
    short — they almost always resolve to a localized placeholder, and we
    have no way to inspect the resolved value at lint time. The canonical
    PP-4421 fix used `label` and `pinLabel` identifiers, so the false-negative
    risk of skipping identifiers is worse than the false-positive risk of
    flagging them.
    """
    literal = match.groupdict().get("literal")
    ident = match.groupdict().get("ident")
    if literal is not None:
        return len(literal) <= _PLACEHOLDER_LITERAL_MAX
    if ident is not None:
        return True
    return False


def _downstream_cures(lines: list[str], start_idx: int) -> bool:
    """Is the call site cured by an `.accessibilityLabel(` or `prompt:` within
    the downstream window?

    `prompt:` is the canonical PP-4421 fix on TextField/SecureField — it
    overrides the placeholder rendering. `.accessibilityLabel(` directly
    answers the VoiceOver concern even if the visual placeholder remains.

    We scan up to _DOWNSTREAM_WINDOW lines after `start_idx`, stopping at the
    first closing brace / blank-line block that would terminate the chained
    view expression.
    """
    end = min(len(lines), start_idx + 1 + _DOWNSTREAM_WINDOW)
    for i in range(start_idx, end):
        line = lines[i]
        if _ACCESSIBILITY_LABEL_RE.search(line):
            return True
        if _PROMPT_KW_RE.search(line):
            return True
    return False


def _has_annotation(lines: list[str], call_idx: int) -> bool:
    """Is there a `// no-a11y-label:` annotation in the preceding window?"""
    start = max(0, call_idx - _ANNOTATION_WINDOW)
    for i in range(start, call_idx + 1):
        if _NO_A11Y_ANNOTATION_RE.search(lines[i]):
            return True
    return False


def _scan_lines(file_path: str, lines: list[str]) -> list[_Finding]:
    """Scan a single Swift file's line list and emit findings."""
    findings: list[_Finding] = []
    for idx, line in enumerate(lines):
        # D2-1: TextField / SecureField with bare label.
        m_tf = _TEXTFIELD_HEAD_RE.match(line)
        if m_tf:
            if not _label_is_short(m_tf):
                pass
            elif _downstream_cures(lines, idx):
                pass
            elif _has_annotation(lines, idx):
                pass
            else:
                kind = m_tf.group("kind")
                findings.append(_Finding(
                    code="D2-1",
                    severity="medium",
                    file_path=file_path,
                    line_no=idx + 1,
                    description=(
                        f"SwiftUI {kind} with bare-string label / placeholder "
                        f"and no `.accessibilityLabel(...)` or `prompt:` "
                        f"override; default `.placeholderText` reads as "
                        f"disabled — Wall: PP-4421"
                    ),
                ))
                continue
        # D2-2: Button label-closure with bare Text.
        m_btn = _BUTTON_TEXT_LABEL_RE.search(line)
        if m_btn and len(m_btn.group("literal")) <= _PLACEHOLDER_LITERAL_MAX:
            if not _downstream_cures(lines, idx) and not _has_annotation(lines, idx):
                findings.append(_Finding(
                    code="D2-2",
                    severity="medium",
                    file_path=file_path,
                    line_no=idx + 1,
                    description=(
                        "SwiftUI Button with short-literal Text label and no "
                        "`.accessibilityLabel(...)`; VoiceOver users hear "
                        "placeholder as disabled — Wall: PP-4421"
                    ),
                ))
                continue
        m_btn2 = _BUTTON_TRAILING_TEXT_RE.search(line)
        if m_btn2 and len(m_btn2.group("literal")) <= _PLACEHOLDER_LITERAL_MAX:
            if not _downstream_cures(lines, idx) and not _has_annotation(lines, idx):
                findings.append(_Finding(
                    code="D2-2",
                    severity="medium",
                    file_path=file_path,
                    line_no=idx + 1,
                    description=(
                        "SwiftUI Button with short-literal Text label and no "
                        "`.accessibilityLabel(...)`; VoiceOver users hear "
                        "placeholder as disabled — Wall: PP-4421"
                    ),
                ))
                continue
        # D2-2 multi-line: `..., label: {` head and a bare `Text("short")` on
        # one of the next few lines. Anchor on the opener so we don't trip on
        # every closure that happens to contain a Text.
        if _BUTTON_LABEL_OPENER_RE.search(line):
            body_end = min(len(lines), idx + 1 + _BUTTON_LABEL_BODY_WINDOW)
            for body_idx in range(idx + 1, body_end):
                m_body = _BARE_TEXT_LINE_RE.match(lines[body_idx])
                if not m_body:
                    continue
                if len(m_body.group("literal")) > _PLACEHOLDER_LITERAL_MAX:
                    break
                # Cure / annotation lookup is anchored on the opener line so
                # `.accessibilityLabel` further down the chain still cures.
                if _downstream_cures(lines, idx) or _has_annotation(lines, idx):
                    break
                findings.append(_Finding(
                    code="D2-2",
                    severity="medium",
                    file_path=file_path,
                    line_no=idx + 1,
                    description=(
                        "SwiftUI Button with short-literal Text label and no "
                        "`.accessibilityLabel(...)`; VoiceOver users hear "
                        "placeholder as disabled — Wall: PP-4421"
                    ),
                ))
                break
    return findings


# --- Mode adapters ---------------------------------------------------------

# Paths excluded from scan + diff modes — same set used by check-blast-radius
# so we don't lint fixtures, test code, or harness substrate.
_EXCLUDE_PATH_SUBSTRINGS = (
    "PalaceTests/",
    "Tests/",
    "TestSupport/",
    "Mocks/",
    "Preview Content/",
    ".forgeos/",
    "scripts/_fixtures/",
    "scripts/tests/fixtures/",
    ".build/",
    "DerivedData/",
    "Pods/",
    "Carthage/",
)


def _is_excluded(path: str) -> bool:
    return any(s in path for s in _EXCLUDE_PATH_SUBSTRINGS)


def _scan_directory(root: Path) -> list[_Finding]:
    findings: list[_Finding] = []
    for swift_file in root.rglob("*.swift"):
        rel = str(swift_file)
        if _is_excluded(rel):
            continue
        try:
            text = swift_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        lines = text.splitlines()
        # Report paths relative to root for greppable consistency.
        try:
            rel_path = str(swift_file.relative_to(root))
        except ValueError:
            rel_path = rel
        findings.extend(_scan_lines(rel_path, lines))
    findings.sort(key=lambda f: (f.file_path, f.line_no, f.code))
    return findings


def _scan_diff(diff_text: str) -> list[_Finding]:
    """Scan only added lines from a unified diff.

    Each diff file is reconstructed as a sparse line-array indexed by
    post-image line number, then run through the same _scan_lines predicate.
    Lines we didn't see in the diff are filled with empty strings — the
    downstream-cure heuristic will under-detect cures on those rare cases
    (an `.accessibilityLabel` modifier added later in an existing line will
    not be visible if that line wasn't in the hunk). This is an explicit
    accept: the diff mode exists to surface NEW additions; pre-existing
    cures stay covered by the periodic --scan run.
    """
    findings: list[_Finding] = []
    per_file: dict[str, dict[int, str]] = {}
    for dl in iter_hunk_lines(diff_text):
        if dl.kind == "-":
            continue
        if not dl.file_path.endswith(".swift"):
            continue
        if _is_excluded(dl.file_path):
            continue
        per_file.setdefault(dl.file_path, {})[dl.line_no] = dl.text

    for path, lines_map in per_file.items():
        if not lines_map:
            continue
        max_line = max(lines_map.keys())
        # Reconstruct a sparse 0-indexed list up to max_line.
        lines = [lines_map.get(i + 1, "") for i in range(max_line)]
        file_findings = _scan_lines(path, lines)
        # Only emit findings whose line was actually present in the diff
        # (i.e. an added line). This keeps diff-mode strictly about NEW
        # additions and avoids re-flagging pre-existing violations on
        # context lines we picked up.
        for f in file_findings:
            if f.line_no in lines_map:
                findings.append(f)
    findings.sort(key=lambda f: (f.file_path, f.line_no, f.code))
    return findings


# --- CLI -------------------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-swiftui-placeholder-a11y.py",
        description=(
            "Scan Swift files for SwiftUI TextField/SecureField/Button calls "
            "whose label is a bare short string with no `.accessibilityLabel` "
            "or `prompt:` override — PP-4421 (HelpSpot 17923) bug class."
        ),
    )
    parser.add_argument("--scan", default=None,
                        help="Recursively scan `*.swift` under DIR.")
    parser.add_argument("--diff", default=None,
                        help="Unified-diff input file. `-` or omit for stdin.")
    parser.add_argument("--severity-floor", default="medium",
                        choices=("low", "medium", "high"),
                        help="Block at LVL or above (default: medium).")
    parser.add_argument("--no-block", action="store_true",
                        help="Print findings, always exit 0.")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress summary line on stderr.")
    args = parser.parse_args(argv)

    if args.scan and args.diff:
        print("ERROR: --scan and --diff are mutually exclusive.", file=sys.stderr)
        return 2

    if args.scan:
        root = Path(args.scan)
        if not root.is_dir():
            print(f"ERROR: --scan target not a directory: {args.scan}",
                  file=sys.stderr)
            return 2
        findings = _scan_directory(root)
    else:
        diff_text = read_diff(args.diff)
        findings = _scan_diff(diff_text)

    blocking: list[_Finding] = []
    for f in findings:
        if at_or_above(f.severity, args.severity_floor):
            blocking.append(f)
        print(f.render())

    if not args.quiet:
        msg = (f"\n{len(findings)} SwiftUI placeholder-a11y finding(s); "
               f"{len(blocking)} at/above floor={args.severity_floor}")
        print(msg, file=sys.stderr)

    if args.no_block:
        return 0
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
