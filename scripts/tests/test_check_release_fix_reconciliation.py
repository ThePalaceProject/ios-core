#!/usr/bin/env python3
"""
Tests for check-release-fix-reconciliation.py.

Builds a throwaway git repo with a `release` branch and a `develop` branch, then
drives the gate through the scenarios that matter for the 3.2.0 retro:

  - a crash fix touching a critical-path file, landed on develop only  -> BLOCK
  - the same fix cherry-picked into the release (different SHA)         -> pass
    (proves the `git cherry` patch-id match, the crux of the tool)
  - the fix explicitly waived                                          -> pass
  - a non-critical-path fix                                            -> ignored
  - a critical-path refactor with no fix wording                       -> ignored
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "check-release-fix-reconciliation.py"


def _git(repo: Path, *args: str, env: dict | None = None) -> str:
    proc = subprocess.run(
        ["git", *args], cwd=repo, capture_output=True, text=True, env=env
    )
    assert proc.returncode == 0, f"git {args} failed: {proc.stderr}"
    return proc.stdout.strip()


def _commit(repo: Path, path: str, content: str, message: str) -> str:
    f = repo / path
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(content)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", message)
    return _git(repo, "rev-parse", "HEAD")


def _run_gate(repo: Path, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT),
         "--release-ref", "release", "--develop-ref", "develop", *extra],
        cwd=repo, capture_output=True, text=True,
    )


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    r = tmp_path / "repo"
    r.mkdir()
    _git(r, "init", "-q", "-b", "main")
    _git(r, "config", "user.email", "t@t.io")
    _git(r, "config", "user.name", "t")
    # Base commit, then cut `release` here — the divergence point.
    _commit(r, "README.md", "base\n", "base")
    _git(r, "branch", "release")
    _git(r, "branch", "develop")
    _git(r, "checkout", "-q", "develop")
    return r


def test_unreconciled_critical_fix_blocks(repo: Path):
    # Crash fix on a critical-path file, develop only.
    _commit(repo, "Palace/Book/Models/BookRegistrySync.swift",
            "// fixed reentrancy\n",
            "fix(registry): saveSync reentrancy deadlock (#999)")
    res = _run_gate(repo)
    assert res.returncode == 1, res.stderr
    assert "BLOCK" in res.stderr
    assert "#999" in res.stderr


def test_cherry_picked_fix_is_reconciled(repo: Path):
    sha = _commit(repo, "Palace/Book/Models/BookRegistrySync.swift",
                  "// fixed reentrancy\n",
                  "fix(registry): saveSync reentrancy deadlock (#999)")
    # Cherry-pick the SAME change onto release — new SHA, identical patch.
    _git(repo, "checkout", "-q", "release")
    _git(repo, "cherry-pick", sha)
    _git(repo, "checkout", "-q", "develop")
    res = _run_gate(repo)
    assert res.returncode == 0, res.stderr + res.stdout


def test_waiver_reconciles(repo: Path):
    sha = _commit(repo, "Palace/MyBooks/BorrowOperation.swift", "// x\n",
                  "fix(borrow): guard nil acquisition (#1001)")
    waiver = repo / "waivers.txt"
    waiver.write_text(f"{sha[:9]} intentionally held for next release\n")
    res = _run_gate(repo, "--waiver-file", str(waiver))
    assert res.returncode == 0, res.stderr
    assert "waived" in res.stderr.lower()


def test_waiver_by_pr_number(repo: Path):
    _commit(repo, "Palace/SignInLogic/OIDC.swift", "// x\n",
            "fix(signin): OIDC token race (#1234)")
    waiver = repo / "waivers.txt"
    waiver.write_text("#1234 shipping separately\n")
    res = _run_gate(repo, "--waiver-file", str(waiver))
    assert res.returncode == 0, res.stderr


def test_non_critical_fix_ignored(repo: Path):
    _commit(repo, "docs/notes.md", "typo fix\n",
            "fix(docs): correct a typo")
    res = _run_gate(repo)
    assert res.returncode == 0, res.stderr


def test_critical_refactor_without_fix_wording_ignored(repo: Path):
    _commit(repo, "Palace/Book/Models/BookRegistryStore.swift", "// refactor\n",
            "refactor(registry): extract snapshot helper")
    res = _run_gate(repo)
    assert res.returncode == 0, res.stderr


def test_clean_release_passes(repo: Path):
    # develop == release (no new commits) -> nothing to reconcile.
    res = _run_gate(repo)
    assert res.returncode == 0, res.stderr


def test_bad_ref_errors(repo: Path):
    res = subprocess.run(
        [sys.executable, str(SCRIPT),
         "--release-ref", "release", "--develop-ref", "nonexistent-ref"],
        cwd=repo, capture_output=True, text=True,
    )
    assert res.returncode == 2, res.stderr


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
