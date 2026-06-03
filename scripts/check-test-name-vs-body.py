#!/usr/bin/env python3
"""
check-test-name-vs-body.py — runnable-grep escalation for fake-wiring tests.

Detects Swift XCTest methods whose names embed a multi-step verb
(`Path`, `via`, `through`, `invokes`, `roundtrip`, `across`, `inProduction`,
`viaX`, `Wiring`) AND a PascalCase production-class noun, but whose bodies
never reference that noun (no instantiation, no static call, no type annotation).

Catches the fake-wiring-test pattern documented in:
  - .forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md
  - .forgeos/wall-failures/2026-05-28-cs9a267b63-arch1.md

Usage:
  python3 scripts/check-test-name-vs-body.py [--quiet] <test-file> [<test-file> ...]

Exit codes:
  0 — all multi-step test names have matching bodies (or no multi-step names found)
  1 — at least one multi-step test name has a body that doesn't reference the embedded noun
  2 — argument / file-read error

Output (greppable): <file>:<lineno>: <testname>: claims '<noun>' but body has no reference
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# --- Configuration ---------------------------------------------------------

# Test names containing any of these case-insensitive tokens are "multi-step"
# claims. Their bodies are then scanned for the embedded class noun.
MULTI_STEP_VERBS = (
    "path", "via", "through", "invokes", "roundtrip",
    "across", "inproduction", "viax", "wiring",
)

# PascalCase tokens that are never production-class nouns. Case-sensitive.
NOISE_NOUNS = frozenset((
    # Verbs / prepositions / verbs-as-PascalCase test-name tokens:
    "Path Via Through Invokes Roundtrip Across InProduction Wiring ViaX "
    "When Then Should Returns For From With After Before And Or If Else "
    "Drives Fires Publishes Clears Resets Reads Writes Sends Receives "
    "Handles Processes Calls Test Tests TestCase "
    # XCTest framework:
    "XCTestCase XCTAssert XCTAssertEqual XCTAssertTrue XCTAssertFalse "
    "XCTAssertNil XCTAssertNotNil XCTestExpectation XCTSkip "
    # Foundation primitives / common types:
    "String Int Bool URL URLRequest URLResponse URLSession Data Date Set "
    "Array Dictionary Double Float UInt Optional Error Result Void Any Self Type "
    # Concurrency:
    "MainActor Task Combine Publisher Subscriber AnyCancellable "
    "DispatchQueue DispatchGroup "
    # SwiftUI / UIKit:
    "View UIView UIViewController UIWindow UIApplication Bundle "
    # Generic test-vocabulary words:
    "Completion Callback Closure Block State Status Action Event Notification "
    "Driver Presenter Receiver Sender Outcome Response Request "
    "Account User Patron Library Catalog Book Page Item Entry Record "
    "Modal Sheet Alert Dialog Popup Button Label Field Cell Row "
    "Spy Stub Fake Mock Recorder Token Credential Credentials Header Headers "
    "Body Payload Message Source Target Origin Destination "
    "Setup Teardown Fixture Step Phase Round Pass "
    "Default Initial Final Terminal Current Previous Next Last First "
    "New Old Active Inactive Pending Valid Invalid Empty Full None Some "
    "True False Yes No Foo Bar Baz Qux"
).split())

# A token whose FIRST CamelCase word is in this set is a descriptive phrase,
# not a class noun — e.g. `RoundTripsThroughOPDS2CatalogsFeedDecoder` ends in
# `Decoder` (a suffix that LOOKS class-like) but starts with `Round`.
LEADING_VERB_OR_ADJECTIVE_WORDS = frozenset((
    "Round Through With Without Across Past Via "
    "Completion Production Development Mock Fake Stub "
    "Empty Full Valid Invalid New Old Default Current Previous "
    "Initial Final Custom Generic Single Multiple Real Bidirectional "
    "Helper Bridge Helpers"
).split())

# Tokens that look class-like must EITHER:
#   - start with a known Palace/Apple class-prefix acronym + Title-cased word
#   - end with a recognized class-name suffix
# This is intentionally conservative; the wall-failure shapes
# (TPPReauthenticator, AudiobookSessionManager) both pass.
PALACE_CLASS_PREFIXES = ("TPP", "NYPL")
PALACE_CLASS_PREFIX_RE = re.compile(
    r"^(?:" + "|".join(PALACE_CLASS_PREFIXES) + r")[A-Z][a-z]"
)
CLASS_NAME_SUFFIXES = tuple((
    "Manager Service Coordinator Repository Store "
    "Dispatcher Executor Responder Resolver Provider "
    "Factory Builder Container Registry ViewModel Reducer Operation "
    "Client Session Connection Worker Engine Loader Parser "
    "Adapter Wrapper Facade "
    "Reauthenticator Authenticator Validator "
    "Subscriber Observer Listener Controller Delegate DataSource"
).split())

# Regex: func test*(...) declaration (captures the test name).
TEST_FUNC_RE = re.compile(r"\bfunc\s+(test[A-Za-z0-9_]*)\s*\([^)]*\)")

# Compound PascalCase identifier: greedy run from an uppercase letter.
PASCAL_RE = re.compile(r"[A-Z][A-Za-z0-9]*")

# CamelCase splitter: emits each capital-led word individually.
# "TPPReauthenticatorPath" → ["TPP", "Reauthenticator", "Path"]
# "ViaSafelyPresent"       → ["Via", "Safely", "Present"]
CAMEL_SPLIT_RE = re.compile(
    r"[A-Z]+(?=[A-Z][a-z])"   # acronym followed by another Title-cased word
    r"|[A-Z][a-z0-9]+"        # standard Title-cased word
    r"|[A-Z]+$"               # trailing acronym
)


def split_camel(token: str) -> list[str]:
    return CAMEL_SPLIT_RE.findall(token)


def looks_class_like(token: str) -> bool:
    """Heuristic: does this token look like a real Swift class identifier?"""
    words = split_camel(token)
    if words and words[0] in LEADING_VERB_OR_ADJECTIVE_WORDS:
        return False
    if PALACE_CLASS_PREFIX_RE.match(token):
        return True
    for suffix in CLASS_NAME_SUFFIXES:
        if token.endswith(suffix) and len(token) > len(suffix):
            return True
    return False


# --- Swift parsing ---------------------------------------------------------

def strip_strings_and_comments(swift_src: str) -> str:
    """Replace Swift string literals + comments with spaces (preserving offsets)."""
    out: list[str] = []
    i, n = 0, len(swift_src)
    while i < n:
        ch = swift_src[i]
        nxt = swift_src[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            while i < n and swift_src[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if ch == "/" and nxt == "*":
            out.append("  ")
            i += 2
            while i < n and not (swift_src[i] == "*" and i + 1 < n and swift_src[i + 1] == "/"):
                out.append("\n" if swift_src[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append("  ")
                i += 2
            continue
        if ch == "#" and nxt == '"':
            out.append("  ")
            i += 2
            while i < n:
                if swift_src[i] == '"' and i + 1 < n and swift_src[i + 1] == "#":
                    out.append("  ")
                    i += 2
                    break
                out.append("\n" if swift_src[i] == "\n" else " ")
                i += 1
            continue
        if ch == '"':
            out.append(" ")
            i += 1
            while i < n and swift_src[i] != '"':
                if swift_src[i] == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                    continue
                out.append("\n" if swift_src[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append(" ")
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def extract_method_body(swift_src: str, func_decl_start: int) -> tuple[str, int] | None:
    """Find `{ ... }` after the func decl by brace-matching."""
    open_idx = swift_src.find("{", func_decl_start)
    if open_idx < 0:
        return None
    depth = 1
    i, n = open_idx + 1, len(swift_src)
    while i < n and depth > 0:
        c = swift_src[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return swift_src[open_idx + 1 : i], i
        i += 1
    return None


# --- Noun extraction -------------------------------------------------------

def is_multi_step_name(test_name: str) -> bool:
    lower = test_name.lower()
    return any(verb in lower for verb in MULTI_STEP_VERBS)


def extract_candidate_nouns(test_name: str) -> list[str]:
    """
    From a test method name, extract candidate PascalCase production-class nouns.

    Algorithm:
      - Strip leading `test` + underscores.
      - Split on underscores; each segment yields candidates.
      - For segments starting uppercase, the whole segment is a candidate AND
        we peel trailing NOISE words (so `TPPReauthenticatorPath` → also yields
        `TPPReauthenticator`).
      - Verb-led segments contribute only their internal PascalCase tokens.
      - All candidates pass through NOISE_NOUNS + looks_class_like filters.
      - Sorted longest-first so the most-specific noun is reported first.
    """
    body = test_name[len("test"):] if test_name.startswith("test") else test_name
    body = body.lstrip("_")

    candidates: list[str] = []
    seen: set[str] = set()

    def maybe_add(tok: str) -> None:
        if not tok or tok in seen or tok in NOISE_NOUNS or len(tok) < 3:
            return
        if not looks_class_like(tok):
            return
        seen.add(tok)
        candidates.append(tok)

    for seg in body.split("_"):
        if not seg:
            continue
        if not seg[:1].isupper():
            # Verb-led segment: yield internal PascalCase tokens only.
            for tok in split_camel(seg):
                maybe_add(tok)
            continue
        # Uppercase-led segment: full segment + peeled forms + individual words.
        maybe_add(seg)
        words = split_camel(seg)
        if len(words) >= 2:
            peeled = words[:]
            while len(peeled) >= 2 and peeled[-1] in NOISE_NOUNS:
                peeled = peeled[:-1]
                maybe_add("".join(peeled))
            for w in words:
                maybe_add(w)

    candidates.sort(key=len, reverse=True)
    return candidates


# --- Body-reference check --------------------------------------------------

def _camel_property_form(noun: str) -> str | None:
    """Convert PascalCase noun to its camelCase property form, or None if no-op."""
    if not noun or not noun[0].isupper():
        return None
    i = 0
    while i < len(noun) and noun[i].isupper():
        i += 1
    if i >= len(noun) or i == 1:
        # Single leading cap OR all-caps: lowercase first char.
        camel = noun[0].lower() + noun[1:]
    else:
        # Multi-cap acronym: lowercase all but the last cap of the run.
        camel = noun[: i - 1].lower() + noun[i - 1 :]
    return camel if camel != noun else None


def body_references_noun(stripped_body: str, noun: str) -> bool:
    """
    True if `stripped_body` contains a real Swift code reference to `noun`
    OR to its camelCase property form (so `AudiobookSession` is satisfied by
    either `AudiobookSession(...)` or `.audiobookSession`).
    """
    forms = [noun]
    camel = _camel_property_form(noun)
    if camel:
        forms.append(camel)
    for form in forms:
        n = re.escape(form)
        pattern = (
            r"(?<![A-Za-z0-9_])"
            + n
            + r"(?:\(|\.|\?|!|<|>|\s*\{|\s*:|\s*,|\s*\)|\s*$|\s+[A-Za-z_])"
        )
        if re.search(pattern, stripped_body, flags=re.MULTILINE):
            return True
    return False


# --- File-level check ------------------------------------------------------

def line_number_at(swift_src: str, offset: int) -> int:
    return swift_src.count("\n", 0, offset) + 1


def file_level_sut_names(file_path: Path) -> set[str]:
    """
    Derive the file-level SUT name set from `<SUT>Tests.swift`.
    These are excluded from candidate-noun checks (already covered by DoD #1
    file-level grep). Common multi-test suffixes are also stripped.
    """
    name = file_path.stem
    if not name.endswith("Tests"):
        return set()
    base = name[: -len("Tests")]
    if not base:
        return set()
    suts: set[str] = {base}
    multi_test_suffixes = (
        "Lifecycle Predicate Wiring Extended Coverage Snapshot Smoke "
        "Integration Contract Helper Helpers Property Edge EdgeCase "
        "EdgeCases Behavior Behaviour Regression Recovery Migration "
        "Mock Mocks State StateMachine Deep Sanity Async Sync "
        "Concurrency Predicates Lifecycles AuthCoordinator Coordinator "
        "Loader Driver Path Paths Bridge Phase Tier1 Tier2 Tier3"
    ).split()
    for suffix in multi_test_suffixes:
        if base.endswith(suffix) and len(base) > len(suffix):
            suts.add(base[: -len(suffix)])
    expanded = set(suts)
    for s in suts:
        if s.startswith("TPP"):
            expanded.add(s[3:])
        else:
            expanded.add("TPP" + s)
    return {s for s in expanded if s}


def check_file(file_path: Path) -> list[str]:
    """Run the check on a single Swift test file. Returns failure messages."""
    failures: list[str] = []
    try:
        swift_src = file_path.read_text(encoding="utf-8")
    except OSError as e:
        print(f"ERROR: cannot read {file_path}: {e}", file=sys.stderr)
        sys.exit(2)

    sut_names = file_level_sut_names(file_path)
    stripped_src = strip_strings_and_comments(swift_src)

    for match in TEST_FUNC_RE.finditer(stripped_src):
        test_name = match.group(1)
        if not is_multi_step_name(test_name):
            continue
        candidate_nouns = extract_candidate_nouns(test_name)
        candidate_nouns = [n for n in candidate_nouns if n not in sut_names]
        if not candidate_nouns:
            continue
        body_result = extract_method_body(stripped_src, match.start())
        if body_result is None:
            continue
        body, _ = body_result
        line_no = line_number_at(swift_src, match.start())

        matched = any(body_references_noun(body, n) for n in candidate_nouns)
        if not matched:
            most_specific = candidate_nouns[0]
            failures.append(
                f"{file_path}:{line_no}: {test_name}: "
                f"claims '{most_specific}' but body has no reference"
            )
    return failures


# --- CLI -------------------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="check-test-name-vs-body.py",
        description=(
            "Detect fake-wiring tests where the test name embeds a "
            "PascalCase production-class noun but the body never references it."
        ),
    )
    parser.add_argument("files", nargs="+",
                        help="Swift test files to check.")
    parser.add_argument("--quiet", action="store_true",
                        help="Only print failures; suppress summary line.")
    args = parser.parse_args(argv)

    all_failures: list[str] = []
    files_checked = 0
    for f in args.files:
        path = Path(f)
        if not path.is_file():
            print(f"ERROR: file not found: {f}", file=sys.stderr)
            return 2
        all_failures.extend(check_file(path))
        files_checked += 1

    for fail in all_failures:
        print(fail)

    if not args.quiet:
        if all_failures:
            print(
                f"\n{len(all_failures)} fake-wiring test(s) found across "
                f"{files_checked} file(s).\n"
                f"Wall-failure shape: .forgeos/wall-failures/2026-05-28-cs9a267b63-arch1.md\n"
                f"Action: either instantiate the embedded production-class noun "
                f"in the test body,\n        or rename the test to not embed it "
                f"(only the name promises the wiring).",
                file=sys.stderr,
            )
        else:
            print(
                f"OK: {files_checked} file(s) checked, 0 fake-wiring tests found.",
                file=sys.stderr,
            )

    return 1 if all_failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
