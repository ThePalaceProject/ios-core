"""Tests for the pbxproj merge driver.

prior-art-checked: the suggested matches were a fleet roster, glyph capture,
memory writes and a harness defect-escape test, none of which merge a
pbxproj. In scripts/tests/ three files mention pbxproj (relevance, committed
signing, strings) and none tests a merge driver.

The driver exists to union membership conflicts and to refuse everything
else, so both halves need pinning. A driver that resolved too much would
reintroduce the duplicate-key defect `.gitattributes` records; one that
refused everything would be the manual process it replaces.
"""

import importlib.util
import pathlib

import pytest

MODULE_PATH = (
    pathlib.Path(__file__).resolve().parent.parent / "pbxproj_merge_driver.py"
)
_spec = importlib.util.spec_from_file_location("pbxproj_merge_driver", MODULE_PATH)
driver = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(driver)


def conflicted(ours: str, theirs: str) -> str:
    return (
        "/* Begin PBXBuildFile section */\n"
        "<<<<<<< HEAD\n"
        f"{ours}\n"
        "=======\n"
        f"{theirs}\n"
        ">>>>>>> origin/develop\n"
        "/* End PBXBuildFile section */\n"
    )


BUILD_FILE_A = (
    "\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* Alpha.swift in Sources */ = "
    "{isa = PBXBuildFile; fileRef = 111111111111111111111111 /* Alpha.swift */; };"
)
BUILD_FILE_B = (
    "\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* Beta.swift in Sources */ = "
    "{isa = PBXBuildFile; fileRef = 222222222222222222222222 /* Beta.swift */; };"
)
SOURCES_A = "\t\t\t\tCCCCCCCCCCCCCCCCCCCCCCCC /* Alpha.swift in Sources */,"
SOURCES_B = "\t\t\t\tDDDDDDDDDDDDDDDDDDDDDDDD /* Beta.swift in Sources */,"
FILE_REF_A = (
    "\t\tEEEEEEEEEEEEEEEEEEEEEEEE /* Alpha.swift */ = {isa = PBXFileReference; "
    "includeInIndex = 1; lastKnownFileType = sourcecode.swift; path = Alpha.swift; "
    'sourceTree = "<group>"; };'
)


# --- the half that resolves -------------------------------------------------


def test_two_branches_adding_different_build_files_keep_both():
    """The case this driver exists for: both sides are new keys."""
    out = driver.merge(conflicted(BUILD_FILE_A, BUILD_FILE_B))
    assert "Alpha.swift in Sources */ = {isa = PBXBuildFile" in out
    assert "Beta.swift in Sources */ = {isa = PBXBuildFile" in out
    assert "<<<<<<<" not in out and ">>>>>>>" not in out


def test_sources_phase_entries_are_unioned():
    out = driver.merge(conflicted(SOURCES_A, SOURCES_B))
    assert SOURCES_A.strip() in out
    assert SOURCES_B.strip() in out


def test_file_reference_and_phase_entry_mix_resolves():
    out = driver.merge(conflicted(FILE_REF_A, SOURCES_B))
    assert "Alpha.swift */ = {isa = PBXFileReference" in out
    assert SOURCES_B.strip() in out


def test_an_unconflicted_file_is_returned_unchanged():
    text = "/* Begin PBXBuildFile section */\n" + BUILD_FILE_A + "\n"
    assert driver.merge(text) == text


def test_identical_lines_on_both_sides_are_not_duplicated():
    out = driver.merge(conflicted(SOURCES_A, SOURCES_A))
    assert out.count("Alpha.swift in Sources */,") == 1


# --- the half that refuses --------------------------------------------------


def test_a_build_setting_conflict_is_refused():
    """The defect `.gitattributes` measured: two values for one key."""
    with pytest.raises(driver.Refusal):
        driver.merge(
            conflicted(
                "\t\t\t\tCURRENT_PROJECT_VERSION = 510;",
                "\t\t\t\tCURRENT_PROJECT_VERSION = 500;",
            )
        )


def test_a_marketing_version_conflict_is_refused():
    with pytest.raises(driver.Refusal):
        driver.merge(
            conflicted(
                "\t\t\t\tMARKETING_VERSION = 3.3.0;",
                "\t\t\t\tMARKETING_VERSION = 3.2.4;",
            )
        )


def test_the_same_file_added_under_two_keys_is_refused():
    """Unioning this would compile the file twice; nothing else catches it."""
    a = "\t\t\t\t111111111111111111111111 /* Same.swift in Sources */,"
    b = "\t\t\t\t222222222222222222222222 /* Same.swift in Sources */,"
    with pytest.raises(driver.Refusal) as excinfo:
        driver.merge(conflicted(a, b))
    assert "Same.swift" in str(excinfo.value)


def test_a_hunk_mixing_membership_and_a_setting_is_refused():
    """One non-membership line poisons the whole hunk."""
    with pytest.raises(driver.Refusal):
        driver.merge(
            conflicted(SOURCES_A + "\n\t\t\t\tSWIFT_VERSION = 5.0;", SOURCES_B)
        )


