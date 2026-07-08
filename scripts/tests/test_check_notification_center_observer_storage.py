"""
test_check_notification_center_observer_storage.py — pytest for the
D5-1 NotificationCenter observer-storage detector.

Each test invokes scripts/check-notification-center-observer-storage.py
via subprocess against a fixture Swift file under
scripts/tests/fixtures/notification_center/, using --scan on a temp
directory so the detector treats the fixture as if it were a
production Palace file.

Coverage (5 fixtures + 1 inline synthetic):
  - violation_unstored_observer.swift       → D5-1 flagged (PP-4329 verbatim)
  - clean_property_stored.swift             → no findings (canonical fix)
  - clean_removeobserver_in_deinit.swift    → no findings (deinit cleanup)
  - clean_annotated.swift                   → no findings (annotation escape)
  - clean_selector_form_with_deinit.swift   → no findings (selector form
                                              + deinit cleanup is the
                                              false-positive we explicitly
                                              guard against)
  - inline: no-addObserver-at-all           → no findings (sanity)
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = (
    _REPO_ROOT
    / "scripts"
    / "check-notification-center-observer-storage.py"
)
_FIXTURE_DIR = (
    _REPO_ROOT / "scripts" / "tests" / "fixtures" / "notification_center"
)


def _run_scan(scan_root: Path) -> subprocess.CompletedProcess:
    """Run the detector in --scan mode against a temp root.

    Using --scan (rather than --diff) sidesteps the diff-narrowing
    rule so the detector reports findings on every addObserver line
    in the fixture.
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
    """Copy a fixture into `<tmp>/Palace/AppInfrastructure/<fixture>`
    so the detector treats it as a production file under Palace/."""
    target_dir = tmp_path / "Palace" / "AppInfrastructure"
    target_dir.mkdir(parents=True, exist_ok=True)
    src = _FIXTURE_DIR / fixture_name
    dst = target_dir / fixture_name
    shutil.copy(src, dst)
    return tmp_path


def test_flags_unstored_closure_observer(tmp_path):
    """PP-4329 verbatim: closure-form addObserver whose return value
    is discarded, no removeObserver anywhere in the type → D5-1."""
    scan_root = _make_scan_root(tmp_path, "violation_unstored_observer.swift")
    result = _run_scan(scan_root)
    assert result.returncode == 1, (
        f"expected exit 1, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "D5-1" in result.stdout, (
        f"expected D5-1 finding in output, got: {result.stdout!r}"
    )
    assert "violation_unstored_observer.swift" in result.stdout
    assert "PP-4329" in result.stdout


def test_clean_when_token_stored_in_property(tmp_path):
    """Canonical PP-4329 fix: token captured in `firstRunFlowObserver`
    property + removeObserver before re-register. Detector PASSES."""
    scan_root = _make_scan_root(tmp_path, "clean_property_stored.swift")
    result = _run_scan(scan_root)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "D5-1" not in result.stdout, (
        f"did not expect D5-1 finding, got: {result.stdout!r}"
    )


def test_clean_when_removeObserver_in_deinit(tmp_path):
    """Token NOT captured per-observer, but the type body has a
    `deinit { removeObserver(self) }` cleanup. Detector treats the
    deinit removal as sufficient cleanup evidence. PASSES."""
    scan_root = _make_scan_root(
        tmp_path, "clean_removeobserver_in_deinit.swift"
    )
    result = _run_scan(scan_root)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "D5-1" not in result.stdout, (
        f"did not expect D5-1 finding, got: {result.stdout!r}"
    )


def test_clean_when_annotation_present(tmp_path):
    """`// no-observer-storage: <reason>` escape hatch on the preceding
    comment line for app-lifetime observers. Detector PASSES."""
    scan_root = _make_scan_root(tmp_path, "clean_annotated.swift")
    result = _run_scan(scan_root)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "D5-1" not in result.stdout, (
        f"did not expect D5-1 finding, got: {result.stdout!r}"
    )


def test_clean_when_selector_form_with_deinit(tmp_path):
    """Selector-form addObserver is OUT OF SCOPE per the architect
    contract — it has no return token. The detector should NOT flag
    it at all. The fixture also has a `removeObserver(self)` in
    deinit; even if a sibling closure-form appeared, the deinit
    cleanup would cover it. False-positive guard."""
    scan_root = _make_scan_root(
        tmp_path, "clean_selector_form_with_deinit.swift"
    )
    result = _run_scan(scan_root)
    assert result.returncode == 0, (
        f"expected exit 0, got {result.returncode}\n"
        f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
    )
    assert "D5-1" not in result.stdout, (
        f"did not expect D5-1 finding, got: {result.stdout!r}"
    )


def test_clean_when_no_addObserver_at_all(tmp_path):
    """Sanity: a file with NO addObserver calls anywhere must PASS.
    Inline so the fixture surface stays tight at 5."""
    target_dir = tmp_path / "Palace" / "AppInfrastructure"
    target_dir.mkdir(parents=True)
    src = target_dir / "no_observer_at_all.swift"
    src.write_text(
        "import Foundation\n"
        "final class NoObservers {\n"
        "    func doNothingWithObservers() {\n"
        "        print(\"nothing to see here\")\n"
        "    }\n"
        "}\n"
    )
    result = _run_scan(tmp_path)
    assert result.returncode == 0
    assert "D5-1" not in result.stdout


if __name__ == "__main__":  # pragma: no cover
    sys.exit(pytest.main([__file__, "-v"]))
