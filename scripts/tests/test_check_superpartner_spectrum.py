"""
test_check_superpartner_spectrum.py — pytest for the SP (superpartner-spectrum)
detector, `scripts/check-superpartner-spectrum.py` (severity: warn gate).

The detector is DIFF-based, not scan-based: it reads a unified diff from
`--diff <file>` (or stdin via `--diff -`) and flags new production Swift
functions (SP-1), enum cases (SP-2), and state transitions (SP-3) that have no
matching test in the SAME diff — unless marked `// no-superpartner: <reason>`.

Interface pinned here (must match the script exactly, or the gate is wiring-bugged):
  - input: unified diff on stdin (`--diff -`)
  - `--severity-floor low|medium|high` (default high)
  - exit 0 when nothing blocks at/above the floor; exit 1 when something does.

Every test asserts BOTH the exit code AND the finding text (or its absence).
The CLEAN-pass assertions are the ones that catch a wiring regression where the
detector rejects an interface it should accept.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-superpartner-spectrum.py"


def _run(diff_text: str, *extra_args: str) -> subprocess.CompletedProcess:
    """Feed `diff_text` to the detector on stdin (`--diff -`)."""
    return subprocess.run(
        [sys.executable, str(_SCRIPT), "--diff", "-", *extra_args],
        input=diff_text,
        capture_output=True,
        text=True,
        timeout=30,
    )


def _prod_func_diff(*, comment_line: str = "") -> str:
    """A diff adding a new func on a critical path (Palace/Audiobooks/).

    `comment_line` (if given) is inserted as an added line immediately before
    the func — used to exercise the `// no-superpartner:` escape hatch.
    """
    comment = f"+{comment_line}\n" if comment_line else ""
    return (
        "diff --git a/Palace/Audiobooks/AudiobookFoo.swift "
        "b/Palace/Audiobooks/AudiobookFoo.swift\n"
        "index 111..222 100644\n"
        "--- a/Palace/Audiobooks/AudiobookFoo.swift\n"
        "+++ b/Palace/Audiobooks/AudiobookFoo.swift\n"
        "@@ -10,2 +10,6 @@ class AudiobookFoo {\n"
        "     let x = 1\n"
        f"{comment}"
        "+    func computePlaybackOffset() -> Int {\n"
        "+        return 42\n"
        "+    }\n"
    )


# --- (a) VIOLATION IS CAUGHT ----------------------------------------------

def test_new_func_without_test_is_flagged_high_and_blocks():
    """A new non-private func on a critical path with no matching test is an
    SP-1 high finding and blocks at the default (high) floor → exit 1."""
    result = _run(_prod_func_diff())
    assert result.returncode == 1, (
        f"expected exit 1, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "SP-1" in result.stdout
    assert "computePlaybackOffset" in result.stdout
    assert ": high:" in result.stdout


def test_new_enum_case_without_test_is_flagged():
    """A new enum case with no test is an SP-2 finding (medium). It blocks at
    --severity-floor medium → exit 1."""
    diff = (
        "diff --git a/Palace/Book/BookThing.swift b/Palace/Book/BookThing.swift\n"
        "index 111..222 100644\n"
        "--- a/Palace/Book/BookThing.swift\n"
        "+++ b/Palace/Book/BookThing.swift\n"
        "@@ -3,2 +3,3 @@ enum BookThing {\n"
        "     case existing\n"
        "+    case brandNewCase\n"
    )
    result = _run(diff, "--severity-floor", "medium")
    assert result.returncode == 1, (
        f"expected exit 1, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "SP-2" in result.stdout
    assert "brandNewCase" in result.stdout


def test_new_state_transition_without_test_is_flagged():
    """A new `self.state = .buffering` with no round-trip / referencing test is
    an SP-3 finding (capped at medium). Blocks at floor medium → exit 1."""
    diff = (
        "diff --git a/Palace/Audiobooks/Player.swift b/Palace/Audiobooks/Player.swift\n"
        "index 111..222 100644\n"
        "--- a/Palace/Audiobooks/Player.swift\n"
        "+++ b/Palace/Audiobooks/Player.swift\n"
        "@@ -8,2 +8,3 @@ func advance() {\n"
        "     doThing()\n"
        "+    self.state = .buffering\n"
    )
    result = _run(diff, "--severity-floor", "medium")
    assert result.returncode == 1, (
        f"expected exit 1, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "SP-3" in result.stdout
    assert "buffering" in result.stdout


# --- (b) CLEAN INPUT PASSES (the wiring-bug catchers) ----------------------

def test_func_marked_no_superpartner_passes():
    """The `// no-superpartner: <reason>` escape hatch on the preceding line
    makes the same func an intentional, non-blocking decision → exit 0, no
    finding printed."""
    diff = _prod_func_diff(
        comment_line="    // no-superpartner: trivial constant, no observable behavior"
    )
    result = _run(diff)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "SP-1" not in result.stdout
    # The summary should count it as intentional, not missing.
    assert "1 marked intentional" in result.stderr


def test_func_with_referencing_test_in_same_diff_passes():
    """When the same diff adds a `func test…` that names/calls the new func,
    the detector treats it as paired → exit 0, no finding."""
    diff = (
        "diff --git a/Palace/Audiobooks/AudiobookFoo.swift "
        "b/Palace/Audiobooks/AudiobookFoo.swift\n"
        "index 111..222 100644\n"
        "--- a/Palace/Audiobooks/AudiobookFoo.swift\n"
        "+++ b/Palace/Audiobooks/AudiobookFoo.swift\n"
        "@@ -10,2 +10,5 @@ class AudiobookFoo {\n"
        "     let x = 1\n"
        "+    func computePlaybackOffset() -> Int {\n"
        "+        return 42\n"
        "+    }\n"
        "diff --git a/PalaceTests/Audiobooks/AudiobookFooTests.swift "
        "b/PalaceTests/Audiobooks/AudiobookFooTests.swift\n"
        "index 333..444 100644\n"
        "--- a/PalaceTests/Audiobooks/AudiobookFooTests.swift\n"
        "+++ b/PalaceTests/Audiobooks/AudiobookFooTests.swift\n"
        "@@ -5,2 +5,5 @@ class AudiobookFooTests: XCTestCase {\n"
        "     let y = 2\n"
        "+    func testComputePlaybackOffset_returnsExpected() {\n"
        "+        XCTAssertEqual(AudiobookFoo().computePlaybackOffset(), 42)\n"
        "+    }\n"
    )
    result = _run(diff)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "SP-1" not in result.stdout
    assert "1 have a test" in result.stderr


def test_empty_diff_passes():
    """No added lines → nothing to flag → exit 0."""
    result = _run("")
    assert result.returncode == 0
    assert result.stdout.strip() == ""


# --- Severity-floor wiring (finding printed, but does it BLOCK?) -----------

def test_medium_finding_does_not_block_at_default_high_floor():
    """A medium SP-2 finding is PRINTED but must NOT block at the default high
    floor → exit 0 even though a finding line is emitted. This pins the
    floor→exit-code wiring (the classic 'prints but wrong exit code' gap)."""
    diff = (
        "diff --git a/Palace/Book/BookThing.swift b/Palace/Book/BookThing.swift\n"
        "index 111..222 100644\n"
        "--- a/Palace/Book/BookThing.swift\n"
        "+++ b/Palace/Book/BookThing.swift\n"
        "@@ -3,2 +3,3 @@ enum BookThing {\n"
        "     case existing\n"
        "+    case brandNewCase\n"
    )
    result = _run(diff)  # default floor = high
    assert result.returncode == 0, (
        f"expected exit 0 (medium below high floor), got {result.returncode}\n"
        f"stdout: {result.stdout!r}"
    )
    # Finding is still surfaced, just non-blocking.
    assert "SP-2" in result.stdout
    assert "brandNewCase" in result.stdout


if __name__ == "__main__":  # pragma: no cover
    sys.exit(pytest.main([__file__, "-v"]))