def test_one_bad_hunk_refuses_the_whole_file():
    """A later settings hunk must not be rescued by an earlier clean one."""
    text = (
        "<<<<<<< HEAD\n" + SOURCES_A + "\n=======\n" + SOURCES_B + "\n>>>>>>> x\n"
        "<<<<<<< HEAD\n\t\tSWIFT_VERSION = 5.0;\n=======\n"
        "\t\tSWIFT_VERSION = 6.0;\n>>>>>>> x\n"
    )
    with pytest.raises(driver.Refusal):
        driver.merge(text)


def test_an_unterminated_conflict_is_refused():
    with pytest.raises(driver.Refusal):
        driver.merge("<<<<<<< HEAD\n" + BUILD_FILE_A + "\n")


def test_a_lowercase_uuid_is_not_treated_as_membership():
    """pbxproj UUIDs are uppercase; a lowercase lookalike is not an entry."""
    lower = "\t\t\t\taaaaaaaaaaaaaaaaaaaaaaaa /* Alpha.swift in Sources */,"
    assert not driver.is_membership_line(lower)


# --- the predicate itself ---------------------------------------------------


def test_membership_predicate_accepts_each_shape_and_rejects_prose():
    assert driver.is_membership_line(BUILD_FILE_A)
    assert driver.is_membership_line(FILE_REF_A)
    assert driver.is_membership_line(SOURCES_A)
    assert driver.is_membership_line("\t\t\t\tFFFFFFFFFFFFFFFFFFFFFFFF /* Dir */,")
    assert driver.is_membership_line("")
    assert not driver.is_membership_line("\t\t\t\tSWIFT_VERSION = 5.0;")
    assert not driver.is_membership_line("/* Begin PBXBuildFile section */")


def test_entry_name_strips_the_phase_suffix():
    assert driver.entry_name(SOURCES_A) == "Alpha.swift"
    assert driver.entry_name(FILE_REF_A) == "Alpha.swift"
    assert driver.entry_name("no comment here") is None


# --- the driver entry point, which is where the real defect lived -----------
#
# The first version of main() read %A expecting conflict markers. Git hands a
# driver three UNMERGED files, so there were none: it wrote ours back and
# exited 0, dropping 10 of develop's files from a real merge. These pin the
# entry point, not just the hunk resolver.


def write_trio(tmp_path, base: str, ours: str, theirs: str):
    b = tmp_path / "base.pbxproj"
    o = tmp_path / "ours.pbxproj"
    t = tmp_path / "theirs.pbxproj"
    b.write_text(base)
    o.write_text(ours)
    t.write_text(theirs)
    return b, o, t


SECTION_HEAD = "/* Begin PBXBuildFile section */\n"
SECTION_TAIL = "/* End PBXBuildFile section */\n"


def test_driver_keeps_their_added_file(tmp_path):
    """The defect: their side must survive, not be overwritten by ours."""
    base = SECTION_HEAD + SECTION_TAIL
    ours = SECTION_HEAD + BUILD_FILE_A + "\n" + SECTION_TAIL
    theirs = SECTION_HEAD + BUILD_FILE_B + "\n" + SECTION_TAIL
    b, o, t = write_trio(tmp_path, base, ours, theirs)

    rc = driver.main(
        ["--base", str(b), "--ours", str(o), "--theirs", str(t)]
    )

    assert rc == 0
    out = o.read_text()
    assert "Alpha.swift" in out, "ours was lost"
    assert "Beta.swift" in out, "theirs was lost — the shipped defect"


def test_driver_keeps_their_file_when_ours_added_nothing(tmp_path):
    """Ours unchanged from base: the result must still gain their file."""
    base = SECTION_HEAD + SECTION_TAIL
    b, o, t = write_trio(
        tmp_path, base, base, SECTION_HEAD + BUILD_FILE_B + "\n" + SECTION_TAIL
    )

    assert driver.main(["--base", str(b), "--ours", str(o), "--theirs", str(t)]) == 0
    assert "Beta.swift" in o.read_text()


def test_driver_refuses_a_settings_conflict(tmp_path):
    """A build-number disagreement must reach a human, not resolve."""
    base = "\t\t\t\tCURRENT_PROJECT_VERSION = 500;\n"
    b, o, t = write_trio(
        tmp_path,
        base,
        "\t\t\t\tCURRENT_PROJECT_VERSION = 510;\n",
        "\t\t\t\tCURRENT_PROJECT_VERSION = 520;\n",
    )

    assert driver.main(["--base", str(b), "--ours", str(o), "--theirs", str(t)]) == 1
    # Ours is left untouched so git keeps the conflict for the human.
    assert "510" in o.read_text()


def test_verify_union_catches_a_dropped_file():
    """The guard that caught the shipped defect, exercised directly."""
    ours = SECTION_HEAD + SOURCES_A + "\n" + SECTION_TAIL
    theirs = SECTION_HEAD + SOURCES_B + "\n" + SECTION_TAIL
    with pytest.raises(driver.Refusal) as excinfo:
        driver.verify_union(ours, ours, theirs)
    assert "Beta.swift" in str(excinfo.value)


def test_verify_union_passes_a_true_union():
    ours = SECTION_HEAD + SOURCES_A + "\n" + SECTION_TAIL
    theirs = SECTION_HEAD + SOURCES_B + "\n" + SECTION_TAIL
    both = SECTION_HEAD + SOURCES_A + "\n" + SOURCES_B + "\n" + SECTION_TAIL
    driver.verify_union(both, ours, theirs)
