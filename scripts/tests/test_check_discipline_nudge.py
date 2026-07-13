"""
test_check_discipline_nudge.py — pytest for the discipline-nudge advisory.

scripts/check-discipline-nudge.py is a NON-BLOCKING commit-discipline detector.
It ALWAYS exits 0 (never fails a commit) and instead prints advisory nudges to
stderr on two retro-tracked signals:

  1. root-cause prose  — a `fix`-type commit whose body has no "why it broke" line
  2. test:source ratio — a `fix`/`feat` commit that changes Palace/ source with
                          zero accompanying test files

Because exit is always 0, the observable behavior is the nudge text on stderr:
  - a violation  → the "discipline nudge" banner appears on stderr
  - a clean case → NO banner on stderr (the wiring-bug-catching assertion)

Interface exercised (matches the detector exactly):
  check-discipline-nudge.py --commit-msg <file> --diff <file|->
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-discipline-nudge.py"

_BANNER = "discipline nudge"


def _run(commit_msg: str, diff: str, tmp_path: Path) -> subprocess.CompletedProcess:
    """Write commit-msg + diff to temp files and invoke the detector exactly
    the way the commit-msg hook does: --commit-msg <file> --diff <file>."""
    msg_file = tmp_path / "COMMIT_EDITMSG"
    msg_file.write_text(commit_msg)
    diff_file = tmp_path / "staged.diff"
    diff_file.write_text(diff)
    return subprocess.run(
        [
            sys.executable,
            str(_SCRIPT),
            "--commit-msg",
            str(msg_file),
            "--diff",
            str(diff_file),
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )


# ---------------------------------------------------------------------------
# Violations — the nudge banner MUST appear on stderr.
# ---------------------------------------------------------------------------

def test_fix_commit_without_root_cause_line_nudges(tmp_path):
    """A `fix`-type commit whose body never explains WHY it broke triggers the
    root-cause nudge. Body deliberately avoids every root-cause phrase
    (because / regression / the bug / due to / caused by / …)."""
    msg = (
        "fix: crash on audiobook open\n"
        "\n"
        "Resolves the startup problem seen in QA. Adds a guard on the\n"
        "player state so open no longer terminates the session.\n"
    )
    result = _run(msg, diff="", tmp_path=tmp_path)

    # Advisory — never blocks.
    assert result.returncode == 0, (
        f"detector must always exit 0, got {result.returncode}\n"
        f"stderr: {result.stderr!r}"
    )
    assert _BANNER in result.stderr, (
        f"expected discipline nudge on stderr for a root-cause-less fix, "
        f"got: {result.stderr!r}"
    )
    assert "root-cause" in result.stderr, (
        f"expected the root-cause nudge specifically, got: {result.stderr!r}"
    )


def test_feat_touching_source_without_tests_nudges(tmp_path):
    """A `feat` commit that changes a Palace/ production source file with no
    accompanying test file triggers the test:source nudge."""
    msg = "feat: add mini player scrubber\n"
    diff = (
        "diff --git a/Palace/Audiobooks/AudiobookMiniPlayerView.swift "
        "b/Palace/Audiobooks/AudiobookMiniPlayerView.swift\n"
        "--- a/Palace/Audiobooks/AudiobookMiniPlayerView.swift\n"
        "+++ b/Palace/Audiobooks/AudiobookMiniPlayerView.swift\n"
        "@@ -1,1 +1,2 @@\n"
        " import SwiftUI\n"
        "+// scrubber\n"
    )
    result = _run(msg, diff=diff, tmp_path=tmp_path)

    assert result.returncode == 0, (
        f"detector must always exit 0, got {result.returncode}\n"
        f"stderr: {result.stderr!r}"
    )
    assert _BANNER in result.stderr, (
        f"expected discipline nudge for source-without-tests, "
        f"got: {result.stderr!r}"
    )
    assert "production source" in result.stderr, (
        f"expected the test:source nudge specifically, got: {result.stderr!r}"
    )


# ---------------------------------------------------------------------------
# Clean — the nudge banner MUST NOT appear (the wiring-bug-catching path).
# ---------------------------------------------------------------------------

def test_disciplined_fix_with_root_cause_and_test_is_clean(tmp_path):
    """A well-formed fix — root-cause prose in the body AND a paired test file
    in the diff — produces NO nudge. Both conditions must be satisfied so
    neither branch fires."""
    msg = (
        "fix: audiobook session terminated on dismiss\n"
        "\n"
        "The regression was introduced by the morphing-player rework, which\n"
        "released the toolkit player on collapse. Keep it retained.\n"
    )
    diff = (
        "diff --git a/Palace/Audiobooks/AudiobookSessionManager.swift "
        "b/Palace/Audiobooks/AudiobookSessionManager.swift\n"
        "--- a/Palace/Audiobooks/AudiobookSessionManager.swift\n"
        "+++ b/Palace/Audiobooks/AudiobookSessionManager.swift\n"
        "@@ -1,1 +1,2 @@\n"
        " import Foundation\n"
        "+// retain player\n"
        "diff --git a/PalaceTests/Audiobooks/AudiobookSessionManagerTests.swift "
        "b/PalaceTests/Audiobooks/AudiobookSessionManagerTests.swift\n"
        "--- a/PalaceTests/Audiobooks/AudiobookSessionManagerTests.swift\n"
        "+++ b/PalaceTests/Audiobooks/AudiobookSessionManagerTests.swift\n"
        "@@ -1,1 +1,2 @@\n"
        " import XCTest\n"
        "+// covers dismiss retention\n"
    )
    result = _run(msg, diff=diff, tmp_path=tmp_path)

    assert result.returncode == 0, (
        f"detector must always exit 0, got {result.returncode}\n"
        f"stderr: {result.stderr!r}"
    )
    assert _BANNER not in result.stderr, (
        f"a root-caused fix with a paired test must NOT nudge, "
        f"got: {result.stderr!r}"
    )


def test_non_fix_non_feat_commit_is_clean(tmp_path):
    """A plain chore commit is neither fix nor feat, so no discipline branch
    applies even with no root cause and no tests — NO nudge."""
    msg = "chore: bump readme copyright year\n"
    diff = (
        "diff --git a/README.md b/README.md\n"
        "--- a/README.md\n"
        "+++ b/README.md\n"
        "@@ -1,1 +1,1 @@\n"
        "-2025\n"
        "+2026\n"
    )
    result = _run(msg, diff=diff, tmp_path=tmp_path)

    assert result.returncode == 0, (
        f"detector must always exit 0, got {result.returncode}\n"
        f"stderr: {result.stderr!r}"
    )
    assert _BANNER not in result.stderr, (
        f"a non-fix/non-feat chore must NOT nudge, got: {result.stderr!r}"
    )


if __name__ == "__main__":  # pragma: no cover
    sys.exit(pytest.main([__file__, "-v"]))
