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
