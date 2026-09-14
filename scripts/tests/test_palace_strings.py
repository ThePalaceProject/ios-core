"""Tests for scripts/palace_strings.py — the localization inventory + drift gate.

Behavioral spec. Every test must fail if the corresponding production logic is
inverted or deleted; none of these assert a constructor returns non-nil.
"""
import json
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "palace_strings.py"
sys.path.insert(0, str(SCRIPT.parent))
import palace_strings as ps  # noqa: E402


# ---------------------------------------------------------------- extraction

def test_extracts_nslocalizedstring_literal():
    src = 'let a = NSLocalizedString("Borrow", comment: "Button")'
    assert ps.extract_swift(src) == ({"Borrow"}, [])


def test_extracts_nslocalizedstring_spanning_multiple_lines():
    src = '''
    static let hint = NSLocalizedString(
        "Opens book details",
        comment: "VoiceOver hint"
    )
    '''
    keys, _ = ps.extract_swift(src)
    assert "Opens book details" in keys


def test_extracts_swiftui_text_literal():
    # Text("...") is an implicit LocalizedStringKey and IS translated at runtime
    keys, _ = ps.extract_swift('Text("Get")')
    assert keys == {"Get"}


def test_ignores_text_verbatim():
    # Text(verbatim:) is explicitly NOT localized; treating it as a key would
    # add a phantom entry that every language then has to "translate".
    keys, _ = ps.extract_swift('Text(verbatim: "1.2.3")')
    assert keys == set()


def test_ignores_text_with_non_literal_argument():
    keys, _ = ps.extract_swift('Text(book.title)')
    assert keys == set()


def test_extracts_accessibility_label_and_hint():
    src = '.accessibilityLabel("Increase font size").accessibilityHint("Larger text")'
    keys, _ = ps.extract_swift(src)
    assert keys == {"Increase font size", "Larger text"}


def test_nonliteral_macro_argument_is_reported_as_dynamic():
    # NSLocalizedString(someVar, ...) has no recoverable key. genstrings errors
    # on it and moves on; we must surface it or the string silently loses its
    # translation with nothing in the inventory to show for it.
    keys, dynamic = ps.extract_swift('NSLocalizedString(key, comment: "x")')
    assert keys == set()
    assert len(dynamic) == 1


def test_dynamic_key_is_reported_not_extracted():
    # genstrings silently drops these; we must surface them for an allow-list.
    src = 'NSLocalizedString("\\(dateType.rawValue)_suffix_short", comment: "x")'
    keys, dynamic = ps.extract_swift(src)
    assert keys == set()
    assert len(dynamic) == 1


# ------------------------------------------------- format specifier checking

def test_specifier_parity_accepts_identical_specifiers():
    assert ps.specifier_mismatch("Hello %@", "Hallo %@") is None


def test_specifier_parity_rejects_dropped_specifier():
    # dropping %@ crashes String(format:) or prints garbage
    assert ps.specifier_mismatch("%@ of %@", "%@ von") is not None


def test_specifier_parity_rejects_changed_type():
    assert ps.specifier_mismatch("%d books", "%@ Bücher") is not None


def test_specifier_parity_allows_positional_reordering():
    # switching to positional form to reorder is CORRECT, not a defect
    assert ps.specifier_mismatch("%1$@, by %2$@", "von %2$@: %1$@") is None


def test_specifier_parity_rejects_bare_reordering_count_change():
    assert ps.specifier_mismatch("%1$@ %2$@", "%1$@") is not None


def test_literal_percent_is_not_a_specifier():
    assert ps.specifier_mismatch("100%% done", "100%% fertig") is None


# --------------------------------------------------------------- key hygiene

def test_identifier_shaped_key_is_flagged():
    assert ps.is_identifier_key("CarPlay.Error.offline") is True
    assert ps.is_identifier_key("IncreaseFontSize") is True


def test_english_prose_key_is_not_flagged():
    assert ps.is_identifier_key("Increase font size") is False
    assert ps.is_identifier_key("Borrow") is False


def test_format_only_key_detected():
    assert ps.is_format_only("%@ (%@)") is True
    assert ps.is_format_only("%@ books") is False


# ------------------------------------------------------------ table checking

def _write_strings(p: Path, mapping):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("".join(f'"{k}" = "{v}";\n' for k, v in mapping.items()), encoding="utf-8")


