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

and the reverse direction (PP-5389): a commit on the release only blocks until
develop carries it, names its PR or SHA, or a waiver covers it.
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


def _commit_on_release(repo: Path, path: str, content: str, message: str) -> str:
    _git(repo, "checkout", "-q", "release")
    sha = _commit(repo, path, content, message)
    _git(repo, "checkout", "-q", "develop")
    return sha


def test_release_only_commit_blocks_even_without_fix_wording(repo: Path):
    # Shape of e84eb80ae (#1717): merged to release/3.4.0 only, subject has no
    # fix wording, and develop kept the old default until a forward-port.
    _commit_on_release(repo, "Palace/AppInfrastructure/FirebaseManager.swift",
                       "// default on\n",
                       "Default LCP audiobook streaming ON to match the shipped rollout (#1717)")
    res = _run_gate(repo)
    assert res.returncode == 1, res.stderr
    assert "not on develop" in res.stderr
    assert "#1717" in res.stderr


def test_release_commit_cherry_picked_to_develop_is_reconciled(repo: Path):
    sha = _commit_on_release(repo, "Palace/AppInfrastructure/FirebaseManager.swift",
                             "// default on\n", "Default streaming ON (#1717)")
    _git(repo, "cherry-pick", sha)
    res = _run_gate(repo)
    assert res.returncode == 0, res.stderr


def test_forward_port_naming_the_release_pr_is_reconciled(repo: Path):
    # A forward-port that needed conflict resolution has a different patch-id;
    # naming the release PR in its message is what ties the two together.
    _commit_on_release(repo, "Palace/AppInfrastructure/FirebaseManager.swift",
                       "// default on\n", "Default streaming ON (#1717)")
    _commit(repo, "Palace/AppInfrastructure/FirebaseManager.swift",
            "// default on, adjusted for develop\n",
            "Forward-port default streaming ON (#1718)\n\nForward-port of #1717.")
    res = _run_gate(repo)
    assert res.returncode == 0, res.stderr


def test_forward_port_naming_the_release_sha_is_reconciled(repo: Path):
    sha = _commit_on_release(repo, "Palace/AppInfrastructure/FirebaseManager.swift",
                             "// default on\n", "Default streaming ON")
    _commit(repo, "Palace/AppInfrastructure/FirebaseManager.swift",
            "// default on, adjusted for develop\n",
            f"Default streaming ON\n\n(cherry picked from commit {sha})")
    res = _run_gate(repo)
    assert res.returncode == 0, res.stderr


def test_unrelated_pr_number_on_develop_does_not_reconcile(repo: Path):
    # #17 is a prefix of #1717; only an exact PR number counts as a port.
    _commit_on_release(repo, "Palace/AppInfrastructure/FirebaseManager.swift",
                       "// default on\n", "Default streaming ON (#1717)")
    _commit(repo, "docs/notes.md", "x\n", "Update notes (#17)")
    res = _run_gate(repo)
    assert res.returncode == 1, res.stderr


def test_release_only_commit_can_be_waived(repo: Path):
    sha = _commit_on_release(repo, "Palace.xcodeproj/project.pbxproj",
                             "CURRENT_PROJECT_VERSION = 2;\n", "Bump build number")
    waiver = repo / "waivers.txt"
    waiver.write_text(f"{sha[:9]} release-only build bump\n")
    res = _run_gate(repo, "--waiver-file", str(waiver))
    assert res.returncode == 0, res.stderr
    assert "waived" in res.stderr.lower()


def test_release_merge_commit_is_not_flagged(repo: Path):
    # A merge carries no patch of its own; its parents are judged separately.
    _git(repo, "checkout", "-q", "-b", "side", "release")
    _commit(repo, "docs/side.md", "x\n", "Side change")
    _git(repo, "checkout", "-q", "develop")
    _git(repo, "merge", "-q", "--no-ff", "side", "-m", "Merge side into develop")
    _git(repo, "checkout", "-q", "release")
    _git(repo, "merge", "-q", "--no-ff", "side", "-m", "Merge side into release")
    _git(repo, "checkout", "-q", "develop")
    res = _run_gate(repo)
    assert res.returncode == 0, res.stderr


def _fetch_self_as_origin(repo: Path) -> None:
    _git(repo, "remote", "add", "origin", str(repo))
    _git(repo, "fetch", "-q", "origin")


def test_default_waiver_path_drops_the_remote_prefix(repo: Path):
    # A hand run names the remote-tracking ref; the waiver file is named after
    # the branch, as the workflow derives it from the PR head branch.
    sha = _commit_on_release(repo, "Palace.xcodeproj/project.pbxproj",
                             "CURRENT_PROJECT_VERSION = 2;\n", "Bump build number")
    _fetch_self_as_origin(repo)
    waiver = repo / "config" / "ci" / "release-waivers" / "release.txt"
    waiver.parent.mkdir(parents=True)
    waiver.write_text(f"{sha[:9]} release-only build bump\n")
    res = subprocess.run(
        [sys.executable, str(SCRIPT),
         "--release-ref", "origin/release", "--develop-ref", "develop"],
        cwd=repo, capture_output=True, text=True,
    )
    assert res.returncode == 0, res.stderr
    assert "waived" in res.stderr.lower()


def test_missing_waiver_file_warns_once(repo: Path):
    res = _run_gate(repo, "--quiet", "--waiver-file", str(repo / "absent.txt"))
    assert res.returncode == 0, res.stderr
    assert res.stderr.count("absent.txt not found") == 1, res.stderr


def test_bad_ref_errors(repo: Path):
    res = subprocess.run(
        [sys.executable, str(SCRIPT),
         "--release-ref", "release", "--develop-ref", "nonexistent-ref"],
        cwd=repo, capture_output=True, text=True,
    )
    assert res.returncode == 2, res.stderr


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
