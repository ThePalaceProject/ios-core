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



_SWIFT_ESCAPE = re.compile(r"\\u\{([0-9A-Fa-f]{1,8})\}|\\(.)")
_SIMPLE = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


def decode_swift_literal(s: str) -> str:
    r"""Decode Swift source escapes to the characters the compiler produces.

    The runtime key is the COMPILED literal: `"We can\u{2019}t"` is a string
    containing U+2019, not the seven characters of the escape. Carrying the
    escape text into a .strings key produces a key that never matches, and then
    escaping its backslash on write compounds it.
    """
    def repl(m: re.Match) -> str:
        if m.group(1) is not None:
            return chr(int(m.group(1), 16))
        return _SIMPLE.get(m.group(2), m.group(2))
    return _SWIFT_ESCAPE.sub(repl, s)


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
            keys.add(decode_swift_literal(literal))
        elif call in _RUNTIME_KEY_MACROS:
            dynamic.append(literal)
        else:
            keys.add(decode_swift_literal(normalize_interpolation(literal)))
    for m in _MACRO_NONLITERAL.finditer(src):
        dynamic.append(m.group(0).strip())
    return keys, dynamic



# SwiftUI builds a type-specific specifier per interpolation, VERIFIED:
#   Text("\(Int) x")    -> "%lld x"
#   Text("\(Double) x") -> "%lf x"
#   Text("\(String) x") -> "%@ x"
# `genstrings` emits %@ for all three, so a key taken from genstrings (or from
# assuming %@) can never match at runtime and the string renders English
# forever, silently.
_INT_EXPR = re.compile(
    r"^\s*Int\s*\("            # an explicit Int(...) cast is decisive
    r"|^\s*\d+\s*$"            # an integer literal
    r"|\.count\b|\bcount\b|Count\b|Index\b|Retries\b|Retry\b"
    r"|[Pp]ercent\w*\b"         # percentComplete / progressPercentage are Int here
    r"|\bseconds\b|\bminutes\b|\bhours\b|\bdays\b|\blines\b")
# Deliberately no Double rule. Every candidate in this tree that "looked"
# floating-point turned out to be an Int cast or a String property, so a
# Double heuristic here produced only false positives. An explicit cast is
# the one signal worth trusting.
_DOUBLE_EXPR = re.compile(r"^\s*(?:Double|Float|CGFloat)\s*\(")


def infer_specifier(expr: str) -> str:
    """Best-effort specifier for one interpolated expression.

    Deliberately conservative: only clearly numeric shapes are narrowed, and
    every interpolated key is still reported as unconfirmed, because the only
    authoritative source is the compiler (`xcodebuild -exportLocalizations`).
    """
    e = expr.strip()
    if _DOUBLE_EXPR.search(e):
        return "%lf"
    if _INT_EXPR.search(e):
        return "%lld"
    return "%@"


def normalize_interpolation(literal: str) -> str:
    r"""Collapse SwiftUI \(...) segments to %@, as LocalizedStringKey does.

    Nesting-aware: \(a.map { "\($0)" }) must consume its own parentheses.
    The specifier is approximated as %@ (SwiftUI emits type-specific forms such
    as %lld for Int), so these keys are reported for confirmation rather than
    trusted blindly -- see `inventory --json` field "interpolated".
    """
    out, i = [], 0
    while i < len(literal):
        # SwiftUI builds a FORMAT STRING for an interpolated literal, so a
        # literal percent must be escaped exactly as SwiftUI escapes it.
        # Verified: Text("\(n)% complete") -> "%lld%% complete".
        if literal[i] == "%":
            out.append("%%"); i += 1; continue
        if literal.startswith(r"\(", i):
            depth, i = 1, i + 2
            start = i
            while i < len(literal) and depth:
                if literal[i] == "(":
                    depth += 1
                elif literal[i] == ")":
                    depth -= 1
                i += 1
            out.append(infer_specifier(literal[start:i - 1]))
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
    """Parse a .strings file into real characters.

    In-memory strings are always decoded and the file is always escaped, so
    render(parse(render(x))) == render(x). Preserving escapes here instead made
    every read-merge-write cycle double the backslashes.
    """
    return {unescape(m.group(1)): unescape(m.group(2))
            for m in _STRINGS_ENTRY.finditer(_COMMENT_BLOCK.sub("", text))}


