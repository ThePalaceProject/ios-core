#!/usr/bin/env python3
"""Check Swift/ObjC comments in Palace/ and PalaceTests/ against the source-comment
rules in CLAUDE.md "Writing conventions".

Flags internal run IDs, harness paths and reviewer narratives in comments, and
file-header comment blocks longer than HEADER_MAX lines.

  check-comment-hygiene.py                 # whole tree
  check-comment-hygiene.py --diff FILE     # only lines added by a unified diff
  check-comment-hygiene.py --base REF      # only lines changed since merge-base with REF

Exit codes: 0 clean, 1 findings, 2 input error.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOTS = ("Palace", "PalaceTests")
EXTENSIONS = {".swift", ".m", ".h", ".mm"}
HEADER_MAX = 15

PATTERNS = [
    (re.compile(r"\bswarm(?:_\w+)?\b", re.I), "swarm ID"),
    (re.compile(r"\bwave[\s-]*\d+[a-z]?\b", re.I), "wave ID"),
    (re.compile(r"\.forgeos/"), ".forgeos/ path"),
    (re.compile(r"\bwall[- ]failures?\b", re.I), "wall-failure reference"),
    (re.compile(r"\bCLAUDE\.md\b"), "CLAUDE.md citation"),
    (re.compile(r"\b(?:architect|qa|qa_test|blast[_ -]radius|sod)[- ]reviewers?\b", re.I),
     "reviewer-role narrative"),
    (re.compile(r"\b(?:qa_test|blast_radius)\b"), "reviewer-role narrative"),
    (re.compile(r"\breview(?:er)?[- ]rounds?\s*\d", re.I), "reviewer-round narrative"),
    (re.compile(r"\bforge-review\b", re.I), "reviewer-role narrative"),
    (re.compile(r"\brev_[0-9a-f]{6,}\b", re.I), "review ID"),
]


def comment_lines(source: str) -> dict[int, str]:
    """Map 1-based line number -> comment text on that line.

    A small lexer: skips string literals (including Swift multi-line and raw
    strings) so `"https://..."` is not read as a comment, and handles nested
    block comments.
    """
    out: dict[int, list[str]] = {}
    i, n, line = 0, len(source), 1
    depth = 0  # block comment nesting

    def add(ln: int, ch: str) -> None:
        out.setdefault(ln, []).append(ch)

    while i < n:
        c = source[i]
        if depth:
            if source.startswith("/*", i):
                depth += 1
                add(line, "/*")
                i += 2
                continue
            if source.startswith("*/", i):
                depth -= 1
                i += 2
                continue
            if c == "\n":
                line += 1
            else:
                add(line, c)
            i += 1
            continue
        if source.startswith("//", i):
            end = source.find("\n", i)
            end = n if end == -1 else end
            add(line, source[i + 2:end])
            i = end
            continue
        if source.startswith("/*", i):
            depth = 1
            i += 2
            continue
        if c == '"' or (c == "#" and re.match(r'#+"', source[i:])):
            hashes = 0
            while i < n and source[i] == "#":
                hashes += 1
                i += 1
            if source.startswith('"""', i):
                close = '"""' + "#" * hashes
                i += 3
            else:
                close = '"' + "#" * hashes
                i += 1
            while i < n:
                if source[i] == "\\" and hashes == 0:
                    if i + 1 < n and source[i + 1] == "\n":
                        line += 1
                    i += 2
                    continue
                if source.startswith(close, i):
                    i += len(close)
                    break
                if source[i] == "\n":
                    line += 1
                    if len(close) - hashes == 1:
                        break  # unterminated single-line string; resync
                i += 1
            continue
        if c == "\n":
            line += 1
        i += 1
    return {ln: "".join(parts) for ln, parts in out.items()}


def header_length(source: str) -> tuple[int, int]:
    """(first line, length) of the leading comment block, counting blank lines
    inside it but not trailing ones."""
    lines = source.splitlines()
    start, last, in_block = None, None, False
    for idx, raw in enumerate(lines, 1):
        s = raw.strip()
        if in_block:
            last = idx
            if "*/" in s:
                in_block = False
            continue
        if not s:
            continue
        if s.startswith("//"):
            start = start or idx
            last = idx
            continue
        if s.startswith("/*"):
            start = start or idx
            last = idx
            in_block = "*/" not in s[2:]
            continue
        break
    if start is None:
        return 0, 0
    return start, last - start + 1


