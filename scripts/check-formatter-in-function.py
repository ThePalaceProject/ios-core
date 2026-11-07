#!/usr/bin/env python3
"""
check-formatter-in-function.py — flag `DateFormatter()` and
`ISO8601DateFormatter()` constructed inside a function body in `Palace/`.

Creating a date formatter costs far more than using one. A formatter built
inside a function, initializer, accessor or computed property is rebuilt on
every call; on the registry save path that was 2-4% of the app's CPU during
locked audiobook playback (PP-5498). Build the formatter once, configure it,
and only read from it afterwards:

    private static let rfc3339Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        ...
        return formatter
    }()

Allowed: a `static let`, a file-scope `let`, or a stored (`let`/`lazy var`)
property, including a closure that initializes one. Flagged: any construction
whose enclosing scope chain contains a `func`, `init`, `deinit`, `subscript`,
accessor (`get`/`set`/`willSet`/`didSet`) or computed property.

Scope: `Palace/**/*.swift`; tests, mocks and previews are excluded. Escape
hatch for a formatter that is built once by design (a factory called only from
a static initializer, or a one-off export): `// formatter-in-function-ok:
<reason>` on the line or one of the 3 lines above it.

Flags (mirror the sibling detectors):
  --diff <file>   Unified-diff input (`-` or omitted: stdin). Only added lines.
  --scan <root>   Walk `<root>/Palace/**/*.swift` and report every instance.
  --no-block      Print findings, always exit 0.
  --dry-run       Same as --no-block.
  --quiet         No summary line on stderr.

Exit codes: 0 no findings, 1 at least one finding, 2 argument or I/O error.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from _checklib import iter_hunk_lines, read_diff

_RE_CONSTRUCTION = re.compile(r"(?<![\w.])(?:ISO8601)?DateFormatter\s*\(\s*\)")
_RE_ANNOTATION = re.compile(r"//\s*formatter-in-function-ok\b")

_NON_PROD_PATH_SUBSTRINGS = (
    "PalaceTests/",
    "Tests/",
    "TestSupport/",
    "Utilities/Testing/",
    "Preview Content/",
    "Mocks/",
    "/.build/",
)

# Scope classification of the text between the previous `{`, `}` or `;` and an
# opening brace. The last match wins, so `let x = items.map {` reads as an
# initializer and `func f() -> Int {` as a function.
_RE_TYPE = re.compile(
    r"\b(?:struct|enum|extension|actor|protocol)\s+[A-Za-z_]"
    r"|\bclass\s+(?!func\b|var\b|let\b|override\b|private\b|fileprivate\b|"
    r"public\b|internal\b|open\b|final\b|subscript\b|init\b|deinit\b)[A-Za-z_]"
)
_RE_FUNC = re.compile(
    r"\bfunc\b|(?<![\w.])init\s*[?!]?\s*[(<]|\bdeinit\b|\bsubscript\b"
)
_RE_ACCESSOR_TAIL = re.compile(
    r"(?:^|[\s;{}])(?:(?:mutating|nonmutating)\s+)?"
    r"(?:get|set|willSet|didSet|_read|_modify)\s*(?:\(\s*\w+\s*\))?"
    r"(?:\s+(?:async|throws))*\s*$"
)
_RE_BINDING = re.compile(r"\b(let|var)\s+[A-Za-z_]")

TYPE, FUNC, OTHER = "type", "func", "other"


def _strip(source: str) -> str:
    """Blank out comments and string-literal contents, keeping offsets and
    newlines, so braces and constructor names inside them are ignored.
    Interpolations `\\( ... )` stay as code."""
    out = list(source)
    n = len(source)
    i = 0
    # One entry per open interpolation: [closing delimiter, paren depth].
    stack: list[list] = []
    in_string: str | None = None
    while i < n:
        ch = source[i]
        if in_string is not None:
            if source.startswith(in_string, i):
                for k in range(len(in_string)):
                    out[i + k] = " "
                i += len(in_string)
                in_string = None
                continue
            if ch == "\\" and i + 1 < n:
                if source[i + 1] == "(":
                    out[i] = " "
                    stack.append([in_string, 0])
                    in_string = None
                    i += 1
                    continue
                out[i] = " "
                if source[i + 1] != "\n":
                    out[i + 1] = " "
                i += 2
                continue
            if ch != "\n":
                out[i] = " "
            i += 1
            continue
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j == -1 else j
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        if source.startswith("/*", i):
            depth = 0
            j = i
            while j < n:
                if source.startswith("/*", j):
                    depth += 1
                    j += 2
                elif source.startswith("*/", j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                else:
                    j += 1
            for k in range(i, min(j, n)):
                if out[k] != "\n":
                    out[k] = " "
            i = j
            continue
        if stack and ch == "(":
            stack[-1][1] += 1
        elif stack and ch == ")":
            stack[-1][1] -= 1
            if stack[-1][1] == 0:
                in_string = stack.pop()[0]
                i += 1
                continue
        m = re.match(r'(#*)("""|")', source[i:i + 8])
        if m:
            hashes, quote = m.group(1), m.group(2)
            in_string = quote + hashes
            for k in range(len(m.group(0))):
                out[i + k] = " "
            i += len(m.group(0))
            continue
        i += 1
    return "".join(out)


