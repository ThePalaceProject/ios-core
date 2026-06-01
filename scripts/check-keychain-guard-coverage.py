#!/usr/bin/env python3
"""
check-keychain-guard-coverage.py — Wave 2 lint suite.

Scans PalaceTests/*.swift for test methods that touch keychain-backed state
(TPPUserAccount.sharedAccount, TPPUserAccount(), TPPKeychain.shared.*, real
AccountsManager()) without a guard. Guards: `KeychainAvailability.skipIfUnavailable()`
in the method body or setUp; class inherits `: KeychainBackedTestCase`; or
inline `// allow-no-keychain-guard:` marker. Mocks under PalaceTests/Mocks/ and
test methods explicitly named Mock/Fake/Spy touching mock receivers are skipped.

Source: swarm_f88ae9e3 investigation C.
Exit: 0 clean, 1 findings, 2 IO error.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable

RISK_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"TPPUserAccount\.sharedAccount\s*\("), "TPPUserAccount.sharedAccount(...)"),
    (re.compile(r"(?<![A-Za-z0-9_])TPPUserAccount\("), "TPPUserAccount(...)"),
    (re.compile(r"TPPKeychain\.shared\."), "TPPKeychain.shared.*"),
    (re.compile(r"(?<![A-Za-z0-9_])AccountsManager\("), "real AccountsManager()"),
)
GUARD_PATTERNS = (
    re.compile(r"KeychainAvailability\.skipIfUnavailable\s*\("),
    re.compile(r":\s*KeychainBackedTestCase\b"),
)
CARVEOUT_LINE_MARKER = "allow-no-keychain-guard"
CARVEOUT_BASENAMES = frozenset((
    "TPPTestCase.swift", "BaseTestCase.swift",
    "KeychainBackedTestCase.swift", "KeychainAvailability.swift",
))
CARVEOUT_PATH_SEGMENTS = ("Mocks",)
_MOCK_TOKENS = ("mock", "fake", "spy", "stub")

_TEST_FUNC_RE = re.compile(r"\bfunc\s+(test[A-Za-z0-9_]*)\s*\([^)]*\)")
_CLASS_DECL_RE = re.compile(
    r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^{]+?)\s*\{", re.MULTILINE,
)
_SETUP_RE = re.compile(
    r"\boverride\s+func\s+(setUp|setUpWithError|setUp\s*\(\s*\)\s+async)\b"
)
_DIFF_FILE_RE = re.compile(r"^\+\+\+\s+b/(.+)$", re.MULTILINE)


def _is_carveout(path: Path) -> bool:
    if path.name in CARVEOUT_BASENAMES:
        return True
    return any(p in CARVEOUT_PATH_SEGMENTS for p in path.parts)


def _strip_line(line: str) -> str:
    """Strip // comments and string literals from a line (preserve length)."""
    out, i, n, in_str = [], 0, len(line), False
    while i < n:
        ch = line[i]
        nxt = line[i + 1] if i + 1 < n else ""
        if not in_str and ch == "/" and nxt == "/":
            out.append(" " * (n - i)); break
        if ch == '"':
            in_str = not in_str; out.append(" "); i += 1; continue
        out.append(" " if in_str else ch); i += 1
    return "".join(out)


def _strip_block_comments(src: str) -> str:
    """Replace /* ... */ blocks with spaces, preserving offsets."""
    out, i, n = [], 0, len(src)
    while i < n:
        ch, nxt = src[i], src[i + 1] if i + 1 < n else ""
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


def _extract_body(src: str, decl_start: int) -> str | None:
    """Brace-match the body block following the func/class decl."""
    open_idx = src.find("{", decl_start)
    if open_idx < 0:
        return None
    depth, i, n = 1, open_idx + 1, len(src)
    while i < n and depth > 0:
        c = src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[open_idx + 1:i]
        i += 1
    return None


def _line_no(src: str, off: int) -> int:
    return src.count("\n", 0, off) + 1


def _inherits_base(src: str) -> bool:
    return any("KeychainBackedTestCase" in m.group(2) for m in _CLASS_DECL_RE.finditer(src))


def _setup_guards(src: str) -> bool:
    for m in _SETUP_RE.finditer(src):
        body = _extract_body(src, m.start())
        if body and "KeychainAvailability.skipIfUnavailable" in body:
            return True
    return False


def _is_mock_method(name: str) -> bool:
    low = name.lower()
    return any(t in low for t in _MOCK_TOKENS)


def scan_file(path: Path) -> list[str]:
    if _is_carveout(path):
        return []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        print(f"ERROR: cannot read {path}: {e}", file=sys.stderr)
        sys.exit(2)
    src = _strip_block_comments(text)
    if _inherits_base(src) or _setup_guards(src):
        return []
    findings: list[str] = []
    for m in _TEST_FUNC_RE.finditer(src):
        test_name = m.group(1)
        body = _extract_body(src, m.start())
        if body is None:
            continue
        if any(g.search(body) for g in GUARD_PATTERNS):
            continue
        is_mock_method = _is_mock_method(test_name)
        body_start_off = src.find("{", m.start()) + 1
        for off, raw in enumerate(body.split("\n")):
            global_line = _line_no(text, body_start_off) + off
            if CARVEOUT_LINE_MARKER in raw:
                continue
            stripped = _strip_line(raw)
            for regex, label in RISK_PATTERNS:
                if not regex.search(stripped):
                    continue
                if is_mock_method and any(t.capitalize() in stripped for t in _MOCK_TOKENS):
                    continue
                findings.append(
                    f"{path}:{global_line}: KEYCHAIN-GUARD: "
                    f"{test_name} touches {label} without "
                    f"`KeychainAvailability.skipIfUnavailable()` or "
                    f"`: KeychainBackedTestCase`."
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
        prog="check-keychain-guard-coverage.py",
        description=("Detect PalaceTests methods that touch keychain-backed "
                     "state without `KeychainAvailability.skipIfUnavailable()` "
                     "or `: KeychainBackedTestCase`."),
    )
    parser.add_argument("paths", nargs="*",
                        help="Swift test files or directories.")
    parser.add_argument("--diff", default=None,
                        help="Unified-diff file; scan only changed PalaceTests.")
    parser.add_argument("--file", action="append", default=[],
                        help="Explicit file to scan (repeatable).")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress success summary on stderr.")
    args = parser.parse_args(argv)

    targets = [p for p in _iter_targets(args)
               if p.exists() and p.suffix == ".swift"]
    failures: list[str] = []
    for p in targets:
        failures.extend(scan_file(p))
    for fail in failures:
        print(fail, file=sys.stderr)
    if not args.quiet:
        if failures:
            print(f"\n{len(failures)} keychain-guard finding(s) across "
                  f"{len(targets)} file(s).", file=sys.stderr)
        else:
            print(f"OK: {len(targets)} file(s) checked, 0 violations.",
                  file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