def _read_table(root: Path, lang: str) -> dict[str, str] | None:
    for enc in ("utf-8", "utf-16"):
        try:
            return parse_strings((root / f"{lang}.lproj" / "Localizable.strings").read_text(encoding=enc))
        except FileNotFoundError:
            return None
        except (UnicodeDecodeError, UnicodeError):
            continue
    return None


def check_tables(root: Path, langs: list[str],
                 source: dict[str, str] | None = None,
                 require: set[str] | None = None,
                 report: tuple[Path, list[Path]] | None = None) -> list[Finding]:
    """Findings across the committed tables. Empty list means a clean tree."""
    tables = {l: _read_table(root, l) for l in langs}
    findings: list[Finding] = []

    for lang, table in tables.items():
        if table is None:
            findings.append(Finding("missing_table", lang, "", f"no {lang}.lproj/Localizable.strings"))
    present = {l: t for l, t in tables.items() if t is not None}

    if report is not None:
        # A generated document that nobody is forced to regenerate drifts, and a
        # stale coverage report is worse than none: it reads as current.
        doc, doc_sources = report
        if not report_is_current(doc, doc_sources, root, langs):
            findings.append(Finding("stale_report", "", str(doc),
                                    "does not describe the current tables — "
                                    "run: python3 scripts/palace_strings.py report"))

    if require:
        # A source key absent from EVERY table is a string someone added and
        # never translated. This is the check that makes the loop work without
        # an AI in CI: detection is a set difference; only production needs one.
        # Evaluated before the no-tables early return, because a tree with no
        # tables at all is the strongest case of untranslated, not a reason to skip.
        have: set[str] = set().union(*(set(t) for t in present.values())) if present else set()
        # A plural key is translated in .stringsdict, not .strings. Counting only
        # the .strings tables reports every plural as untranslated forever.
        for lang in langs:
            have |= stringsdict_keys(root, lang) or set()
        for key in sorted(require - have):
            findings.append(Finding("untranslated", "", key,
                                    "new source string with no translation in any language"))

    if not present:
        return findings

    # English lives in the CODE. `en.lproj/Localizable.strings` is not wired
    # into the Xcode project, so a committed en table would never ship and
    # could drift from the source silently. Prefer the extracted source map.
    source_lang = langs[0]
    if source is None:
        source = present.get(source_lang, {})
    else:
        source_lang = "<source>"
    every_key: set[str] = set().union(*(set(t) for t in present.values()))

    for lang, table in present.items():
        for key in sorted(every_key - set(table)):
            findings.append(Finding("missing_key", lang, key,
                                    "Foundation returns the key itself on a per-key miss"))
        for key, value in sorted(table.items()):
            if not value.strip():
                findings.append(Finding("empty_value", lang, key, "renders as an empty label"))
            if _HTML_ENTITY.search(value):
                findings.append(Finding("html_entity", lang, key,
                                        "HTML entity encoding renders literally to a patron"))
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
    """Escape a value for a .strings literal, idempotently.

    `parse_strings` preserves escapes rather than decoding them, so escaping a
    value that is already escaped doubles its backslashes -- and an apply cycle
    that reads, merges and rewrites does exactly that, silently, every run.
    Normalising first makes render(parse(render(x))) == render(x).
    """
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


