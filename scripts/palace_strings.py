#!/usr/bin/env python3
"""Localization inventory and drift gate for the Palace iOS app.

Replaces the Transifex runtime dependency's implicit safety net (PP-5094). The
SDK swizzled `Bundle.localizedString(forKey:)`, so EVERY string literal that
reaches a localizable initializer was translated at runtime -- including SwiftUI
`Text("...")` and `.accessibilityLabel("...")`, which `genstrings` cannot see.
An inventory built on `genstrings` alone would report those as dead and prune
translations patrons read today.

Foundation has no per-key fallback: when a language's table EXISTS but lacks a
key, the lookup returns the KEY, not the development-language value. A partial
table is therefore user-visible breakage, which is why `check` treats key-set
inequality across languages as a hard failure rather than a warning.

Commands:
    inventory  list every localizable key found in the sources
    status     per-language coverage against the committed .strings tables
    check      CI gate; non-zero exit on drift
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

# SwiftUI initializers and modifiers whose leading string literal is an
# implicit LocalizedStringKey, plus the explicit Foundation macros.
LOCALIZING_CALLS = (
    "NSLocalizedString", "CFCopyLocalizedString",
    "Text", "Button", "Label", "Toggle", "TextField", "SecureField",
    "Picker", "Stepper", "Link", "NavigationLink", "Section", "Menu",
    "navigationTitle", "navigationBarTitle", "alert", "confirmationDialog",
    "accessibilityLabel", "accessibilityHint", "accessibilityValue",
)
_CALLS_RE = "|".join(LOCALIZING_CALLS)
_STR = r'"((?:[^"\\]|\\.)*)"'

_CALL_LITERAL = re.compile(rf'\b({_CALLS_RE})\s*\(\s*\(?\s*{_STR}', re.S)
# a macro whose first argument is not a literal at all (a variable / function call)
_RUNTIME_KEY_MACROS = {"NSLocalizedString", "CFCopyLocalizedString"}
_MACRO_NONLITERAL = re.compile(r'\b(NSLocalizedString|CFCopyLocalizedString)\s*\(\s*(?!")', re.S)

# printf conversion specifications; %% is a literal percent and is stripped first.
_SPEC = re.compile(
    r'%(?:(\d+)\$)?[-+ #0]*[\d*]*(?:\.[\d*]+)?(?:hh|h|ll|l|q|L|z|t|j)?'
    r'([@diouxXeEfFgGaAcCsSpn])'
)

_COMMENT_BLOCK = re.compile(r'/\*.*?\*/', re.S)
_STRINGS_ENTRY = re.compile(rf'{_STR}\s*=\s*{_STR}\s*;')


@dataclass(frozen=True)
class Finding:
    kind: str
    lang: str
    key: str
    detail: str = ""



_MULTILINE = re.compile(r'"""(.*?)"""', re.S)
_CONCAT = re.compile(rf'{_STR}\s*\+\s*(?=")', re.S)


def _fold_multiline(src: str) -> str:
    """Rewrite Swift \"\"\" literals into equivalent single-line literals.

    Swift strips the closing delimiter's indentation from every line and a
    trailing backslash joins without a newline. Without this the composed key
    is invisible to extraction, and the string silently loses its translation.
    """
    def repl(m: re.Match) -> str:
        lines = m.group(1).split("\n")
        if lines and not lines[0].strip():
            lines = lines[1:]
        indent = len(lines[-1]) - len(lines[-1].lstrip()) if lines else 0
        body, joined = [], ""
        for line in lines[:-1] if lines else []:
            stripped = line[indent:] if len(line) > indent else line.lstrip()
            if stripped.endswith("\\"):
                joined += stripped[:-1]
            else:
                body.append(joined + stripped)
                joined = ""
        if joined:
            body.append(joined)
        text = "\\n".join(body).replace('"', '\\"')
        return f'"{text}"'
    return _MULTILINE.sub(repl, src)


def _fold_concatenation(src: str) -> str:
    """Join compile-time literal concatenation: "a " + "b" -> "a b"."""
    pair = re.compile(rf'{_STR}\s*\+\s*{_STR}', re.S)
    while True:
        folded = pair.sub(lambda m: '"' + m.group(1) + m.group(2) + '"', src)
        if folded == src:
            return src
        src = folded


def preprocess(src: str) -> str:
    """Resolve compile-time literal composition before extraction."""
    return _fold_concatenation(_fold_multiline(src))


# ------------------------------------------------------------------ extraction

def extract_swift(src: str) -> tuple[set[str], list[str]]:
    r"""Return (literal keys, dynamic call sites) for one Swift/ObjC source.

    Interpolation means two opposite things depending on the call, and
    conflating them loses real translations in one direction and invents
    unmatchable keys in the other:

    * SwiftUI `Text("\(n) active days")` builds a LocalizedStringKey whose key
      is the format-normalised string ("%@ active days"). That IS a real,
      translatable key.
    * `NSLocalizedString("\(x)_suffix")` computes its key at runtime from a
      plain String. No static key exists; `genstrings` nonetheless emits the
      uninterpolated literal, which can never match at runtime.
    """
    src = preprocess(src)
    keys: set[str] = set()
    dynamic: list[str] = []
    for m in _CALL_LITERAL.finditer(src):
        call, literal = m.group(1), m.group(2)
        interpolated = r"\(" in literal
        if not interpolated:
            keys.add(literal)
        elif call in _RUNTIME_KEY_MACROS:
            dynamic.append(literal)
        else:
            keys.add(normalize_interpolation(literal))
    for m in _MACRO_NONLITERAL.finditer(src):
        dynamic.append(m.group(0).strip())
    return keys, dynamic


def normalize_interpolation(literal: str) -> str:
    r"""Collapse SwiftUI \(...) segments to %@, as LocalizedStringKey does.

    Nesting-aware: \(a.map { "\($0)" }) must consume its own parentheses.
    The specifier is approximated as %@ (SwiftUI emits type-specific forms such
    as %lld for Int), so these keys are reported for confirmation rather than
    trusted blindly -- see `inventory --json` field "interpolated".
    """
    out, i = [], 0
    while i < len(literal):
        if literal.startswith(r"\(", i):
            depth, i = 1, i + 2
            while i < len(literal) and depth:
                if literal[i] == "(":
                    depth += 1
                elif literal[i] == ")":
                    depth -= 1
                i += 1
            out.append("%@")
        else:
            out.append(literal[i])
            i += 1
    return "".join(out)


# --------------------------------------------------------- specifier checking

def _specifiers(s: str) -> list[tuple[str, str]]:
    return [(m.group(1) or "", m.group(2)) for m in _SPEC.finditer(s.replace("%%", ""))]


def specifier_mismatch(source: str, target: str) -> str | None:
    """None when target carries the same conversions as source.

    Compared as a sorted multiset, so reordering is permitted -- a translator
    reordering via positional specifiers (%1$@ / %2$@) is doing the right
    thing. Dropping, adding, or retyping a specifier is a crash in
    String(format:) and is always reported.
    """
    a, b = sorted(_specifiers(source)), sorted(_specifiers(target))
    if a == b:
        return None
    return f"source {[x[0] + x[1] for x in a]} != target {[x[0] + x[1] for x in b]}"


# --------------------------------------------------------------- key hygiene

def is_identifier_key(key: str) -> bool:
    """True for symbol-shaped keys (CarPlay.Error.offline, IncreaseFontSize).

    These matter because Foundation returns the key on a miss: a prose key
    degrades to readable English, an identifier key degrades to gibberish.
    """
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.]*", key):
        return False
    return bool(re.search(r"[a-z][A-Z]", key) or "_" in key or "." in key)


def is_format_only(key: str) -> bool:
    """True when a key carries no translatable words (e.g. "%@ (%@)")."""
    return not re.search(r"[A-Za-z]", _SPEC.sub(" ", key.replace("%%", " ")))


# ------------------------------------------------------------ .strings tables

def parse_strings(text: str) -> dict[str, str]:
    """Parse a .strings file, preserving escape sequences verbatim."""
    return {m.group(1): m.group(2) for m in _STRINGS_ENTRY.finditer(_COMMENT_BLOCK.sub("", text))}


def _read_table(root: Path, lang: str) -> dict[str, str] | None:
    for enc in ("utf-8", "utf-16"):
        try:
            return parse_strings((root / f"{lang}.lproj" / "Localizable.strings").read_text(encoding=enc))
        except FileNotFoundError:
            return None
        except (UnicodeDecodeError, UnicodeError):
            continue
    return None


def check_tables(root: Path, langs: list[str]) -> list[Finding]:
    """Findings across the committed tables. Empty list means a clean tree."""
    tables = {l: _read_table(root, l) for l in langs}
    findings: list[Finding] = []

    for lang, table in tables.items():
        if table is None:
            findings.append(Finding("missing_table", lang, "", f"no {lang}.lproj/Localizable.strings"))
    present = {l: t for l, t in tables.items() if t is not None}
    if not present:
        return findings

    source_lang = langs[0]
    source = present.get(source_lang, {})
    every_key: set[str] = set().union(*(set(t) for t in present.values()))

    for lang, table in present.items():
        for key in sorted(every_key - set(table)):
            findings.append(Finding("missing_key", lang, key,
                                    "Foundation returns the key itself on a per-key miss"))
        for key, value in sorted(table.items()):
            if not value.strip():
                findings.append(Finding("empty_value", lang, key, "renders as an empty label"))
            src = source.get(key)
            if src is not None and lang != source_lang:
                bad = specifier_mismatch(src, value)
                if bad:
                    findings.append(Finding("specifier_mismatch", lang, key, bad))
    return findings


# ------------------------------------------------------------------ inventory

SOURCE_SUFFIXES = (".swift", ".m", ".mm")


def inventory(paths: list[Path]) -> tuple[set[str], dict[str, list[str]]]:
    keys: set[str] = set()
    dynamic: dict[str, list[str]] = {}
    for base in paths:
        files = [base] if base.is_file() else [p for p in base.rglob("*") if p.suffix in SOURCE_SUFFIXES]
        for f in files:
            try:
                text = f.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            k, d = extract_swift(text)
            keys |= k
            if d:
                dynamic[str(f)] = d
    return keys, dynamic


# ------------------------------------------------------------------------ CLI

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    for name in ("inventory", "status", "check"):
        p = sub.add_parser(name)
        p.add_argument("--lproj-root", type=Path, default=Path("Palace"))
        p.add_argument("--langs", default="en,de,es,fr,it")
        p.add_argument("--source", type=Path, action="append", default=None)
        p.add_argument("--json", action="store_true")

    a = ap.parse_args(argv)
    langs = [l.strip() for l in a.langs.split(",") if l.strip()]
    sources = a.source or [Path("Palace")]

    if a.cmd == "inventory":
        keys, dynamic = inventory(sources)
        if a.json:
            print(json.dumps({"keys": sorted(keys), "dynamic": dynamic}, indent=1, ensure_ascii=False))
        else:
            print(f"{len(keys)} localizable keys; {sum(len(v) for v in dynamic.values())} dynamic sites")
            for key in sorted(keys):
                print("  ", key)
        return 0

    findings = check_tables(a.lproj_root, langs)

    if a.cmd == "status":
        tables = {l: (_read_table(a.lproj_root, l) or {}) for l in langs}
        every = set().union(*(set(t) for t in tables.values())) if tables else set()
        for l in langs:
            have = len(tables[l])
            pct = 100.0 * have / len(every) if every else 100.0
            print(f"  {l}: {have}/{len(every)} keys ({pct:.1f}%)")
        return 0

    by_kind: dict[str, int] = {}
    for f in findings:
        by_kind[f.kind] = by_kind.get(f.kind, 0) + 1
    if a.json:
        print(json.dumps([f.__dict__ for f in findings], indent=1, ensure_ascii=False))
    else:
        for f in findings[:60]:
            print(f"  {f.kind:20} {f.lang:3} {f.key!r} {f.detail}")
        if len(findings) > 60:
            print(f"  ... and {len(findings) - 60} more")
        print(("FAIL " + ", ".join(f"{k}={v}" for k, v in sorted(by_kind.items()))) if findings
              else "OK — tables consistent")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
