#!/usr/bin/env python3
"""
check-adjacency-staleness.py — find stale comment references after renames.

For every removed declaration in the diff (`class`, `struct`, `enum`,
`protocol`, `func`, `typealias` definitions), grep the SURVIVING codebase
for comment-only references to the removed name. Renames frequently leave
in-line doc references unstale; wave 4's
`SignInModalHostingController` → `SignInModalDismissalHosting` rename
left 4 doc-comment refs in `SignInModalSheetPresenter.swift`.

This is warn-only — always exits 0. Renames vs deletions are not
mechanically distinguishable from the diff alone, so a strict gate
would false-positive on legitimate deletes.

Output (greppable):
  ADJ-STALE: <file>:<line>: comment references removed/renamed `<name>`

Usage:
  python3 scripts/check-adjacency-staleness.py [--diff <file>] [--root <path>]
    [--quiet]

Flags:
  --diff <file>     Unified-diff input. Defaults to stdin.
  --root <path>     Codebase root to grep for surviving comments.
                    Defaults to the parent of `scripts/`.
  --quiet           Suppress summary line.

Skips:
  Carthage/  Pods/  ios-audiobooktoolkit/  .forgeos/wall-failures/
  .forgeos/swarms/  scripts/_fixtures/
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from _checklib import read_diff

# --- Patterns --------------------------------------------------------------

_REMOVED_DECL_RE = re.compile(
    r"^-\s*(?:@\w+\s+)*"
    r"(?:public|open|internal|fileprivate|private)?\s*"
    r"(?:final\s+|static\s+|indirect\s+)?"
    r"(class|struct|enum|protocol|func|typealias|actor)"
    r"\s+(\w+)\b"
)
_FILE_HDR_RE = re.compile(r"^\+\+\+ b/(.+)$")
_COMMENT_LINE_RE = re.compile(r"^\s*(?://|/\*|\*\s|///).*$")

_SKIP_DIR_SUBSTRINGS = (
    "/Carthage/",
    "/Pods/",
    "/ios-audiobooktoolkit/",
    "/.forgeos/wall-failures/",
    "/.forgeos/swarms/",
    "/scripts/_fixtures/",
    "/build/",
    "/.build/",
    "/DerivedData/",
    "/.git/",
    "/node_modules/",
)


@dataclass
class _Finding:
    name: str
    file_path: str
    line_no: int

    def render(self) -> str:
        return (f"ADJ-STALE: {self.file_path}:{self.line_no}: "
                f"comment references removed/renamed `{self.name}`")


def _removed_names_from_diff(diff_text: str) -> set[str]:
    """Extract names of declarations removed in the diff."""
    names: set[str] = set()
    in_file_lines: list[str] = []
    for raw in diff_text.splitlines():
        if _FILE_HDR_RE.match(raw):
            in_file_lines.append(raw)
            continue
        if raw.startswith("---") or raw.startswith("+++"):
            continue
        m = _REMOVED_DECL_RE.match(raw)
        if m:
            names.add(m.group(2))
    return names


def _added_names_from_diff(diff_text: str) -> set[str]:
    """Extract names of declarations ADDED in the diff (= true renames)."""
    added: set[str] = set()
    added_re = re.compile(
        r"^\+\s*(?:@\w+\s+)*"
        r"(?:public|open|internal|fileprivate|private)?\s*"
        r"(?:final\s+|static\s+|indirect\s+)?"
        r"(class|struct|enum|protocol|func|typealias|actor)"
        r"\s+(\w+)\b"
    )
    for raw in diff_text.splitlines():
        if raw.startswith("+++") or raw.startswith("---"):
            continue
        m = added_re.match(raw)
        if m:
            added.add(m.group(2))
    return added


def _should_skip_path(rel_path: str) -> bool:
    rel = "/" + rel_path.lstrip("/")
    return any(s in rel for s in _SKIP_DIR_SUBSTRINGS)


def _iter_codebase_files(root: Path) -> list[Path]:
    """Find all Swift/Markdown/comment-bearing files under root (project-tracked)."""
    exts = (".swift", ".m", ".h", ".mm", ".md", ".markdown", ".py")
    out: list[Path] = []
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        if p.suffix.lower() not in exts:
            continue
        rel = str(p.relative_to(root))
        if _should_skip_path(rel):
            continue
        out.append(p)
    return out


def _scan_file_for_comment_ref(path: Path, names: set[str]) -> list[_Finding]:
    """Grep comment lines of `path` for any of the removed names."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    findings: list[_Finding] = []
    word_res = {n: re.compile(r"\b" + re.escape(n) + r"\b") for n in names}
    for line_no, line in enumerate(text.splitlines(), start=1):
        if not _COMMENT_LINE_RE.match(line):
            continue
        for name, name_re in word_res.items():
            if name_re.search(line):
                findings.append(_Finding(
                    name=name,
                    file_path=str(path),
                    line_no=line_no,
                ))
    return findings


# --- CLI -------------------------------------------------------------------

_read_diff = read_diff  # shared with scripts/_checklib.py


def _default_root() -> Path:
    return Path(__file__).resolve().parent.parent


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-adjacency-staleness.py",
        description=(
            "Warn-only check: for every removed declaration in the diff, "
            "grep surviving codebase COMMENTS for stale references."
        ),
    )
    parser.add_argument("--diff", default=None,
                        help="Unified-diff input file. `-` or omit for stdin.")
    parser.add_argument("--root", default=None,
                        help="Codebase root. Defaults to repo root.")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress summary line on stderr.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Parse only; do not scan codebase.")
    args = parser.parse_args(argv)

    diff_text = _read_diff(args.diff)
    removed = _removed_names_from_diff(diff_text)
    added = _added_names_from_diff(diff_text)
    # Only flag when a name was removed AND not re-added (else it's an edit,
    # not a rename — same name, same purpose).
    candidates = removed - added

    if not candidates:
        if not args.quiet:
            print("OK: no removed declarations to check.", file=sys.stderr)
        return 0

    if args.dry_run:
        if not args.quiet:
            print(f"DRY-RUN: would check {len(candidates)} removed name(s): "
                  f"{', '.join(sorted(candidates))}", file=sys.stderr)
        return 0

    root = Path(args.root) if args.root else _default_root()
    if not root.is_dir():
        print(f"ERROR: root is not a directory: {root}", file=sys.stderr)
        return 2

    files = _iter_codebase_files(root)
    all_findings: list[_Finding] = []
    for path in files:
        all_findings.extend(_scan_file_for_comment_ref(path, candidates))

    all_findings.sort(key=lambda f: (f.file_path, f.line_no, f.name))
    for f in all_findings:
        print(f.render())

    if not args.quiet:
        msg = (f"\n{len(all_findings)} adjacency-staleness warning(s) "
               f"across {len(candidates)} removed/renamed name(s).")
        print(msg, file=sys.stderr)

    # Warn-only — always exit 0.
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
