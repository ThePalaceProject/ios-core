"""
test_check_snakecase_codingkeys.py — pytest for the SCK-1 detector.

Each test copies one fixture into a temp dir and runs
scripts/check-snakecase-codingkeys.py --scan against it.

The class: `.convertFromSnakeCase` rewrites the incoming JSON key BEFORE it is
matched against CodingKeys, so a case whose raw value is the snake_case spelling
matches nothing — silently, with no throw. See PR #1462 review r4073991333.

Coverage:
  violations
    - violation_snakecase_key.swift      → SCK-1 (the canonical shape)
    - violation_nested_type.swift        → SCK-1 (nested types inherit the strategy)
    - violation_named_conformance.swift  → SCK-1 (enum not named CodingKeys)
    - violation_single_line_enum.swift   → SCK-1 (single-line enum body; guards the
      depth fix against closing the window before the declaration line is read)
  must-NOT-flag (each maps to something real in the tree)
    - clean_camelcase_keys.swift         → the fix this PR ships
    - clean_non_codingkey_enum.swift     → OPDS2LinkRel shape
    - clean_wire_enum_after_codingkeys.swift → OPDS2LinkRel shape AFTER a CodingKeys
      block in the same file. Regression fixture for the scan-window off-by-one
      found in blast-radius review: clean_non_codingkey_enum has no CodingKeys
      enum, so it never entered the discriminating path and the exclusion held by
      luck. This one holds it by structure.
    - clean_string_constant.swift        → TPPProblemDocument:41 shape
    - clean_no_strategy.swift            → snake_case keys are CORRECT with no strategy
    - annotated_skip.swift               → escape hatch
  wiring
    - the real tree scans clean and exits 0
    - --diff is accepted (the hook passes it uniformly) and does not error
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-snakecase-codingkeys.py"
_FIXTURE_DIR = _REPO_ROOT / "scripts" / "tests" / "fixtures" / "snakecase_codingkeys"


def _run(scan_root: Path, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(_SCRIPT), "--scan", str(scan_root), *extra],
        capture_output=True, text=True,
    )


def _scan_fixture(tmp_path: Path, fixture: str) -> subprocess.CompletedProcess:
    palace = tmp_path / "Palace"
    palace.mkdir()
    shutil.copy(_FIXTURE_DIR / fixture, palace / fixture)
    return _run(tmp_path)


@pytest.mark.parametrize("fixture", [
    "violation_snakecase_key.swift",
    "violation_nested_type.swift",
    "violation_named_conformance.swift",
    "violation_single_line_enum.swift",
])
def test_violation_is_flagged_and_blocks(tmp_path, fixture):
    result = _scan_fixture(tmp_path, fixture)
    assert result.returncode == 1, (
        f"{fixture} must BLOCK. stdout={result.stdout!r} stderr={result.stderr!r}")
    assert "SCK-1" in result.stdout
    assert "show_title" in result.stdout or "first_name" in result.stdout
    assert "can never match" in result.stdout


@pytest.mark.parametrize("fixture", [
    "clean_camelcase_keys.swift",
    "clean_non_codingkey_enum.swift",
    "clean_string_constant.swift",
    "clean_no_strategy.swift",
    "annotated_skip.swift",
    "clean_wire_enum_after_codingkeys.swift",
])
def test_clean_fixture_passes(tmp_path, fixture):
    result = _scan_fixture(tmp_path, fixture)
    assert result.returncode == 0, (
        f"{fixture} must NOT be flagged. stdout={result.stdout!r}")
    assert "SCK-1" not in result.stdout


def test_violation_reports_the_offending_line(tmp_path):
    result = _scan_fixture(tmp_path, "violation_snakecase_key.swift")
    # The fixture's offending case is on line 6.
    assert "violation_snakecase_key.swift:6:" in result.stdout, result.stdout


def test_real_tree_scans_clean(tmp_path):
    """The clean-diff / clean-tree pass CLAUDE.md rule #4 requires.

    A detector that blocks the current tree cannot land, and one that is never
    exercised against real code is a wiring bug waiting to happen.
    """
    result = _run(_REPO_ROOT)
    assert result.returncode == 0, (
        f"detector must not block the current tree. stdout={result.stdout!r}")
    assert "SCK-1" not in result.stdout


def test_diff_flag_is_accepted_and_does_not_error(tmp_path):
    """The pre-commit harness passes --diff to every detector uniformly.

    This rule is deliberately whole-tree, so --diff must be tolerated rather
    than rejected — a detector that errors on the interface its caller uses
    fails every commit, including clean ones.
    """
    result = _scan_fixture(tmp_path, "clean_camelcase_keys.swift")
    assert result.returncode == 0

    palace = tmp_path / "Palace"
    with_diff = subprocess.run(
        [sys.executable, str(_SCRIPT), "--scan", str(tmp_path), "--diff", "-"],
        capture_output=True, text=True, input="",
    )
    assert with_diff.returncode == 0, (
        f"--diff must not error. stderr={with_diff.stderr!r}")
    assert palace.exists()


def test_no_block_flag_reports_without_blocking(tmp_path):
    palace = tmp_path / "Palace"
    palace.mkdir()
    shutil.copy(_FIXTURE_DIR / "violation_snakecase_key.swift",
                palace / "violation_snakecase_key.swift")
    result = _run(tmp_path, "--no-block")
    assert result.returncode == 0
    assert "SCK-1" in result.stdout, "findings must still be REPORTED under --no-block"