def scan_file(path: Path, rel: str, only_lines: set[int] | None = None) -> list[str]:
    try:
        source = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    findings = []
    for ln, text in sorted(comment_lines(source).items()):
        if only_lines is not None and ln not in only_lines:
            continue
        for rx, label in PATTERNS:
            m = rx.search(text)
            if m:
                findings.append(f"{rel}:{ln}: {label}: {m.group(0)!r}")
                break
    start, length = header_length(source)
    if length > HEADER_MAX:
        header_lines = set(range(start, start + length))
        if only_lines is None or header_lines & only_lines:
            findings.append(
                f"{rel}:{start}: file header comment is {length} lines (max {HEADER_MAX}); "
                "move design notes to docs/architecture/ and link"
            )
    return findings


def in_scope(rel: str) -> bool:
    p = Path(rel)
    return bool(p.parts) and p.parts[0] in ROOTS and p.suffix in EXTENSIONS


def added_lines(diff_text: str) -> dict[str, set[int]]:
    files: dict[str, set[int]] = {}
    current = None
    new_line = 0
    for raw in diff_text.splitlines():
        if raw.startswith("+++ "):
            target = raw[4:].strip()
            current = target[2:] if target.startswith("b/") else None
            if current is not None:
                files.setdefault(current, set())
            continue
        if raw.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)", raw)
            new_line = int(m.group(1)) if m else 0
            continue
        if current is None or raw.startswith("--- "):
            continue
        if raw.startswith("+"):
            files[current].add(new_line)
            new_line += 1
        elif raw.startswith("-") or raw.startswith("\\"):
            continue
        else:
            new_line += 1
    return files


def _toplevel() -> str:
    r = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else "."


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    group = ap.add_mutually_exclusive_group()
    group.add_argument("--diff", help="unified diff file; check only added lines")
    group.add_argument("--base", help="git ref; check lines changed since its merge-base")
    ap.add_argument("--root", help="repository root (default: git toplevel, else cwd)")
    ap.add_argument("--quiet", action="store_true", help="print findings only")
    args = ap.parse_args(argv)
    root = Path(args.root or _toplevel()).resolve()

    findings: list[str] = []
    if args.diff or args.base:
        if args.diff:
            try:
                diff_text = Path(args.diff).read_text(encoding="utf-8", errors="replace")
            except OSError as e:
                print(f"check-comment-hygiene: {e}", file=sys.stderr)
                return 2
        else:
            try:
                mb = subprocess.run(["git", "merge-base", args.base, "HEAD"], cwd=root,
                                    capture_output=True, text=True, check=True).stdout.strip()
                diff_text = subprocess.run(["git", "diff", "--unified=0", mb, "--", *ROOTS],
                                           cwd=root, capture_output=True, text=True,
                                           check=True).stdout
                untracked = subprocess.run(
                    ["git", "ls-files", "--others", "--exclude-standard", "--", *ROOTS],
                    cwd=root, capture_output=True, text=True, check=True).stdout.splitlines()
            except subprocess.CalledProcessError as e:
                print(f"check-comment-hygiene: git failed: {e.stderr.strip()}", file=sys.stderr)
                return 2
        changed = added_lines(diff_text)
        if args.base:
            # New files not yet added to git are wholly "added".
            for rel in untracked:
                changed[rel] = None
        for rel, lines in sorted(changed.items()):
            if lines is None and in_scope(rel):
                findings += scan_file(root / rel, rel)
                continue
            if lines and in_scope(rel):
                findings += scan_file(root / rel, rel, lines)
    else:
        for top in ROOTS:
            base = root / top
            if not base.is_dir():
                continue
            for path in sorted(base.rglob("*")):
                if path.suffix in EXTENSIONS and path.is_file():
                    findings += scan_file(path, path.relative_to(root).as_posix())

    for f in findings:
        print(f)
    if findings:
        if not args.quiet:
            print(f"check-comment-hygiene: {len(findings)} finding(s). Comments explain why the "
                  "code is the way it is; see 'Writing conventions' in CLAUDE.md.")
        return 1
    if not args.quiet:
        print("check-comment-hygiene: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
