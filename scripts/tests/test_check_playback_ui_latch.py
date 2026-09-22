"""Tests for check-playback-ui-latch.py (PP-5205 wall).

The controls matter more than the violation case. A detector that only ever sees a
violating fixture gets tuned to keep firing on whatever it was shown — during PP-5205
the author's scope conclusion said 2 survivors while the refined predicate said 1, and
the predicate was right. These tests pin BOTH directions, including the two real
functions that must NOT be flagged.
"""
from __future__ import annotations
import subprocess
import sys
import pathlib
import textwrap

REPO = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-playback-ui-latch.py"


def run(root: pathlib.Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(root)],
        capture_output=True, text=True,
    )


def write(root: pathlib.Path, rel: str, body: str) -> None:
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(textwrap.dedent(body))


def test_script_exists():
    # A missing script exits 127, which is neither pass nor fail of what we meant to test.
    assert SCRIPT.is_file(), f"detector missing at {SCRIPT}"


def test_flags_unlatched_blocking_predicate(tmp_path):
    """The PP-5205 shape: owns a blocking state, reads a live signal, no latch."""
    write(tmp_path, "Palace/UI/Thing.swift", """
        enum LoadingOverlayState { case hidden, downloading }
        nonisolated static func loadingOverlayState(
            isLoaded: Bool,
            isDownloading: Bool,
            forceSkeletons: Bool
        ) -> LoadingOverlayState {
            return .hidden
        }
    """)
    r = run(tmp_path)
    assert r.returncode == 1, r.stdout
    assert "loadingOverlayState" in r.stdout


def test_clean_when_latched(tmp_path):
    write(tmp_path, "Palace/UI/Thing.swift", """
        enum LoadingOverlayState { case hidden, downloading }
        nonisolated static func loadingOverlayState(
            isLoaded: Bool,
            isDownloading: Bool,
            hasStartedPlayback: Bool,
            forceSkeletons: Bool
        ) -> LoadingOverlayState {
            return .hidden
        }
    """)
    r = run(tmp_path)
    assert r.returncode == 0, r.stdout


def test_does_not_flag_a_bool_gate(tmp_path):
    """CONTROL — `shouldSurfaceLoadTimeout`'s real shape.

    It GATES a takeover rather than owning one, and is the backstop that makes the
    latch safe. Latching it would suppress genuine mid-session failures, so a
    detector that flags it would push someone toward the wrong fix.
    """
    write(tmp_path, "Palace/UI/Thing.swift", """
        nonisolated static func shouldSurfaceLoadTimeout(isLoaded: Bool, isDownloading: Bool) -> Bool {
            !isLoaded && !isDownloading
        }
    """)
    r = run(tmp_path)
    assert r.returncode == 0, r.stdout


def test_does_not_flag_unrelated_signal_consumers(tmp_path):
    """CONTROL — lock-screen metadata and book-cell progress read the same signals
    but block nothing. A naive 'takes isLoaded' predicate flagged 8 sites; the class
    is specifically 'returns a blocking UI state'."""
    write(tmp_path, "Palace/UI/NowPlaying.swift", """
        static func updateNowPlaying(isPlaying: Bool, position: Double) -> Void {}
        static func shouldResetDownloadProgress(wasDownloading: Bool, isDownloading: Bool) -> Bool { false }
    """)
    r = run(tmp_path)
    assert r.returncode == 0, r.stdout


def test_multiline_signature_is_seen(tmp_path):
    """Both real instances are written one-parameter-per-line; a single-line regex
    finds neither."""
    write(tmp_path, "Palace/UI/Thing.swift", """
        enum PresentationState { case a, b }
        static func presentationState(
            isBuffering: Bool,
            other: Int
        ) -> PresentationState { .a }
    """)
    r = run(tmp_path)
    assert r.returncode == 1, r.stdout


def test_escape_hatch_must_be_on_the_func_line(tmp_path):
    """Line-adjacent on purpose: a marker on a PRECEDING line is silently ignored by
    other linters in this repo, producing an annotation that looks applied and is not.
    """
    write(tmp_path, "Palace/UI/Ok.swift", """
        enum LoadingState { case a }
        static func s(isLoaded: Bool) -> LoadingState { .a } // no-playback-latch: gates only
    """)
    assert run(tmp_path).returncode == 0

    write(tmp_path, "Palace/UI/Bad.swift", """
        enum LoadingState { case a }
        // no-playback-latch: this placement does NOT count
        static func t(isLoaded: Bool) -> LoadingState { .a }
    """)
    r = run(tmp_path)
    assert r.returncode == 1, "a marker on a preceding line must NOT suppress"


def test_live_repo_is_clean():
    """The tree must stay clean once PP-5205 has landed."""
    r = run(REPO)
    assert r.returncode == 0, r.stdout
