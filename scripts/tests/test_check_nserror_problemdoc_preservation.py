"""
test_check_nserror_problemdoc_preservation.py — pytest for the D4-1 detector.

Each test invokes scripts/check-nserror-problemdoc-preservation.py via
subprocess against a fixture Swift file under
scripts/tests/fixtures/nserror_problemdoc/, using --scan on a temp directory
so the detector treats the fixture as if it were a production Palace file.

Coverage:
  - violation_dropped_problemdoc.swift  → D4-1 flagged (PP-3956 shape)
  - clean_with_title_preserved.swift    → no findings
  - clean_with_detail_preserved.swift   → no findings
  - annotated_skip.swift                → no findings (escape hatch)
  - no_problemdoc_in_scope.swift        → no findings (false-positive immunity)
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-nserror-problemdoc-preservation.py"
_FIXTURE_DIR = (
    _REPO_ROOT / "scripts" / "tests" / "fixtures" / "nserror_problemdoc"
)


def _run_scan(scan_root: Path) -> subprocess.CompletedProcess:
    """Run check-nserror-problemdoc-preservation in --scan mode against a
    temp root. Using --scan (rather than --diff) sidesteps the diff-narrowing
    rule so the detector reports findings on every NSError-construction line
    in the fixture."""
    return subprocess.run(
        [
            sys.executable,
            str(_SCRIPT),
            "--scan",
            str(scan_root),
            "--quiet",
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )


def _make_scan_root(tmp_path: Path, fixture_name: str) -> Path:
    """Copy a fixture into `<tmp>/Palace/Network/<fixture_name>` so the
    detector treats it as a production file under Palace/Network/."""
    target_dir = tmp_path / "Palace" / "Network"
    target_dir.mkdir(parents=True, exist_ok=True)
    src = _FIXTURE_DIR / fixture_name
    dst = target_dir / fixture_name
    shutil.copy(src, dst)
    return tmp_path


def test_detector_flags_dropped_problemdoc_on_token_refresh_rewrap(tmp_path):
    """Canonical PP-3956 shape: function binds `(error as NSError).
    problemDocument` and then constructs NSError(...) without referencing
    `problemDocument.title` / `.detail` / `makeFromProblemDocument` /
    `makeFromHTTPResponse`. Detector MUST flag."""
    scan_root = _make_scan_root(
        tmp_path, "violation_dropped_problemdoc.swift"
    )
    result = _run_scan(scan_root)
    assert result.returncode == 1, (
        f"expected exit 1, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "D4-1" in result.stdout, (
        f"expected D4-1 finding in output, got: {result.stdout!r}"
    )
    assert "violation_dropped_problemdoc.swift" in result.stdout
    assert "PP-3956" in result.stdout


def test_detector_clean_when_problemdoc_title_embedded(tmp_path):
    """userInfo includes `problemDocument.title` directly. Downstream
    `userFacingSignInError` will see the server-supplied title.
    Detector MUST PASS."""
    scan_root = _make_scan_root(tmp_path, "clean_with_title_preserved.swift")
    result = _run_scan(scan_root)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "D4-1" not in result.stdout, (
        f"did not expect D4-1 finding, got: {result.stdout!r}"
    )


def test_detector_clean_when_problemdoc_detail_embedded(tmp_path):
    """userInfo includes `problemDocument.detail` directly — equivalent
    to title preservation per the userFacingSignInError tuple contract.
    Detector MUST PASS."""
    scan_root = _make_scan_root(
        tmp_path, "clean_with_detail_preserved.swift"
    )
    result = _run_scan(scan_root)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "D4-1" not in result.stdout


def test_detector_clean_with_no_problemdoc_preservation_annotation(tmp_path):
    """`// no-problemdoc-preservation: <reason>` on the line above the
    NSError construction suppresses the finding — escape hatch for
    intentional generic re-wraps where the problemDoc is logged
    elsewhere. Detector MUST PASS."""
    scan_root = _make_scan_root(tmp_path, "annotated_skip.swift")
    result = _run_scan(scan_root)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "D4-1" not in result.stdout


def test_detector_clean_when_no_problemdoc_in_scope(tmp_path):
    """False-positive immunity: function constructs NSError(...) but
    has no TPPProblemDocument anywhere in scope (e.g. empty-username
    validation error). NOT the bug class — detector MUST PASS."""
    scan_root = _make_scan_root(tmp_path, "no_problemdoc_in_scope.swift")
    result = _run_scan(scan_root)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "D4-1" not in result.stdout


if __name__ == "__main__":  # pragma: no cover
    sys.exit(pytest.main([__file__, "-v"]))
