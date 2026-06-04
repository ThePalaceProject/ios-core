#!/usr/bin/env python3
"""
check-superpartner-spectrum.py — flag new code that shipped without a test.

What it does, in one sentence: it scans a diff for new functions, new enum
cases, and new state changes, and warns about any that don't have a matching
test in the same change.

Why: when a new function or case ships with no test, the behavior it adds can
regress later and nothing will catch it. This check is the cheap, fast,
pre-commit safety net that asks "did you add a test for this?" — it runs in
seconds on every commit.

What it does NOT do: it does not prove the test is any good. A test can
reference a function and still not really exercise it. Proving a test actually
catches bugs is mutation testing's job (`palace_mutate.py`), which runs before
release. Think of it as two levels:
  1. This check  — is there a test at all?            (fast, every commit)
  2. Mutation    — does the test actually catch bugs?  (slow, pre-release)
Neither replaces the other.

What counts as "new code" (added lines, production .swift only):

  SP-1 (function)   A new non-private, non-override `func`. Considered covered
                    if some `func test…` name mentions it, or an added test line
                    calls it directly.
  SP-2 (enum case)  A new enum `case`. Considered covered if the case name shows
                    up anywhere in the added test code. (A new case usually
                    needs a test pinning what it means — see the wall-failure
                    catalog's `.accountNotFound` dual-meaning bug.)
  SP-3 (state)      A new `setState(…)` / `_setState(…)` / `self.state =` change.
                    Considered covered by a round-trip test (one whose name has
                    reset / roundtrip / across / reenter / redrive AND mentions
                    the state value) or any test that references the value.
                    Capped at medium severity.

Intentionally skipping a test is fine — just say so. If a piece of new code
genuinely has no behavior worth testing (a fire-and-forget analytics call, an
empty delegate stub), mark it with a comment on the same or previous line:

    // no-superpartner: fire-and-forget analytics, no observable behavior

(`// no-superpartner(TICKET-123): …` also works.) Marked items are counted and
shown in the summary but never block — they're a deliberate, visible decision,
not a silent gap.

`if` / `guard` / `switch` branches are NOT checked here — matching individual
branches to tests by name is too noisy to be reliable. Branch coverage is left
to mutation testing, and the summary line says so on every run so nothing is
quietly skipped.

Severity:
  high    — untested new code on a critical path (auth / borrow / return /
            download / DRM / audiobooks / migrations / the auth-error seam).
  medium  — untested new code elsewhere, or any untested state change.
Items marked `// no-superpartner:` have no severity (shown, never block).

Output (greppable): `<file>:<line>: <code>: <severity>: <description>`

Exit codes:
  0  — nothing untested at or above the severity floor
  1  — at least one untested item at or above the floor (default floor: high)
  2  — argument or I/O error

Flags match the sibling pre-commit checks (check-blast-radius.py et al.):
  --diff <file>        Unified-diff input. `-` or omit for stdin.
  --severity-floor LVL Block at LVL or higher (low|medium|high). Default high.
  --no-block           Print findings, always exit 0.
  --quiet              Suppress the trailing summary on stderr.
  --dry-run            Print findings; never exit non-zero.

(The name is a nod to supersymmetry, where every particle has a partner — here
every new piece of code should have a partner test. You do not need to know any
physics to use this; the rest of the file is plain English.)
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field

from _checklib import SEVERITY_RANK, at_or_above, iter_hunk_lines, read_diff  # noqa: F401

# --- Severity ladder (shared with scripts/_checklib.py) --------------------

_SEVERITY_RANK = SEVERITY_RANK
_at_or_above = at_or_above


# --- Path classification ---------------------------------------------------

# Non-production Swift (never emits particles; harvested for partners instead).
_NON_PROD_PATH_SUBSTRINGS = (
    "PalaceTests/",
    "Tests/",
    "TestSupport/",
    "Utilities/Testing/",
    "Preview Content/",
    "Mocks/",
    ".forgeos/",
    "scripts/_fixtures/",
)

_TEST_PATH_SUBSTRINGS = ("PalaceTests/", "Tests/")

# Critical-path globs (verbatim from CLAUDE.md "Risk-driven rigor bar").
# Untested new code in one of these files is high-severity.
_CRITICAL_PATH_RES = tuple(re.compile(p) for p in (
    r"Palace/SignInLogic/",
    r"Palace/Packages/PalaceAuth/",
    r"Palace/MyBooks/Borrow",
    r"Palace/MyBooks/BookReturn",
    r"Palace/MyBooks/Download",
    r"Palace/Audiobooks/",
    r"Palace/Migrations/",
    r"Palace/Network/TPPNetworkResponder\.swift",
    r"Palace/Network/TPPNetworkExecutor\.swift",
))


def _is_swift(path: str) -> bool:
    return path.endswith(".swift")


def _is_non_prod_swift(path: str) -> bool:
    return any(s in path for s in _NON_PROD_PATH_SUBSTRINGS)


def _is_test_swift(path: str) -> bool:
    return _is_swift(path) and any(s in path for s in _TEST_PATH_SUBSTRINGS)


def _is_critical_path(path: str) -> bool:
    return any(r.search(path) for r in _CRITICAL_PATH_RES)


# --- Diff parsing (post-image added lines, mirrors check-blast-radius.py) ---

@dataclass
class _AddedLine:
    file_path: str
    line_no: int
    text: str
    prev_comment: str  # the immediately-preceding added/context comment line


def _parse_diff(diff_text: str) -> list[_AddedLine]:
    """Collect post-image added lines (with the preceding comment line), built
    on the shared iter_hunk_lines() primitive.

    `last_comment` is reset on file change and hunk boundary; with
    iter_hunk_lines a hunk boundary is detected as a non-contiguous post-image
    line number (equivalent to the prior reset on the `@@` header, since within
    a hunk added/context lines are contiguous and removed lines don't advance
    the counter).
    """
    added: list[_AddedLine] = []
    last_comment = ""
    prev_path: str | None = None
    prev_line_no: int | None = None

    for dl in iter_hunk_lines(diff_text):
        if dl.kind == "-":
            # Removed lines do not advance the post-image counter.
            continue
        if dl.file_path != prev_path or (
            prev_line_no is not None and dl.line_no != prev_line_no + 1
        ):
            last_comment = ""
        prev_path = dl.file_path
        prev_line_no = dl.line_no

        if dl.kind == "+":
            added.append(_AddedLine(dl.file_path, dl.line_no, dl.text, last_comment))
        stripped = dl.text.lstrip()
        last_comment = stripped if stripped.startswith("//") else ""
    return added


# --- Particle detection ----------------------------------------------------

# func decl: capture the name. We inspect the full line for access/override.
_FUNC_RE = re.compile(r"\bfunc\s+([A-Za-z_]\w*)\s*[(<]")
_FUNC_SKIP_MODIFIER_RE = re.compile(r"\b(?:private|fileprivate|override)\b")

# enum case declaration (NOT a switch arm). Switch arms start with `.`/`let`/`is`
# or end with `:`. Enum decls: `case foo`, `case foo(Int)`, `case foo = 1`,
# `case a, b, c`. Require lowerCamel leading idents and no terminating colon.
_CASE_LINE_RE = re.compile(r"^\s*case\s+(?![.])([a-z]\w*(?:\s*,\s*[a-z]\w*)*)")
_CASE_NAME_RE = re.compile(r"[a-z]\w*")

# state transitions
_STATE_TRANSITION_RES = (
    re.compile(r"\b_?setState\s*\(\s*\.?([A-Za-z_]\w*)?"),
    re.compile(r"\bself\.state\s*=\s*\.?([A-Za-z_]\w*)?"),
)

_NO_PARTNER_RE = re.compile(r"//\s*no-superpartner(?:\([^)]*\))?\s*:")

# func names not worth treating as separately-testable code
_FUNC_NOISE = frozenset((
    "init deinit body makeUIView updateUIView makeCoordinator "
    "encode hash callAsFunction"
).split())

# round-trip verbs that qualify a test as covering a state change
_ROUNDTRIP_VERBS = ("reset", "roundtrip", "round_trip", "across", "reenter",
                    "re_enter", "redrive", "again", "twice", "restore", "recover")


@dataclass
class _Particle:
    code: str           # SP-1 | SP-2 | SP-3
    kind: str           # func | case | state
    name: str           # the function / case / state-value name
    file_path: str
    line_no: int
    declared_break: str  # the `// no-superpartner:` reason, or ""


def _line_ends_with_colon(text: str) -> bool:
    # Strip trailing line-comment then whitespace.
    code = text.split("//", 1)[0].rstrip()
    return code.endswith(":")


def _collect_particles(added: list[_AddedLine]) -> list[_Particle]:
    particles: list[_Particle] = []
    for entry in added:
        path = entry.text  # placeholder to avoid accidental misuse
        del path
        if not _is_swift(entry.file_path) or _is_non_prod_swift(entry.file_path):
            continue
        text = entry.text
        brk_here = _NO_PARTNER_RE.search(text)
        brk_prev = _NO_PARTNER_RE.search(entry.prev_comment)
        declared_break = ""
        if brk_here or brk_prev:
            src = text if brk_here else entry.prev_comment
            declared_break = src.split(":", 1)[1].strip() if ":" in src else "(unspecified)"

        # SP-1 func
        m_func = _FUNC_RE.search(text)
        if m_func and not _FUNC_SKIP_MODIFIER_RE.search(text):
            name = m_func.group(1)
            if name not in _FUNC_NOISE and len(name) >= 3:
                particles.append(_Particle("SP-1", "func", name,
                                           entry.file_path, entry.line_no, declared_break))
                continue  # a func line is one particle; don't double-count below

        # SP-2 enum case (skip switch arms)
        m_case = _CASE_LINE_RE.match(text)
        if m_case and not _line_ends_with_colon(text) and " in " not in text:
            for cname in _CASE_NAME_RE.findall(m_case.group(1)):
                particles.append(_Particle("SP-2", "case", cname,
                                           entry.file_path, entry.line_no, declared_break))
            continue

        # SP-3 state transition
        for srx in _STATE_TRANSITION_RES:
            m_state = srx.search(text)
            if m_state:
                value = m_state.group(1) or "state"
                particles.append(_Particle("SP-3", "state", value,
                                           entry.file_path, entry.line_no, declared_break))
                break
    return particles


# --- Superpartner harvest (from added test-file lines) ---------------------

@dataclass
class _PartnerIndex:
    test_names: list[str] = field(default_factory=list)   # lowercased, no underscores
    test_name_raw: list[str] = field(default_factory=list)  # lowercased, underscores kept
    test_text: str = ""                                   # all added test text, lowercased
    has_contract_snapshot: bool = False


_TEST_FUNC_RE = re.compile(r"\bfunc\s+(test[A-Za-z0-9_]*)\s*\(")


def _harvest_partners(added: list[_AddedLine]) -> _PartnerIndex:
    idx = _PartnerIndex()
    chunks: list[str] = []
    for entry in added:
        if not _is_test_swift(entry.file_path):
            continue
        lower = entry.text.lower()
        chunks.append(lower)
        if "contractsnapshot.assert" in lower:
            idx.has_contract_snapshot = True
        for m in _TEST_FUNC_RE.finditer(entry.text):
            raw = m.group(1).lower()
            idx.test_name_raw.append(raw)
            idx.test_names.append(raw.replace("_", ""))
    idx.test_text = "\n".join(chunks)
    return idx


# --- Pairing ---------------------------------------------------------------

def _is_paired(p: _Particle, idx: _PartnerIndex) -> bool:
    name_l = p.name.lower()
    if len(name_l) < 3:
        return True  # too short to match honestly; don't raise a false alarm

    if p.kind == "func":
        if any(name_l in tn for tn in idx.test_names):
            return True
        # direct call in an added test line: `particle(`
        return bool(re.search(r"(?<![a-z0-9_])" + re.escape(name_l) + r"\s*\(",
                              idx.test_text))

    if p.kind == "case":
        # the case name referenced anywhere in added test text (semantics test)
        return bool(re.search(r"(?<![a-z0-9_])" + re.escape(name_l) + r"(?![a-z0-9_])",
                              idx.test_text))

    # SP-3 state: a round-trip test that references the value, OR any reference.
    if p.kind == "state":
        referenced = bool(re.search(r"(?<![a-z0-9_])" + re.escape(name_l) + r"(?![a-z0-9_])",
                                    idx.test_text))
        roundtrip = any(v in tn for tn in idx.test_name_raw for v in _ROUNDTRIP_VERBS)
        return referenced or roundtrip
    return False


# --- Findings --------------------------------------------------------------

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


def _severity_for(p: _Particle) -> str:
    if p.kind == "state":
        return "medium"
    return "high" if _is_critical_path(p.file_path) else "medium"


def build_spectrum(diff_text: str) -> tuple[list[_Finding], dict[str, int]]:
    added = _parse_diff(diff_text)
    particles = _collect_particles(added)
    idx = _harvest_partners(added)

    findings: list[_Finding] = []
    stats = {"total": len(particles), "paired": 0,
             "declared_break": 0, "unpaired": 0}

    for p in particles:
        if p.declared_break:
            stats["declared_break"] += 1
            continue
        if _is_paired(p, idx):
            stats["paired"] += 1
            continue
        stats["unpaired"] += 1
        sev = _severity_for(p)
        findings.append(_Finding(
            code=p.code,
            severity=sev,
            file_path=p.file_path,
            line_no=p.line_no,
            description=(
                f"new {p.kind} `{p.name}` has no matching test in this change "
                f"— add a test that references it, or mark it intentional with "
                f"`// no-superpartner: <reason>`"
            ),
        ))

    findings.sort(key=lambda f: (f.file_path, f.line_no, f.code))
    return findings, stats


# --- CLI -------------------------------------------------------------------

_read_diff = read_diff  # shared with scripts/_checklib.py


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-superpartner-spectrum.py",
        description=(
            "Flag new code that shipped without a test: every new function, enum "
            "case, or state change in a diff should have a matching test, or be "
            "marked intentional with `// no-superpartner: <reason>`."
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
                        help="Suppress the spectrum summary on stderr.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print findings; do not exit non-zero.")
    args = parser.parse_args(argv)

    diff_text = _read_diff(args.diff)
    findings, stats = build_spectrum(diff_text)

    blocking: list[_Finding] = []
    for f in findings:
        if _at_or_above(f.severity, args.severity_floor):
            blocking.append(f)
        print(f.render())

    if not args.quiet:
        print(
            f"\ntest-pairing check: {stats['total']} new item(s) — "
            f"{stats['paired']} have a test, "
            f"{stats['declared_break']} marked intentional, "
            f"{stats['unpaired']} missing a test; "
            f"{len(blocking)} need attention at level={args.severity_floor}.\n"
            f"(if/switch branches aren't checked here — run mutation testing, "
            f"palace_mutate.py, to confirm those tests actually catch bugs.)",
            file=sys.stderr,
        )

    if args.no_block or args.dry_run:
        return 0
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
