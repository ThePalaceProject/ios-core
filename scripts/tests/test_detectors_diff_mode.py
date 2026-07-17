"""Diff-mode contract tests for the Phase-3.5 class-scan detectors.

The pre-commit hook (`scripts/pre-commit-phase35-detectors.sh`) wires these five
detectors as **`--diff`** — it feeds each one `git diff --cached` and blocks (or
warns) on a finding. Their existing pytests, however, exercise only **`--scan`**
mode, which "sidesteps the diff-narrowing rule" (per those tests' own docstrings).
That left the production interface — the `--diff` path with its file-narrowing and
post-image reconstruction — with no violation-path coverage: a regression there
would silently turn a blocking gate into a no-op while the pytest board stayed green
(exactly the failure the green-board contract rule #4 warns about).

This module pins that interface. For each detector it builds a real
`git diff --cached` that ADDS a known-violation fixture at a production `Palace/`
path — byte-for-byte the input the hook produces — and asserts the detector fires.
A companion empty-diff case proves the `--diff` path does not false-positive on a
no-op (the clean-path half of the contract).
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

_REPO = Path(__file__).resolve().parents[2]
_SCRIPTS = _REPO / "scripts"
_FIXTURES = _SCRIPTS / "tests" / "fixtures"

# script | fixtures subdir | violation fixture | prod-relative dir | finding token | mode
_CASES = [
    ("check-foreign-host-401-scoping.py",           "foreign_host_401",    "violation_missing_guard.swift",      "Palace/Network",           "FH-1",    "block"),
    ("check-completion-nil-error-suppression.py",    "completion_nil_error","violation_string_literals.swift",    "Palace/SignInLogic",       "D3-1",    "block"),
    ("check-nserror-problemdoc-preservation.py",     "nserror_problemdoc",  "violation_dropped_problemdoc.swift", "Palace/Network",           "D4-1",    "block"),
    ("check-swiftui-placeholder-a11y.py",            "swiftui_a11y",        "violation.swift",                    "Palace/CatalogUI",         "PP-4421", "warn"),
    ("check-notification-center-observer-storage.py","notification_center", "violation_unstored_observer.swift",  "Palace/AppInfrastructure", "D5-1",    "warn"),
]

_IDS = [c[0].removeprefix("check-").removesuffix(".py") for c in _CASES]


def _git(repo: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, text=True)


def _staged_repo(tmp_path: Path, subdir: str, violation: str, prod_dir: str):
    """Create a throwaway git repo with the violation fixture staged at its
    production path, and return (repo, diff_file) where diff_file holds the
    `git diff --cached` text the pre-commit hook would feed the detector."""
    repo = tmp_path / "repo"
    dest = repo / prod_dir
    dest.mkdir(parents=True)
    shutil.copy(_FIXTURES / subdir / violation, dest / violation)
    _git(repo, "init", "-q")
    _git(repo, "add", "-A")
    diff = subprocess.run(
        ["git", "diff", "--cached"], cwd=repo, capture_output=True, text=True
    ).stdout
    diff_file = tmp_path / "staged.diff"
    diff_file.write_text(diff)
    return repo, diff_file


def _run_diff(script: str, repo: Path, diff_file: Path) -> subprocess.CompletedProcess:
    # cwd=repo so the detector resolves the added file on disk too, whether it
    # reconstructs the post-image from the diff or reads the source directly.
    return subprocess.run(
        [sys.executable, str(_SCRIPTS / script), "--diff", str(diff_file), "--quiet"],
        cwd=repo,
        capture_output=True,
        text=True,
        timeout=30,
    )


@pytest.mark.parametrize("script,subdir,violation,prod_dir,token,mode", _CASES, ids=_IDS)
def test_detector_fires_in_diff_mode(tmp_path, script, subdir, violation, prod_dir, token, mode):
    """A staged violation must make the detector exit non-zero in --diff mode and
    name its finding — the production `diff` wiring, previously untested."""
    repo, diff_file = _staged_repo(tmp_path, subdir, violation, prod_dir)
    r = _run_diff(script, repo, diff_file)
    assert r.returncode != 0, (
        f"{script} did NOT fire in --diff mode (exit {r.returncode}); "
        f"the {mode}-mode gate would silently pass this violation.\n"
        f"stdout: {r.stdout!r}\nstderr: {r.stderr!r}"
    )
    assert token in (r.stdout + r.stderr), (
        f"{script}: expected finding token {token!r} in output, got:\n"
        f"stdout: {r.stdout!r}\nstderr: {r.stderr!r}"
    )


@pytest.mark.parametrize("script", [c[0] for c in _CASES], ids=_IDS)
def test_detector_clean_on_empty_diff(tmp_path, script):
    """The clean-path half: an empty diff must exit 0 — the --diff path must not
    block/warn on a no-op (guards against a narrowing regression that flips to
    always-fire)."""
    diff_file = tmp_path / "empty.diff"
    diff_file.write_text("")
    r = subprocess.run(
        [sys.executable, str(_SCRIPTS / script), "--diff", str(diff_file), "--quiet"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert r.returncode == 0, (
        f"{script} did not pass a clean (empty) diff (exit {r.returncode})\n"
        f"stdout: {r.stdout!r}\nstderr: {r.stderr!r}"
    )


if __name__ == "__main__":  # pragma: no cover
    sys.exit(pytest.main([__file__, "-v"]))
