#!/usr/bin/env python3
"""
test_check_swiftui_placeholder_a11y.py — pytest verification of the D2 detector.

Drives `scripts/check-swiftui-placeholder-a11y.py --scan <fixture-dir>`
against four scenarios:

  1. violation                       — TextField + SecureField + Button
                                       label-closure, all bare. Expect
                                       D2-1 (×2) + D2-2 (≥1) findings,
                                       non-zero exit.
  2. clean-with-accessibilityLabel   — each control adds `.accessibilityLabel`
                                       in the downstream-cure window.
                                       Expect ZERO findings, exit 0.
  3. clean-with-bare-text-but-annotation
                                     — `// no-a11y-label:` annotation precedes
                                       each call. Expect ZERO findings, exit 0.
  4. false-positive-immunity         — Buttons / fields with long-sentence
                                       literal labels (above placeholder
                                       length cap). Expect ZERO findings,
                                       exit 0.

The detector script is invoked as a subprocess so we exercise the same path
the verify-pr.sh / pre-commit hook will use — no internal-API coupling.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-swiftui-placeholder-a11y.py"
_FIXTURES = _REPO_ROOT / "scripts" / "tests" / "fixtures" / "swiftui_a11y"


def _run_scan(fixture_filename: str) -> tuple[int, str, str]:
    """Run the detector against a single fixture file in isolation.

    We point `--scan` at a temp dir holding only the one fixture so the
    test is unaffected by neighbours.
    """
    import shutil
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        shutil.copy(_FIXTURES / fixture_filename, tmp_path / fixture_filename)
        result = subprocess.run(
            [sys.executable, str(_SCRIPT), "--scan", str(tmp_path), "--quiet"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    return (result.returncode, result.stdout, result.stderr)


def test_violation_fixture_emits_d2_findings_and_blocks() -> None:
    rc, stdout, stderr = _run_scan("violation.swift")
    assert rc != 0, (
        f"Expected non-zero exit on violation.swift; got 0.\n"
        f"stdout: {stdout!r}\nstderr: {stderr!r}"
    )
    # Expect at least two D2-1 findings (TextField + SecureField).
    d2_1_lines = [ln for ln in stdout.splitlines() if "D2-1:" in ln]
    assert len(d2_1_lines) >= 2, (
        f"Expected ≥2 D2-1 findings for the TextField+SecureField pair; "
        f"got {len(d2_1_lines)}.\nstdout:\n{stdout}"
    )
    # Expect at least one D2-2 finding for the Button label-closure.
    d2_2_lines = [ln for ln in stdout.splitlines() if "D2-2:" in ln]
    assert len(d2_2_lines) >= 1, (
        f"Expected ≥1 D2-2 finding for the bare-Text Button label; "
        f"got {len(d2_2_lines)}.\nstdout:\n{stdout}"
    )
    # Findings must cite PP-4421 lineage so the operator can trace.
    assert "PP-4421" in stdout, (
        f"Expected PP-4421 wall-failure citation in finding text.\n"
        f"stdout:\n{stdout}"
    )


def test_clean_with_accessibility_label_emits_no_findings() -> None:
    rc, stdout, stderr = _run_scan("clean_with_accessibility_label.swift")
    assert rc == 0, (
        f"Expected exit 0 on clean_with_accessibility_label.swift; got {rc}.\n"
        f"stdout: {stdout!r}\nstderr: {stderr!r}"
    )
    assert "D2-1:" not in stdout, (
        f"Did not expect D2-1 findings; got:\n{stdout}"
    )
    assert "D2-2:" not in stdout, (
        f"Did not expect D2-2 findings; got:\n{stdout}"
    )


def test_clean_with_annotation_suppresses_findings() -> None:
    rc, stdout, stderr = _run_scan("clean_with_annotation.swift")
    assert rc == 0, (
        f"Expected exit 0 on clean_with_annotation.swift; got {rc}.\n"
        f"stdout: {stdout!r}\nstderr: {stderr!r}"
    )
    assert "D2-1:" not in stdout, (
        f"Did not expect D2-1 findings (suppressed by annotation); got:\n{stdout}"
    )
    assert "D2-2:" not in stdout, (
        f"Did not expect D2-2 findings (suppressed by annotation); got:\n{stdout}"
    )


def test_false_positive_immunity_on_long_literals() -> None:
    rc, stdout, stderr = _run_scan("false_positive_immunity.swift")
    assert rc == 0, (
        f"Expected exit 0 on false_positive_immunity.swift (long literals "
        f"are out of scope); got {rc}.\nstdout: {stdout!r}\nstderr: {stderr!r}"
    )
    assert "D2-1:" not in stdout, (
        f"Did not expect D2-1 findings on long-literal fixture; got:\n{stdout}"
    )
    assert "D2-2:" not in stdout, (
        f"Did not expect D2-2 findings on long-literal fixture; got:\n{stdout}"
    )


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
