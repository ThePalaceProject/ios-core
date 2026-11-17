#!/usr/bin/env python3
"""Git merge driver for Palace.xcodeproj/project.pbxproj.

prior-art-checked: `harness capabilities` has no pbxproj, merge-driver or
conflict entry, and scripts/ has pbxproj_add_swift.rb, pbxproj_remove_swift.rb
and pbxproj_add_registry_freshness_phase.rb, none of which merge. This driver
calls the first of those on refusal rather than reimplementing it.

A pbxproj is a keyed dictionary, so `merge=union` is unsafe: it emits both
sides of every conflict, and two values for one key leave Xcode silently
keeping the last. The 3.3.0 reconciliation carried CURRENT_PROJECT_VERSION
510 and 500 that way. `.gitattributes` holds that measurement.

Target-membership conflicts are a different shape. When two branches each add
source files, both sides are new UUID-keyed entries at the same insertion
point, and keeping both is the only correct answer. That is the resolution
`.gitattributes` already prescribes by hand; doing it by hand is how a branch
lost AdobeConnectorBuild.h/.mm and failed its bridging-header scan before any
test ran (#1642).

So a conflicted hunk is unioned only when every line on both sides is a
membership entry, and the whole merge is refused otherwise, leaving the
markers for a human. A settings conflict never resolves itself.

    pbxproj_merge_driver.py --ours A --theirs B --base O
Exit 0 means resolved; 1 means a human must resolve it.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

# A pbxproj UUID is 24 uppercase hex characters.
UUID = r"[0-9A-F]{24}"

# The four membership shapes. Each is keyed by a fresh UUID, so two branches
# adding different files never collide on a key.
MEMBERSHIP_PATTERNS = (
    # ABC... /* Foo.swift in Sources */ = {isa = PBXBuildFile; fileRef = ...};
    re.compile(rf"^\s*{UUID} /\* .+ \*/ = \{{isa = PBXBuildFile;.*\}};\s*$"),
    # ABC... /* Foo.swift */ = {isa = PBXFileReference; ...};
    re.compile(rf"^\s*{UUID} /\* .+ \*/ = \{{isa = PBXFileReference;.*\}};\s*$"),
    # ABC... /* Foo.swift in Sources */,   -- a build-phase entry
    re.compile(rf"^\s*{UUID} /\* .+ in \w+ \*/,\s*$"),
    # ABC... /* Foo.swift */,              -- a group children entry
    re.compile(rf"^\s*{UUID} /\* .+ \*/,\s*$"),
)

# `/* Foo.swift in Sources */` and `/* Foo.swift */` both yield Foo.swift
NAME_IN_COMMENT = re.compile(r"/\* (?P<name>[^*]+?)(?: in \w+)? \*/")


class Refusal(Exception):
    """The merge is not one this driver may resolve."""


def is_membership_line(line: str) -> bool:
    """Whether a line is a UUID-keyed membership entry.

    Blank lines ride along inside a hunk and carry no key, so they pass;
    anything else makes the hunk a human's problem.
    """
    if not line.strip():
        return True
    return any(p.match(line) for p in MEMBERSHIP_PATTERNS)


def entry_name(line: str) -> str | None:
    """The file name a membership line names, for duplicate detection."""
    match = NAME_IN_COMMENT.search(line)
    return match.group("name").strip() if match else None


def split_hunks(lines: list[str]) -> list[tuple[int, int, list[str], list[str]]]:
    """Every conflict region as (start, end_exclusive, ours, theirs).

    Raises on a nested or unterminated marker rather than guessing: a
    malformed conflict is not something to resolve optimistically.
    """
    hunks: list[tuple[int, int, list[str], list[str]]] = []
    i = 0
    while i < len(lines):
        if not lines[i].startswith("<<<<<<<"):
            i += 1
            continue
        start = i
        ours: list[str] = []
        i += 1
        while i < len(lines) and not lines[i].startswith("======="):
            if lines[i].startswith(("<<<<<<<", ">>>>>>>")):
                raise Refusal(f"nested conflict marker at line {i + 1}")
            ours.append(lines[i])
            i += 1
        if i >= len(lines):
            raise Refusal(f"unterminated conflict at line {start + 1}")
        theirs: list[str] = []
        i += 1
        while i < len(lines) and not lines[i].startswith(">>>>>>>"):
            if lines[i].startswith(("<<<<<<<", "=======")):
                raise Refusal(f"nested conflict marker at line {i + 1}")
            theirs.append(lines[i])
            i += 1
        if i >= len(lines):
            raise Refusal(f"unterminated conflict at line {start + 1}")
        hunks.append((start, i + 1, ours, theirs))
        i += 1
    return hunks


def resolve_hunk(ours: list[str], theirs: list[str]) -> list[str]:
    """Union one membership hunk, or refuse.

    Refuses when the same file name appears on both sides under different
    UUIDs: unioning that compiles the file twice, which no later check
    catches. Two branches adding the same file is a real ambiguity.
    """
    for line in (*ours, *theirs):
        if not is_membership_line(line):
            raise Refusal(f"not a membership entry: {line.strip()[:120]}")

    # Dedup identical entries first. Both sides carrying the same line is the
    # same key, not a conflict, so collapsing it is safe; only a name that
    # SURVIVES dedup on both sides means two keys for one file.
    merged: list[str] = []
    seen: set[str] = set()
    for line in (*ours, *theirs):
        if not line.strip() or line in seen:
            continue
        seen.add(line)
        merged.append(line)

    names: dict[str, int] = {}
    for line in merged:
        name = entry_name(line)
        if name:
            names[name] = names.get(name, 0) + 1
    duplicated = sorted(n for n, count in names.items() if count > 1)
    if duplicated:
        raise Refusal(
            "the same file would be added under two keys: " + ", ".join(duplicated)
        )
    return merged


def merge(text: str) -> str:
    """Resolve a conflicted pbxproj, or raise Refusal."""
    lines = text.splitlines()
    hunks = split_hunks(lines)
    if not hunks:
        return text
    out: list[str] = []
    cursor = 0
    for start, end, ours, theirs in hunks:
        out.extend(lines[cursor:start])
        out.extend(resolve_hunk(ours, theirs))
        cursor = end
    out.extend(lines[cursor:])
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


def three_way(base: Path, ours: Path, theirs: Path) -> str:
    """The conflicted 3-way merge, via git's own merge-file.

    Git hands a merge driver the three UNMERGED inputs and expects the driver
    to do the merge; %A is plain "ours", not a pre-merged file with markers.
    Treating it as pre-merged is a silent data loss: the text has no conflict
    markers, so a hunk-resolver finds nothing to do, writes ours back, and
    exits 0 having dropped every change from the other side. That happened
    here and cost develop 10 files before a set-comparison against both
    parents caught it, which is why `verify_union` exists below.
    """
    merged = Path(str(ours) + ".pbxmerge")
    merged.write_bytes(ours.read_bytes())
    # Exit status is the conflict count, or >127 on failure; either way the
    # file now holds the merge with markers where the sides disagree.
    result = subprocess.run(
        [
            "git",
            "merge-file",
            "--marker-size=7",
            str(merged),
            str(base),
            str(theirs),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode > 127:
        merged.unlink(missing_ok=True)
        raise Refusal(f"git merge-file failed: {result.stderr.strip()[:200]}")
    text = merged.read_text(encoding="utf-8")
    merged.unlink(missing_ok=True)
    return text


def source_names(text: str) -> set[str]:
    """Every file named by a build-phase membership entry."""
    names = set()
    for line in text.splitlines():
        if MEMBERSHIP_PATTERNS[2].match(line) or MEMBERSHIP_PATTERNS[3].match(line):
            name = entry_name(line)
            if name:
                names.add(name)
    return names


def verify_union(resolved: str, ours: str, theirs: str) -> None:
    """Refuse a result that lost a side's files.

    A resolution is only correct if every file either side referenced is
    still referenced. Checked because the failure mode is a clean merge with
    a silently smaller project, which no later gate catches.
    """
    want = source_names(ours) | source_names(theirs)
    missing = sorted(want - source_names(resolved))
    if missing:
        raise Refusal(
            "resolution would drop membership for: " + ", ".join(missing[:10])
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ours", required=True, help="%%A, our version")
    parser.add_argument("--base", required=True, help="%%O, the merge base")
    parser.add_argument("--theirs", required=True, help="%%B, their version")
    parser.add_argument("--output", help="where to write (default: --ours)")
    args = parser.parse_args(argv)

    ours_path = Path(args.ours)
    try:
        conflicted = three_way(Path(args.base), ours_path, Path(args.theirs))
        resolved = merge(conflicted)
        verify_union(
            resolved,
            ours_path.read_text(encoding="utf-8"),
            Path(args.theirs).read_text(encoding="utf-8"),
        )
    except Refusal as refusal:
        print(f"[pbxproj-merge] refusing to auto-resolve: {refusal}", file=sys.stderr)
        print(
            "[pbxproj-merge] resolve by hand, then re-add every file with "
            "scripts/pbxproj_add_swift.rb, which is idempotent and covers .h/.mm",
            file=sys.stderr,
        )
        return 1
    Path(args.output or args.ours).write_text(resolved, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
