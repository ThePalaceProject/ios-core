"""
test_check_appcontainer_locator_count.py — pytest for the Wave 0
`AppContainer.production()`-locator monotone-down gate
(scripts/check-appcontainer-locator-count.sh).

Asserts BOTH directions (CLAUDE.md gate rule — clean-diff pass required):
  (a) count ABOVE baseline -> FAIL (exit 1),
  (b) count AT baseline    -> PASS (exit 0),
  (c) count BELOW baseline -> PASS + prints the lower number,
plus the exclusion contract: allowlisted composition-root files, @Environment
default lines, and Palace/Packages/ are NOT counted.

Each case builds a throwaway tree + allowlist + baseline and points the script
at them via LOCATOR_SCAN_ROOT / LOCATOR_BASELINE / LOCATOR_ALLOWLIST.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-appcontainer-locator-count.sh"


def _run(scan_root, baseline, allowlist, mode=None) -> subprocess.CompletedProcess:
    cmd = ["bash", str(_SCRIPT)]
    if mode:
        cmd.append(mode)
    return subprocess.run(
        cmd,
        env={
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LOCATOR_SCAN_ROOT": str(scan_root),
            "LOCATOR_BASELINE": str(baseline),
            "LOCATOR_ALLOWLIST": str(allowlist),
        },
        capture_output=True,
        text=True,
        timeout=30,
    )


def _build_tree(tmp_path: Path) -> Path:
    """Two counted call sites, plus three that must be EXCLUDED."""
    root = tmp_path / "Palace"
    (root / "Book").mkdir(parents=True, exist_ok=True)
    (root / "AppInfrastructure").mkdir(parents=True, exist_ok=True)
    (root / "Packages" / "Pkg" / "Sources").mkdir(parents=True, exist_ok=True)

    # counted: 2 real locator uses in an ordinary file
    (root / "Book" / "BookService.swift").write_text(
        "let am = AppContainer.production().accountsManager\n"
        "let br = AppContainer.production().bookRegistry\n"
        "let e = something // @Environment placeholder unrelated\n"
    )
    # excluded: @Environment default line
    (root / "Book" / "SomeView.swift").write_text(
        "@Environment(\\.container) var c = AppContainer.production()\n"
    )
    # excluded: allowlisted composition root
    (root / "AppInfrastructure" / "AppContainer.swift").write_text(
        "static func production() -> AppContainer { AppContainer.production() }\n"
    )
    # excluded: under Packages/
    (root / "Packages" / "Pkg" / "Sources" / "P.swift").write_text(
        "let x = AppContainer.production().foo\n"
    )
    return root


def _allowlist(tmp_path: Path) -> Path:
    p = tmp_path / "allow.txt"
    p.write_text("# comment\nAppInfrastructure/AppContainer.swift\n")
    return p


def test_script_passes_bash_syntax_check():
    r = subprocess.run(["bash", "-n", str(_SCRIPT)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_count_mode_excludes_allowlist_env_and_packages(tmp_path):
    root = _build_tree(tmp_path)
    baseline = tmp_path / "b.txt"
    baseline.write_text("2\n")
    r = _run(root, baseline, _allowlist(tmp_path), mode="--count")
    assert r.returncode == 0
    assert r.stdout.strip() == "2", r.stdout


def test_at_baseline_passes(tmp_path):
    root = _build_tree(tmp_path)
    baseline = tmp_path / "b.txt"
    baseline.write_text("2\n")
    r = _run(root, baseline, _allowlist(tmp_path))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "PASS" in r.stdout


def test_above_baseline_fails(tmp_path):
    root = _build_tree(tmp_path)
    baseline = tmp_path / "b.txt"
    baseline.write_text("1\n")  # tree has 2 -> over
    r = _run(root, baseline, _allowlist(tmp_path))
    assert r.returncode == 1, r.stdout + r.stderr
    assert "FAIL" in r.stdout


def test_below_baseline_passes_and_reports(tmp_path):
    root = _build_tree(tmp_path)
    baseline = tmp_path / "b.txt"
    baseline.write_text("9\n")  # tree has 2 -> under
    r = _run(root, baseline, _allowlist(tmp_path))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "PASS" in r.stdout
    assert "2" in r.stdout


def test_empty_allowlist_counts_the_root_file(tmp_path):
    """With no allowlist entry, the AppContainer.swift use IS counted (3 total)."""
    root = _build_tree(tmp_path)
    baseline = tmp_path / "b.txt"
    baseline.write_text("3\n")
    empty = tmp_path / "empty.txt"
    empty.write_text("# nothing\n")
    r = _run(root, baseline, empty, mode="--count")
    assert r.stdout.strip() == "3", r.stdout


def test_live_repo_baseline_passes():
    """Checked-in baseline + allowlist must PASS against today's Palace/ tree."""
    r = subprocess.run(["bash", str(_SCRIPT)], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr
