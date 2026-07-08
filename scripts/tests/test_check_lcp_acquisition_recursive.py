#!/usr/bin/env python3
"""
test_check_lcp_acquisition_recursive.py — pytest harness for
scripts/check-lcp-acquisition-recursive.py.

Drives the detector against fixture files in
scripts/tests/fixtures/lcp_acquisition/ and asserts:

  - violation_legacy_canOpenBook.swift            -> 1 finding (D1-1)
  - clean_with_indirectAcquisitions.swift         -> 0 findings
  - clean_with_hasLCPAcquisition_delegate.swift   -> 0 findings
  - annotated_exception.swift                     -> 0 findings (annotation honored)
  - no_lcp_in_scope.swift                         -> 0 findings (no LCP context)

Also asserts the exit code semantics (1 on violation, 0 on clean).

The detector's default scan dirs (`Palace/MyBooks/` etc.) are NOT used here
— each test invokes the script with `--scan-dir <fixture-path>` so the
fixture corpus is the only input.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-lcp-acquisition-recursive.py"
_FIXTURES_DIR = _REPO_ROOT / "scripts" / "tests" / "fixtures" / "lcp_acquisition"


def _run(fixture_path: Path) -> tuple[int, str, str]:
    """Run the detector against a single fixture (file or dir)."""
    result = subprocess.run(
        [
            sys.executable,
            str(_SCRIPT),
            "--scan-dir",
            str(fixture_path),
            "--quiet",
        ],
        capture_output=True,
        text=True,
        cwd=str(_REPO_ROOT),
        timeout=30,
    )
    return (result.returncode, result.stdout, result.stderr)


def test_violation_legacy_canOpenBook_flagged() -> None:
    """The PP-4407 / PP-4454 bug shape is flagged."""
    fixture = _FIXTURES_DIR / "violation_legacy_canOpenBook.swift"
    rc, out, _err = _run(fixture)
    assert rc == 1, f"expected exit 1 on violation fixture, got {rc}"
    assert "D1-1" in out, f"expected D1-1 finding code in stdout: {out!r}"
    assert "canOpenBook" in out, f"expected `canOpenBook` mentioned: {out!r}"
    assert "PP-4407" in out, f"expected wall ref `PP-4407` in finding: {out!r}"


def test_clean_with_indirectAcquisitions_not_flagged() -> None:
    """A function that walks `indirectAcquisitions` is clean."""
    fixture = _FIXTURES_DIR / "clean_with_indirectAcquisitions.swift"
    rc, out, _err = _run(fixture)
    assert rc == 0, f"expected exit 0 on clean fixture, got {rc} / {out!r}"
    assert "D1-1" not in out, f"unexpected D1-1 finding: {out!r}"


def test_clean_with_hasLCPAcquisition_delegate_not_flagged() -> None:
    """A function that delegates to `hasLCPAcquisition` is clean."""
    fixture = _FIXTURES_DIR / "clean_with_hasLCPAcquisition_delegate.swift"
    rc, out, _err = _run(fixture)
    assert rc == 0, f"expected exit 0 on delegate fixture, got {rc} / {out!r}"
    assert "D1-1" not in out, f"unexpected D1-1 finding: {out!r}"


def test_annotated_exception_not_flagged() -> None:
    """`// no-lcp-recursive: <reason>` above a func suppresses the finding."""
    fixture = _FIXTURES_DIR / "annotated_exception.swift"
    rc, out, _err = _run(fixture)
    assert rc == 0, f"expected exit 0 on annotated fixture, got {rc} / {out!r}"
    assert "D1-1" not in out, f"unexpected D1-1 finding: {out!r}"


def test_no_lcp_in_scope_not_flagged_false_positive_immunity() -> None:
    """
    `defaultAcquisition` used for non-LCP routing (availability/href) does
    not match. Detector must not false-positive on the BorrowOperation /
    BookCellModel shape.
    """
    fixture = _FIXTURES_DIR / "no_lcp_in_scope.swift"
    rc, out, _err = _run(fixture)
    assert rc == 0, f"expected exit 0 on no-LCP fixture, got {rc} / {out!r}"
    assert "D1-1" not in out, f"unexpected D1-1 finding: {out!r}"


def test_full_fixtures_dir_emits_exactly_one_finding() -> None:
    """
    Pointing the detector at the entire `lcp_acquisition/` fixture dir
    should yield exactly ONE finding (the violation fixture). All four
    clean/annotated/no-LCP fixtures must remain silent.
    """
    rc, out, _err = _run(_FIXTURES_DIR)
    assert rc == 1, f"expected exit 1 on full dir scan, got {rc} / {out!r}"
    # Count D1-1 finding lines.
    finding_lines = [
        ln for ln in out.splitlines() if "D1-1:" in ln
    ]
    assert len(finding_lines) == 1, (
        f"expected exactly 1 D1-1 finding in full-dir scan, got "
        f"{len(finding_lines)}: {finding_lines!r}"
    )
    assert "violation_legacy_canOpenBook.swift" in finding_lines[0], (
        f"finding cited the wrong file: {finding_lines[0]!r}"
    )


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