def test_check_passes_on_complete_consistent_tables(tmp_path):
    # THE CLEAN-DIFF ASSERTION: a correct tree must not be blocked.
    for lang, val in [("en", "Borrow"), ("de", "Ausleihen"), ("fr", "Emprunter")]:
        _write_strings(tmp_path / f"{lang}.lproj" / "Localizable.strings", {"Borrow": val})
    findings = ps.check_tables(tmp_path, ["en", "de", "fr"])
    assert findings == []


def test_check_detects_key_missing_from_one_language(tmp_path):
    # Foundation returns the KEY on a per-key miss, so this is user-visible.
    _write_strings(tmp_path / "en.lproj" / "Localizable.strings", {"Borrow": "Borrow", "Hold": "Hold"})
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"Borrow": "Ausleihen"})
    findings = ps.check_tables(tmp_path, ["en", "de"])
    assert any(f.kind == "missing_key" and f.key == "Hold" and f.lang == "de" for f in findings)


def test_check_detects_empty_value(tmp_path):
    _write_strings(tmp_path / "en.lproj" / "Localizable.strings", {"Borrow": "Borrow"})
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"Borrow": ""})
    findings = ps.check_tables(tmp_path, ["en", "de"])
    assert any(f.kind == "empty_value" for f in findings)


def test_check_detects_specifier_mismatch_across_languages(tmp_path):
    _write_strings(tmp_path / "en.lproj" / "Localizable.strings", {"%d books": "%d books"})
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"%d books": "%@ Bücher"})
    findings = ps.check_tables(tmp_path, ["en", "de"])
    assert any(f.kind == "specifier_mismatch" for f in findings)


def test_parse_strings_handles_escaped_quotes():
    text = '"say \\"hi\\"" = "sag \\"hallo\\"";\n'
    assert ps.parse_strings(text) == {'say \\"hi\\"': 'sag \\"hallo\\"'}


def test_parse_strings_ignores_comments():
    text = '/* a comment with "quotes" */\n"k" = "v";\n'
    assert ps.parse_strings(text) == {"k": "v"}


# ------------------------------------------------------------------ CLI wiring

def test_cli_check_exits_nonzero_on_drift(tmp_path):
    _write_strings(tmp_path / "en.lproj" / "Localizable.strings", {"a": "a", "b": "b"})
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"a": "A"})
    r = subprocess.run([sys.executable, str(SCRIPT), "check", "--lproj-root", str(tmp_path),
                        "--langs", "en,de"], capture_output=True, text=True)
    assert r.returncode != 0


def test_cli_check_exits_zero_on_clean_tree(tmp_path):
    _write_strings(tmp_path / "en.lproj" / "Localizable.strings", {"a": "a"})
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"a": "A"})
    r = subprocess.run([sys.executable, str(SCRIPT), "check", "--lproj-root", str(tmp_path),
                        "--langs", "en,de"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


# ------------------------------------------- SwiftUI interpolation vs dynamic

def test_swiftui_interpolation_becomes_a_format_key():
    # Text("\(n) active days") is a LocalizedStringKey: the real key is the
    # format-normalised string. Treating it as dynamic loses a real translation.
    keys, dynamic = ps.extract_swift(r'Text("\(streak.activeDates.count) active days")')
    assert keys == {"%@ active days"}
    assert dynamic == []


def test_nslocalizedstring_interpolation_stays_dynamic():
    # Opposite case: the key is computed at runtime, so no static key exists.
    keys, dynamic = ps.extract_swift(r'NSLocalizedString("\(t.rawValue)_suffix_short", comment: "x")')
    assert keys == set()
    assert len(dynamic) == 1


def test_normalize_interpolation_handles_nested_parens():
    assert ps.normalize_interpolation(r'\(f(a, g(b))) left') == "%@ left"


def test_normalize_interpolation_multiple_segments():
    assert ps.normalize_interpolation(r'\(a) of \(b)') == "%@ of %@"


# ------------------------------------------------ compile-time composed keys

def test_extracts_key_built_by_literal_concatenation():
    src = '''NSLocalizedString(
        ("You must enable camera access " +
            "to sign up."),
        comment: "c")'''
    keys, _ = ps.extract_swift(src)
    assert "You must enable camera access to sign up." in keys


def test_extracts_multiline_literal_with_continuation():
    src = 'NSLocalizedString("""\n    One line. \\\n    Two line.\n    """, comment: "")'
    keys, _ = ps.extract_swift(src)
    assert "One line. Two line." in keys


def test_multiline_without_continuation_keeps_newline():
    src = 'NSLocalizedString("""\n    A\n    B\n    """, comment: "")'
    keys, _ = ps.extract_swift(src)
    assert any("\\n" in k for k in keys), keys
