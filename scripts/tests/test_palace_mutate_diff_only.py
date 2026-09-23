"""`--diff-only` must report line numbers for the file it is about to mutate.

`palace_mutate` mutates the WORKING TREE. `changed_lines` used to diff
`<base>..HEAD`, which compares the base against the last COMMIT — a different
version of the file whenever the tree is dirty. The hunk line numbers then
referred to HEAD's numbering while the mutations were applied to the working
tree's, so genuinely-changed lines were skipped and stale numbers still resolved
to *some* line, meaning the wrong lines could be mutated with no error reported.

A dirty tree is the normal state for `--diff-only`: you run it while iterating
on a fix, before committing. The observed symptom was a changed line carrying
four mutation points being reported as "0 mutation points on changed lines".
"""

import os
import subprocess
import sys

import pytest

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, SCRIPTS)

import palace_mutate  # noqa: E402


def _git(repo, *args):
    subprocess.run(["git", *args], cwd=repo, check=True,
                   capture_output=True, text=True)


@pytest.fixture
def repo(tmp_path):
    """A git repo with one committed file, on a `base` ref."""
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q")
    _git(repo, "config", "user.email", "t@example.invalid")
    _git(repo, "config", "user.name", "t")
    src = repo / "Source.swift"
    src.write_text("line1\nline2\nline3\n")
    _git(repo, "add", "Source.swift")
    _git(repo, "commit", "-qm", "base")
    _git(repo, "branch", "base")
    return repo


def _changed(repo, base="base"):
    original = palace_mutate.REPO_ROOT
    palace_mutate.REPO_ROOT = str(repo)
    try:
        return palace_mutate.changed_lines("Source.swift", base)
    finally:
        palace_mutate.REPO_ROOT = original


def test_uncommitted_edit_is_reported_as_changed(repo):
    """The regression: an edit present only in the working tree must be seen.

    This is the file palace_mutate will actually mutate, so if this returns an
    empty set the tool reports "nothing to mutate" on a real change.
    """
    (repo / "Source.swift").write_text("line1\nCHANGED\nline3\n")

    assert _changed(repo) == {2}


def test_committed_edit_is_still_reported(repo):
    """The pre-existing behaviour must not regress."""
    (repo / "Source.swift").write_text("line1\nCHANGED\nline3\n")
    _git(repo, "commit", "-qam", "change")

    assert _changed(repo) == {2}


def test_committed_and_uncommitted_edits_are_both_reported(repo):
    """Commit one change, leave another dirty — a PR mid-iteration."""
    (repo / "Source.swift").write_text("line1\nCOMMITTED\nline3\n")
    _git(repo, "commit", "-qam", "first")
    (repo / "Source.swift").write_text("line1\nCOMMITTED\nDIRTY\n")

    assert _changed(repo) == {2, 3}


def test_line_numbers_index_the_working_tree_not_head(repo):
    """The numbering must match the file on disk.

    Insert lines ABOVE the edit so HEAD's numbering and the working tree's
    diverge. A `..HEAD` diff would report the line's position in HEAD, which
    addresses different content in the file being mutated.
    """
    (repo / "Source.swift").write_text("line1\nline2\nline3\n")
    _git(repo, "commit", "-qam", "noop", "--allow-empty")
    (repo / "Source.swift").write_text("new0\nnew0b\nline1\nline2\nCHANGED\n")

    changed = _changed(repo)
    working = (repo / "Source.swift").read_text().splitlines()

    assert 5 in changed, "the edited line must be reported at its working-tree position"
    assert working[4] == "CHANGED"
    for n in changed:
        assert 1 <= n <= len(working), f"line {n} is outside the file being mutated"


def test_unchanged_file_reports_nothing(repo):
    assert _changed(repo) == set()
