"""detect_base_branch() must score, not order.

PP-5128 (2026-09-14): the function returned the first of develop/main/master
that existed, so every branch cut from a release branch was diffed against
develop and inherited the whole release delta — 26 production files for a
4-file fix, failing the intent-recorded leg over other people's commits.
"""
import subprocess
import textwrap
import pytest

SCRIPT = "scripts/verify-pr.sh"


def _git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args],
                          check=True, capture_output=True, text=True).stdout.strip()


def _detect(repo, repo_root):
    """Source detect_base_branch() out of the real script and run it in `repo`."""
    extract = textwrap.dedent(f"""
        set -e
        cd "{repo}"
        # Pull just the function out of the real script so the test cannot
        # drift from the shipped implementation.
        eval "$(sed -n '/^detect_base_branch() {{/,/^}}/p' "{repo_root}/{SCRIPT}")"
        detect_base_branch
    """)
    out = subprocess.run(["bash", "-c", extract], capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    return out.stdout.strip()


@pytest.fixture
def repo(tmp_path):
    r = tmp_path / "r"
    r.mkdir()
    _git(r, "init", "-q", "-b", "develop")
    _git(r, "config", "user.email", "t@t")
    _git(r, "config", "user.name", "t")
    (r / "f").write_text("0")
    _git(r, "add", "f")
    _git(r, "commit", "-qm", "base")
    return r


def _commit(repo, text):
    (repo / "f").write_text(text)
    _git(repo, "commit", "-qam", text)


def test_branch_off_release_picks_the_release_branch(repo, request):
    root = request.config.rootpath
    # develop and release/3.3.0 both exist; release has moved on since the fork.
    _git(repo, "update-ref", "refs/remotes/origin/develop", "HEAD")
    _git(repo, "checkout", "-qb", "rel")
    _commit(repo, "release-only-1")
    _commit(repo, "release-only-2")
    _git(repo, "update-ref", "refs/remotes/origin/release/3.3.0", "HEAD")
    # A topic branch cut from the release branch, one commit of its own.
    _git(repo, "checkout", "-qb", "topic")
    _commit(repo, "my-fix")

    assert _detect(repo, root) == "origin/release/3.3.0", (
        "a branch cut from a release branch must be scored against it, not develop"
    )


def test_branch_off_develop_still_picks_develop(repo, request):
    """The fix must not drag ordinary work onto a release base."""
    root = request.config.rootpath
    _git(repo, "checkout", "-qb", "rel")
    _commit(repo, "release-only")
    _git(repo, "update-ref", "refs/remotes/origin/release/3.3.0", "HEAD")
    _git(repo, "checkout", "-q", "develop")
    _commit(repo, "develop-moved")
    _git(repo, "update-ref", "refs/remotes/origin/develop", "HEAD")
    _git(repo, "checkout", "-qb", "topic")
    _commit(repo, "my-fix")

    assert _detect(repo, root) == "origin/develop"


def test_no_remote_refs_falls_back(repo, request):
    root = request.config.rootpath
    assert _detect(repo, root) == "HEAD~10"
