"""
test_check_test_name_vs_body.py — pytest for the fake-wiring-test detector.

Subject: scripts/check-test-name-vs-body.py

The detector is a runnable-grep escalation for the "fake wiring test" pattern
(wall-failures cs847892e8-arch1 / cs9a267b63-arch1): a Swift XCTest method
whose name embeds a multi-step verb (`Path`, `invokes`, `via`, `Wiring`, ...)
AND a PascalCase production-class noun, but whose body never references that
noun. Such a test's name PROMISES a production seam it never exercises.

CLI shape (learned by reading the detector):
  python3 scripts/check-test-name-vs-body.py [--quiet] <file> [<file> ...]
  exit 0 — clean (no multi-step name with an unreferenced embedded noun)
  exit 1 — at least one fake-wiring test found
  exit 2 — argument / file-read error
The detector takes Swift file PATHS as positional args — there is no --diff or
--scan mode, so we invoke it directly on the fixture files (no temp-dir/staging
dance needed).

Both paths are asserted, per CLAUDE.md CI rule #4 — the clean-pass assertion is
the one that catches a wiring bug (a detector that fires on everything).
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-test-name-vs-body.py"
_FIXTURE_DIR = _REPO_ROOT / "scripts" / "tests" / "fixtures" / "test_name_vs_body"


def _run(fixture_name: str) -> subprocess.CompletedProcess:
    """Run the detector against a single fixture file under _FIXTURE_DIR."""
    return subprocess.run(
        [sys.executable, str(_SCRIPT), str(_FIXTURE_DIR / fixture_name)],
        capture_output=True,
        text=True,
        timeout=30,
    )


def test_detector_flags_name_embedded_noun_absent_from_body():
    """A test named testTPPReauthenticatorPath_invokesRefreshToken whose body
    never references TPPReauthenticator must be flagged (exit 1)."""
    result = _run("violation_fake_wiring.swift")
    assert result.returncode == 1, (
        f"expected exit 1 (violation), got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    # Greppable finding: names the offending test + the embedded noun.
    assert "testTPPReauthenticatorPath_invokesRefreshToken" in result.stdout, (
        f"expected the offending test name in output, got: {result.stdout!r}"
    )
    assert "TPPReauthenticator" in result.stdout, (
        f"expected the embedded class noun in output, got: {result.stdout!r}"
    )
    assert "violation_fake_wiring.swift" in result.stdout


def test_detector_passes_when_body_references_embedded_noun():
    """Same multi-step name, but the body constructs TPPReauthenticator() —
    the detector must treat that as wiring evidence and PASS (exit 0).

    This is the wiring-bug guard: if the detector fired here too, it would be
    flagging on the NAME alone and the gate would be worthless."""
    result = _run("clean_references_noun.swift")
    assert result.returncode == 0, (
        f"expected exit 0 (clean), got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "no reference" not in result.stdout, (
        f"did not expect a finding, got: {result.stdout!r}"
    )


def test_detector_arg_error_on_missing_file():
    """A path that does not exist is an argument error (exit 2), not a
    silently-clean pass — proves the detector actually opened the file."""
    result = subprocess.run(
        [sys.executable, str(_SCRIPT),
         str(_FIXTURE_DIR / "does_not_exist.swift")],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 2, (
        f"expected exit 2 (arg/file error), got {result.returncode}\n"
        f"stderr: {result.stderr!r}"
    )


if __name__ == "__main__":  # pragma: no cover
    sys.exit(pytest.main([__file__, "-v"]))
