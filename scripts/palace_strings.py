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


def strip_comments(src: str) -> str:
    """Remove Swift comments, leaving string literals intact.

    A regex cannot do this: `"http://x"` contains `//` inside a literal, and a
    commented-out call site contains a literal inside a comment. Both directions
    corrupt the inventory -- the second invents a key that every language is
    then asked to translate.
    """
    out, i, n = [], 0, len(src)
    depth = 0          # nested /* */ depth
    while i < n:
        two = src[i:i + 2]
        if depth:
            if two == "/*":
                depth += 1; i += 2; continue
            if two == "*/":
                depth -= 1; i += 2; continue
            i += 1; continue
        if two == "/*":
            depth = 1; i += 2; continue
        if two == "//":
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        ch = src[i]
        if ch == '"':
            # copy the literal verbatim, honouring backslash escapes
            out.append(ch); i += 1
            while i < n:
                if src[i] == "\\" and i + 1 < n:
                    out.append(src[i:i + 2]); i += 2; continue
                out.append(src[i])
                if src[i] == '"':
                    i += 1; break
                i += 1
            continue
        out.append(ch); i += 1
    return "".join(out)


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
    return _fold_concatenation(_fold_multiline(strip_comments(src)))


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
    """None when target's conversions are compatible with source's.

    Compatible means the same conversions are consumed, in one of two forms:

    * bare in both -- types must line up in order;
    * positional in the target -- indices must be exactly 1..n with no gaps or
      repeats, and the type at index i must match source's i-th conversion.

    The second case is not a defect but the CORRECT way to reorder arguments,
    and rejecting it would block the safest thing a translator can do. What is
    always a defect is dropping, adding, repeating or retyping a conversion:
    `String(format:)` then reads the wrong argument, which is undefined
    behaviour in a release build.
    """
    src, tgt = _specifiers(source), _specifiers(target)
    src_types = [t for _i, t in src]
    if any(i for i, _t in tgt):                      # target uses positional form
        if any(not i for i, _t in tgt):
            return "target mixes positional and bare conversions"
        idx = sorted(int(i) for i, _t in tgt)
        if idx != list(range(1, len(src_types) + 1)):
            return f"target indices {idx} are not exactly 1..{len(src_types)}"
        for i, ty in tgt:
            want = src_types[int(i) - 1]
            if ty != want:
                return f"%{i}$ is {ty!r} in target but {want!r} in source"
        return None

    if src_types != [t for _i, t in tgt]:            # both bare: order must hold
        return f"source {src_types} != target {[t for _i, t in tgt]}"
    return None


# --------------------------------------------------------------- key hygiene

def is_identifier_key(key: str) -> bool:
    """True for symbol-shaped keys (CarPlay.Error.offline, IncreaseFontSize).

    These matter because Foundation returns the key on a miss: a prose key
    degrades to readable English, an identifier key degrades to gibberish.
    """
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.]*", key):
        return False
    # Trailing ellipsis is prose punctuation, not namespacing: "Loading..."
    # renders correctly on a miss and must not be flagged.
    stem = key.rstrip(".")
    return bool(re.search(r"[a-z][A-Z]", stem) or "_" in stem or "." in stem)


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



# ------------------------------------------------- unsafe-degradation checking

_VALUE_ARG = (r'"{key}"\s*,\s*(?:tableName\s*:[^,]*,\s*)?(?:bundle\s*:[^,]*,\s*)?'
              r'value\s*:\s*"(?:[^"\\]|\\.)+"')


def has_value_fallback(src: str, key: str) -> bool:
    """True when this key's call site supplies a non-empty `value:`.

    Foundation returns `value` when the key is absent, so such a call degrades
    to readable English. Verified: value nil -> the key; value "Chapters" ->
    "Chapters"; value "" -> the key (empty is treated as absent).
    """
    return re.search(_VALUE_ARG.format(key=re.escape(key)), src, re.S) is not None


