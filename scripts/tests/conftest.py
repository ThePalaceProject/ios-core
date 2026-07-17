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
"""

import os

import pytest


@pytest.fixture(autouse=True, scope="session")
def _scrub_git_hook_env():
    """Strip inherited git hook env vars for the whole test session."""
    removed = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
    try:
        yield
    finally:
        os.environ.update(removed)
