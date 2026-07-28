"""Shared pytest configuration for scripts/tests/.

Autouse guard against git hook-environment leakage.

git exports GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE (and friends) into the
environment of any process it launches as a hook. Several tests here build a
throwaway repo under ``tmp_path`` and shell out to ``git`` with ``cwd=`` set —
but ``cwd`` does NOT win repo discovery once ``GIT_DIR`` is present. So when
this suite runs under the pre-push hook (``scripts/pre-push-test-gate.sh``),
those inherited vars make every ``git add``/``git commit`` operate on the REAL
repository being pushed instead of the fixture, corrupting the branch (observed:
a bogus mass-deletion "base" commit staged into the pushed worktree).

Deleting the GIT_* vars from ``os.environ`` once, before any test runs,
immunizes the whole suite: child ``subprocess.run(["git", ...])`` calls then
inherit a clean environment and honor their own ``cwd`` / ``git init``. This is
belt-and-suspenders with the ``env -u GIT_*`` scrub the pre-push gate now applies
before invoking pytest — either alone is sufficient; both cost nothing.

Second guard: enclosing-repo integrity.

The scrub above is *prevention*. The guard below is *detection*: it snapshots the
ENCLOSING repo's HEAD + ``git status --porcelain`` at session start and re-checks
them at session end, failing the whole suite loudly if either changed. Any future
fixture that regresses — a ``git init``/``commit``/``reset`` that escapes its
``tmp_path`` and mutates the live tree (the exact corruption that made
``SKIP_PRE_PUSH_TESTS=1`` folklore) — becomes a RED test instead of a silently
corrupted branch. It compares before-vs-after, so a repo that is already dirty
(untracked files, modified submodule) is fine — only a *change* during the session
trips it.
"""

import os
import subprocess
from pathlib import Path

import pytest

# scripts/tests/conftest.py -> scripts/tests -> scripts -> repo root
_REPO_ROOT = Path(__file__).resolve().parents[2]


def _git_snapshot(repo_root: Path):
    """Return (head, porcelain) for repo_root using a git-env-free subprocess, or
    None if repo_root is not inside a git work tree. GIT_* is stripped from the
    child so repo discovery honors ``cwd`` regardless of any inherited hook env."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    inside = subprocess.run(
        ["git", "rev-parse", "--is-inside-work-tree"],
        cwd=repo_root, env=env, capture_output=True, text=True,
    )
    if inside.returncode != 0 or inside.stdout.strip() != "true":
        return None
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo_root, env=env, capture_output=True, text=True,
    ).stdout.strip()
    status = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=repo_root, env=env, capture_output=True, text=True,
    ).stdout
    return (head, status)


@pytest.fixture(autouse=True, scope="session")
def _scrub_git_hook_env():
    """Strip inherited git hook env vars for the whole test session."""
    removed = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
    try:
        yield
    finally:
        os.environ.update(removed)


@pytest.fixture(autouse=True, scope="session")
def _enclosing_repo_integrity_guard(_scrub_git_hook_env):
    """Fail the suite loudly if any test mutated the ENCLOSING git repo.

    Records HEAD + porcelain status before the session and re-checks after. A leak
    (a fixture that shells out to git without isolating to ``tmp_path``) changes one
    of them and turns into a red test here — never a silent branch corruption. Runs
    AFTER ``_scrub_git_hook_env`` (declared as a dependency) so both snapshots read
    the real enclosing repo, not a GIT_DIR-redirected one."""
    before = _git_snapshot(_REPO_ROOT)
    yield
    if before is None:
        # Not inside a git work tree (e.g. an exported tarball) — nothing to guard.
        return
    after = _git_snapshot(_REPO_ROOT)
    assert after is not None, (
        "enclosing-repo integrity guard: repo became unreadable during the session "
        f"(was a git work tree at {_REPO_ROOT} at start) — a fixture likely corrupted it"
    )
    before_head, before_status = before
    after_head, after_status = after
    assert before_head == after_head, (
        "enclosing-repo integrity guard: HEAD changed during the test session "
        f"({before_head} -> {after_head}) at {_REPO_ROOT}. A fixture leaked a git "
        "commit/reset onto the live branch instead of operating in tmp_path. "
        "Isolate the offending fixture to a throwaway tmp_path repo."
    )
    assert before_status == after_status, (
        "enclosing-repo integrity guard: working-tree status changed during the test "
        f"session at {_REPO_ROOT}. A fixture mutated tracked/untracked files in the "
        "live tree instead of tmp_path.\n"
        f"--- before ---\n{before_status}\n--- after ---\n{after_status}"
    )