def scan_unsafe_keys(paths: list[Path]) -> list[tuple[str, str]]:
    """Identifier-shaped keys that would render raw to the user on a miss.

    A prose key degrades to readable English because the key IS the English.
    An identifier-shaped key degrades to gibberish -- unless its call site
    supplies `value:`. Those are the only ones that need backfilling.
    """
    unsafe: list[tuple[str, str]] = []
    for base in paths:
        files = [base] if base.is_file() else [p for p in base.rglob("*") if p.suffix in SOURCE_SUFFIXES]
        for f in files:
            try:
                raw = f.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            keys, _ = extract_swift(raw)
            for key in keys:
                if is_identifier_key(key) and not has_value_fallback(preprocess(raw), key):
                    unsafe.append((key, str(f)))
    return sorted(set(unsafe))


def stringsdict_keys(root: Path, lang: str) -> set[str] | None:
    """Top-level keys of a language's .stringsdict, or None when absent."""
    import plistlib
    try:
        with open(root / f"{lang}.lproj" / "Localizable.stringsdict", "rb") as fh:
            return set(plistlib.load(fh))
    except (FileNotFoundError, OSError):
        return None


def check_stringsdict(root: Path, langs: list[str]) -> list[Finding]:
    """Plural tables must carry identical key sets across languages.

    `.stringsdict` has the same no-per-key-fallback behaviour as `.strings`:
    a language whose dict EXISTS but lacks a key renders that key verbatim.
    """
    present = {l: k for l in langs if (k := stringsdict_keys(root, l)) is not None}
    if not present:
        return []
    every = set().union(*present.values())
    return [Finding("stringsdict_missing_key", l, k, "renders the key verbatim")
            for l, keys in sorted(present.items()) for k in sorted(every - keys)]


# ------------------------------------------------ canonical-variant matching

# Both repos ship strings that resolve against the app bundle, so an inventory
# scoped to one of them under-reports and then reports the other's live strings
# as dead.
DEFAULT_SOURCES = ["Palace", "ios-audiobooktoolkit/PalaceAudiobookToolkit"]

# Paths whose strings never reach a patron. Excluded from translation scope.
_DEVELOPER_PATH = re.compile(r"DeveloperSettings|Settings/Debug|MockBackend|DebugMenu", re.I)

_POSITIONAL = re.compile(r"%(\d+)\$")
_CURLY = {"\u2019": "'", "\u2018": "'", "\u201c": '"', "\u201d": '"',
          "\u2026": "...", "\u00a0": " "}


def unescape(s: str) -> str:
    r"""Decode .strings escapes. Keys carry \" and \n; the CDS stores them decoded,
    so an escaped key never matches its own translation without this."""
    return (s.replace('\\"', '"').replace("\\n", "\n")
             .replace("\\t", "\t").replace("\\\\", "\\"))


def canonical(s: str) -> str:
    """Fold differences that are mechanical rather than semantic.

    A recase ("Add bookmark" vs "Add Bookmark") or a specifier-form change
    ("%d hours" vs "%1$d hours") changes the KEY while leaving the translation
    correct. Without folding, both orphan a translation the project already
    owns and already paid for.
    """
    import unicodedata
    s = unicodedata.normalize("NFKC", unescape(s))
    for a, b in _CURLY.items():
        s = s.replace(a, b)
    s = _POSITIONAL.sub("%", s)
    return re.sub(r"\s+", " ", s).strip().lower().rstrip(" .:")


def is_developer_path(path: str) -> bool:
    """True for source that ships only to developers."""
    return _DEVELOPER_PATH.search(str(path)) is not None


