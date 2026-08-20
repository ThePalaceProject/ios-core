#!/usr/bin/env python3
"""Pytest for scripts/check-ci-parity-stamp.sh.

One of the two detectors that shipped without a test. The gate blocks a push
whose range changes production Swift unless `.git/ci-parity-pass.sha` names the
exact HEAD being pushed.

Every test builds a throwaway git repo and copies the gate into ITS scripts/
dir, because the script derives REPO_ROOT from its own location — running the
committed copy would gate this repository instead of the fixture.

Both directions are asserted. A gate only ever tested against a violation is
untested against false positives, and this one's false-positive surface is
large: docs-only, test-only, and script-only pushes are the common case and
must sail through.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
GATE = REPO / "scripts" / "check-ci-parity-stamp.sh"
PARITY_RUNNER = REPO / "scripts" / "ci-parity-local.sh"

#: Both halves of the contract must name the same file, or the runner stamps
#: something the gate never reads and the gate blocks forever.
STAMP_BASENAME = "ci-parity-pass.sha"


def _git(repo: Path, *args: str) -> str:
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("GIT_"):
            env.pop(k)
    env.update({
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t.io",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t.io",
    })
    out = subprocess.run(["git", *args], cwd=str(repo), capture_output=True,
                         text=True, env=env, check=True)
    return out.stdout.strip()


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """A fixture repo with the gate installed and a `develop` base branch."""
    r = tmp_path / "fixture"
    (r / "scripts").mkdir(parents=True)
    (r / "Palace").mkdir()
    (r / "PalaceTests").mkdir()
    (r / "docs").mkdir()
    shutil.copy2(GATE, r / "scripts" / GATE.name)

    _git(r, "init", "-q", "-b", "develop")
    (r / "README.md").write_text("base\n")
    _git(r, "add", "-A")
    _git(r, "commit", "-q", "-m", "base")
    # The gate diffs against origin/develop; make that ref real.
    _git(r, "update-ref", "refs/remotes/origin/develop", "HEAD")
    _git(r, "checkout", "-q", "-b", "feature")
    return r


def _run(repo: Path, **env_extra) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("GIT_"):
            env.pop(k)
    env.update(env_extra)
    return subprocess.run(["bash", "scripts/check-ci-parity-stamp.sh"],
                          cwd=str(repo), capture_output=True, text=True,
                          env=env, timeout=60)


def _commit(repo: Path, rel: str, body: str = "x\n") -> None:
    p = repo / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(body)
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", f"touch {rel}")


def _stamp(repo: Path, sha: str) -> None:
    git_dir = Path(_git(repo, "rev-parse", "--absolute-git-dir"))
    (git_dir / STAMP_BASENAME).write_text(sha + "\n")


# --- the blocking direction -------------------------------------------------

def test_blocks_production_swift_without_a_stamp(repo):
    _commit(repo, "Palace/Feature/Thing.swift")
    rc = _run(repo)
    assert rc.returncode == 1, rc.stdout + rc.stderr
    assert "BLOCKED" in rc.stderr
    assert "ci-parity-local.sh" in rc.stderr, \
        "a blocking gate must name the command that unblocks it"


def test_blocks_when_the_stamp_names_an_older_commit(repo):
    _commit(repo, "Palace/Feature/Thing.swift")
    stale = _git(repo, "rev-parse", "HEAD")
    _stamp(repo, stale)
    _commit(repo, "Palace/Feature/Other.swift")
    rc = _run(repo)
    assert rc.returncode == 1, "a stamp for the PREVIOUS commit must not pass"
    assert stale[:8] in rc.stderr or "parity-verified" in rc.stderr


# --- the clean directions (false-positive surface) --------------------------

def test_passes_when_the_stamp_matches_head(repo):
    _commit(repo, "Palace/Feature/Thing.swift")
    _stamp(repo, _git(repo, "rev-parse", "HEAD"))
    rc = _run(repo)
    assert rc.returncode == 0, rc.stdout + rc.stderr
    assert "verified" in rc.stderr


def test_docs_only_change_is_not_gated(repo):
    _commit(repo, "docs/Testing/notes.md")
    rc = _run(repo)
    assert rc.returncode == 0, rc.stdout + rc.stderr
    assert "not required" in rc.stderr


def test_test_only_change_is_not_gated(repo):
    _commit(repo, "PalaceTests/ThingTests.swift")
    rc = _run(repo)
    assert rc.returncode == 0, rc.stdout + rc.stderr


def test_script_only_change_is_not_gated(repo):
    _commit(repo, "scripts/helper.sh")
    rc = _run(repo)
    assert rc.returncode == 0, rc.stdout + rc.stderr


def test_a_swift_file_named_tests_inside_palace_is_not_production(repo):
    """`Palace/**/FooTests.swift` is excluded by the gate's own predicate."""
    _commit(repo, "Palace/Feature/ThingTests.swift")
    rc = _run(repo)
    assert rc.returncode == 0, rc.stdout + rc.stderr


def test_bypass_env_var_is_honoured_and_logged(repo):
    _commit(repo, "Palace/Feature/Thing.swift")
    rc = _run(repo, SKIP_CI_PARITY="1")
    assert rc.returncode == 0, rc.stdout + rc.stderr
    assert "SKIP_CI_PARITY" in rc.stderr, "a bypass must announce itself"


def test_custom_base_ref_is_honoured(repo):
    _commit(repo, "Palace/Feature/Thing.swift")
    _git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    # Against a base that already contains the change there is nothing new.
    rc = _run(repo, CI_PARITY_BASE="origin/main")
    assert rc.returncode == 0, rc.stdout + rc.stderr


def test_missing_base_ref_falls_back_to_the_last_commit(repo):
    _git(repo, "update-ref", "-d", "refs/remotes/origin/develop")
    _commit(repo, "Palace/Feature/Thing.swift")
    rc = _run(repo)
    assert rc.returncode == 1, "HEAD~1..HEAD fallback should still see the change"


# --- the contract between the two halves ------------------------------------

def test_the_runner_writes_the_file_the_gate_reads():
    """RED if either half renames the stamp.

    The runner stamps on pass; the gate requires the stamp. They agree only by
    convention — nothing links them at runtime, so pin the filename here.
    """
    assert STAMP_BASENAME in GATE.read_text(encoding="utf-8")
    assert STAMP_BASENAME in PARITY_RUNNER.read_text(encoding="utf-8")


def test_gate_passes_bash_syntax_check():
    rc = subprocess.run(["bash", "-n", str(GATE)], capture_output=True, text=True)
    assert rc.returncode == 0, rc.stderr
