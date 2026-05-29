#!/usr/bin/env python3
"""
check-protocol-isolation.py — Wave 2 lint suite.

Identifies Palace/ protocols whose 100% of detected conformers are `@MainActor`
while the protocol itself is not — a single-point-of-fix hoisting opportunity.
Threshold: ≥2 conformers required (single-conformer cases are too sparse).

Heuristic limits (intentional): single-line decls + 1-line attribute lookback;
generic `where`-constrained extensions are NOT treated as conformers.

Source: swarm_f88ae9e3 investigation E + outcome.md Fix 4.
Exit: 0 clean, 1 candidate found, 2 IO error.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable

_PROTOCOL_RE = re.compile(
    r"^(?P<indent>\s*)"
    r"(?P<modifiers>(?:public|internal|fileprivate|private)\s+)?"
    r"(?P<actor>@MainActor\s+)?"
    r"protocol\s+(?P<name>[A-Z][A-Za-z0-9_]*)"
    r"(?:\s*:\s*[^{]+?)?\s*\{",
    re.MULTILINE,
)
_CONFORMER_DECL_RE = re.compile(
    r"^(?P<indent>\s*)"
    r"(?P<modifiers>(?:public|internal|fileprivate|private|open)\s+)?"
    r"(?P<actor>@MainActor\s+)?"
    r"(?P<final>final\s+)?"
    r"(?P<kind>class|struct|actor|enum)\s+(?P<name>[A-Z][A-Za-z0-9_]*)"
    r"(?:\s*<[^>]*>)?\s*:\s*(?P<inh>[^{]+?)\s*\{",
    re.MULTILINE,
)
_EXTENSION_DECL_RE = re.compile(
    r"^(?P<indent>\s*)"
    r"(?P<actor>@MainActor\s+)?"
    r"extension\s+(?P<name>[A-Za-z_][A-Za-z0-9_.]*)"
    r"\s*:\s*(?P<inh>[^{]+?)\s*\{",
    re.MULTILINE,
)
_DIFF_FILE_RE = re.compile(r"^\+\+\+\s+b/(.+)$", re.MULTILINE)


def _split_inh(inh: str) -> list[str]:
    out: list[str] = []
    for tok in inh.split(","):
        tok = tok.strip()
        lt = tok.find("<")
        if lt > 0:
            tok = tok[:lt]
        if tok:
            out.append(tok)
    return out


def _line_no(src: str, off: int) -> int:
    return src.count("\n", 0, off) + 1


def _prev_line_has_main_actor(src: str, decl_start: int) -> bool:
    if decl_start == 0:
        return False
    line_start = src.rfind("\n", 0, decl_start) + 1
    prev_end = line_start - 1
    if prev_end <= 0:
        return False
    prev_start = src.rfind("\n", 0, prev_end) + 1
    return src[prev_start:prev_end].strip().startswith("@MainActor")


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


def _is_palace_source(p: Path) -> bool:
    parts = set(p.parts)
    if "Palace" not in parts:
        return False
    if "PalaceTests" in parts or "Mocks" in parts:
        return False
    return p.suffix == ".swift"


def _collect_protocols(src: str, path: Path) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for m in _PROTOCOL_RE.finditer(src):
        actor_attr = bool(m.group("actor")) or _prev_line_has_main_actor(src, m.start())
        out[m.group("name")] = {
            "main_actor": actor_attr,
            "lineno": _line_no(src, m.start()),
            "file": path,
        }
    return out


def _collect_conformers(src: str, path: Path, names: set[str]) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {n: [] for n in names}
    for m in _CONFORMER_DECL_RE.finditer(src):
        actor = bool(m.group("actor")) or _prev_line_has_main_actor(src, m.start())
        for proto in _split_inh(m.group("inh")):
            if proto in names:
                out[proto].append({
                    "main_actor": actor,
                    "lineno": _line_no(src, m.start()),
                    "kind": m.group("kind"),
                    "name": m.group("name"),
                })
    for m in _EXTENSION_DECL_RE.finditer(src):
        segment = src[m.start():m.end()]
        if " where " in segment.split(":", 1)[0]:
            continue
        actor = bool(m.group("actor")) or _prev_line_has_main_actor(src, m.start())
        for proto in _split_inh(m.group("inh")):
            if proto in names:
                out[proto].append({
                    "main_actor": actor,
                    "lineno": _line_no(src, m.start()),
                    "kind": "extension",
                    "name": m.group("name"),
                })
    return out


def _scan(paths: list[Path]) -> list[str]:
    src_cache: dict[Path, str] = {}
    protocols: dict[str, dict] = {}
    for p in paths:
        try:
            text = p.read_text(encoding="utf-8")
        except OSError:
            continue
        src = _strip_block_comments(text)
        src_cache[p] = src
        for name, info in _collect_protocols(src, p).items():
            protocols.setdefault(name, info)
    if not protocols:
        return []
    names = set(protocols)
    all_conformers: dict[str, list[dict]] = {n: [] for n in names}
    for p, src in src_cache.items():
        for proto, lst in _collect_conformers(src, p, names).items():
            all_conformers[proto].extend(lst)
    findings: list[str] = []
    for name in sorted(protocols):
        info = protocols[name]
        if info["main_actor"]:
            continue
        conformers = all_conformers[name]
        if len(conformers) < 2:
            continue
        if not all(c["main_actor"] for c in conformers):
            continue
        findings.append(
            f"{info['file']}:{info['lineno']}: PROTOCOL-ISO: protocol "
            f"`{name}` has {len(conformers)} conformers, all `@MainActor`, "
            f"but the protocol itself is not. Hoist `@MainActor` onto the "
            f"protocol to eliminate per-conformer annotations."
        )
    return findings


def _files_from_diff(diff_path: Path) -> list[Path]:
    try:
        text = diff_path.read_text(encoding="utf-8")
    except OSError as e:
        print(f"ERROR: cannot read diff {diff_path}: {e}", file=sys.stderr)
        sys.exit(2)
    return [Path(m.group(1)) for m in _DIFF_FILE_RE.finditer(text)
            if _is_palace_source(Path(m.group(1)))]


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
        prog="check-protocol-isolation.py",
        description=("Identify Palace/ protocols whose 100% of conformers are "
                     "@MainActor while the protocol itself isn't."),
    )
    parser.add_argument("paths", nargs="*",
                        help="Swift source files or directories.")
    parser.add_argument("--diff", default=None,
                        help="Unified-diff file; scan only changed Palace files.")
    parser.add_argument("--file", action="append", default=[],
                        help="Explicit file to scan (repeatable).")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress success summary on stderr.")
    args = parser.parse_args(argv)
    targets = [p for p in _iter_targets(args)
               if p.exists() and p.suffix == ".swift"]
    failures = _scan(targets)
    for fail in failures:
        print(fail, file=sys.stderr)
    if not args.quiet:
        if failures:
            print(f"\n{len(failures)} protocol-isolation candidate(s) "
                  f"across {len(targets)} file(s).", file=sys.stderr)
        else:
            print(f"OK: {len(targets)} file(s) checked, 0 candidates.",
                  file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