def load_migrations(path: Path) -> dict[str, str]:
    """old key -> current key, for translations carried across a key change.

    Absent file is normal (most trees have no migrations pending), not an error.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            return {str(k): str(v) for k, v in json.load(fh).items()}
    except (FileNotFoundError, OSError, ValueError):
        return {}


# ------------------------------------------------------------ writing tables

def _escape(s: str) -> str:
    """Escape a value for a .strings literal."""
    return (s.replace("\\", "\\\\").replace('"', '\\"')
             .replace("\n", "\\n").replace("\t", "\\t"))


def render_strings(mapping: dict[str, str], comments: dict[str, str]) -> str:
    """Render a .strings table.

    Sorted by key so a re-render produces no diff noise and a real change is
    visible in review -- the ticket asks for a reviewable diff, and an
    unstable order destroys that.
    """
    out: list[str] = []
    for key in sorted(mapping):
        note = comments.get(key)
        if note:
            out.append(f"/* {note} */")
        out.append(f'"{_escape(key)}" = "{_escape(mapping[key])}";')
        out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def validate_translations(candidate: dict[str, str], source: dict[str, str]) -> list[Finding]:
    """Reject a batch before it reaches a table.

    A bad translation written to disk is worse than a missing one: it looks
    like coverage. Each check corresponds to a failure a patron would see --
    a crash (specifier), a blank label (empty), or a raw symbol (identifier).
    """
    findings: list[Finding] = []
    for key, value in sorted(candidate.items()):
        if not value or not value.strip():
            findings.append(Finding("empty_value", "", key, "renders as an empty label"))
            continue
        if is_identifier_key(value) and not is_identifier_key(key):
            findings.append(Finding("identifier_value", "", key,
                                    f"value {value!r} is a symbol, not a translation"))
        src = source.get(key)
        if src:
            bad = specifier_mismatch(src, value)
            if bad:
                findings.append(Finding("specifier_mismatch", "", key, bad))
    return findings

# ------------------------------------------------------------------ inventory

SOURCE_SUFFIXES = (".swift", ".m", ".mm")


def inventory(paths: list[Path], include_developer: bool = False
              ) -> tuple[set[str], dict[str, list[str]]]:
    """Localizable keys across the given roots.

    Developer-only source is excluded by default: those strings never reach a
    patron, so counting them inflates the translation bill.
    """
    keys: set[str] = set()
    dynamic: dict[str, list[str]] = {}
    for base in paths:
        files = [base] if base.is_file() else [p for p in base.rglob("*") if p.suffix in SOURCE_SUFFIXES]
        for f in files:
            if not include_developer and is_developer_path(f):
                continue
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
        p.add_argument("--include-developer", action="store_true",
                       help="include strings that ship only to developers")
        p.add_argument("--json", action="store_true")

    a = ap.parse_args(argv)
    langs = [l.strip() for l in a.langs.split(",") if l.strip()]
    sources = a.source or [Path(p) for p in DEFAULT_SOURCES if Path(p).exists()]

    if a.cmd == "inventory":
        keys, dynamic = inventory(sources, a.include_developer)
        if a.json:
            print(json.dumps({"keys": sorted(keys), "dynamic": dynamic}, indent=1, ensure_ascii=False))
        else:
            print(f"{len(keys)} localizable keys; {sum(len(v) for v in dynamic.values())} dynamic sites")
            for key in sorted(keys):
                print("  ", key)
        return 0

    findings = check_tables(a.lproj_root, langs) + check_stringsdict(a.lproj_root, langs)

    if a.cmd == "status":
        # Coverage is measured against the keys the SOURCE actually asks for.
        # Comparing the tables only to each other reports 100% for a tree whose
        # tables are empty in every language, which is exactly backwards.
        wanted, _ = inventory(sources, a.include_developer)
        for l in langs:
            table = _read_table(a.lproj_root, l) or {}
            have = len(wanted & set(table))
            pct = 100.0 * have / len(wanted) if wanted else 100.0
            missing = len(wanted - set(table))
            extra = len(set(table) - wanted)
            print(f"  {l}: {have}/{len(wanted)} source keys ({pct:.1f}%)"
                  f"  missing={missing} not-in-source={extra}")
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
