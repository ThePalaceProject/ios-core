"""
test_check_shared_read_count.py — pytest for the Wave 0 `.shared`-read
monotone-down gate (scripts/check-shared-read-count.sh).

Asserts BOTH directions (CLAUDE.md gate rule — clean-diff pass required):
  (a) count ABOVE baseline -> FAIL (exit 1),
  (b) count AT baseline    -> PASS (exit 0),
  (c) count BELOW baseline -> PASS + prints the lower number,
plus the exclusion contract: system singletons (URLSession.shared etc.) and
anything under Palace/Packages/ are NOT counted.

Each case builds a throwaway Palace/ tree and points the script at it via
SHARED_SCAN_ROOT / SHARED_BASELINE.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-shared-read-count.sh"


def _run(scan_root: Path, baseline: Path, mode: str | None = None) -> subprocess.CompletedProcess:
    cmd = ["bash", str(_SCRIPT)]
    if mode:
        cmd.append(mode)
    return subprocess.run(
        cmd,
        env={
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SHARED_SCAN_ROOT": str(scan_root),
            "SHARED_BASELINE": str(baseline),
        },
        capture_output=True,
        text=True,
        timeout=30,
    )


def _scan_root(tmp_path: Path, body: str, *, in_packages: str = "") -> Path:
    root = tmp_path / "Palace"
    (root).mkdir(parents=True, exist_ok=True)
    (root / "Feature.swift").write_text(body)
    if in_packages:
        pkg = root / "Packages" / "PalaceThing" / "Sources"
        pkg.mkdir(parents=True, exist_ok=True)
        (pkg / "Thing.swift").write_text(in_packages)
    return root


# Two non-system reads; several system reads that must be ignored.
_BODY_TWO = """
let a = AccountStateStore.shared
let b = ImageCache.shared
let sys1 = URLSession.shared
let sys2 = FileManager.shared
let sys3 = NotificationCenter.shared
let sys4 = UIApplication.shared
"""


def test_script_passes_bash_syntax_check():
    r = subprocess.run(["bash", "-n", str(_SCRIPT)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_count_mode_excludes_system_and_packages(tmp_path):
    root = _scan_root(tmp_path, _BODY_TWO, in_packages="let x = InPackage.shared\n")
    baseline = tmp_path / "b.txt"
    baseline.write_text("2\n")
    r = _run(root, baseline, mode="--count")
    assert r.returncode == 0
    assert r.stdout.strip() == "2", r.stdout  # 2 non-system, Packages excluded


def test_at_baseline_passes(tmp_path):
    root = _scan_root(tmp_path, _BODY_TWO)
    baseline = tmp_path / "b.txt"
    baseline.write_text("2\n")
    r = _run(root, baseline)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "PASS" in r.stdout


def test_above_baseline_fails(tmp_path):
    root = _scan_root(tmp_path, _BODY_TWO)
    baseline = tmp_path / "b.txt"
    baseline.write_text("1\n")  # tree has 2 -> over
    r = _run(root, baseline)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "FAIL" in r.stdout


def test_below_baseline_passes_and_reports(tmp_path):
    root = _scan_root(tmp_path, _BODY_TWO)
    baseline = tmp_path / "b.txt"
    baseline.write_text("5\n")  # tree has 2 -> under
    r = _run(root, baseline)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "PASS" in r.stdout
    assert "2" in r.stdout


def test_baseline_comments_ignored(tmp_path):
    root = _scan_root(tmp_path, _BODY_TWO)
    baseline = tmp_path / "b.txt"
    baseline.write_text("# note\n2\n")
    r = _run(root, baseline)
    assert r.returncode == 0, r.stdout + r.stderr


def test_live_repo_baseline_passes():
    """Checked-in baseline must PASS against today's Palace/ tree."""
    r = subprocess.run(["bash", str(_SCRIPT)], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr
