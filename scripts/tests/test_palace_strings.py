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


def test_parse_strings_decodes_escaped_quotes():
    # In-memory strings are real characters; the file carries the escapes.
    text = '"say \\"hi\\"" = "sag \\"hallo\\"";\n'
    assert ps.parse_strings(text) == {'say "hi"': 'sag "hallo"'}


def test_parse_strings_ignores_comments():
    text = '/* a comment with "quotes" */\n"k" = "v";\n'
    assert ps.parse_strings(text) == {"k": "v"}


# ------------------------------------------------------------------ CLI wiring

def test_cli_check_exits_nonzero_on_drift(tmp_path):
    _write_strings(tmp_path / "en.lproj" / "Localizable.strings", {"a": "a", "b": "b"})
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"a": "A"})
    r = subprocess.run([sys.executable, str(SCRIPT), "check", "--lproj-root", str(tmp_path),
                        "--source", str(tmp_path), "--langs", "en,de"],
                       capture_output=True, text=True)
    assert r.returncode != 0


def test_cli_check_exits_zero_on_clean_tree(tmp_path):
    _write_strings(tmp_path / "en.lproj" / "Localizable.strings", {"a": "a"})
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"a": "A"})
    r = subprocess.run([sys.executable, str(SCRIPT), "check", "--lproj-root", str(tmp_path),
                        "--source", str(tmp_path), "--langs", "en,de"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


# ------------------------------------------- SwiftUI interpolation vs dynamic

def test_swiftui_interpolation_becomes_a_format_key():
    # Text("\(n) active days") is a LocalizedStringKey, and for an Int SwiftUI
    # builds "%lld active days" -- NOT "%@". This test previously asserted %@,
    # which is the key genstrings emits and which can never match at runtime.
    keys, dynamic = ps.extract_swift(r'Text("\(streak.activeDates.count) active days")')
    assert keys == {"%lld active days"}
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
    assert any("\n" in k for k in keys), keys


def test_status_measures_against_source_not_other_tables(tmp_path, capsys):
    # A tree whose tables are all empty must NOT report 100%. Comparing tables
    # only to each other is self-referential and always says "complete".
    src = tmp_path / "src"; src.mkdir()
    (src / "V.swift").write_text('NSLocalizedString("Borrow", comment: "")\nText("Hold")\n')
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"Borrow": "Ausleihen"})
    rc = ps.main(["status", "--lproj-root", str(tmp_path), "--langs", "de",
                  "--source", str(src)])
    out = capsys.readouterr().out
    assert rc == 0
    assert "1/2" in out and "50.0%" in out, out


# --------------------------------------------- unsafe degradation (identifier)

def test_identifier_key_without_value_fallback_is_unsafe(tmp_path):
    f = tmp_path / "V.swift"
    f.write_text('.accessibilityLabel(Text("IncreaseFontSize"))')
    assert ps.scan_unsafe_keys([tmp_path]) == [("IncreaseFontSize", str(f))]


def test_identifier_key_with_value_fallback_is_safe(tmp_path):
    # Foundation returns `value` on a miss, so this degrades to English.
    (tmp_path / "V.swift").write_text(
        'NSLocalizedString("CarPlay.chapters", value: "Chapters", comment: "c")')
    assert ps.scan_unsafe_keys([tmp_path]) == []


def test_empty_value_fallback_is_still_unsafe(tmp_path):
    # Verified against Foundation: value "" is treated as absent.
    (tmp_path / "V.swift").write_text(
        'NSLocalizedString("CarPlay.chapters", value: "", comment: "c")')
    assert [k for k, _ in ps.scan_unsafe_keys([tmp_path])] == ["CarPlay.chapters"]


def test_prose_key_is_never_unsafe(tmp_path):
    (tmp_path / "V.swift").write_text('NSLocalizedString("Borrow this book", comment: "c")')
    assert ps.scan_unsafe_keys([tmp_path]) == []


def test_stringsdict_missing_key_detected(tmp_path):
    import plistlib
    def w(lang, keys):
        d = {k: {"NSStringLocalizedFormatKey": "%#@n@",
                 "n": {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                       "NSStringFormatValueTypeKey": "d", "one": "1", "other": "%d"}} for k in keys}
        p = tmp_path / f"{lang}.lproj" / "Localizable.stringsdict"
        p.parent.mkdir(parents=True, exist_ok=True)
        plistlib.dump(d, open(p, "wb"))
    w("en", ["day_suffix_long", "day_suffix_short"])
    w("de", ["day_suffix_long"])
    findings = ps.check_stringsdict(tmp_path, ["en", "de"])
    assert any(f.lang == "de" and f.key == "day_suffix_short" for f in findings)


def test_stringsdict_equal_key_sets_pass(tmp_path):
    import plistlib
    for lang in ("en", "de"):
        p = tmp_path / f"{lang}.lproj" / "Localizable.stringsdict"
        p.parent.mkdir(parents=True, exist_ok=True)
        plistlib.dump({"k": {"NSStringLocalizedFormatKey": "%#@n@"}}, open(p, "wb"))
    assert ps.check_stringsdict(tmp_path, ["en", "de"]) == []


def test_prose_with_trailing_ellipsis_is_not_an_identifier_key():
    # "Loading..." renders correctly on a miss; flagging it would send a
    # reviewer to backfill a key that is already safe.
    assert ps.is_identifier_key("Loading...") is False
    assert ps.is_identifier_key("More...") is False
    assert ps.is_identifier_key("Filtering...") is False


def test_internal_dot_is_still_an_identifier_key():
    assert ps.is_identifier_key("opds.error.feed_invalid") is True
    assert ps.is_identifier_key("CarPlay.Error.offline") is True


# ------------------------------------------------------------ comment safety

def test_string_in_line_comment_is_not_a_key():
    # A commented-out call site must not inject a phantom key that every
    # language is then asked to translate.
    keys, _ = ps.extract_swift('// was Text("IncreaseFontSize") before PP-5094\nText("Real")')
    assert keys == {"Real"}


def test_string_in_block_comment_is_not_a_key():
    keys, _ = ps.extract_swift('/* Text("Ghost") */ Text("Real")')
    assert keys == {"Real"}


def test_double_slash_inside_a_literal_does_not_start_a_comment():
    keys, _ = ps.extract_swift('Text("http://example.com/a")')
    assert keys == {"http://example.com/a"}


def test_nested_block_comment_is_fully_stripped():
    keys, _ = ps.extract_swift('/* outer /* inner Text("Ghost") */ still */ Text("Real")')
    assert keys == {"Real"}


def test_escaped_quote_inside_literal_does_not_end_it():
    keys, _ = ps.extract_swift(r'Text("say \"hi\" // not a comment")')
    assert len(keys) == 1


# ------------------------------------------------- canonical-variant matching

def test_canonical_folds_capitalisation():
    # "Add bookmark" vs "Add Bookmark" is a recase, not a new string; the
    # existing translation stays correct and must not be re-paid for.
    assert ps.canonical("Add bookmark") == ps.canonical("Add Bookmark")


def test_canonical_folds_positional_specifiers():
    # The toolkit writes bare specifiers, Transifex holds positional. Same
    # string; treating them as different orphans a real translation.
    assert ps.canonical("%d hours and %d minutes") == ps.canonical("%1$d hours and %2$d minutes")


def test_canonical_folds_trailing_punctuation_and_curly_quotes():
    assert ps.canonical("Narrators") == ps.canonical("Narrators:")
    assert ps.canonical("We can’t load") == ps.canonical("We can't load")


def test_canonical_keeps_distinct_strings_distinct():
    # The fold must not be so aggressive that it merges different messages.
    assert ps.canonical("Borrow this book") != ps.canonical("Return this book")
    assert ps.canonical("%d books") != ps.canonical("%d holds")


def test_unescape_decodes_escaped_quote_and_newline():
    assert ps.unescape(r'say \"hi\"') == 'say "hi"'
    assert ps.unescape(r'a\nb') == "a\nb"


# ------------------------------------------------------------ developer paths

def test_developer_paths_are_recognised():
    assert ps.is_developer_path("Palace/Settings/DeveloperSettings/X.swift") is True
    assert ps.is_developer_path("Palace/Settings/Debug/Y.swift") is True
    assert ps.is_developer_path("Palace/Settings/Debug/MockBackend/Z.swift") is True


def test_shipping_paths_are_not_developer_paths():
    assert ps.is_developer_path("Palace/Reader2/UI/Reader.swift") is False
    assert ps.is_developer_path("Palace/CarPlay/CarPlayTemplateManager.swift") is False


# ---------------------------------------------------------- key migration map

def test_migration_map_resolves_old_key_to_new(tmp_path):
    m = tmp_path / "map.json"
    m.write_text(json.dumps({"Add Bookmark": "Add bookmark"}))
    assert ps.load_migrations(m) == {"Add Bookmark": "Add bookmark"}


def test_missing_migration_map_is_not_an_error(tmp_path):
    assert ps.load_migrations(tmp_path / "nope.json") == {}


def test_inventory_excludes_developer_paths_by_default(tmp_path):
    dev = tmp_path / "Settings" / "DeveloperSettings"; dev.mkdir(parents=True)
    (dev / "D.swift").write_text('NSLocalizedString("Dump caches", comment: "")')
    ship = tmp_path / "Reader"; ship.mkdir()
    (ship / "S.swift").write_text('NSLocalizedString("Borrow", comment: "")')
    keys, _ = ps.inventory([tmp_path])
    assert keys == {"Borrow"}


def test_inventory_can_include_developer_paths_on_request(tmp_path):
    dev = tmp_path / "Settings" / "DeveloperSettings"; dev.mkdir(parents=True)
    (dev / "D.swift").write_text('NSLocalizedString("Dump caches", comment: "")')
    keys, _ = ps.inventory([tmp_path], include_developer=True)
    assert keys == {"Dump caches"}


# ------------------------------------ positional/bare specifier compatibility

def test_bare_source_accepts_positional_translation():
    # The whole point of positional form is that a translation may reorder
    # arguments. Flagging it would block the safest thing a translator can do.
    assert ps.specifier_mismatch("%d hours and %d minutes",
                                 "%1$d Stunden und %2$d Minuten") is None


def test_bare_source_accepts_reordered_positional_translation():
    assert ps.specifier_mismatch("%@ by %@", "%2$@ de %1$@") is None


def test_positional_translation_with_wrong_type_is_rejected():
    assert ps.specifier_mismatch("%d books", "%1$@ Bucher") is not None


def test_positional_translation_with_missing_index_is_rejected():
    # %1$ used twice, %2$ never -> the second argument is silently dropped.
    assert ps.specifier_mismatch("%@ of %@", "%1$@ von %1$@") is not None


def test_positional_translation_with_out_of_range_index_is_rejected():
    assert ps.specifier_mismatch("%@ of %@", "%1$@ von %3$@") is not None


def test_target_mixing_positional_and_bare_is_rejected():
    # iOS does not allow mixing the two forms in one format string; the
    # arguments bind unpredictably.
    assert ps.specifier_mismatch("%@ of %@", "%1$@ von %@") is not None


def test_target_with_fewer_conversions_is_rejected():
    assert ps.specifier_mismatch("%@ of %@", "%@ von") is not None


def test_target_with_more_conversions_is_rejected():
    assert ps.specifier_mismatch("%@ only", "%@ and %@") is not None


# --------------------------------------------------------- writing .strings

def test_written_table_round_trips():
    text = ps.render_strings({"Borrow": "Ausleihen", "Hold": "Vormerken"}, {})
    assert ps.parse_strings(text) == {"Borrow": "Ausleihen", "Hold": "Vormerken"}


def test_writer_escapes_quotes_and_newlines():
    original = {'Say "hi"': 'Sag "hallo"\nbitte'}
    text = ps.render_strings(original, {})
    assert r'\"hi\"' in text and r"\n" in text
    assert ps.parse_strings(text) == original


def test_writer_emits_developer_comment_when_present():
    text = ps.render_strings({"Borrow": "Ausleihen"}, {"Borrow": "Button title"})
    assert "/* Button title */" in text


def test_writer_output_is_deterministically_ordered():
    a = ps.render_strings({"b": "B", "a": "A"}, {})
    b = ps.render_strings({"a": "A", "b": "B"}, {})
    assert a == b


def test_validate_rejects_specifier_mismatch():
    bad = ps.validate_translations({"%d books": "%@ Bucher"}, {"%d books": "%d books"})
    assert any(f.kind == "specifier_mismatch" for f in bad)


def test_validate_rejects_empty_value():
    assert any(f.kind == "empty_value"
               for f in ps.validate_translations({"Borrow": "  "}, {"Borrow": "Borrow"}))


def test_validate_rejects_identifier_shaped_value():
    # A "translation" that is just the key echoed back is untranslated, and
    # writing it would look like coverage while rendering a symbol to a patron.
    bad = ps.validate_translations({"Sort By": "MyBooksViewControllerGroupSortBy"},
                                   {"Sort By": "Sort By"})
    assert any(f.kind == "identifier_value" for f in bad)


def test_validate_accepts_a_clean_batch():
    ok = ps.validate_translations({"%d books": "%d Bucher", "Borrow": "Ausleihen"},
                                  {"%d books": "%d books", "Borrow": "Borrow"})
    assert ok == []


# --------------------------------- SwiftUI type-specific interpolation keys

def test_int_interpolation_uses_lld_not_at():
    # VERIFIED against SwiftUI: Text("\(Int) retries") builds key "%lld retries".
    # Emitting "%@" produces a key that can never match, so the string renders
    # English forever and no check ever notices.
    assert ps.infer_specifier("action.retryCount") == "%lld"
    assert ps.infer_specifier("streak.activeDates.count") == "%lld"
    assert ps.infer_specifier("42") == "%lld"


def test_string_interpolation_uses_at():
    assert ps.infer_specifier("book.title") == "%@"


def test_normalize_interpolation_uses_inferred_specifier():
    assert ps.normalize_interpolation(r"(\(action.retryCount)/\(action.maxRetries) retries)") \
        == "(%lld/%lld retries)"
    assert ps.normalize_interpolation(r"\(book.title) by \(book.author)") == "%@ by %@"


def test_interpolated_keys_are_reported_as_unconfirmed(tmp_path):
    # Static inference cannot be trusted for every expression; the authoritative
    # answer is the compiler. Surface them rather than silently shipping a guess.
    (tmp_path / "V.swift").write_text(r'Text("\(vm.items.count) items")')
    keys, _, unconfirmed = ps.inventory_detailed([tmp_path])
    assert "%lld items" in keys
    assert any("items" in u for u in unconfirmed)


def test_check_uses_supplied_source_map_for_specifier_parity(tmp_path):
    # English is the CODE, not a committed table: `en.lproj/Localizable.strings`
    # is not in the Xcode project, so a file there would never ship and could
    # drift from the source unnoticed.
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"%lld books": "%@ Bucher"})
    findings = ps.check_tables(tmp_path, ["de"], source={"%lld books": "%lld books"})
    assert any(f.kind == "specifier_mismatch" for f in findings)


def test_check_without_source_map_still_cross_compares_languages(tmp_path):
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"a": "A", "b": "B"})
    _write_strings(tmp_path / "fr.lproj" / "Localizable.strings", {"a": "A"})
    findings = ps.check_tables(tmp_path, ["de", "fr"])
    assert any(f.kind == "missing_key" and f.lang == "fr" for f in findings)


def test_source_map_prefers_the_value_argument(tmp_path):
    # For an identifier key the English is the `value:`, not the key. Using the
    # key would compare a translation against a string with no specifiers.
    (tmp_path / "V.swift").write_text(
        'NSLocalizedString("CarPlay.chapterNumber", value: "Chapter %d", comment: "c")')
    assert ps.source_map([tmp_path]) == {"CarPlay.chapterNumber": "Chapter %d"}


def test_source_map_falls_back_to_the_key_for_prose(tmp_path):
    (tmp_path / "V.swift").write_text('NSLocalizedString("Borrow", comment: "c")')
    assert ps.source_map([tmp_path]) == {"Borrow": "Borrow"}


def test_render_is_idempotent_over_a_read_write_cycle():
    # Two keys were corrupted by a read-merge-write cycle re-escaping what was
    # already escaped, before parse and render were made symmetric.
    original = {'Remove "%@" from holds?': '"%@" entfernen?'}
    once = ps.render_strings(original, {})
    twice = ps.render_strings(ps.parse_strings(once), {})
    assert once == twice
    assert ps.parse_strings(twice) == original


def test_render_escapes_a_raw_quote_that_was_never_escaped():
    out = ps.render_strings({'say "hi"': 'sag "hallo"'}, {})
    assert r'\"hi\"' in out and out.count('";') == 1


def test_interpolated_literal_escapes_a_literal_percent():
    # VERIFIED against SwiftUI: Text("\(n)% complete") builds "%lld%% complete".
    # Leaving the % bare makes "% c" parse as a conversion, so the key both
    # fails to match AND would consume an argument if it were ever formatted.
    assert ps.normalize_interpolation(r"\(badge.progressPercentage)% complete") == "%lld%% complete"


def test_interpolated_literal_without_percent_is_unchanged_otherwise():
    assert ps.normalize_interpolation(r"\(items.count) items") == "%lld items"


def test_ambiguous_expression_is_not_guessed_as_an_int():
    # A bare name carries no type signal. Defaulting to %lld would invent a key
    # that never matches; %@ is the conservative choice and the key is reported
    # as unconfirmed either way.
    assert ps.infer_specifier("n") == "%@"


def test_plain_literal_percent_is_not_escaped():
    # A literal with no interpolation is stored verbatim by SwiftUI -- escaping
    # it here would invent a key that never matches.
    keys, _ = ps.extract_swift('Text("50% off")')
    assert keys == {"50% off"}


# ------------------------------------------------- Swift literal escape decoding

def test_unicode_escape_is_decoded_to_the_real_character():
    # Swift compiles "\u{2019}" to U+2019, so the RUNTIME key contains the
    # character. Keeping the escape text produces a key that never matches.
    keys, _ = ps.extract_swift(r'NSLocalizedString("We can\u{2019}t load", comment: "c")')
    assert keys == {"We can’t load"}


def test_escaped_quote_is_decoded():
    keys, _ = ps.extract_swift(r'NSLocalizedString("Remove \"%@\"?", comment: "c")')
    assert keys == {'Remove "%@"?'}


def test_escaped_newline_is_decoded():
    keys, _ = ps.extract_swift(r'NSLocalizedString("a\nb", comment: "c")')
    assert keys == {"a\nb"}


def test_decoding_survives_a_render_parse_round_trip():
    key = "We can’t load \"it\"\nnow"
    text = ps.render_strings({key: "x"}, {})
    assert list(ps.parse_strings(text)) == [key]


def test_explicit_int_cast_is_decisive():
    # `Int(presenter.overallDownloadProgress * 100)` reads as floating-point by
    # name and is an Int by construction. The cast is the one signal worth
    # trusting over a name-shaped guess.
    assert ps.infer_specifier("Int(presenter.overallDownloadProgress * 100") == "%lld"
    assert ps.infer_specifier("Double(x)") == "%lf"


# ------------------------------------------- export / import work-file cycle

def test_export_lists_only_keys_missing_from_the_tables(tmp_path):
    src = tmp_path / "src"; src.mkdir()
    (src / "V.swift").write_text('NSLocalizedString("Borrow", comment: "Button")\n'
                                 'NSLocalizedString("Return", comment: "Button")\n')
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"Borrow": "Ausleihen"})
    work = ps.build_work_file([src], tmp_path, ["de"])
    assert [s["key"] for s in work["strings"]] == ["Return"]
    assert work["strings"][0]["english"] == "Return"
    assert work["strings"][0]["comment"] == "Button"
    assert work["strings"][0]["de"] == ""


def test_export_skips_format_only_keys(tmp_path):
    src = tmp_path / "src"; src.mkdir()
    (src / "V.swift").write_text('NSLocalizedString("%@ %@", comment: "")')
    work = ps.build_work_file([src], tmp_path, ["de"])
    assert work["strings"] == []


def test_export_uses_the_value_argument_as_english(tmp_path):
    src = tmp_path / "src"; src.mkdir()
    (src / "V.swift").write_text(
        'NSLocalizedString("CarPlay.x", value: "Chapters", comment: "c")')
    work = ps.build_work_file([src], tmp_path, ["de"])
    assert work["strings"][0]["english"] == "Chapters"


def test_import_writes_validated_values(tmp_path):
    src = tmp_path / "src"; src.mkdir()
    (src / "V.swift").write_text('NSLocalizedString("Borrow", comment: "b")')
    work = {"languages": ["de"], "strings": [{"key": "Borrow", "english": "Borrow", "de": "Ausleihen"}]}
    findings = ps.apply_work_file(work, [src], tmp_path)
    assert findings == []
    assert ps.parse_strings((tmp_path / "de.lproj" / "Localizable.strings")
                            .read_text(encoding="utf-8")) == {"Borrow": "Ausleihen"}


def test_import_refuses_a_specifier_mismatch_and_writes_nothing(tmp_path):
    src = tmp_path / "src"; src.mkdir()
    (src / "V.swift").write_text('NSLocalizedString("%d books", comment: "b")')
    work = {"languages": ["de"], "strings": [{"key": "%d books", "english": "%d books", "de": "%@ Bucher"}]}
    findings = ps.apply_work_file(work, [src], tmp_path)
    assert any(f.kind == "specifier_mismatch" for f in findings)
    assert not (tmp_path / "de.lproj" / "Localizable.strings").exists()


def test_import_ignores_a_blank_value_rather_than_writing_it(tmp_path):
    # A partially-filled work file is normal: a human may return one language
    # at a time. Blanks are skipped, not written as empty strings.
    src = tmp_path / "src"; src.mkdir()
    (src / "V.swift").write_text('NSLocalizedString("Borrow", comment: "b")')
    work = {"languages": ["de"], "strings": [{"key": "Borrow", "english": "Borrow", "de": "  "}]}
    assert ps.apply_work_file(work, [src], tmp_path) == []
    assert not (tmp_path / "de.lproj" / "Localizable.strings").exists()


def test_import_rejects_a_key_that_is_not_in_the_source(tmp_path):
    src = tmp_path / "src"; src.mkdir()
    (src / "V.swift").write_text('NSLocalizedString("Borrow", comment: "b")')
    work = {"languages": ["de"], "strings": [{"key": "Ghost", "english": "Ghost", "de": "Geist"}]}
    findings = ps.apply_work_file(work, [src], tmp_path)
    assert any(f.kind == "unknown_key" for f in findings)


def test_allowlisted_keys_are_not_exported(tmp_path):
    # The escape hatch: a key deliberately not translated (a debug placeholder,
    # a brand name) is recorded WITH A REASON rather than nagging every export.
    src = tmp_path / "src"; src.mkdir()
    (src / "V.swift").write_text('NSLocalizedString("Lorem ipsum", comment: "")\n'
                                 'NSLocalizedString("Borrow", comment: "")\n')
    allow = tmp_path / "allow.json"
    allow.write_text(json.dumps({"skip": {"Lorem ipsum": "debug placeholder"}}))
    work = ps.build_work_file([src], tmp_path, ["de"], allowlist=ps.load_allowlist(allow))
    assert [s["key"] for s in work["strings"]] == ["Borrow"]


def test_allowlist_absent_is_not_an_error(tmp_path):
    assert ps.load_allowlist(tmp_path / "nope.json") == {}


def test_require_complete_fails_on_an_untranslated_new_string(tmp_path):
    # The forcing function: a developer adds a string, ships nothing else, and
    # CI stops the PR. This is the whole reason the loop does not need AI in CI.
    src = tmp_path / "src"; src.mkdir()
    (src / "V.swift").write_text('NSLocalizedString("Renew this loan", comment: "")')
    findings = ps.check_tables(tmp_path, ["de"], require=ps.inventory([src])[0])
    assert any(f.kind == "untranslated" and f.key == "Renew this loan" for f in findings)


def test_require_complete_passes_once_translated(tmp_path):
    src = tmp_path / "src"; src.mkdir()
    (src / "V.swift").write_text('NSLocalizedString("Renew this loan", comment: "")')
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"Renew this loan": "Leihfrist"})
    assert ps.check_tables(tmp_path, ["de"], require=ps.inventory([src])[0]) == []


# --------------------------------------------- status report + staleness gate

def _tiny_tree(tmp_path, keys=("Borrow",), de="Ausleihen"):
    src = tmp_path / "src"; src.mkdir(exist_ok=True)
    (src / "V.swift").write_text("".join(
        f'NSLocalizedString("{k}", comment: "c")\n' for k in keys))
    for lang in ("de", "es", "fr", "it"):
        _write_strings(tmp_path / f"{lang}.lproj" / "Localizable.strings",
                       {k: de for k in keys})
    return src


def test_report_includes_a_fingerprint_of_the_current_state(tmp_path):
    src = _tiny_tree(tmp_path)
    text = ps.build_report([src], tmp_path, ["de", "es", "fr", "it"])
    assert ps.REPORT_FINGERPRINT_MARKER in text
    assert ps.state_fingerprint([src], tmp_path, ["de", "es", "fr", "it"]) in text


def test_report_is_stale_once_a_translation_changes(tmp_path):
    src = _tiny_tree(tmp_path)
    langs = ["de", "es", "fr", "it"]
    doc = tmp_path / "status.md"
    doc.write_text(ps.build_report([src], tmp_path, langs))
    assert ps.report_is_current(doc, [src], tmp_path, langs) is True

    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"Borrow": "Leihen"})
    assert ps.report_is_current(doc, [src], tmp_path, langs) is False


def test_report_is_stale_once_a_source_string_is_added(tmp_path):
    src = _tiny_tree(tmp_path)
    langs = ["de", "es", "fr", "it"]
    doc = tmp_path / "status.md"
    doc.write_text(ps.build_report([src], tmp_path, langs))
    (src / "W.swift").write_text('NSLocalizedString("Return", comment: "c")')
    assert ps.report_is_current(doc, [src], tmp_path, langs) is False


def test_missing_report_is_not_current(tmp_path):
    src = _tiny_tree(tmp_path)
    assert ps.report_is_current(tmp_path / "nope.md", [src], tmp_path, ["de"]) is False


def test_report_states_real_counts(tmp_path):
    src = _tiny_tree(tmp_path, keys=("Borrow", "Return"))
    # Return is present in every table too, so coverage is complete
    for lang in ("de", "es", "fr", "it"):
        _write_strings(tmp_path / f"{lang}.lproj" / "Localizable.strings",
                       {"Borrow": "A", "Return": "B"})
    text = ps.build_report([src], tmp_path, ["de", "es", "fr", "it"])
    assert "2" in text and "100.0%" in text


def test_check_fails_when_the_report_is_stale(tmp_path):
    src = _tiny_tree(tmp_path)
    langs = ["de", "es", "fr", "it"]
    doc = tmp_path / "status.md"
    doc.write_text(ps.build_report([src], tmp_path, langs))
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"Borrow": "Leihen"})
    findings = ps.check_tables(tmp_path, langs, report=(doc, [src]))
    assert any(f.kind == "stale_report" for f in findings)


def test_check_passes_when_the_report_is_current(tmp_path):
    src = _tiny_tree(tmp_path)
    langs = ["de", "es", "fr", "it"]
    doc = tmp_path / "status.md"
    doc.write_text(ps.build_report([src], tmp_path, langs))
    findings = ps.check_tables(tmp_path, langs, report=(doc, [src]))
    assert not any(f.kind == "stale_report" for f in findings)


def test_packet_includes_a_reviewer_brief(tmp_path):
    src = _tiny_tree(tmp_path)
    out = tmp_path / "packet"
    ps.build_packet([src], tmp_path, ["de"], out)
    brief = (out / "README.md").read_text(encoding="utf-8")
    # the brief must state the limits of what was checked, or a reviewer may
    # read automated mechanics as a linguistic endorsement
    assert "native speaker" in brief.lower()
    assert "%@" in brief          # the specifier constraint on their suggestions


def test_packet_writes_one_csv_per_language(tmp_path):
    src = _tiny_tree(tmp_path)
    out = tmp_path / "packet"
    info = ps.build_packet([src], tmp_path, ["de", "fr"], out)
    assert (out / "de.csv").exists() and (out / "fr.csv").exists()
    assert info["values"] == info["strings"] * 2


# ------------------------------------------------- HTML entity contamination

def test_validate_rejects_an_html_entity_in_a_value():
    # `l&#39;emprunt` renders literally to a patron. 19 of these survived the
    # validator because it checked specifiers, empties and symbol-names but
    # never looked for entity encoding.
    bad = ps.validate_translations({"Borrow failed": "Échec de l&#39;emprunt"},
                                   {"Borrow failed": "Borrow failed"})
    assert any(f.kind == "html_entity" for f in bad)


def test_validate_rejects_a_quot_entity():
    bad = ps.validate_translations({'Remove "%@"?': "Rimuovere &quot;%@&quot;?"},
                                   {'Remove "%@"?': 'Remove "%@"?'})
    assert any(f.kind == "html_entity" for f in bad)


def test_validate_allows_a_literal_ampersand():
    # "Health & safety" is ordinary text, not an encoding artifact.
    ok = ps.validate_translations({"Terms & conditions": "Bedingungen & Konditionen"},
                                  {"Terms & conditions": "Terms & conditions"})
    assert not any(f.kind == "html_entity" for f in ok)


def test_decode_entities_restores_real_punctuation():
    assert ps.decode_html_entities("l&#39;emprunt") == "l'emprunt"
    assert ps.decode_html_entities("&quot;%@&quot;") == '"%@"'
    assert ps.decode_html_entities("A & B") == "A & B"


def test_check_tables_also_rejects_html_entities(tmp_path):
    # The gate has its own loop and does NOT call validate_translations; a
    # detector added to only one of the two passes the CI gate while the other
    # rejects the same value.
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings",
                   {"Borrow failed": "Fehler bei l&#39;emprunt"})
    findings = ps.check_tables(tmp_path, ["de"], source={"Borrow failed": "Borrow failed"})
    assert any(f.kind == "html_entity" for f in findings)


# ------------------------- imported-data contamination (the class, not one case)

def test_validate_rejects_a_zero_width_character():
    bad = ps.validate_translations({"Borrow": "Aus​leihen"}, {"Borrow": "Borrow"})
    assert any(f.kind == "invisible_character" for f in bad)


def test_validate_rejects_a_byte_order_mark_inside_a_value():
    bad = ps.validate_translations({"Borrow": "﻿Ausleihen"}, {"Borrow": "Borrow"})
    assert any(f.kind == "invisible_character" for f in bad)


def test_validate_rejects_a_control_character():
    bad = ps.validate_translations({"Borrow": "Aus\x07leihen"}, {"Borrow": "Borrow"})
    assert any(f.kind == "control_character" for f in bad)


def test_validate_allows_a_non_breaking_space():
    # French requires U+00A0 before ? ! : ; — it is correct typography here,
    # not contamination, and flagging it would fight the style guide.
    ok = ps.validate_translations({"Ready?": "Prêt ?"}, {"Ready?": "Ready?"})
    assert ok == []


def test_validate_flags_trailing_whitespace():
    bad = ps.validate_translations({"Borrow": "Ausleihen "}, {"Borrow": "Borrow"})
    assert any(f.kind == "stray_whitespace" for f in bad)


def test_validate_allows_a_deliberate_leading_space_in_the_source():
    # If the ENGLISH carries the space, the translation should too.
    ok = ps.validate_translations({" of ": " von "}, {" of ": " of "})
    assert not any(f.kind == "stray_whitespace" for f in ok)


# --------------------------------------------- the inventory needs ALL sources

def test_cli_refuses_to_run_when_a_source_root_is_absent(tmp_path):
    # `DEFAULT_SOURCES` spans both repos. When the submodule is not checked out
    # the tool used to silently drop it and compute over a SUBSET — 556 keys
    # instead of 592. Every number it printed was then wrong in the safe-looking
    # direction: fewer keys demanded, fewer gaps found, and a report fingerprint
    # that could never match the one a developer committed. CI ran the gate that
    # way for the whole life of the gate.
    r = subprocess.run([sys.executable, str(SCRIPT), "check", "--lproj-root", str(tmp_path)],
                       capture_output=True, text=True, cwd=tmp_path)
    assert r.returncode != 0
    out = r.stdout + r.stderr
    assert "ios-audiobooktoolkit" in out
    assert "submodule" in out.lower()


