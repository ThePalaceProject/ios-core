#!/usr/bin/env python3
"""
check-snakecase-codingkeys.py — detect `CodingKey` cases whose raw value is
snake_case in a file whose JSONDecoder uses `.convertFromSnakeCase`.

Catches the class surfaced by PR #1462 review r4073991333 (PP-5202):

    jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    ...
    private enum CodingKeys: String, CodingKey {
        case showTitle = "show_title"      // <-- matches NOTHING, ever
    }

`.convertFromSnakeCase` rewrites the INCOMING key `show_title` to `showTitle`
BEFORE it is matched against `CodingKeys`. A case whose raw value is the
snake_case spelling therefore never matches: the member decodes as absent even
for a perfectly well-formed body.

The failure is SILENT — no throw, no crash, no log — and it survives any test
that only asserts "the document decoded". That invisibility is why this needs a
detector rather than review: the instinctive fix for a *different* bug (a
declared member whose type mismatch kills the whole document) is exactly this
spelling, and it looks like it works.

Predicate (SCK-1):

  Within a single Swift file under `Palace/` that contains the literal
  `.convertFromSnakeCase`, ALL of the following hold:

    1. An enum is declared that is either named `CodingKeys` or declares
       conformance to `CodingKey`. Nested types in the same file ARE inspected
       — they inherit the decoder's key strategy.

    2. That enum has a `case` with an explicit string raw value containing `_`.

    3. No `// no-snakecase-codingkeys: <reason>` annotation appears on the case
       line or the 3 preceding lines.

Deliberately NOT matched (all three exist in the tree today and must stay clean):

  - Enums that are not `CodingKey`s, even in a `.convertFromSnakeCase` file.
    `OPDS2LinkRel` (OPDS2AuthenticationDocument.swift) is a link-relation enum
    living beside such a decoder; its raw values are wire constants, not keys.
  - Snake_case *string constants*, e.g.
    `static let DetailLoanTermLimitReached = "loan_term_limit_reached"`
    (TPPProblemDocument.swift). Not an enum case.
  - Snake_case enums in files with no `.convertFromSnakeCase` decoder at all —
    FirebaseManager, AppLaunchTracker, PerformanceMetric. Their raw values are
    remote-config / metric names and are correct as written.

KNOWN LIMITATION — read before trusting this globally:

  The strategy-to-type correlation is established SAME-FILE. All three
  production types that use `.convertFromSnakeCase` today (TPPProblemDocument,
  TokenResponse, OPDS2AuthenticationDocument) configure the decoder in the same
  file as the type, which is the assumption this rule encodes. A type decoded by
  a `.convertFromSnakeCase` decoder configured in a DIFFERENT file is NOT
  detected. If that pattern ever appears, this rule must grow a cross-file pass.

Whole-tree by default, not diff-scoped — matching check-doc-references-resolve's
rationale: the hazard appears when a DECODER elsewhere in the file gains the
strategy, and that commit may touch no `CodingKeys` at all.

Output (greppable):

    <file>:<line>: SCK-1: high: CodingKey raw value "<raw>" is snake_case in a
        file using .convertFromSnakeCase — the case can never match — Wall: PP-5202

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

_STRATEGY = ".convertFromSnakeCase"
_ANNOTATION = "no-snakecase-codingkeys:"
_SEVERITIES = ("low", "medium", "high")

# `enum Foo: String, CodingKey {` / `private enum CodingKeys: String, CodingKey {`
_ENUM_DECL = re.compile(r"\benum\s+(\w+)\s*(?::\s*([^{]*))?\{")
# `case showTitle = "show_title"` — only cases with an explicit string raw value.
_CASE_RAW = re.compile(r'\bcase\s+(\w+)\s*=\s*"([^"]*)"')


@dataclass(frozen=True)
class _Finding:
    file_path: str
    line_no: int
    code: str
    severity: str
    message: str

    def render(self) -> str:
        return (f"{self.file_path}:{self.line_no}: {self.code}: {self.severity}: "
                f"{self.message} — Wall: PP-5202")


def _is_coding_key_enum(name: str, conformances: str | None) -> bool:
    """True for `CodingKeys`-named enums and anything conforming to CodingKey."""
    if name == "CodingKeys":
        return True
    if conformances and re.search(r"\bCodingKey\b", conformances):
        return True
    return False


def _annotated(lines: list[str], idx: int) -> bool:
    """Escape hatch on the case line or the 3 lines above it."""
    for probe in range(max(0, idx - 3), idx + 1):
        if _ANNOTATION in lines[probe]:
            return True
    return False


def _scan_file(rel_path: str, source: str) -> list[_Finding]:
    if _STRATEGY not in source:
        return []

    lines = source.splitlines()
    findings: list[_Finding] = []

    # Track brace depth so we know exactly where a CodingKey enum's body ends.
    #
    # `enum_depth` is the depth INSIDE the body — i.e. one deeper than the line
    # that declares the enum. Getting this off by one makes the scan window run
    # to the end of the ENCLOSING type instead of the enum, which flags every
    # snake_case enum case that merely FOLLOWS a CodingKeys block in the same
    # file. That is the `OPDS2LinkRel` shape the rule promises to exclude
    # structurally, so the off-by-one silently converts the exclusion into luck.
    # Caught in blast-radius review; pinned by
    # `clean_wire_enum_after_codingkeys.swift`.
    in_key_enum = False
    enum_depth = 0
    depth = 0

    for idx, line in enumerate(lines):
        stripped = line.split("//", 1)[0]
        opens = stripped.count("{")
        closes = stripped.count("}")

        if not in_key_enum:
            m = _ENUM_DECL.search(stripped)
            if m and _is_coding_key_enum(m.group(1), m.group(2)):
                in_key_enum = True
                enum_depth = depth + 1

        # Cases are checked on the declaration line too, so a single-line enum
        # body (`enum CodingKeys: String, CodingKey { case a = "a_b" }`) is
        # still inspected before the exit test below closes it out.
        if in_key_enum:
            for case_m in _CASE_RAW.finditer(stripped):
                raw = case_m.group(2)
                if "_" not in raw:
                    continue
                if _annotated(lines, idx):
                    continue
                findings.append(_Finding(
                    file_path=rel_path,
                    line_no=idx + 1,
                    code="SCK-1",
                    severity="high",
                    message=(f'CodingKey raw value "{raw}" is snake_case in a file using '
                             f"{_STRATEGY} — the strategy rewrites the incoming key before "
                             f"matching, so case `{case_m.group(1)}` can never match"),
                ))

        depth += opens - closes

        if in_key_enum and depth < enum_depth:
            in_key_enum = False

    return findings


def _scan_repo(repo_root: Path, subdir: str = "Palace") -> list[_Finding]:
    out: list[_Finding] = []
    base = repo_root / subdir
    if not base.exists():
        base = repo_root
    for root, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if d not in {".build", "DerivedData", ".git"}]
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            full = Path(root) / name
            try:
                rel = str(full.relative_to(repo_root))
            except ValueError:
                rel = str(full)
            try:
                source = full.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            out.extend(_scan_file(rel, source))
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-snakecase-codingkeys.py",
        description=("Detect CodingKey cases with snake_case raw values in files whose "
                     "JSONDecoder uses .convertFromSnakeCase (they can never match)."),
    )
    parser.add_argument("--scan", default=None,
                        help="Repo root to walk (default: current directory).")
    parser.add_argument("--severity-floor", default="high", choices=_SEVERITIES,
                        help="Block at LVL or above (default: high).")
    parser.add_argument("--no-block", action="store_true",
                        help="Print findings, always exit 0.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print findings; do not exit non-zero.")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress the summary line on stderr.")
    # Accepted and ignored: the pre-commit harness passes --diff to every
    # detector uniformly. This rule is deliberately whole-tree (a decoder
    # gaining the strategy is the hazard, and that commit may touch no
    # CodingKeys), so a --diff invocation scans the tree rather than erroring.
    # Rejecting it here would make the hook fail on a CLEAN diff — the exact
    # wiring bug CLAUDE.md rule #4 warns about.
    parser.add_argument("--diff", default=None, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    try:
        root = Path(args.scan).resolve() if args.scan else Path.cwd()
        findings = _scan_repo(root)
    except Exception as exc:  # pragma: no cover - safety net
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    floor = _SEVERITIES.index(args.severity_floor)
    blocking = [f for f in findings if _SEVERITIES.index(f.severity) >= floor]

    for f in sorted(findings, key=lambda x: (x.file_path, x.line_no)):
        print(f.render())

    if not args.quiet:
        print(f"\n{len(findings)} snakecase-codingkeys finding(s); "
              f"{len(blocking)} at/above floor={args.severity_floor}", file=sys.stderr)

    if args.no_block or args.dry_run:
        return 0
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
