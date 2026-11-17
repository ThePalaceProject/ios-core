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


# One real read; the rest are `.shared` mentions inside comments that must NOT count.
_BODY_COMMENTS = """
let real = AccountStateStore.shared
// Prefer the injected seam over RemoteFeatureFlags.shared here.
let x = 1  // legacy path used ImageCache.shared before the extraction
/// doc: TPPBookCoverRegistry.shared is the old ambient reach
/* AnotherStore.shared named in a block comment */
"""


def test_comment_mentions_not_counted(tmp_path):
    """THE FIX: a `.shared` named in a `//`, `///`, or block comment is documentation,
    not a read — only the one real `AccountStateStore.shared` counts."""
    root = _scan_root(tmp_path, _BODY_COMMENTS)
    baseline = tmp_path / "b.txt"
    baseline.write_text("1\n")
    r = _run(root, baseline, mode="--count")
    assert r.returncode == 0
    assert r.stdout.strip() == "1", r.stdout


def test_url_double_slash_not_mistaken_for_comment(tmp_path):
    """A `://` inside a string URL must not be treated as a comment start, so a real
    read on the same line is still counted."""
    body = 'let u = URL(string: "https://x.example/shared")!; let r = ImageCache.shared\n'
    root = _scan_root(tmp_path, body)
    baseline = tmp_path / "b.txt"
    baseline.write_text("1\n")
    r = _run(root, baseline, mode="--count")
    assert r.stdout.strip() == "1", r.stdout


def test_live_repo_baseline_passes():
    """Checked-in baseline must PASS against today's Palace/ tree."""
    r = subprocess.run(["bash", str(_SCRIPT)], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr


def test_live_baseline_has_zero_slack():
    """The checked-in baseline must EQUAL today's measured count, not merely bound it.

    `test_live_repo_baseline_passes` above asserts exit 0, which the gate also
    returns when the tree is BELOW baseline. The gate prints "Ratchet baseline
    down to N" in that case and the advisory feeds nothing — it does not touch
    the exit code, so accumulated slack is invisible to the whole suite. A
    ratchet with slack is not a ratchet: reads removed by one wave silently
    fund reads added by the next, and the baseline stops describing the tree.

    Asserting the advisory empty also closes the direction that actually bit.
    On 2026-09 commit a0968e652 raised this baseline 164 -> 167 in the same
    commit as the code needing it — the one edit to the file carrying no
    rationale line — after the gate failed and told the author to inject the
    dependency via an AppContainer seam instead. With this arm, a raise above
    the measured count fails here even though the gate itself still exits 0.

    It does NOT close the two-sided edit where new reads are added and the
    baseline is raised to exactly match: the tree then measures its new
    baseline, no slack, `==` satisfied. Nothing inside the tree can catch that,
    because every in-tree record of the old value is editable in the same
    commit. Closing it needs the baseline compared against the BASE branch's
    committed copy, which the PR cannot rewrite. Not done here — it turns on
    origin/develop being reliably fetched in CI and locally, and a ratchet that
    silently skips when the ref is missing is worse than none. Same survivor,
    and for the same reason, as the one named in
    test_check_file_size_ceiling.py::test_live_allowlist_has_zero_slack.
    """
    r = subprocess.run(["bash", str(_SCRIPT)], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr
    slack = [ln.strip() for ln in r.stdout.splitlines() if "Ratchet baseline down to" in ln]
    assert not slack, (
        "`.shared` reads are below the checked-in baseline. Lower the integer in "
        "scripts/godclass-shared-read-baseline.txt to the measured count and add a "
        "rationale line saying which change removed them:\n  " + "\n  ".join(slack)
    )