def test_an_explicit_source_still_overrides_the_defaults(tmp_path):
    # The escape hatch has to keep working, or the check above makes the tool
    # unusable anywhere but a fully checked-out tree.
    (tmp_path / "S.swift").write_text('Text("a")\n', encoding="utf-8")
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"a": "A"})
    r = subprocess.run([sys.executable, str(SCRIPT), "check", "--lproj-root", str(tmp_path),
                        "--source", str(tmp_path), "--langs", "de"],
                       capture_output=True, text=True, cwd=tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr

def test_a_key_translated_via_stringsdict_counts_as_translated(tmp_path):
    # Plurals live in .stringsdict, not .strings. Without this, every plural key
    # is reported untranslated forever and the gate trains people to ignore it.
    import plistlib
    src = tmp_path / "src"; src.mkdir()
    (src / "V.swift").write_text(
        'NSLocalizedString("day_count", value: "%d days", comment: "c")')
    for lang in ("de",):
        p = tmp_path / f"{lang}.lproj" / "Localizable.stringsdict"
        p.parent.mkdir(parents=True, exist_ok=True)
        plistlib.dump({"day_count": {"NSStringLocalizedFormatKey": "%#@d@"}}, open(p, "wb"))
    findings = ps.check_tables(tmp_path, ["de"], require=ps.inventory([src])[0])
    assert not any(f.kind == "untranslated" for f in findings), findings


# ------------------------------------------ runtime translation SDK detection
#
# The tables this tool checks are INERT while a runtime translation SDK is
# installed: Transifex Native swizzles `Bundle.localizedString(forKey:...)` and
# never calls `super` once activated, so the committed `.strings` files are read
# by nobody. Coverage reported 100% for three years against a cache last written
# in 2022. A gate that cannot see that condition reports a green board on an app
# that ships English.

def test_flags_a_source_file_importing_a_runtime_translation_sdk(tmp_path):
    src = tmp_path / "Palace"
    src.mkdir()
    (src / "Manager.swift").write_text("import Transifex\n\nclass M {}\n", encoding="utf-8")
    findings = ps.check_no_runtime_translation_sdk([src], tmp_path)
    assert [f.kind for f in findings] == ["runtime_translation_sdk"]
    assert "Manager.swift" in findings[0].key


def test_flags_the_package_pin_even_with_no_swift_import(tmp_path):
    # The pin alone re-links the SDK; a later commit only has to call setup().
    src = tmp_path / "Palace"
    src.mkdir()
    (src / "Clean.swift").write_text("class M {}\n", encoding="utf-8")
    proj = tmp_path / "Palace.xcodeproj"
    proj.mkdir()
    (proj / "project.pbxproj").write_text(
        'repositoryURL = "https://github.com/transifex/transifex-swift/";\n', encoding="utf-8")
    findings = ps.check_no_runtime_translation_sdk([src], tmp_path)
    assert [f.kind for f in findings] == ["runtime_translation_sdk"]
    assert "project.pbxproj" in findings[0].key


def test_flags_the_resolved_pin(tmp_path):
    src = tmp_path / "Palace"
    src.mkdir()
    resolved = tmp_path / "Palace.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
    resolved.mkdir(parents=True)
    (resolved / "Package.resolved").write_text(
        json.dumps({"pins": [{"identity": "transifex-swift"}]}), encoding="utf-8")
    findings = ps.check_no_runtime_translation_sdk([src], tmp_path)
    assert [f.kind for f in findings] == ["runtime_translation_sdk"]
    assert "Package.resolved" in findings[0].key


def test_a_clean_tree_produces_no_finding(tmp_path):
    # The clean path must PASS. A detector that only ever sees violations in its
    # fixture cannot tell a working gate from one that fires on everything.
    src = tmp_path / "Palace"
    src.mkdir()
    (src / "Strings.swift").write_text(
        'let a = NSLocalizedString("Borrow", value: "Borrow", comment: "")\n', encoding="utf-8")
    assert ps.check_no_runtime_translation_sdk([src], tmp_path) == []


def test_the_word_transifex_in_a_comment_is_not_a_finding(tmp_path):
    # This repo's own docs and migration map name the retired service. Flagging
    # prose would make the gate unrunnable on the commit that removes the SDK.
    src = tmp_path / "Palace"
    src.mkdir()
    (src / "Note.swift").write_text(
        "// Transifex used to fetch these at runtime; it no longer does.\n", encoding="utf-8")
    assert ps.check_no_runtime_translation_sdk([src], tmp_path) == []


def test_the_real_repo_has_no_runtime_translation_sdk():
    root = Path(__file__).resolve().parents[2]
    srcs = [root / p for p in ps.DEFAULT_SOURCES if (root / p).exists()]
    findings = ps.check_no_runtime_translation_sdk(srcs, root)
    assert findings == [], "\n".join(f"{f.key}: {f.detail}" for f in findings)


# ------------------------------------------------------ bundle-scoped lookups
#
# `NSLocalizedString(key, bundle: Bundle.audiobookToolkit()!, ...)` resolves
# against THAT framework's bundle. A translation for such a key in the app's
# `Palace/de.lproj` is never read — Foundation looks in the bundle the call
# names, and nowhere else. 30 reviewed values sat in the app tables unreachable
# for exactly this reason.

def test_a_foreign_bundle_argument_scopes_the_key_away_from_the_app():
    src = ('NSLocalizedString("Decrease speed", bundle: Bundle.audiobookToolkit()!, '
           'value: "Decrease speed", comment: "Button")')
    native, foreign = ps.bundle_scoped_keys(src)
    assert foreign == {"Decrease speed"}
    assert native == set()


def test_no_bundle_argument_means_the_main_bundle():
    src = 'NSLocalizedString("Borrow", value: "Borrow", comment: "Button")'
    native, foreign = ps.bundle_scoped_keys(src)
    assert native == {"Borrow"}
    assert foreign == set()


def test_an_explicit_main_bundle_is_not_foreign():
    src = 'NSLocalizedString("Borrow", bundle: Bundle.main, value: "Borrow", comment: "")'
    native, foreign = ps.bundle_scoped_keys(src)
    assert native == {"Borrow"}
    assert foreign == set()


def test_inventory_drops_a_key_only_ever_looked_up_in_another_bundle(tmp_path):
    (tmp_path / "Player.swift").write_text(
        'NSLocalizedString("Speed presets", bundle: Bundle.audiobookToolkit()!, '
        'value: "Speed presets", comment: "")\n'
        'Text("Borrow")\n', encoding="utf-8")
    keys, _ = ps.inventory([tmp_path])
    assert "Borrow" in keys
    assert "Speed presets" not in keys


def test_inventory_keeps_a_key_that_is_also_looked_up_in_the_main_bundle(tmp_path):
    # Three keys really are reached both ways. Dropping them because ONE call
    # site names another bundle would leave the app rendering the raw key.
    (tmp_path / "Player.swift").write_text(
        'NSLocalizedString("Decrease speed", bundle: Bundle.audiobookToolkit()!, '
        'value: "Decrease speed", comment: "")\n', encoding="utf-8")
    (tmp_path / "Strings.swift").write_text(
        'NSLocalizedString("Decrease speed", value: "Decrease speed", comment: "")\n',
        encoding="utf-8")
    keys, _ = ps.inventory([tmp_path])
    assert "Decrease speed" in keys


def test_a_swiftui_text_in_a_framework_file_still_counts_as_the_app_bundle(tmp_path):
    # SwiftUI `Text` has no bundle argument and resolves against Bundle.main
    # regardless of which module the view is compiled into.
    (tmp_path / "View.swift").write_text('Text("Speed presets")\n', encoding="utf-8")
    keys, _ = ps.inventory([tmp_path])
    assert "Speed presets" in keys


def test_fingerprint_ignores_a_language_that_ships_no_table(tmp_path):
    # The CI gate runs `--langs de,es,fr,it`; the documented regeneration command
    # defaults to `en,de,es,fr,it`. English lives in the code and ships no table,
    # so naming it must not change the fingerprint — otherwise the report is
    # PERMANENTLY stale and the gate that detects staleness becomes noise.
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"a": "A"})
    src = tmp_path / "src"; src.mkdir()
    (src / "S.swift").write_text('Text("a")\n', encoding="utf-8")
    with_en = ps.state_fingerprint([src], tmp_path, ["en", "de"])
    without = ps.state_fingerprint([src], tmp_path, ["de"])
    assert with_en == without


