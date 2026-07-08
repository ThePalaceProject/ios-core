"""
test_check_foreign_host_401_scoping.py — pytest for the FH-1 detector.

Each test invokes scripts/check-foreign-host-401-scoping.py via subprocess
against a fixture Swift file under
scripts/tests/fixtures/foreign_host_401/, using --scan on a temp directory
so the detector treats the fixture as if it were a production Palace file.

Coverage:
  - violation_missing_guard.swift  → FH-1 flagged (statusCode == 401)
  - violation_nserror_code.swift   → FH-1 flagged (Phase-1a-revised case)
  - clean_with_provider.swift      → no findings
  - annotated_skip.swift           → no findings (escape hatch)
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-foreign-host-401-scoping.py"
_FIXTURE_DIR = _REPO_ROOT / "scripts" / "tests" / "fixtures" / "foreign_host_401"


def _run_scan(scan_root: Path) -> subprocess.CompletedProcess:
    """Run check_foreign_host_401_scoping in --scan mode against a temp root.

    Using --scan (rather than --diff) sidesteps the diff-narrowing rule so
    the detector reports findings on every dispatch line in the fixture.
    """
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
    detector treats it as a production file under Palace/."""
    target_dir = tmp_path / "Palace" / "Network"
    target_dir.mkdir(parents=True, exist_ok=True)
    src = _FIXTURE_DIR / fixture_name
    dst = target_dir / fixture_name
    shutil.copy(src, dst)
    return tmp_path


def test_detector_flags_raw_401_dispatch_without_scoping(tmp_path):
    """Bare `statusCode == 401` + mark-stale dispatch with no
    host-scoping reference must trigger FH-1."""
    scan_root = _make_scan_root(tmp_path, "violation_missing_guard.swift")
    result = _run_scan(scan_root)
    assert result.returncode == 1, (
        f"expected exit 1, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "FH-1" in result.stdout, (
        f"expected FH-1 finding in output, got: {result.stdout!r}"
    )
    assert "violation_missing_guard.swift" in result.stdout


def test_detector_flags_nsError_code_401_dispatch_without_scoping(tmp_path):
    """The Phase-1a-revised case: `nsError.code == 401` paired with
    `markCredentialsStale` in scope. statusCode-only predicate would
    miss this — must trigger FH-1."""
    scan_root = _make_scan_root(tmp_path, "violation_nserror_code.swift")
    result = _run_scan(scan_root)
    assert result.returncode == 1, (
        f"expected exit 1, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "FH-1" in result.stdout
    assert "violation_nserror_code.swift" in result.stdout


def test_detector_clean_with_currentAccountHostsProvider_reference(tmp_path):
    """PR #1044 canonical pattern: classifier wired with
    `currentAccountHostsProvider` in the same function body. Detector
    treats the reference as wiring evidence and PASSES."""
    scan_root = _make_scan_root(tmp_path, "clean_with_provider.swift")
    result = _run_scan(scan_root)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "FH-1" not in result.stdout, (
        f"did not expect FH-1 finding, got: {result.stdout!r}"
    )


def test_detector_clean_with_no_host_scoping_annotation(tmp_path):
    """A 401 + dispatch site that uses the `// no-host-scoping:`
    escape hatch (e.g. structurally closure-bound to the originating
    account) must PASS."""
    scan_root = _make_scan_root(tmp_path, "annotated_skip.swift")
    result = _run_scan(scan_root)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "FH-1" not in result.stdout, (
        f"did not expect FH-1 finding, got: {result.stdout!r}"
    )


def test_detector_clean_when_no_401_in_scope(tmp_path):
    """Synthetic case: a function that calls `markCredentialsStale()`
    without any 401 sentinel in scope is NOT the bug class — must
    PASS. Generated inline so the fixture surface stays tight at 4."""
    target_dir = tmp_path / "Palace" / "Network"
    target_dir.mkdir(parents=True)
    src = target_dir / "no_401_in_scope.swift"
    src.write_text(
        "import Foundation\n"
        "final class NoForOhOne {\n"
        "    func onSignOutTap(accountsManager: Any) {\n"
        "        // Explicit user-initiated sign-out — no 401 anywhere.\n"
        "        (accountsManager as AnyObject).markCredentialsStale()\n"
        "    }\n"
        "}\n"
    )
    result = _run_scan(tmp_path)
    assert result.returncode == 0
    assert "FH-1" not in result.stdout


def test_detector_clean_when_no_dispatch_in_scope(tmp_path):
    """Synthetic case: a function that observes 401 in scope but does
    NOT dispatch markCredentialsStale / refreshCredentialsIfNeeded
    is NOT the bug class — must PASS."""
    target_dir = tmp_path / "Palace" / "Network"
    target_dir.mkdir(parents=True)
    src = target_dir / "no_dispatch_in_scope.swift"
    src.write_text(
        "import Foundation\n"
        "final class NoDispatch {\n"
        "    func observe(response: HTTPURLResponse?) {\n"
        "        guard let response else { return }\n"
        "        if response.statusCode == 401 {\n"
        "            print(\"got 401 — purely logged\")\n"
        "        }\n"
        "    }\n"
        "}\n"
    )
    result = _run_scan(tmp_path)
    assert result.returncode == 0
    assert "FH-1" not in result.stdout


if __name__ == "__main__":  # pragma: no cover
    sys.exit(pytest.main([__file__, "-v"]))
