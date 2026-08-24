#!/usr/bin/env python3
"""
A submodule bump must not read as a documentation change.

WHY THIS EXISTS (PP-4976). Every submodule in this repo has `ignore = all` set
in git config. `git diff --name-only` therefore reports a submodule POINTER BUMP
AS NOTHING AT ALL — measured on a real toolkit bump, the default reports zero
lines and `--ignore-submodules=none` reports one.

That is not merely a missed audiobook gate. `verify-pr.sh` derives its
changed-file list from that diff, and the docs-only predicate reads an empty
list as "nothing but documentation changed" and skips the entire battery: build,
tests, coverage, mutation, accessibility. Then it prints CLEAR.

So a PR that only bumps `ios-audiobooktoolkit` — which is exactly how an
audiobook toolkit change lands here — was verified by nothing and said so in the
affirmative.

These tests pin both halves: the diff must see the pointer, and the docs-only
predicate must refuse it even if the diff ever stops.
"""

import os
import re
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
VPR = os.path.join(REPO, "scripts", "verify-pr.sh")


def source() -> str:
    with open(VPR, encoding="utf-8") as fh:
        return fh.read()


def submodule_paths() -> list[str]:
    out = subprocess.run(
        ["git", "config", "-f", ".gitmodules", "--get-regexp", r"submodule\..*\.path"],
        capture_output=True, text=True, cwd=REPO,
    ).stdout
    return [l.split()[1] for l in out.split("\n") if l.strip()]


def test_the_repo_really_does_hide_submodules_by_default():
    """The premise, asserted rather than assumed.

    If someone removes `ignore = all` this test fails and the fix below becomes
    belt-only — which is worth knowing, because the comment in verify-pr.sh
    explains itself in terms of this setting.
    """
    out = subprocess.run(
        ["git", "config", "--get-regexp", r"submodule\..*\.ignore"],
        capture_output=True, text=True, cwd=REPO,
    ).stdout
    assert "all" in out, (
        "no submodule is set to ignore=all any more — re-read the rationale in "
        "verify-pr.sh, it may now be stale"
    )


def test_a_real_submodule_bump_is_invisible_without_the_flag():
    """Measured against history, not reasoned about.

    This is the defect. If it ever stops reproducing, the flag may be removable
    — but find out from this test rather than by removing it and hoping.
    """
    bump = subprocess.run(
        ["git", "log", "--format=%H", "-20", "--", "ios-audiobooktoolkit"],
        capture_output=True, text=True, cwd=REPO,
    ).stdout.split("\n")[0].strip()
    if not bump:
        pytest.skip("no toolkit bump in recent history")

    def count(extra):
        r = subprocess.run(
            ["git", "diff", "--name-only", *extra, f"{bump}^", bump],
            capture_output=True, text=True, cwd=REPO,
        ).stdout
        return sum(1 for l in r.split("\n") if "ios-audiobooktoolkit" in l)

    assert count([]) == 0, "premise changed: the default diff now shows the bump"
    assert count(["--ignore-submodules=none"]) >= 1, (
        "even --ignore-submodules=none does not show the bump — the fix does not work"
    )


def test_the_changed_file_list_uses_ignore_submodules_none():
    """The producer of every downstream decision must see submodule pointers."""
    m = re.search(r"^ALL_CHANGED=\$\(git diff --name-only([^)]*)\)", source(), re.M)
    assert m, "ALL_CHANGED assignment not found — has it been restructured?"
    assert "--ignore-submodules=none" in m.group(1), (
        "ALL_CHANGED is computed without --ignore-submodules=none, so a "
        "submodule-only PR produces an empty list and takes the docs-only path"
    )


def docs_only_decision(changed: list[str]) -> bool:
    """Run the real docs-only predicate against a changed-file list."""
    text = source()
    start = text.index("  NON_DOCS=$(echo")
    end = text.index("PASS_COUNT=0")
    block = text[start:end]
    assert "NON_DOCS" in block and "DOCS_ONLY=true" in block, \
        "extraction range has drifted"
    # The block starts INSIDE an outer `if`, so it carries that `if`'s closing
    # `fi` and is unbalanced on its own. Open a matching block rather than trim
    # the tail — trimming would silently drop a real line if the range shifts.
    script = (
        "#!/usr/bin/env bash\nDOCS_ONLY=false\n"
        "ALL_CHANGED=$(cat <<'EOF'\n" + "\n".join(changed) + "\nEOF\n)\n"
        + "if true; then\n"
        + block
        + '\necho "DOCS_ONLY=$DOCS_ONLY"\n'
    )
    r = subprocess.run(["bash", "-s"], input=script, capture_output=True,
                       text=True, cwd=REPO)
    return "DOCS_ONLY=true" in r.stdout


def test_a_genuine_docs_only_change_still_takes_the_fast_path():
    """The fast path exists for a reason; breaking it makes every doc PR cost
    25 minutes and the next person deletes the guard."""
    assert docs_only_decision(["README.md", "docs/architecture/thing.md"])


@pytest.mark.parametrize("sub", submodule_paths())
def test_a_submodule_bump_never_takes_the_docs_only_path(sub):
    """Even alongside nothing but documentation.

    This holds because `--ignore-submodules=none` puts the submodule path INTO
    the changed-file list, where it fails the documentation filter. There is no
    separate submodule check — one was written and deleted, because it could
    only fire when the path was present, which is exactly when it was not
    needed. The single guard is the diff flag.
    """
    assert not docs_only_decision([sub]), (
        f"a bump of {sub} alone was treated as a documentation change"
    )
    assert not docs_only_decision(["README.md", sub]), (
        f"a bump of {sub} with a doc edit was treated as documentation-only"
    )


def test_an_empty_changed_list_is_still_docs_only():
    """Control, and a deliberate one: an empty diff with no submodule touched is
    genuinely nothing to verify. If this ever needs to change, it should be a
    decision rather than a side effect of the guard above."""
    assert docs_only_decision([])


def test_a_source_change_never_takes_the_fast_path():
    """Control for the whole predicate — without it, a mutant that always
    returns false would pass every assertion above."""
    assert not docs_only_decision(["Palace/MyBooks/MyBooksDownloadCenter.swift"])