def test_fingerprint_still_changes_when_a_shipped_value_changes(tmp_path):
    # The relaxation above must not make the fingerprint blind.
    src = tmp_path / "src"; src.mkdir()
    (src / "S.swift").write_text('Text("a")\n', encoding="utf-8")
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"a": "A"})
    before = ps.state_fingerprint([src], tmp_path, ["en", "de"])
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"a": "B"})
    assert ps.state_fingerprint([src], tmp_path, ["en", "de"]) != before


def test_a_missing_development_language_table_is_not_a_finding(tmp_path):
    # English lives in the CODE. `en.lproj/Localizable.strings` is deliberately
    # not wired into the Xcode project, so reporting its absence turns the
    # documented no-flag command into a permanent red that teaches people to
    # ignore the gate.
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"a": "A"})
    kinds = [f.kind for f in ps.check_tables(tmp_path, ["en", "de"])]
    assert "missing_table" not in kinds


def test_a_missing_translation_table_is_still_a_finding(tmp_path):
    # The relaxation is for the development language ONLY.
    _write_strings(tmp_path / "de.lproj" / "Localizable.strings", {"a": "A"})
    findings = ps.check_tables(tmp_path, ["en", "de", "fr"])
    assert [(f.kind, f.lang) for f in findings if f.kind == "missing_table"] == [("missing_table", "fr")]


# ------------------------------------- a literal in a NON-localizing position
#
# `Text(_ key: LocalizedStringKey)` looks a key up ONLY for a string LITERAL.
# Pass a `String` variable and Swift picks `Text(_ content: S) where S:
# StringProtocol`, which renders the characters verbatim. So a helper typed
# `func row(title: String)` that renders `Text(title)` localizes nothing, and an
# English literal handed to it renders English in every language — while the
# extractor still sees a quoted string near a UI call and the table still
# carries a perfectly good translation nobody reads.
#
# Found on device: Settings showed "Get Help" in German and Italian with
# "Hilfe" and "Assistenza" sitting unused in the tables.

def test_flags_a_literal_passed_to_a_title_parameter_of_a_plain_helper():
    src = 'row(title: "Get Help", index: 10, selection: self.$sel, destination: v)'
    assert ps.unlocalized_literals(src) == [("row", "Get Help")]


def test_an_already_localized_value_in_the_same_position_is_not_flagged():
    # Every other caller in the real file passes `DisplayStrings.x`, which is an
    # NSLocalizedString result. Only a LITERAL can be the defect.
    src = 'row(title: DisplayStrings.aboutApp, index: 2, selection: s, destination: v)'
    assert ps.unlocalized_literals(src) == []


def test_a_swiftui_initializer_in_the_same_shape_is_not_flagged():
    # `Section(header: Text("Support"))` and `Button("Borrow")` DO localize —
    # flagging them would make the detector unrunnable on this tree.
    for src in ('Section(header: Text("Support"))',
                'Button("Borrow") { borrow() }',
                'Label("Catalog", systemImage: "book")',
                'Text("Get Help")',
                'NavigationLink("Settings", destination: v)'):
        assert ps.unlocalized_literals(src) == [], src


def test_an_nslocalizedstring_argument_is_not_flagged():
    src = 'row(title: NSLocalizedString("Get Help", comment: ""), index: 10)'
    assert ps.unlocalized_literals(src) == []


# Pre-existing violations elsewhere in the tree are BASELINED, exactly as the
# doc gates do it: the count may not grow, and a baselined file that starts
# coming back clean also fails, so the amnesty can neither expand nor go stale.
# The 14 strings behind these sites were invisible to the inventory entirely —
# no localizing call ever names them — so "594/594" was really 594 of 608.
_UNLOCALIZED_BASELINE = {
    "Palace/Packages/PalaceTriageBot/Sources/TriageBotUI/KBMatchCard.swift": 4,
    "Palace/Packages/PalaceTriageBot/Sources/TriageBotUI/SupportChatView.swift": 1,
    "Palace/Packages/PalaceTriageBot/Sources/TriageBotUI/TicketPreviewCard.swift": 3,
    "Palace/Reader2/Typography/TypographySettingsView.swift": 5,
    "Palace/Reader2/UI/TPPEPUBViewController.swift": 1,
}


def _scan_tree_for_unlocalized() -> dict[str, int]:
    root = Path(__file__).resolve().parents[2]
    counts: dict[str, int] = {}
    for f in sorted((root / "Palace").rglob("*.swift")):
        rel = str(f.relative_to(root))
        if ps.is_developer_path(f) or "/Tests/" in rel or rel.endswith("Tests.swift"):
            continue
        n = len(ps.unlocalized_literals(f.read_text(encoding="utf-8", errors="replace")))
        if n:
            counts[rel] = n
    return counts


def test_no_new_literal_lands_in_a_non_localizing_position():
    counts = _scan_tree_for_unlocalized()
    new = {f: n for f, n in counts.items()
           if n > _UNLOCALIZED_BASELINE.get(f, 0)}
    assert not new, ("new unlocalized display literals: " + repr(new)
                     + "\npass the value through NSLocalizedString; "
                       "Text(aString) performs no lookup")


def test_the_baseline_does_not_go_stale():
    counts = _scan_tree_for_unlocalized()
    fixed = {f: n for f, n in _UNLOCALIZED_BASELINE.items()
             if counts.get(f, 0) < n}
    assert not fixed, ("these improved — lower the baseline: " + repr(fixed))


def test_the_settings_rows_proven_on_device_are_fixed():
    # The regression this QA run actually caught: Settings rendered "Get Help"
    # in German and Italian. Named explicitly so a revert fails loudly rather
    # than merely nudging a count.
    root = Path(__file__).resolve().parents[2]
    src = (root / "Palace/Settings/NewSettings/TPPSettingsView.swift").read_text(encoding="utf-8")
    assert ps.unlocalized_literals(src) == []