_HTML_ENTITY = re.compile(r"&(?:quot|apos|amp|lt|gt|nbsp|#\d+|#x[0-9A-Fa-f]+);")
# Invisible characters that survive a copy-paste or a bad export and are
# impossible to see in review. U+00A0 is EXCLUDED: French typography requires it
# before ? ! : ; and flagging it would fight the style guide.
_INVISIBLE = re.compile(r"[\u200b-\u200f\u2028\u2029\ufeff\u00ad]")
_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def decode_html_entities(s: str) -> str:
    """Decode HTML entities that leaked into a translation.

    A `.strings` value is not HTML. `&#39;` reaches the patron as those five
    characters, not an apostrophe.
    """
    import html
    return html.unescape(s)


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
        if _HTML_ENTITY.search(value):
            findings.append(Finding("html_entity", "", key,
                                    "value carries HTML entity encoding; a .strings value "
                                    "is not HTML and renders it literally"))
        if _INVISIBLE.search(value):
            findings.append(Finding("invisible_character", "", key,
                                    "zero-width or bidi character — invisible in review, "
                                    "breaks search and comparison"))
        if _CONTROL.search(value):
            findings.append(Finding("control_character", "", key,
                                    "control character in a user-facing string"))
        src_for_ws = source.get(key)
        if src_for_ws is not None and value != value.strip() and src_for_ws == src_for_ws.strip():
            findings.append(Finding("stray_whitespace", "", key,
                                    "leading/trailing whitespace the English does not have"))
        src = source.get(key)
        if src:
            bad = specifier_mismatch(src, value)
            if bad:
                findings.append(Finding("specifier_mismatch", "", key, bad))
    return findings

# ------------------------------------------------------------------ inventory

SOURCE_SUFFIXES = (".swift", ".m", ".mm")
ALLOWLIST_PATH = Path(__file__).resolve().parent / "l10n-untranslated-allowlist.json"


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


