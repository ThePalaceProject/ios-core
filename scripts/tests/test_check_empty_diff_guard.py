"""
test_check_empty_diff_guard.py — regression test for the false-green-empty-diff
wall-failure (2026-07-01, swarm_495a88d9).

A diff-consuming detector that reads from stdin and gets NOTHING must fail
loudly (nonzero) instead of reporting exit 0 ("green") — otherwise a
misinvocation (nobody piped a diff) silently masks real findings, as happened
when `check-blast-radius.py --quiet` was run standalone with empty stdin and
falsely passed a real `#if DEBUG` finding.

Coverage:
  - Unit: `_checklib.read_diff` — empty stdin exits 2; allow_empty returns "";
    non-empty stdin returns content; missing named file exits 2.
  - Integration: representative detectors (check-blast-radius,
    check-superpartner-spectrum) exit nonzero on empty stdin, and still run
    normally when handed a real diff via --diff.
"""

from __future__ import annotations

import io
import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPTS = _REPO_ROOT / "scripts"

# Detectors that consume a unified diff via _checklib.read_diff (stdin default).
_DIFF_DETECTORS = [
    "check-blast-radius.py",
    "check-superpartner-spectrum.py",
]

_SAMPLE_DIFF = (
    "diff --git a/Foo.swift b/Foo.swift\n"
    "--- a/Foo.swift\n"
    "+++ b/Foo.swift\n"
    "@@ -1,1 +1,2 @@\n"
    " let x = 1\n"
    "+let y = 2\n"
)


# --- Unit: read_diff guard --------------------------------------------------

@pytest.fixture(autouse=True)
def _import_checklib():
    if str(_SCRIPTS) not in sys.path:
        sys.path.insert(0, str(_SCRIPTS))


def test_read_diff_empty_stdin_exits_2(monkeypatch):
    import _checklib
    monkeypatch.setattr("sys.stdin", io.StringIO("   \n  \n"))
    with pytest.raises(SystemExit) as exc:
        _checklib.read_diff(None)
    assert exc.value.code == 2


def test_read_diff_empty_stdin_allow_empty_returns_blank(monkeypatch):
    import _checklib
    monkeypatch.setattr("sys.stdin", io.StringIO(""))
    assert _checklib.read_diff(None, allow_empty=True) == ""


def test_read_diff_nonempty_stdin_returns_content(monkeypatch):
    import _checklib
    monkeypatch.setattr("sys.stdin", io.StringIO(_SAMPLE_DIFF))
    assert _checklib.read_diff(None) == _SAMPLE_DIFF


def test_read_diff_missing_file_exits_2():
    import _checklib
    with pytest.raises(SystemExit) as exc:
        _checklib.read_diff(str(_REPO_ROOT / "does-not-exist.diff"))
    assert exc.value.code == 2


# --- Integration: real detectors reject empty stdin -------------------------

@pytest.mark.parametrize("detector", _DIFF_DETECTORS)
def test_detector_empty_stdin_is_not_green(detector):
    script = _SCRIPTS / detector
    if not script.is_file():
        pytest.skip(f"{detector} not present")
    proc = subprocess.run(
        [sys.executable, str(script), "--quiet"],
        input="",
        capture_output=True,
        text=True,
    )
    assert proc.returncode != 0, (
        f"{detector} returned exit 0 on EMPTY stdin — false green. "
        f"stdout={proc.stdout!r} stderr={proc.stderr!r}"
    )
    assert "empty" in proc.stderr.lower() or "no diff" in proc.stderr.lower()


@pytest.mark.parametrize("detector", _DIFF_DETECTORS)
def test_detector_real_diff_via_file_runs(tmp_path, detector):
    """A real diff handed via --diff must NOT trip the empty guard (it should
    scan normally — clean sample diff has no findings, so exit 0)."""
    script = _SCRIPTS / detector
    if not script.is_file():
        pytest.skip(f"{detector} not present")
    diff_file = tmp_path / "sample.diff"
    diff_file.write_text(_SAMPLE_DIFF)
    proc = subprocess.run(
        [sys.executable, str(script), "--diff", str(diff_file), "--quiet"],
        capture_output=True,
        text=True,
    )
    # The clean sample has no violations for either detector → exit 0, and
    # critically it must NOT be the exit-2 empty-input error.
    assert proc.returncode == 0, (
        f"{detector} unexpectedly failed on a clean real diff: "
        f"rc={proc.returncode} stderr={proc.stderr!r}"
    )
