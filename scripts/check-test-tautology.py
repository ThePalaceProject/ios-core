#!/usr/bin/env python3
"""
check-test-tautology.py — Wave 2 lint suite.

Flags `XCTAssertNotNil(<receiver>.<method>())` calls where `<method>()` in
the Palace production codebase declares a non-optional return type. Such
assertions are mathematically guaranteed to pass — testing Swift's type
system rather than behavior.

Bare local idents (`XCTAssertNotNil(value)`) are skipped (cannot infer type).
Methods with no production declaration are skipped (could be test helpers
returning Optional). Methods with inconsistent return-type forms (`-> Foo`
and `-> Foo?` both declared somewhere) are skipped (ambiguous).

Carveout: `// allow-non-optional-not-nil: <reason>` marker on the line or
within 2 lines above.

Source: .forgeos/wall-failures/2026-05-29-cs7e4db982-qa-block.md.
Exit: 0 clean, 1 tautology, 2 IO error.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable

_XCT_RE = re.compile(r"\bXCTAssertNotNil\s*\(")
_BARE_IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_RECEIVER_METHOD_RE = re.compile(
    r"^(?P<receiver>[A-Za-z_][A-Za-z0-9_.]*?)"
    r"\.(?P<method>[A-Za-z_][A-Za-z0-9_]*)"
    r"\s*\((?P<rest>.*)$",
)
_FUNC_DECL_RE = re.compile(
    r"\bfunc\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*"
    r"(?:<[^>]*>)?"
    r"\s*\([^{]*?\)"
    r"\s*(?:async\s+)?(?:throws\s+)?(?:rethrows\s+)?(?:async\s+)?"
    r"->\s*(?P<ret>[^{]+?)\s*(?:\{|$)",
    re.DOTALL,
)
_DIFF_FILE_RE = re.compile(r"^\+\+\+\s+b/(.+)$", re.MULTILINE)
MARKER_PREFIX = "allow-non-optional-not-nil:"
MARKER_LOOKBACK_LINES = 2


def _strip_block_comments(src: str) -> str:
    out, i, n = [], 0, len(src)
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            while i < n and src[i] != "\n":
                out.append(" "); i += 1
            continue
        if ch == "/" and nxt == "*":
            end = src.find("*/", i + 2)
            if end < 0:
                for c in src[i:]:
                    out.append("\n" if c == "\n" else " ")
                break
            for c in src[i:end + 2]:
                out.append("\n" if c == "\n" else " ")
            i = end + 2; continue
        out.append(ch); i += 1
    return "".join(out)


def _extract_call_arg(src: str, open_paren_idx: int) -> tuple[str, int] | None:
    depth, i, n, in_str, start = 1, open_paren_idx + 1, len(src), False, open_paren_idx + 1
    while i < n and depth > 0:
        c = src[i]
        if c == '"' and (i == 0 or src[i - 1] != "\\"):
            in_str = not in_str; i += 1; continue
        if in_str:
            i += 1; continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return (src[start:i].strip(), i)
        elif c == "," and depth == 1:
            return (src[start:i].strip(), i)
        i += 1
    return None


def _is_simple_method_call(expr: str) -> tuple[str, str] | None:
    m = _RECEIVER_METHOD_RE.match(expr)
    if not m:
        return None
    rest = m.group("rest")
    if not rest.rstrip().endswith(")"):
        return None
    depth, i, n, in_str = 1, 0, len(rest), False
    while i < n and depth > 0:
        c = rest[i]
        if c == '"' and (i == 0 or rest[i - 1] != "\\"):
            in_str = not in_str; i += 1; continue
        if in_str:
            i += 1; continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                if rest[i + 1:].strip():
                    return None
                break
        i += 1
    return (m.group("receiver"), m.group("method"))


def _collect_returns(root: Path) -> dict[str, set[str]]:
    """Walk root/Palace/ and map method-name → set of declared return types."""
    cache: dict[str, set[str]] = {}
    palace = root / "Palace"
    if not palace.is_dir():
        return cache
    for swift in palace.rglob("*.swift"):
        parts = set(swift.parts)
        if "PalaceTests" in parts or "Mocks" in parts:
            continue
        try:
            text = swift.read_text(encoding="utf-8")
        except OSError:
            continue
        stripped = _strip_block_comments(text)
        for m in _FUNC_DECL_RE.finditer(stripped):
            name = m.group("name")
            ret = m.group("ret").strip().rstrip(",")
            where_idx = ret.find(" where ")
            if where_idx >= 0:
                ret = ret[:where_idx].strip()
            cache.setdefault(name, set()).add(ret)
    return cache


def _looks_optional(ret: str) -> bool:
    s = ret.strip()
    if s in ("Void", "()"):
        return True
    if s.endswith("?") or s.endswith("!"):
        return True
    if s.startswith("Optional<") and s.endswith(">"):
        return True
    return False


def _is_definitely_non_optional(returns: set[str]) -> bool:
    if not returns:
        return False
    return all(not _looks_optional(r) for r in returns)


def _line_no(src: str, off: int) -> int:
    return src.count("\n", 0, off) + 1


def _has_marker(lines: list[str], idx: int) -> bool:
    start = max(0, idx - MARKER_LOOKBACK_LINES)
    return any(f"// {MARKER_PREFIX}" in lines[j] for j in range(start, idx + 1))


def scan_file(path: Path, returns: dict[str, set[str]]) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        print(f"ERROR: cannot read {path}: {e}", file=sys.stderr)
        sys.exit(2)
    stripped = _strip_block_comments(text)
    raw_lines = text.split("\n")
    findings: list[str] = []
    for m in _XCT_RE.finditer(stripped):
        result = _extract_call_arg(stripped, m.end() - 1)
        if result is None:
            continue
        arg, _ = result
        if not arg or _BARE_IDENT_RE.match(arg):
            continue
        rm = _is_simple_method_call(arg)
        if rm is None:
            continue
        _receiver, method = rm
        types = returns.get(method, set())
        if not _is_definitely_non_optional(types):
            continue
        line_no = _line_no(text, m.start())
        if _has_marker(raw_lines, line_no - 1):
            continue
        ret_render = ", ".join(sorted(types))
        findings.append(
            f"{path}:{line_no}: TEST-TAUTOLOGY: XCTAssertNotNil on "
            f"`{method}()` whose declared return type is non-optional "
            f"({ret_render}). Replace with a behavioral assertion or add "
            f"`// {MARKER_PREFIX} <reason>`."
        )
    return findings


def _files_from_diff(diff_path: Path) -> list[Path]:
    try:
        text = diff_path.read_text(encoding="utf-8")
    except OSError as e:
        print(f"ERROR: cannot read diff {diff_path}: {e}", file=sys.stderr)
        sys.exit(2)
    return [Path(m.group(1)) for m in _DIFF_FILE_RE.finditer(text)
            if Path(m.group(1)).suffix == ".swift"
            and "PalaceTests" in Path(m.group(1)).parts]


def _iter_targets(args: argparse.Namespace) -> Iterable[Path]:
    seen: set[Path] = set()
    if args.diff:
        for p in _files_from_diff(Path(args.diff)):
            if p not in seen and p.exists():
                seen.add(p); yield p
    if args.file:
        for f in args.file:
            p = Path(f)
            if p not in seen:
                seen.add(p); yield p
    for f in args.paths:
        p = Path(f)
        if p.is_dir():
            for sub in sorted(p.rglob("*.swift")):
                if sub not in seen:
                    seen.add(sub); yield sub
        elif p not in seen:
            seen.add(p); yield p


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-test-tautology.py",
        description=("Detect XCTAssertNotNil(receiver.method()) calls where "
                     "the production-side method() return type is non-optional."),
    )
    parser.add_argument("paths", nargs="*",
                        help="Swift test files or directories.")
    parser.add_argument("--diff", default=None,
                        help="Unified-diff file; scan only changed PalaceTests.")
    parser.add_argument("--file", action="append", default=[],
                        help="Explicit file to scan (repeatable).")
    parser.add_argument("--root", default=None,
                        help="Codebase root for production lookup (defaults "
                             "to the repo root).")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress success summary on stderr.")
    args = parser.parse_args(argv)
    root = Path(args.root) if args.root else Path(__file__).resolve().parent.parent
    targets = [p for p in _iter_targets(args)
               if p.exists() and p.suffix == ".swift"]
    returns = _collect_returns(root)
    failures: list[str] = []
    for p in targets:
        failures.extend(scan_file(p, returns))
    for fail in failures:
        print(fail, file=sys.stderr)
    if not args.quiet:
        if failures:
            print(f"\n{len(failures)} test-tautology finding(s) across "
                  f"{len(targets)} file(s).", file=sys.stderr)
        else:
            print(f"OK: {len(targets)} file(s) checked, 0 tautologies.",
                  file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