def _has_initializer(rest: str) -> bool:
    depth = 0
    for idx, c in enumerate(rest):
        if c in "([<":
            depth += 1
        elif c in ")]>":
            depth -= 1
        elif c == "=" and depth <= 0:
            nxt = rest[idx + 1] if idx + 1 < len(rest) else ""
            prev = rest[idx - 1] if idx > 0 else ""
            if nxt != "=" and prev not in "=!<>":
                return True
    return False


def _classify(header: str) -> str:
    candidates: list[tuple[int, str]] = []
    for rx, kind in ((_RE_TYPE, TYPE), (_RE_FUNC, FUNC)):
        for m in rx.finditer(header):
            candidates.append((m.start(), kind))
    for m in _RE_BINDING.finditer(header):
        if m.group(1) == "var" and not _has_initializer(header[m.end():]):
            candidates.append((m.start(), FUNC))  # computed property
        else:
            candidates.append((m.start(), OTHER))
    if _RE_ACCESSOR_TAIL.search(header):
        candidates.append((len(header), FUNC))
    if not candidates:
        return OTHER
    return max(candidates, key=lambda c: c[0])[1]


def _function_scope_spans(stripped: str) -> list[tuple[int, int]]:
    """(open, close) offsets of every brace scope that sits inside a function."""
    spans: list[tuple[int, int]] = []
    stack: list[tuple[int, bool]] = []
    boundary = 0
    for i, ch in enumerate(stripped):
        if ch == "{":
            kind = _classify(stripped[boundary:i])
            parent_in_func = stack[-1][1] if stack else False
            stack.append((i, parent_in_func or kind == FUNC))
            boundary = i + 1
        elif ch == "}":
            if stack:
                start, in_func = stack.pop()
                if in_func:
                    spans.append((start, i))
            boundary = i + 1
        elif ch == ";":
            boundary = i + 1
    spans.extend((start, len(stripped)) for start, in_func in stack if in_func)
    return spans


@dataclass
class Finding:
    file_path: str
    line_no: int
    text: str

    def render(self) -> str:
        return (f"{self.file_path}:{self.line_no}: DFF-1: {self.text} is built inside a "
                "function body and is rebuilt on every call. Move it to a configured-once "
                "`static let` (see NSDate.rfc3339String) or annotate "
                "`// formatter-in-function-ok: <reason>`.")


def _is_non_prod(path: str) -> bool:
    return any(s in path for s in _NON_PROD_PATH_SUBSTRINGS)


def scan_source(rel_path: str, source: str) -> list[Finding]:
    if not rel_path.endswith(".swift") or _is_non_prod(rel_path):
        return []
    stripped = _strip(source)
    spans = _function_scope_spans(stripped)
    lines = source.splitlines()
    findings: list[Finding] = []
    for m in _RE_CONSTRUCTION.finditer(stripped):
        pos = m.start()
        if not any(start < pos < end for start, end in spans):
            continue
        line_no = source.count("\n", 0, pos) + 1
        window = lines[max(0, line_no - 4):line_no]
        if any(_RE_ANNOTATION.search(l) for l in window):
            continue
        findings.append(Finding(rel_path, line_no, re.sub(r"\s+", "", m.group(0))))
    return findings


def _reconstruct_post_image(diff_text: str, target: str) -> str | None:
    rows: dict[int, str] = {}
    for dl in iter_hunk_lines(diff_text):
        if dl.file_path == target and dl.kind in ("+", " "):
            rows[dl.line_no] = dl.text
    if not rows:
        return None
    return "\n".join(rows.get(i, "") for i in range(1, max(rows) + 1))


def scan_diff(diff_text: str, repo_root: Path) -> list[Finding]:
    added: dict[str, set[int]] = {}
    for dl in iter_hunk_lines(diff_text):
        if dl.kind == "+" and dl.file_path.startswith("Palace/") \
                and dl.file_path.endswith(".swift") and not _is_non_prod(dl.file_path):
            added.setdefault(dl.file_path, set()).add(dl.line_no)
    out: list[Finding] = []
    for rel, lines in added.items():
        on_disk = repo_root / rel
        if on_disk.is_file():
            source = on_disk.read_text(encoding="utf-8", errors="replace")
        else:
            source = _reconstruct_post_image(diff_text, rel)
            if source is None:
                continue
        out.extend(f for f in scan_source(rel, source) if f.line_no in lines)
    return out


def scan_repo(root: Path) -> list[Finding]:
    base = root / "Palace"
    out: list[Finding] = []
    if not base.is_dir():
        return out
    for dirpath, _dirs, files in os.walk(base):
        for name in files:
            if not name.endswith(".swift"):
                continue
            full = Path(dirpath) / name
            rel = str(full.relative_to(root))
            try:
                source = full.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            out.extend(scan_source(rel, source))
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="check-formatter-in-function.py")
    ap.add_argument("--diff", default=None)
    ap.add_argument("--scan", default=None)
    ap.add_argument("--no-block", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    if args.scan:
        root = Path(args.scan).resolve()
        if not root.is_dir():
            print(f"ERROR: scan root not found: {args.scan}", file=sys.stderr)
            return 2
        findings = scan_repo(root)
    else:
        findings = scan_diff(read_diff(args.diff), Path.cwd())

    findings.sort(key=lambda f: (f.file_path, f.line_no))
    for f in findings:
        print(f.render())
    if not args.quiet:
        print(f"\n{len(findings)} formatter-in-function finding(s)", file=sys.stderr)
    if args.no_block or args.dry_run:
        return 0
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
