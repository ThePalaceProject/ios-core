#!/usr/bin/env python3
"""
A submodule bump must not read as a documentation change.

WHY THIS EXISTS (PP-4976). On a checkout where `submodule.<name>.ignore=all` is
set, `git diff --name-only` reports a submodule POINTER BUMP AS NOTHING AT ALL —
measured on a real toolkit bump, the default reports zero lines and
`--ignore-submodules=none` reports one.

THAT SETTING IS LOCAL, NOT COMMITTED, and an earlier version of this file
asserted it as a property of the repo. CI has no such config and the assertion
failed there, which is the correction: eight entries live in this machine's
`.git/config` and none in `.gitmodules`. The defect is therefore CONDITIONAL —
it affects a developer whose clone carries that setting, which is precisely the
population `verify-pr.sh` serves, since it is a local pre-PR check. The fix is
unconditional and harmless either way.

The premise tests below SKIP where the premise does not hold rather than fail,
because a test that encodes its author's machine as fact is the thing that sent
this file to CI red.

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


def ignore_all_configured() -> bool:
    out = subprocess.run(
        ["git", "config", "--get-regexp", r"submodule\..*\.ignore"],
        capture_output=True, text=True, cwd=REPO,
    ).stdout
    return "all" in out


def test_where_ignore_all_is_configured_the_default_diff_hides_the_bump():
    """The premise, asserted where it holds and skipped where it does not.

    `ignore = all` is a LOCAL setting — eight entries in this machine's config,
    none in `.gitmodules`. A fresh CI clone has none, so asserting it
    unconditionally fails there for the right reason and the wrong subject.
    """
    if not ignore_all_configured():
        pytest.skip(
            "no submodule.*.ignore=all in this checkout's config — the hiding "
            "behaviour cannot be observed here. The fix is unconditional; this "
            "test only documents the condition that makes it necessary."
        )
    bump = _recent_toolkit_bump()
    if not bump:
        pytest.skip("no toolkit bump with a parent in this checkout's history")
    assert _count_toolkit_lines(bump, []) == 0, (
        "ignore=all is configured but the default diff still shows the bump — "
        "re-read the rationale in verify-pr.sh, it may now be stale"
    )


def _recent_toolkit_bump() -> str:
    """A commit that moved the toolkit pointer AND has a parent available.

    A shallow CI clone can hold the commit without its parent, in which case
    `bump^` does not resolve and every count comes back zero — which would read
    as "the fix does not work" when the truth is "this clone cannot answer".
    """
    out = subprocess.run(
        ["git", "log", "--format=%H", "-20", "--", "ios-audiobooktoolkit"],
        capture_output=True, text=True, cwd=REPO,
    ).stdout
    for sha in [l.strip() for l in out.split("\n") if l.strip()]:
        has_parent = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", f"{sha}^"],
            capture_output=True, text=True, cwd=REPO,
        ).returncode == 0
        if has_parent:
            return sha
    return ""


def _count_toolkit_lines(bump: str, extra: list[str]) -> int:
    r = subprocess.run(
        ["git", "diff", "--name-only", *extra, f"{bump}^", bump],
        capture_output=True, text=True, cwd=REPO,
    ).stdout
    return sum(1 for l in r.split("\n") if "ios-audiobooktoolkit" in l)


def test_the_flag_shows_the_bump_wherever_history_allows_the_question():
    """The half that must hold everywhere: with the flag, the pointer is visible.

    Deliberately does NOT assert the default hides it — that depends on local
    config, and conflating the two is what turned this file red on CI.
    """
    bump = _recent_toolkit_bump()
    if not bump:
        pytest.skip("no toolkit bump with a parent in this checkout's history")
    assert _count_toolkit_lines(bump, ["--ignore-submodules=none"]) >= 1, (
        "--ignore-submodules=none does not show a known pointer bump — the fix "
        "does not do what it claims"
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
