#!/usr/bin/env python3
"""
verify-pr.sh must recognise an audiobook change wherever the file lives.

WHY THIS EXISTS (PP-4976). The audiobook cross-vendor smoke gate matched only
`Palace/Audiobooks/` and `ios-audiobooktoolkit/`. A change that was entirely
about audiobook playback — a player view under `AppInfrastructure/` — did not
match, so the gate recorded a pass having run nothing, on a PR whose whole
subject was the audiobook player.

A gate that decides what to run from a path prefix is only as good as the
assumption that the code lives where the prefix says. This tree disproves that
assumption 25 times.

THE TWO ARMS, and why neither alone is enough. Measured against the real tree:

  - IMPORT ONLY misses `AudiobookBookmarkBusinessLogic.swift` and
    `AudioBookmark.swift`, which are audiobook code that does not import the
    toolkit.
  - PATH/MENTION ONLY pulls in `Strings.swift` and `AccessibilityIdentifiers.swift`,
    which name audiobooks and are localisation and test-identifier files.

Together they are precise on the tree as it stands. These tests pin both
directions, because a matcher that over-fires gets narrowed by the next person
who is annoyed by it, and one that under-fires is the defect above.
"""

import os
import re
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
VPR = os.path.join(REPO, "scripts", "verify-pr.sh")


def classifier_block() -> str:
    """Lift the audiobook classification out of verify-pr.sh."""
    with open(VPR, encoding="utf-8") as fh:
        text = fh.read()
    start = text.index("  # WHAT COUNTS AS AN AUDIOBOOK FILE.")
    end = text.index("  if [ -z \"$AUDIOBOOK_CHANGED\" ]; then")
    block = text[start:end]
    assert "AUDIOBOOK_BY_IMPORT" in block, "extraction range has drifted"
    assert "AUDIOBOOK_BY_PATH" in block, "extraction range has drifted"
    return block


def classify(changed: list[str]) -> list[str]:
    """Run the real block against a changed-file list, in the real repo.

    Deliberately NOT a Python re-implementation of the shell. Re-implementing
    the predicate under test is how a check ends up agreeing with itself — the
    lesson this repo recorded as fixture provenance.
    """
    script = (
        "#!/usr/bin/env bash\n"
        f"ALL_CHANGED=$(cat <<'EOF'\n" + "\n".join(changed) + "\nEOF\n)\n"
        + classifier_block()
        + '\nprintf "%s\\n" "$AUDIOBOOK_CHANGED"\n'
    )
    proc = subprocess.run(["bash", "-s"], input=script, capture_output=True,
                          text=True, cwd=REPO)
    return [l for l in proc.stdout.split("\n") if l.strip()]


# --- The defect this gate was written for ---------------------------------

def test_the_player_view_that_slipped_through_is_now_caught():
    """`AudiobookMorphingPlayerView.swift` lives under AppInfrastructure and is
    the file PP-4976 was filed about."""
    path = "Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift"
    assert os.path.exists(os.path.join(REPO, path)), "fixture file moved"
    assert classify([path]) == [path]


def test_the_original_prefixes_still_match():
    """Widening must not lose what already worked."""
    for path in ("Palace/Audiobooks/AudiobookSessionManager.swift",
                 "ios-audiobooktoolkit/Sources/Whatever.swift"):
        assert classify([path]), f"{path} no longer classifies as audiobook"


# --- The import arm, which the path arm cannot see -------------------------

def test_a_toolkit_importer_outside_the_prefixes_is_caught():
    """`CarPlayAudiobookBridge` is caught by BOTH arms, so use a file whose only
    signal is the import — its path says nothing about audiobooks."""
    path = "Palace/Keychain/TPPKeychainManager.swift"
    with open(os.path.join(REPO, path), encoding="utf-8") as fh:
        assert re.search(r"^\s*import PalaceAudiobookToolkit", fh.read(), re.M), \
            "fixture no longer imports the toolkit — pick another importer"
    assert classify([path]) == [path], "the import arm did not fire"


# --- The path arm, which the import arm cannot see -------------------------

@pytest.mark.parametrize("path", [
    "Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift",
    "Palace/Reader2/Bookmarks/AudioBookmark.swift",
])
def test_audiobook_named_files_without_the_import_are_caught(path):
    full = os.path.join(REPO, path)
    assert os.path.exists(full), f"fixture file moved: {path}"
    with open(full, encoding="utf-8") as fh:
        assert not re.search(r"^\s*import PalaceAudiobookToolkit", fh.read(), re.M), \
            "fixture now imports the toolkit — it no longer tests the path arm"
    assert classify([path]) == [path], "the path arm did not fire"


# --- Over-firing is the other failure mode ---------------------------------

@pytest.mark.parametrize("path", [
    "Palace/Utilities/Localization/Strings.swift",
    "Palace/Utilities/Testing/AccessibilityIdentifiers.swift",
])
def test_files_that_merely_mention_audiobooks_do_not_fire(path):
    """A matcher that runs the smoke on every localisation edit gets narrowed by
    whoever is annoyed by it next, and then the real defect comes back."""
    assert os.path.exists(os.path.join(REPO, path)), f"fixture file moved: {path}"
    assert classify([path]) == [], f"{path} wrongly classified as audiobook"


def test_an_unrelated_change_classifies_as_nothing():
    """Control: without this, every assertion above could pass on a matcher that
    simply returns its whole input."""
    assert classify(["Palace/Network/TPPNetworkExecutor.swift", "README.md"]) == []


def test_a_mixed_changeset_returns_only_the_audiobook_files():
    audiobook = "Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift"
    result = classify([audiobook, "README.md",
                       "Palace/Network/TPPNetworkExecutor.swift"])
    assert result == [audiobook]


def test_a_deleted_audiobook_file_is_still_caught_by_path():
    """A deletion cannot be read for its imports, so the path arm has to carry
    it. Named because the import arm silently skips absent files."""
    assert classify(["Palace/Audiobooks/DeletedThing.swift"])
