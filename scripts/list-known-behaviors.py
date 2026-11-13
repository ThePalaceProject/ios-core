#!/usr/bin/env python3
"""List `// Known: PP-1234 <text>` markers in Palace/ and PalaceTests/.

A marker sits on or above an assertion or snapshot that keeps behavior the
author suspects is wrong, so a passing test does not read as an endorsement.

  list-known-behaviors.py                    # every marker in the tree
  list-known-behaviors.py --diff-base REF    # only markers added since merge-base with REF
  list-known-behaviors.py --markdown         # a table for a CI step summary

Exit codes: 0 listed, 1 a marker has no PP key, 2 input error.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOTS = ("Palace", "PalaceTests")
EXTENSIONS = {".swift", ".m", ".h", ".mm"}
MARKER = re.compile(r"//\s*Known:\s*(.*)$")
KEY = re.compile(r"\bPP-\d+\b")


def in_scope(rel: str) -> bool:
    p = Path(rel)
    return bool(p.parts) and p.parts[0] in ROOTS and p.suffix in EXTENSIONS


def parse_marker(line: str) -> tuple[list[str], str] | None:
    """(PP keys, marker text) for a marker line, or None if the line has none."""
    m = MARKER.search(line)
    if not m:
        return None
    text = m.group(1).strip()
    return KEY.findall(text), text


def markers_in_source(rel: str, source: str) -> list[tuple[str, int, list[str], str]]:
    out = []
    for ln, line in enumerate(source.splitlines(), 1):
        parsed = parse_marker(line)
        if parsed:
            out.append((rel, ln, parsed[0], parsed[1]))
    return out


def markers_in_diff(diff_text: str) -> list[tuple[str, int, list[str], str]]:
    """Markers on lines a unified diff adds, in in-scope files only."""
    out = []
    current, new_line = None, 0
    for raw in diff_text.splitlines():
        if raw.startswith("+++ "):
            target = raw[4:].strip()
            current = target[2:] if target.startswith("b/") else None
            continue
        if raw.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)", raw)
            new_line = int(m.group(1)) if m else 0
            continue
        if current is None or raw.startswith("--- "):
            continue
        if raw.startswith("+"):
            parsed = parse_marker(raw[1:]) if in_scope(current) else None
            if parsed:
                out.append((current, new_line, parsed[0], parsed[1]))
            new_line += 1
        elif not (raw.startswith("-") or raw.startswith("\\")):
            new_line += 1
    return out


def _git(root: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=root, capture_output=True, text=True,
                          check=True).stdout


def collect(root: Path, diff_base: str | None) -> list[tuple[str, int, list[str], str]]:
    if diff_base:
        mb = _git(root, "merge-base", diff_base, "HEAD").strip()
        # Diff the working tree, not HEAD, so uncommitted edits are listed too.
        found = markers_in_diff(_git(root, "diff", "--unified=0", mb, "--", *ROOTS))
        for rel in _git(root, "ls-files", "--others", "--exclude-standard", "--",
                        *ROOTS).splitlines():
            if in_scope(rel):
                found += markers_in_source(rel, (root / rel).read_text(errors="replace"))
        return sorted(found)
    found = []
    for rel in _git(root, "ls-files", "--", *ROOTS).splitlines():
        if in_scope(rel) and (root / rel).is_file():
            found += markers_in_source(rel, (root / rel).read_text(errors="replace"))
    return found


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--diff-base", help="git ref; list only markers added since its merge-base")
    ap.add_argument("--root", help="repository root (default: cwd)")
    ap.add_argument("--markdown", action="store_true", help="print a Markdown table")
    args = ap.parse_args(argv)
    root = Path(args.root or ".").resolve()

    try:
        markers = collect(root, args.diff_base)
    except subprocess.CalledProcessError as e:
        print(f"list-known-behaviors: git failed: {e.stderr.strip()}", file=sys.stderr)
        return 2

    scope = f"added since {args.diff_base}" if args.diff_base else "in the tree"
    if args.markdown:
        print(f"### Known behaviors kept ({len(markers)} {scope})\n")
        if markers:
            print("| Location | Key | Note |\n|---|---|---|")
            for rel, ln, keys, text in markers:
                note = text.replace("|", "\\|")
                print(f"| `{rel}:{ln}` | {', '.join(keys) or 'missing'} | {note} |")
    else:
        for rel, ln, keys, text in markers:
            print(f"{rel}:{ln}: {', '.join(keys) or '(no PP key)'}: {text}")
        print(f"list-known-behaviors: {len(markers)} marker(s) {scope}")

    missing = [(rel, ln) for rel, ln, keys, _ in markers if not keys]
    for rel, ln in missing:
        print(f"list-known-behaviors: {rel}:{ln}: a Known marker needs a PP key, "
              "e.g. `// Known: PP-1234 <what is kept and why it may be wrong>`",
              file=sys.stderr)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
