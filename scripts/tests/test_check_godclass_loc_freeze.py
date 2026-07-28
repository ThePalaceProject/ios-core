"""
test_check_godclass_loc_freeze.py — pytest for the Wave 0 god-class LOC freeze
gate (scripts/check-godclass-loc-freeze.sh).

Asserts BOTH directions (CLAUDE.md gate rule: a gate that only ever sees a
violation hides wiring bugs that block everything):
  (a) a file that GREW past its baseline -> FAIL (exit 1),
  (b) a file exactly AT baseline         -> PASS (exit 0) — the clean-diff pass,
  (c) a file that SHRANK                  -> PASS + prints the lower number,
  (d) a baselined file gone missing       -> FAIL (catch rename/move drift).

Each case builds a throwaway tree + baseline and points the script at it via
GODCLASS_ROOT / GODCLASS_BASELINE, so the test never depends on the live repo.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-godclass-loc-freeze.sh"


def _run(root: Path, baseline: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(_SCRIPT)],
        env={
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GODCLASS_ROOT": str(root),
            "GODCLASS_BASELINE": str(baseline),
        },
        capture_output=True,
        text=True,
        timeout=30,
    )


def _make_swift(path: Path, lines: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(f"// line {i}" for i in range(lines)) + "\n")


def test_script_passes_bash_syntax_check():
    r = subprocess.run(["bash", "-n", str(_SCRIPT)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_file_at_baseline_passes(tmp_path):
    _make_swift(tmp_path / "Palace" / "God.swift", 100)
    baseline = tmp_path / "baseline.txt"
    baseline.write_text("100 Palace/God.swift\n")
    r = _run(tmp_path, baseline)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "PASS" in r.stdout


def test_file_exceeding_baseline_fails(tmp_path):
    _make_swift(tmp_path / "Palace" / "God.swift", 137)
    baseline = tmp_path / "baseline.txt"
    baseline.write_text("100 Palace/God.swift\n")
    r = _run(tmp_path, baseline)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "GREW" in r.stdout
    assert "137" in r.stdout


def test_file_shrunk_passes_and_reports_new_number(tmp_path):
    _make_swift(tmp_path / "Palace" / "God.swift", 80)
    baseline = tmp_path / "baseline.txt"
    baseline.write_text("100 Palace/God.swift\n")
    r = _run(tmp_path, baseline)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "PASS" in r.stdout
    assert "ratchet" in r.stdout.lower()
    assert "80" in r.stdout


def test_missing_baselined_file_fails(tmp_path):
    # No file created on disk.
    baseline = tmp_path / "baseline.txt"
    baseline.write_text("100 Palace/Gone.swift\n")
    r = _run(tmp_path, baseline)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "MISSING" in r.stdout


def test_comments_and_blanks_ignored(tmp_path):
    _make_swift(tmp_path / "Palace" / "God.swift", 100)
    baseline = tmp_path / "baseline.txt"
    baseline.write_text("# a comment\n\n100 Palace/God.swift\n")
    r = _run(tmp_path, baseline)
    assert r.returncode == 0, r.stdout + r.stderr


def test_live_repo_baseline_passes():
    """The checked-in baseline must PASS against today's tree (zero false positives)."""
    r = subprocess.run(
        ["bash", str(_SCRIPT)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert r.returncode == 0, r.stdout + r.stderr