def inventory_detailed(paths: list[Path], include_developer: bool = False):
    """(keys, dynamic, unconfirmed) -- unconfirmed are interpolated SwiftUI keys
    whose specifier was inferred statically and needs compiler confirmation."""
    keys, dynamic = inventory(paths, include_developer)
    unconfirmed: list[str] = []
    for base in paths:
        files = [base] if base.is_file() else [p for p in base.rglob("*") if p.suffix in SOURCE_SUFFIXES]
        for f in files:
            if not include_developer and is_developer_path(f):
                continue
            try:
                src = preprocess(f.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                continue
            for m in _CALL_LITERAL.finditer(src):
                call, lit = m.group(1), m.group(2)
                if r"\(" in lit and call not in _RUNTIME_KEY_MACROS:
                    unconfirmed.append(normalize_interpolation(lit))
    return keys, dynamic, sorted(set(unconfirmed))



_VALUE_CALL = re.compile(
    r'\b(?:NSLocalizedString|CFCopyLocalizedString)\s*\(\s*"((?:[^"\\]|\\.)*)"'
    r'(?:\s*,\s*tableName\s*:[^,]*)?(?:\s*,\s*bundle\s*:[^,]*)?'
    r'\s*,\s*value\s*:\s*"((?:[^"\\]|\\.)*)"', re.S)


def source_map(paths: list[Path], include_developer: bool = False) -> dict[str, str]:
    """key -> the English the runtime falls back to.

    For a prose key that is the key itself. For an identifier key it is the
    `value:` argument, and using the key instead would compare a translation
    against a string carrying none of its format specifiers.
    """
    keys, _ = inventory(paths, include_developer)
    out = {k: k for k in keys}
    for base in paths:
        files = [base] if base.is_file() else [p for p in base.rglob("*") if p.suffix in SOURCE_SUFFIXES]
        for f in files:
            if not include_developer and is_developer_path(f):
                continue
            try:
                src = preprocess(f.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                continue
            for m in _VALUE_CALL.finditer(src):
                k = decode_swift_literal(m.group(1))
                if k in out and m.group(2):
                    out[k] = decode_swift_literal(m.group(2))
    return out



# --------------------------------------------------- work-file export/import

def load_allowlist(path: Path) -> dict[str, str]:
    """key -> why it is deliberately untranslated.

    Every entry carries a reason so the list cannot quietly become a dumping
    ground, and so a reviewer can see what was waived and on what grounds.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            return {str(k): str(v) for k, v in (json.load(fh).get("skip") or {}).items()}
    except (FileNotFoundError, OSError, ValueError):
        return {}


def build_work_file(sources: list[Path], lproj_root: Path, langs: list[str],
                    include_developer: bool = False,
                    allowlist: dict[str, str] | None = None) -> dict:
    """The keys that still need a translation, as a fillable document.

    Deliberately a plain data file rather than an agent-only path: whoever
    fills it -- a translation skill, a contractor, a volunteer with a
    spreadsheet -- hands it back to `apply_work_file`, which validates the
    same way regardless. The AI is a pluggable producer, not a dependency.
    """
    keys, _ = inventory(sources, include_developer)
    english = source_map(sources, include_developer)
    comments = _comment_map(sources, include_developer)
    have = {l: set(_read_table(lproj_root, l) or {}) for l in langs}
    rows = []
    for key in sorted(keys):
        if is_format_only(key) or key in (allowlist or {}):
            continue
        missing = [l for l in langs if key not in have[l]]
        if not missing:
            continue
        row = {"key": key, "english": english.get(key, key),
               "comment": comments.get(key, ""), "needs": missing}
        for l in langs:
            row[l] = "" if l in missing else (_read_table(lproj_root, l) or {}).get(key, "")
        rows.append(row)
    return {"languages": list(langs),
            "instructions": ("Fill the language fields for each string. Copy every format "
                             "specifier verbatim -- identical set, count and type. Leave a "
                             "field blank to skip it; blanks are ignored, never written."),
            "strings": rows}


def _comment_map(sources: list[Path], include_developer: bool = False) -> dict[str, str]:
    """key -> the developer comment, which is the only context a translator gets."""
    pat = re.compile(
        r'\b(?:NSLocalizedString|CFCopyLocalizedString)\s*\(\s*"((?:[^"\\]|\\.)*)"'
        r'(?:[^)]*?)comment\s*:\s*"((?:[^"\\]|\\.)*)"', re.S)
    out: dict[str, str] = {}
    for base in sources:
        files = [base] if base.is_file() else [p for p in base.rglob("*") if p.suffix in SOURCE_SUFFIXES]
        for f in files:
            if not include_developer and is_developer_path(f):
                continue
            try:
                src = preprocess(f.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                continue
            for m in pat.finditer(src):
                k = decode_swift_literal(m.group(1))
                if m.group(2):
                    out.setdefault(k, decode_swift_literal(m.group(2)))
    return out


def apply_work_file(work: dict, sources: list[Path], lproj_root: Path,
                    include_developer: bool = False) -> list[Finding]:
    """Validate a filled work file and write it. Returns findings; writes nothing if any.

    All-or-nothing on purpose: a half-applied batch leaves the tables in a state
    nobody chose, and the whole point of the gate is that what lands is what was
    reviewed.
    """
    keys, _ = inventory(sources, include_developer)
    english = source_map(sources, include_developer)
    langs = work.get("languages") or []
    findings: list[Finding] = []
    staged: dict[str, dict[str, str]] = {l: {} for l in langs}

    for row in work.get("strings", []):
        key = row.get("key", "")
        if key not in keys:
            findings.append(Finding("unknown_key", "", key, "not present in the source"))
            continue
        for l in langs:
            value = (row.get(l) or "").strip()
            if not value:
                continue                      # blank means "not my language / not yet"
            staged[l][key] = value

    for l in langs:
        findings.extend(Finding(f.kind, l, f.key, f.detail)
                        for f in validate_translations(staged[l], english))
    if findings:
        return findings

    for l in langs:
        if not staged[l]:
            continue
        p = lproj_root / f"{l}.lproj" / "Localizable.strings"
        existing = _read_table(lproj_root, l) or {}
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(render_strings({**existing, **staged[l]}, _comment_map(sources, include_developer)),
                     encoding="utf-8")
    return []


# ----------------------------------------------------- status report + staleness

REPORT_FINGERPRINT_MARKER = "<!-- l10n-state:"
REPORT_PATH = Path("docs/Operations/localization-status.md")


def state_fingerprint(sources: list[Path], lproj_root: Path, langs: list[str],
                      include_developer: bool = False) -> str:
    """A hash over everything the report describes.

    Covers the SOURCE keys and every shipped value, so adding a string,
    translating one, or editing one all change it. That is what lets a stale
    report be detected mechanically rather than remembered.
    """
    import hashlib
    keys, _ = inventory(sources, include_developer)
    h = hashlib.sha256()
    for k in sorted(keys):
        h.update(k.encode("utf-8")); h.update(b"\x00")
    for lang in langs:
        h.update(lang.encode("utf-8")); h.update(b"\x01")
        for k, v in sorted((_read_table(lproj_root, lang) or {}).items()):
            h.update(k.encode("utf-8")); h.update(b"\x02")
            h.update(v.encode("utf-8")); h.update(b"\x03")
    return h.hexdigest()[:16]


def build_report(sources: list[Path], lproj_root: Path, langs: list[str],
                 include_developer: bool = False) -> str:
    """The committed status document. Regenerated, never hand-edited."""
    keys, _, unconfirmed = inventory_detailed(sources, include_developer)
    allow = load_allowlist(ALLOWLIST_PATH)
    fmt = {k for k in keys if is_format_only(k)}
    translatable = keys - fmt - set(allow)
    tables = {l: (_read_table(lproj_root, l) or {}) for l in langs}
    fp = state_fingerprint(sources, lproj_root, langs, include_developer)

    lines = [
        "# Localization status",
        "",
        "**Generated — do not hand-edit.** Regenerate with:",
        "",
        "```bash",
        "python3 scripts/palace_strings.py report",
        "```",
        "",
        "`palace_strings.py check` fails when this document does not describe the "
        "current tables, so it cannot drift silently.",
        "",
        "## Coverage",
        "",
        "| Language | Translated | Of translatable | Missing |",
        "|---|---:|---:|---:|",
    ]
    for lang in langs:
        have = len(translatable & set(tables[lang]))
        pct = 100.0 * have / len(translatable) if translatable else 100.0
        lines.append(f"| {lang} | {have} | {pct:.1f}% | {len(translatable) - have} |")

    lines += [
        "",
        "## Scope",
        "",
        f"- **{len(keys)}** localizable keys in the source (app + audiobook toolkit).",
        f"- **{len(fmt)}** {'is' if len(fmt) == 1 else 'are'} format-only "
        "(`%@ %@`, `%02d:%02d`) with nothing to translate.",
        f"- **{len(allow)}** {'is' if len(allow) == 1 else 'are'} deliberately "
        "untranslated; see `scripts/l10n-untranslated-allowlist.json`, which records "
        "a reason for each.",
        f"- **{len(translatable)}** are therefore in scope.",
        "",
        "## Needs confirmation",
        "",
        f"**{len(unconfirmed)}** interpolated SwiftUI keys have a statically inferred "
        "format specifier. SwiftUI builds `%lld` for an `Int` and `%lf` for a `Double`, "
        "and escapes a literal `%` to `%%`; the inference is a heuristic and the "
        "authoritative answer is `xcodebuild -exportLocalizations`.",
        "",
        "## Reviewing the translations",
        "",
        "This document reports COVERAGE, not quality. Nothing here means a native "
        "speaker has read anything. To produce a packet for linguistic review:",
        "",
        "```bash",
        "python3 scripts/palace_strings.py packet --file /tmp/review-packet",
        "```",
        "",
        "See `docs/Operations/localization-workflow.md` for how strings are added "
        "and translated.",
        "",
        f"{REPORT_FINGERPRINT_MARKER} {fp} -->",
        "",
    ]
    return "\n".join(lines)


def report_is_current(path: Path, sources: list[Path], lproj_root: Path,
                      langs: list[str], include_developer: bool = False) -> bool:
    """True when the report on disk describes the current state."""
    try:
        text = path.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError):
        return False
    want = state_fingerprint(sources, lproj_root, langs, include_developer)
    return f"{REPORT_FINGERPRINT_MARKER} {want} -->" in text



_BRIEF = """# Palace iOS — translation review packet

Product: Palace, a public-library reading app (ebooks and audiobooks), iOS.
Source language: English. Languages under review: {langs}.
{count} strings, {values} translated values.

## What this is, and what it is not

**No native speaker has reviewed any of this.** That is the gap this review
closes. Nothing in these files is a linguistic endorsement.

What was checked is mechanical only and says nothing about whether the language
is good:

| checked automatically | NOT checked |
| --- | --- |
| Format specifiers match the source in set, count and type | Whether it reads naturally |
| No empty values | Register and formality |
| No value is a symbol name instead of a translation | Library-domain terminology |
| Key sets identical across languages | Gender, agreement, idiom |
| Tables parse and load at runtime | Whether a term matches the patron's own library |

## Constraints on any replacement you suggest

1. **Format specifiers must survive verbatim** — `%@`, `%d`, `%lld`, and
   positional `%1$@` / `%2$@` — identical in set, count and type. Reordering is
   allowed only by switching to positional form. A dropped or retyped specifier
   is undefined behaviour at runtime, not a cosmetic slip.
2. **Length matters in places.** German runs ~30% longer than English; CarPlay
   strings render on a dashboard with hard width limits; tab and button labels
   truncate. The `len_ratio` column flags candidates.
3. **Do NOT abbreviate accessibility strings.** Many are spoken by VoiceOver
   rather than displayed; they have no layout budget and clarity beats brevity.
4. **Do not translate** product and format names: Palace, Adobe, LCP, Readium,
   OverDrive, Bibliotheca, Axis 360, AirPlay, CarPlay, ePub, PDF, VoiceOver.

## Where to start

`REVIEW_verdict`, `REVIEW_suggested_replacement` and `REVIEW_notes` are empty
columns for you. `developer_comment` is the context the engineer wrote and is
often the only clue to intent.

Questions we would most value judgement on:

- **Formality.** Is the register right for a public-library app in each
  language? This decision touches nearly every string.
- **Library terminology** — borrow, hold/reservation, return, loan, copies.
  Does each match what a patron meets in their own library's catalogue?
- **Agreement around placeholders.** `%@` is usually a book title whose gender
  is unknown when the string is written. Translations recast to avoid agreeing
  with it — did that succeed, or does it read stiffly?
- **Anything where the ENGLISH is the problem.** If a string cannot be
  translated well because the source is ambiguous or assembles a sentence from
  fragments, say so — the English can change.

A severity signal helps: **critical** (wrong meaning, or the transaction is
inverted), **major** (unnatural, wrong register, internally inconsistent),
**minor** (preference).
"""


def _reviewer_brief(langs: list[str], count: int) -> str:
    return _BRIEF.format(langs=", ".join(langs), count=count, values=count * len(langs))


def build_packet(sources: list[Path], lproj_root: Path, langs: list[str],
                 out_dir: Path, include_developer: bool = False) -> dict:
    """CSVs for an outside linguistic reviewer, plus the termbase they follow."""
    import csv as _csv
    out_dir.mkdir(parents=True, exist_ok=True)
    english = source_map(sources, include_developer)
    comments = _comment_map(sources, include_developer)
    tables = {l: (_read_table(lproj_root, l) or {}) for l in langs}
    keys = sorted(set().union(*(set(t) for t in tables.values())) if tables else set())

    for lang in langs:
        with open(out_dir / f"{lang}.csv", "w", newline="", encoding="utf-8-sig") as fh:
            w = _csv.writer(fh)
            w.writerow(["key", "english", "translation", "developer_comment",
                        "len_en", "len_target", "len_ratio",
                        "REVIEW_verdict", "REVIEW_suggested_replacement", "REVIEW_notes"])
            for k in keys:
                en, tg = english.get(k, k), tables[lang].get(k, "")
                ratio = f"{len(tg)/len(en):.2f}" if en else ""
                w.writerow([k, en, tg, comments.get(k, ""), len(en), len(tg), ratio, "", "", ""])
    (out_dir / "README.md").write_text(_reviewer_brief(langs, len(keys)), encoding="utf-8")
    glossary = Path(".claude/skills/translate/references/glossary.md")
    if glossary.is_file():
        (out_dir / "glossary-used.md").write_text(glossary.read_text(encoding="utf-8"),
                                                  encoding="utf-8")
    return {"languages": list(langs), "strings": len(keys),
            "values": len(keys) * len(langs), "dir": str(out_dir)}

# ------------------------------------------------------------------------ CLI

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    for name in ("inventory", "status", "check", "export", "import", "report", "packet"):
        p = sub.add_parser(name)
        p.add_argument("--lproj-root", type=Path, default=Path("Palace"))
        p.add_argument("--langs", default="en,de,es,fr,it")
        p.add_argument("--source", type=Path, action="append", default=None)
        p.add_argument("--include-developer", action="store_true",
                       help="include strings that ship only to developers")
        p.add_argument("--json", action="store_true")
        p.add_argument("--file", type=Path,
                       help="work file to write (export) or read (import)")
        p.add_argument("--require-complete", action="store_true",
                       help="also fail when a source string has no translation at all")

    a = ap.parse_args(argv)
    langs = [l.strip() for l in a.langs.split(",") if l.strip()]
    if a.source:
        sources = a.source
    else:
        sources = [Path(p) for p in DEFAULT_SOURCES]
        # Skipping an absent root silently is the worst available behaviour: the
        # tool keeps working, prints a smaller inventory, demands fewer
        # translations, and produces a report fingerprint no full checkout can
        # ever match. CI ran exactly that way — 556 of 592 keys graded, the other
        # 36 never checked in any language — and the only symptom was a
        # `stale_report` finding that looked like someone had forgotten to
        # regenerate a document.
        missing = [p for p in sources if not p.exists()]
        if missing:
            for p in missing:
                print(f"source root not found: {p}")
            print("The inventory spans both repos. Check out the submodule "
                  "(git submodule update --init ios-audiobooktoolkit) or name "
                  "the roots explicitly with --source.")
            return 2

    if a.cmd == "report":
        out = a.file or REPORT_PATH
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(build_report(sources, a.lproj_root, langs, a.include_developer),
                       encoding="utf-8")
        print(f"wrote {out}")
        return 0

    if a.cmd == "packet":
        out = a.file or Path("l10n-review-packet")
        info = build_packet(sources, a.lproj_root, langs, out, a.include_developer)
        print(f"{info['strings']} string(s) x {len(info['languages'])} language(s) "
              f"= {info['values']} values -> {info['dir']}")
        print("  one CSV per language with empty REVIEW_ columns, plus the glossary.")
        return 0

    if a.cmd == "export":
        work = build_work_file(sources, a.lproj_root, langs, a.include_developer,
                               load_allowlist(ALLOWLIST_PATH))
        out = a.file or Path("l10n-work.json")
        out.write_text(json.dumps(work, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        n = len(work["strings"])
        print(f"{n} string(s) need translation -> {out}")
        if n:
            print("  fill the language fields, then: "
                  f"python3 scripts/palace_strings.py import --file {out}")
        return 0

    if a.cmd == "import":
        src = a.file or Path("l10n-work.json")
        try:
            work = json.loads(src.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            print(f"cannot read {src}: {exc}")
            return 1
        findings = apply_work_file(work, sources, a.lproj_root, a.include_developer)
        for f in findings[:40]:
            print(f"  {f.kind:20} {f.lang:3} {f.key!r} {f.detail}")
        if findings:
            print(f"REJECTED {len(findings)} finding(s) — nothing written")
            return 1
        filled = sum(1 for r in work.get("strings", [])
                     for l in work.get("languages", []) if (r.get(l) or "").strip())
        print(f"OK — applied {filled} value(s)")
        return 0

    if a.cmd == "inventory":
        keys, dynamic = inventory(sources, a.include_developer)
        if a.json:
            print(json.dumps({"keys": sorted(keys), "dynamic": dynamic}, indent=1, ensure_ascii=False))
        else:
            print(f"{len(keys)} localizable keys; {sum(len(v) for v in dynamic.values())} dynamic sites")
            for key in sorted(keys):
                print("  ", key)
        return 0

    _req = None
    if a.require_complete:
        _allow = load_allowlist(ALLOWLIST_PATH)
        _req = {k for k in inventory(sources, a.include_developer)[0]
                if not is_format_only(k) and k not in _allow}
    _report = (REPORT_PATH, sources) if a.require_complete and REPORT_PATH.exists() else None
    findings = (check_tables(a.lproj_root, langs, source_map(sources, a.include_developer),
                             _req, _report)
                + check_stringsdict(a.lproj_root, langs))

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
